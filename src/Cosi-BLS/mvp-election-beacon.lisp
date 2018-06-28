
(in-package :cosi-simgen)

;; ---------------------------------------------------------------------------
;; list of (pubkey stake) associations for all witness nodes

(defvar *all-nodes*  nil) 

(defun set-nodes (node-list)
  "NODE-LIST is a list of (public-key stake-amount) pairs"
  (ac:pr (format nil "election set-nodes ~A" node-list))
  (assert node-list)
  (setf *all-nodes* node-list))

(defun get-witness-list ()
  *all-nodes*)

(defun get-witnesses-sans-pkey (pkey)
  (remove pkey (get-witness-list)
          :key  'first
          :test 'int=))

(defun witness-p (pkey)
  (find pkey (get-witness-list)
        :key  'first
        :test 'int=))

;; ---------------------------------------------------------------------------------------
;; Stake-weighted elections

(defclass tree-node ()
  ((l   :reader tree-node-l
        :initarg :l
        :initform nil)
   (r   :reader tree-node-r
        :initarg :r
        :initform nil)
   (sum :reader tree-node-sum
        :initarg :sum))
  (:documentation "Election tree node"))

(defmethod tree-node-p ((x tree-node))
  t)

(defmethod tree-node-p (x)
  nil)

(defmethod node-stake ((node tree-node))
  (tree-node-sum node))

(defmethod node-stake ((node cons))
  (second node))

;; a tree of stakes, cosi-simgen:nodes at the leaves (very bottom of tree)

(defun make-tree-node (pair)
  (destructuring-bind (l &optional r) pair
    (if r
        (make-instance 'tree-node
                       :l  l
                       :r  r
                       :sum (+ (node-stake l)
                               (node-stake r)))
      ;; else
      l)))

(defun hold-election (nfrac &optional (nodes (get-witness-list)))
  "Given a fraction (0 < nfrac < 1) arrange all stakeholders into a
binary decision tree, and determine the node which wins the election,
based on their relative stake"
  (let* ((tree    (car (um:nlet-tail iter ((nodes nodes)) ;; tail recursive, scheme-like, named let
                         (if (= 1 (length nodes))
                             nodes
                           (iter (mapcar 'make-tree-node (um:group nodes 2))))))))
    (when tree
      (um:nlet-tail iter ((tree  tree))                       ;; tail recursive, scheme-like, named let
        (if (tree-node-p tree)
            (let* ((l      (tree-node-l tree))
                   (r      (tree-node-r tree))
                   (lstake  (node-stake l))
                   (tstake  (node-stake tree)))
              (if (< (/ lstake tstake) nfrac)
                    (iter r)
                  (iter l)))
          ;; else - we have arrived at a winner
          (first tree)))))) ;; return pkey of winner

;; --------------------------------------------------------------------------

(defvar *election-central*
  ;; an actor to prevent SMP multiple mutation of seed. Could also use
  ;; a monitor.
  (ac:make-actor
   (let ((seed  nil)) ;; actually okay if never reset
     (lambda (&rest msg)
       (um:dcase msg

         (:next-after-reset (&optional reply-to)
          ;; use a coarse (1 hour) value that we would all likely
          ;; agree upon
          (setf seed (round (get-universal-time) 3600))
          (ac:self-call :next reply-to))
         
         (:next (&optional reply-to)
          (setf seed (hash/256 seed))
          (let ((ans (float (/ (int seed) #.(ash 1 256)) 1d0)))
            (when reply-to
              (send reply-to ans))
            ans))

         (:update-seed (pkey)
          ;; perturb our seed so we don't mindlessly repeat the same
          ;; seed sequence as some other node after a major reset
          (setf seed (hash/256 (uuid:make-v1-uuid) ;; varies with machine and time
                               pkey                ;; varies with node
                               seed)))             ;; based on last seed we generated

         )))))

(defmacro with-election-reply (reply-args msg &body body)
  ;; define convenient continuation interface for actors calling on
  ;; election services for some result
  `(=bind ,reply-args
       (send *election-central* ,msg (lambda (val)
                                       (=values val)))
     ,@body))

(defun update-election-seed (pkey)
  (send *election-central* :update-seed pkey))

;; -----------------------------------------
;; REPL interface...

(defun get-election-seed ()
  (ac:ask *election-central* :next))

(defun reset-and-get-election-seed ()
  (ac:ask *election-central* :next-after-reset))

(defun fire-election () ;; for REPL playing...
  (send-hold-election-from-node *my-node*))

#|
(progn
  (setf *election-seed* nil)
  (let* ((arr (loop repeat 10000 collect (get-election-seed))))
    (plt:histogram 'histo arr :clear t)))

(=bind (seed)
    (send *election-central* :next (lambda (val)
                                     (=values val)))
  (pr seed))
 |#

;; ---------------------------------------------------------------------------

(defun make-election-message-skeleton (pkey seed)
  `(:hold-an-election
       :n      ,seed
       :beacon ,pkey
       :sig))

(defun make-signed-election-message (pkey seed skey)
  (let ((skel (make-election-message-skeleton pkey seed)))
    (um:conc1 skel (pbc:sign-hash (hash/256 skel) skey))))

(defun validate-election-message (n beacon sig)
  (and (or (and (null *beacon*)      ;; it would be nil at startup
                (witness-p beacon))  ;;   from someone we know?
           (int= beacon *beacon*))   ;; or from the beacon we know?
       (let ((skel (make-election-message-skeleton beacon n)))
         (pbc:check-hash (hash/256 skel) sig beacon)))) ;; not a forgery

(defun send-hold-election-from-node (node)
  (with-election-reply (seed) :next
    (with-accessors ((pkey  node-pkey)
                     (skey  node-skey)) node
      (broadcast+me (make-signed-election-message pkey seed skey)))
    ))

;; --------------------------------------------------------------------------
;; Augment message handlers for election process

(defmethod node-dispatcher ((msg-sym (eql :hold-an-election)) &key n beacon sig)
  (if *holdoff*
      (emotiq:note "Election held-off")
    ;; else
    (when (validate-election-message n beacon sig)
      (run-election n))
    ))

(defun run-special-election ()
  ;; try to resync on stalled system
  (let ((node (current-node)))
    (with-election-reply (seed) :next-after-reset
      (with-current-node node
        (run-election seed)))))
   
(defvar *mvp-election-period*  20) ;; seconds between election rounds

(defun run-election (n)
  ;; use the election value n (0 < n < 1) to decide on staked winner
  ;; to become new leader node. Second runner up becomes responsible
  ;; for spawning an election beacon (one-shot).
  ;;
  ;; So election beacon becomes a roving responsibility. If it gets
  ;; knocked out, then we fall back to early elections with BFT
  ;; consensus on decision to resync.
  (let ((self      (current-actor))
        (node      (current-node))
        (witnesses (get-witness-list)))
    
    (with-accessors ((stake       node-stake)
                     (pkey        node-pkey)
                     (local-epoch node-local-epoch)) node

      (update-election-seed pkey)

      (let* ((winner     (hold-election n))
             (new-beacon (hold-election n (get-witnesses-sans-pkey winner))))

        (setf *leader*           winner
              *beacon*           new-beacon
              *local-epoch*      n  ;; unlikely to repeat from election to election
              *election-calls*   nil) ;; reset list of callers for new election
        
        (emotiq:note "~A got :hold-an-election ~A" (short-id node) n)
        (emotiq:note "election results ~A (stake = ~A)"
                     (if (int= pkey winner) " *ME* " " not me ")
                     stake)
        (emotiq:note "winner ~A me=~A"
                     (short-id winner)
                     (short-id pkey))

        (set-holdoff)
        (when (int= pkey new-beacon)
          ;; launch a beacon
          (ac:spawn (lambda ()
                      (recv
                        :TIMEOUT    *mvp-election-period*
                        :ON-TIMEOUT (send-hold-election-from-node node)))))

        (cond ((int= pkey winner)
               ;; why not use ac:self-call?  A: Because doing it with
               ;; send, instead, allows queued up messages to be
               ;; handled first. Might be some transactions waiting to
               ;; enter the pool.
               (send self :become-leader)
               (send self :make-block))

              (t
               ;; ditto
               (send self :become-witness))

              )))))

;; ---------------------------------------------------------------
;; if we don't hold a new election before this timeout, established at
;; the end of commit phase, then call for a new election
(defvar *emergency-timeout*  60)

(defun setup-emergency-call-for-new-election ()
  ;; give the election beacon a chance to do its thing
  (let* ((node      (current-node))
         (old-epoch *local-epoch*))
    (ac:spawn (lambda ()
                (recv
                  :TIMEOUT     *emergency-timeout*
                  :ON-TIMEOUT  (progn
                                 ;; first time processing at startup
                                 ;; go gather keys and stakes.
                                 ;; *local-epoch* will also not have
                                 ;; changed
                                 (unless (get-witness-list)
                                   (let* ((pkeys  (gossip:get-live-uids))
                                          (stakes (gather-stakes pkeys)))
                                     (set-nodes (mapcar 'list pkeys stakes))))
                                 
                                 (when (= *local-epoch* old-epoch) ;; anything changed?
                                   (with-current-node node  ;; guess not...
                                     (call-for-new-election))))
                  ))
              )))

(defun gather-stakes (pkeys)
  ;; return a list of stake amounts corresponding to each pkey in list
  (mapcar (lambda (pkey)
            (declare (ignore pkey))
            (random 1000000))
          pkeys))

;; -----------------------------------------------------------

(defun make-call-for-election-message-skeleton (pkey epoch)
  `(:call-for-new-election
    :pkey  ,pkey
    :epoch ,epoch
    :sig))

(defun make-signed-call-for-election-message (pkey epoch skey)
  (let ((skel  (make-call-for-election-message-skeleton pkey epoch)))
    (um:conc1 skel (pbc:sign-hash (hash/256 skel) skey))))

(defun validate-call-for-election-message (pkey epoch sig)
  (and (= epoch *local-epoch*)        ;; talking about current epoch? not late arrival?
       (witness-p pkey)               ;; from someone we know?
       (not (find pkey *election-calls*  ;; not a repeat call
                  :test 'int=))
       (let ((skel (make-call-for-election-message-skeleton pkey epoch)))
         (pbc:check-hash (hash/256 skel) sig pkey))  ;; not a forgery
       (push pkey *election-calls*)))
  
(defun call-for-new-election ()
  (with-accessors ((pkey  node-pkey)
                   (skey  node-skey)) (current-node)
    (unless (find pkey *election-calls*
                  :test 'int=)
      (push pkey *election-calls*) ;; need this or we'll fail with only 3 nodes...
      (gossip:broadcast (make-signed-call-for-election-message pkey *local-epoch* skey)
                        :graphID :UBER))))

(defmethod node-dispatcher ((msg-sym (eql :call-for-new-election)) &key pkey epoch sig)
  (when (and (validate-call-for-election-message pkey epoch sig) ;; valid call-for-election?
             (>= (length *election-calls*)
                 (* 2/3 (length (get-witness-list)))))
    (run-special-election)))

