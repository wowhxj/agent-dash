;;; agent-dash-queue.el --- Local multimodal delivery queue -*- lexical-binding: t; -*-

;;; Commentary:
;; Pending payloads belong to Emacs, not to a backend queue.  Delivery is a
;; one-way boundary: never edit, withdraw or automatically retry a handed-off
;; message.  Native queues remain separate and read-only.  No disk persistence.

;;; Code:
(require 'agent-dash-core)
(require 'agent-dash-images)
(require 'agent-dash-input)
(require 'tabulated-list)
(require 'hl-line)
(require 'transient)

(defcustom agent-dash-queue-limit 100
  "Maximum retained local queue entries per session."
  :type 'integer :group 'agent-dash)
(defcustom agent-dash-queue-image-limit (* 64 1024 1024)
  "Maximum retained base64 image bytes per local queue."
  :type 'integer :group 'agent-dash)
(defvar agent-dash-queue--sessions nil)
(defvar-local agent-dash-queue--owner nil)
(defvar-local agent-dash-queue--entry-id nil)
(defvar-local agent-dash-queue--saved nil)
(defvar agent-dash-prompt-filter-functions nil)
(defvar agent-dash--session)
(defvar agent-dash--attachments)
(defvar agent-dash--input-start)
(defvar agent-dash--transcript-end)
(defvar agent-dash--input-overlay)
(defvar agent-dash--quitting)
(declare-function agent-dash-mode "agent-dash-ui")
(declare-function agent-dash--input "agent-dash-ui")
(declare-function agent-dash--set-input "agent-dash-ui")
(declare-function agent-dash--decorate-input "agent-dash-ui")
(declare-function agent-dash--insert-composer-separator "agent-dash-ui" (separator))
(declare-function agent-dash--setup-buffer "agent-dash-ui")
(declare-function agent-dash-refresh-chat "agent-dash-ui")
(declare-function agent-dash--on-kill "agent-dash-ui")
(declare-function agent-dash--schedule-answer "agent-dash-ui")

(defun agent-dash-queue-entries (session)
  "Return local entries owned by SESSION, including read-only deliveries."
  (agent-dash-data session :local-queue))
(defun agent-dash-queue-entry (session id)
  "Find SESSION's local entry ID."
  (cl-find id (agent-dash-queue-entries session) :key (lambda (e) (plist-get e :id))
           :test #'equal))
(defun agent-dash-queue-pending (session &optional kind)
  "Return SESSION's pending entries, optionally restricted to KIND."
  (cl-remove-if-not (lambda (e) (and (eq (plist-get e :status) 'pending)
                                     (or (not kind) (eq kind (plist-get e :kind)))))
                    (agent-dash-queue-entries session)))
(defun agent-dash-queue--sent-dsh-steer-p (session entry)
  "Return non-nil for a retained DSH steering receipt in SESSION."
  (and (eq (agent-dash-session-backend session) 'dsh)
       (eq (plist-get entry :kind) 'steer)
       (eq (plist-get entry :status) 'sent)))
(defun agent-dash-queue-managed-p (session)
  "Whether SESSION has pending local work or an outstanding delivery."
  (or (agent-dash-queue-pending session) (agent-dash-data session :queue-inflight)))
(defun agent-dash-queue--editable (session id)
  "Return editable entry ID from SESSION, or signal a user error."
  (let ((entry (agent-dash-queue-entry session id)))
    (unless (eq (plist-get entry :status) 'pending)
      (user-error (concat "Delivery is read-only (%s), not pending. "
                          "RET: view; c: copy failed/unknown to a new draft")
                  (plist-get entry :status)))
    (when (buffer-live-p (plist-get entry :editor))
      (user-error "Finish or cancel this entry's editor first"))
    entry))
(defun agent-dash-queue--payload (session text images &optional replacing)
  "Validate TEXT and IMAGES for SESSION, excluding REPLACING from limits."
  (when (and (string-blank-p text) (not images)) (user-error "Empty queue message"))
  (when (string-prefix-p "/" (string-trim-left text))
    (user-error "Slash commands cannot be stored as queued messages"))
  (when (and images (or (not (agent-dash-capability session :images))
                        (eq (agent-dash-data session :images-supported) :false)))
    (user-error "This backend cannot send images"))
  (let ((bytes 0))
    (when (> (length images) agent-dash-image--max-attachments)
      (user-error "Too many images"))
    (dolist (image images)
      (agent-dash-image-bytes image)
      (cl-incf bytes (length (plist-get image :data))))
    (when (> bytes (* 28 1024 1024)) (user-error "Image message is too large"))
    (dolist (entry (agent-dash-queue-entries session))
      (unless (equal replacing (plist-get entry :id))
        (dolist (image (plist-get entry :images))
          (cl-incf bytes (length (plist-get image :data))))))
    (when (> bytes agent-dash-queue-image-limit) (user-error "Queue image memory limit reached")))
  (let ((agent-dash--session session)
        (default-directory (agent-dash-session-root session)))
    (let ((wire (seq-reduce (lambda (value filter) (funcall filter value))
                            agent-dash-prompt-filter-functions text)))
      (unless (stringp wire) (user-error "A prompt filter did not return text"))
      (list :text text :wire-text wire :images (copy-tree images)))))
(defun agent-dash-queue--dsh-steer-ready-p (session)
  "Whether SESSION can hand a new steer to its active DSH run now."
  (and (eq (agent-dash-session-backend session) 'dsh)
       (eq (agent-dash-session-state session) 'running)
       (buffer-live-p (agent-dash-session-buffer session))
       (not (agent-dash-data session :queue-paused))
       (not (agent-dash-data session :queue-detached))
       (not (agent-dash-session-requests session))))

(defun agent-dash-queue-add (session text images &optional kind)
  "Queue one atomic TEXT plus IMAGES message for SESSION with KIND.
Follow-ups dispatch when idle.  An active, unpaused DSH run takes a steer
immediately.  Other steering entries wait for explicit Apply."
  (setq kind (or kind 'follow-up))
  (unless (memq kind '(follow-up steer)) (user-error "Invalid queue kind"))
  (when (and (eq kind 'steer) (not (agent-dash-capability session :steer)))
    (user-error "This backend cannot steer"))
  (when (>= (length (agent-dash-queue-entries session)) agent-dash-queue-limit)
    ;; Hidden success receipts must not fill the editable queue indefinitely.
    (agent-dash-set-data session :local-queue
                         (cl-remove-if (lambda (e) (eq (plist-get e :status) 'sent))
                                       (agent-dash-queue-entries session))))
  (when (>= (length (agent-dash-queue-entries session)) agent-dash-queue-limit)
    (user-error "Queue full; remove pending items or failed delivery records first"))
  (let ((entry (append (list :id (agent-dash-uuid) :kind kind :status 'pending
                             :editor nil :accepted nil :started nil :ended nil)
                       (agent-dash-queue--payload session text images))))
    (cl-pushnew session agent-dash-queue--sessions :test #'eq)
    (agent-dash-set-data session :local-queue
                         (append (agent-dash-queue-entries session) (list entry)))
    (when (or (not (buffer-live-p (agent-dash-session-buffer session)))
              (eq (agent-dash-session-state session) 'dead))
      (agent-dash-set-data session :queue-paused t)
      (agent-dash-set-data session :queue-detached t))
    (if (and (eq kind 'steer) (agent-dash-queue--dsh-steer-ready-p session))
        (agent-dash-queue-apply session (plist-get entry :id))
      (agent-dash-queue--touch session)
      (agent-dash-queue--schedule session))
    entry))
(defun agent-dash-queue-update (session id text images)
  "Replace unsent entry ID with atomic TEXT and IMAGES in SESSION."
  (let* ((entry (agent-dash-queue--editable session id))
         (payload (agent-dash-queue--payload session text images id)))
    (agent-dash--plist-merge entry payload)
    (agent-dash-queue--touch session)
    entry))
(defun agent-dash-queue-delete (session id)
  "Remove unsent local entry ID from SESSION; never retract a delivery."
  (agent-dash-queue--editable session id)
  (agent-dash-set-data session :local-queue
                       (cl-remove id (agent-dash-queue-entries session)
                                  :key (lambda (e) (plist-get e :id)) :test #'equal))
  (agent-dash-queue--touch session)
  (agent-dash-queue--schedule session))
(defun agent-dash-queue-convert (session id kind)
  "Convert SESSION's entry ID to KIND.
Selecting steer for an active, unpaused DSH session applies it immediately."
  (unless (memq kind '(follow-up steer)) (user-error "Invalid queue kind"))
  (when (and (eq kind 'steer) (not (agent-dash-capability session :steer)))
    (user-error "This backend cannot steer"))
  (plist-put (agent-dash-queue--editable session id) :kind kind)
  (if (and (eq kind 'steer) (agent-dash-queue--dsh-steer-ready-p session))
      (agent-dash-queue-apply session id)
    ;; A staged conversion must not dispatch merely because a timer is pending.
    (agent-dash-set-data session :queue-paused t)
    (agent-dash-queue--touch session)))
(defun agent-dash-queue-move (session id delta)
  "Move SESSION's pending ID by DELTA, crossing the Steer/Follow boundary.
Crossing stages a kind conversion and pauses delivery; it never sends."
  (unless (memq delta '(-1 1)) (user-error "Move one position at a time"))
  (let* ((entry (agent-dash-queue--editable session id))
         (kind (plist-get entry :kind))
         (peers (agent-dash-queue-pending session kind))
         (index (cl-position entry peers :test #'eq))
         (target (+ index delta))
         (entries (copy-sequence (agent-dash-queue-entries session))))
    (if (and (>= target 0) (< target (length peers)))
        (let* ((other (nth target peers))
               (a (cl-position entry entries :test #'eq))
               (b (cl-position other entries :test #'eq)))
          (agent-dash-queue--editable session (plist-get other :id))
          (setf (nth a entries) other (nth b entries) entry))
      (unless (or (and (eq kind 'steer) (= delta 1))
                  (and (eq kind 'follow-up) (= delta -1)))
        (user-error "Queue boundary"))
      (let* ((next-kind (if (eq kind 'steer) 'follow-up 'steer))
             (others (agent-dash-queue-pending session next-kind))
             (other (if (eq next-kind 'follow-up) (car others) (car (last others)))))
        (when (and (eq next-kind 'steer) (not (agent-dash-capability session :steer)))
          (user-error "This backend cannot steer"))
        (when other (agent-dash-queue--editable session (plist-get other :id)))
        (setq entries (delq entry entries))
        (let ((position (if other
                            (+ (cl-position other entries :test #'eq)
                               (if (eq next-kind 'steer) 1 0))
                          (if (eq next-kind 'steer) 0 (length entries)))))
          (setq entries (append (cl-subseq entries 0 position) (list entry)
                                (nthcdr position entries))))
        (plist-put entry :kind next-kind)
        (agent-dash-set-data session :queue-paused t)))
    (agent-dash-set-data session :local-queue entries)
    (agent-dash-queue--touch session)))
(defun agent-dash-queue-pause (session)
  "Pause SESSION's local follow-up dispatcher."
  (agent-dash-set-data session :queue-paused t)
  (agent-dash-queue--touch session))
(defun agent-dash-queue-continue (session)
  "Explicitly resume SESSION's unsent follow-ups; never retry deliveries."
  (when (or (eq (agent-dash-session-state session) 'dead)
            (not (buffer-live-p (agent-dash-session-buffer session)))
            (agent-dash-data session :queue-detached))
    (user-error "Reconnect the chat first, then continue the queue"))
  (agent-dash-set-data session :queue-paused nil)
  (agent-dash-queue--touch session)
  (agent-dash-queue--schedule session))
(defun agent-dash-queue--touch (session)
  "Notify chat and queue views of a local change to SESSION."
  (agent-dash-emit session '(:type local-queue))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (eq major-mode 'agent-dash-queue-mode) (eq agent-dash-queue--owner session))
        (agent-dash-queue--render)))))
(defun agent-dash-queue--schedule (session)
  "Schedule a non-reentrant follow-up check for SESSION."
  (unless (timerp (agent-dash-data session :queue-timer))
    (agent-dash-set-data session :queue-timer
                         (run-at-time 0 nil #'agent-dash-queue--pump session))))
(defun agent-dash-queue--pump (session)
  "Hand off at most one idle follow-up for SESSION."
  (agent-dash-set-data session :queue-timer nil)
  (let ((entry (car (agent-dash-queue-pending session 'follow-up)))
        (native (agent-dash-session-queue session)))
    (when (and entry (not (buffer-live-p (plist-get entry :editor)))
               (not (agent-dash-data session :queue-paused))
               (not (agent-dash-data session :queue-inflight))
               (not (agent-dash-data session :queue-detached))
               (not (agent-dash-data session :pi-native-pending))
               (buffer-live-p (agent-dash-session-buffer session))
               (eq (agent-dash-session-state session) 'idle)
               (not (agent-dash-session-requests session))
               (not (plist-get native :steering)) (not (plist-get native :follow-up)))
      (agent-dash-queue--dispatch session entry 'prompt))))
(defun agent-dash-queue-apply (session id)
  "Explicitly inject pending steer ID into SESSION's current run."
  (let ((entry (agent-dash-queue--editable session id)))
    (unless (eq (plist-get entry :kind) 'steer) (user-error "Apply selects a steering entry"))
    (unless (agent-dash-capability session :steer) (user-error "This backend cannot steer"))
    (unless (and (buffer-live-p (agent-dash-session-buffer session))
                 (not (agent-dash-data session :queue-detached))
                 (eq (agent-dash-session-state session) 'running))
      (user-error "No connected running task to steer"))
    (when (agent-dash-session-requests session) (user-error "Answer the pending dialog first"))
    (if (eq (agent-dash-session-backend session) 'dsh)
        ;; DSH acknowledges the steer RPC independently of the turn it steers.
        ;; Leave the follow-up that owns this turn in the normal inflight slot.
        (let ((sending (agent-dash-data session :queue-sending)))
          (plist-put entry :status 'sending)
          (agent-dash-queue--touch session)
          (condition-case nil
              (progn
                (agent-dash-set-data session :queue-sending id)
                (unwind-protect
                    (agent-dash-backend-send 'dsh session (plist-get entry :wire-text)
                                             (plist-get entry :images) 'steer)
                  (agent-dash-set-data session :queue-sending sending))
                (plist-put entry :accepted t)
                (plist-put entry :ended t)
                (agent-dash-queue--finish session entry))
            (error (agent-dash-queue--fail session entry 'unknown))
            (quit (agent-dash-queue--fail session entry 'unknown)
                  (signal 'quit nil))))
      (when (agent-dash-data session :queue-inflight)
        (user-error "Wait for the outstanding delivery first"))
      (agent-dash-queue--dispatch session entry 'steer))))
(defun agent-dash-queue--dispatch (session entry mode)
  "Cross the one-way delivery boundary for ENTRY of SESSION using MODE."
  (let* ((id (plist-get entry :id))
         (backend (agent-dash-session-backend session))
         (image-token (agent-dash-data session :image-draft-token)))
    (plist-put entry :status 'sending)
    (plist-put entry :started (and (eq mode 'steer) (not (eq backend 'claude))))
    (agent-dash-set-data session :queue-inflight id)
    (agent-dash-set-data session :queue-claude-uuid nil)
    (agent-dash-set-data session :queue-claude-started nil)
    (agent-dash-set-data session :queue-sending id)
    (agent-dash-set-data session :image-draft-token nil)
    (agent-dash-queue--touch session)
    (unwind-protect
        (condition-case nil
            (progn
              (agent-dash-backend-send backend session (plist-get entry :wire-text)
                                       (plist-get entry :images) mode)
              ;; These adapters provide a correlated protocol acknowledgement.
              (unless (memq backend '(pi claude codex hermes agy))
                (agent-dash-delivery-result session id t)))
          (error (agent-dash-queue--fail session entry 'unknown))
          (quit (agent-dash-queue--fail session entry 'unknown)
                (signal 'quit nil)))
      (agent-dash-set-data session :queue-sending nil)
      (agent-dash-set-data session :image-draft-token image-token))))
(defun agent-dash-queue--fail (session entry status)
  "Freeze ENTRY as STATUS and pause SESSION without retrying anything."
  (plist-put entry :status status)
  (when (equal (plist-get entry :id) (agent-dash-data session :queue-inflight))
    (agent-dash-set-data session :queue-inflight nil))
  (agent-dash-set-data session :queue-paused t)
  (agent-dash-queue--touch session))
(defun agent-dash-queue--finish (session entry)
  "Close SESSION's ENTRY only after acknowledgement and run completion."
  (when (and (plist-get entry :accepted) (plist-get entry :ended))
    (plist-put entry :status 'sent)
    (plist-put entry :image-count (length (plist-get entry :images)))
    ;; Successful deliveries keep lightweight read-only receipts, not blobs.
    (plist-put entry :images nil)
    (when (equal (plist-get entry :id) (agent-dash-data session :queue-inflight))
      (agent-dash-set-data session :queue-inflight nil))
    (agent-dash-queue--touch session)
    (agent-dash-queue--schedule session)))
(defun agent-dash-queue--event (session event)
  "Observe authoritative run and correlated delivery EVENT for SESSION."
  (let* ((id (agent-dash-data session :queue-inflight))
         (entry (and id (agent-dash-queue-entry session id))))
    (pcase (plist-get event :type)
      ('delivery
       (when (and entry (equal id (plist-get event :queue-id)))
         (if (plist-get event :accepted)
             (progn (plist-put entry :accepted t)
                    (when (plist-get event :started)
                      (plist-put entry :started t)
                      (agent-dash-set-data session :queue-claude-started t))
                    (plist-put entry :status 'accepted)
                    (agent-dash-queue--finish session entry)
                    (agent-dash-queue--touch session))
           (agent-dash-queue--fail session entry 'failed))))
      ('user
       (when (and entry (eq (agent-dash-session-backend session) 'claude)
                  (equal (plist-get event :id) (agent-dash-data session :queue-claude-uuid)))
         (agent-dash-delivery-result session id t t)))
      ('run
       (unless (eq (plist-get event :state) 'dead)
         (agent-dash-set-data session :queue-detached nil))
       (pcase (plist-get event :state)
         ('running (when (and entry (not (eq (agent-dash-session-backend session) 'claude)))
                     (plist-put entry :started t)))
         ('idle (when (and entry (plist-get entry :started))
                  (plist-put entry :ended t)
                  (agent-dash-queue--finish session entry))
                (when (agent-dash-queue-pending session) (agent-dash-queue--schedule session)))
         ('dead (when (agent-dash-queue-managed-p session)
                  (agent-dash-queue-disconnect session)))))
      ('queue
       (agent-dash-queue--touch session)
       (when (agent-dash-queue-pending session) (agent-dash-queue--schedule session)))
      ((or 'request-done 'meta 'notice)
       (when (agent-dash-queue-pending session) (agent-dash-queue--schedule session))))))
(defun agent-dash-queue-disconnect (session)
  "Pause SESSION on detach; preserve pending images and uncertain deliveries."
  (when-let* ((timer (agent-dash-data session :queue-timer))) (cancel-timer timer))
  (agent-dash-set-data session :queue-timer nil)
  (agent-dash-set-data session :queue-detached t)
  (agent-dash-set-data session :queue-paused t)
  (when-let* ((id (agent-dash-data session :queue-inflight))
              (entry (agent-dash-queue-entry session id)))
    (agent-dash-queue--fail session entry 'unknown))
  (agent-dash-queue--touch session))

;;;; Queue view and isolated multimodal editor
(defun agent-dash-queue--close-view (&optional kill)
  "Close this view's windows in the current frame, optionally KILL its buffer.
Do not close anything if killing is declined, and never delete the last window."
  (let* ((buffer (current-buffer))
         (windows (get-buffer-window-list buffer nil (selected-frame))))
    (when (or (not kill) (kill-buffer buffer))
      (dolist (window windows)
        (when (window-live-p window)
          (if (one-window-p t)
              (unless kill (quit-window nil window))
            (delete-window window))))
      (when (and (not kill) (buffer-live-p buffer)) (bury-buffer buffer)))))

(defun agent-dash-queue-quit ()
  "Close the queue window without deleting queued messages."
  (interactive)
  (agent-dash-queue--close-view t))

(defvar agent-dash-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (dolist (binding '(("e" . agent-dash-queue-edit) ("RET" . agent-dash-queue-view)
                       ("a" . agent-dash-queue-new) ("c" . agent-dash-queue-copy)
                       ("d" . agent-dash-queue-remove)
                       ("f" . agent-dash-queue-follow) ("s" . agent-dash-queue-steer)
                       ("M-<up>" . agent-dash-queue-up) ("M-<down>" . agent-dash-queue-down)
                       ("x" . agent-dash-queue-send-steer) ("P" . agent-dash-queue-stop)
                       ("n" . agent-dash-queue-next) ("p" . agent-dash-queue-previous)
                       ("M-n" . agent-dash-queue-down) ("M-p" . agent-dash-queue-up)
                       ("SPC" . agent-dash-queue-toggle-pause) ("?" . agent-dash-queue-help)
                       ("r" . agent-dash-queue-resume) ("D" . agent-dash-queue-forget)
                       ("o" . agent-dash-queue-chat) ("g" . agent-dash-queue--render)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))
(define-key agent-dash-queue-mode-map (kbd "q") #'agent-dash-queue-quit)
(define-derived-mode agent-dash-queue-mode tabulated-list-mode "Agent Queue"
  "Manage unsent local messages, separately from read-only deliveries."
  (setq tabulated-list-format [("Message" 0 nil)]
        tabulated-list-padding 2 tabulated-list-sort-key nil)
  (setq-local mode-line-format
              (list (concat " a add · f/s type · x apply"
                            " · SPC pause/resume · r continue · q close ")))
  (tabulated-list-init-header)
  (hl-line-mode 1))
;;;###autoload
(defun agent-dash-queue (&optional session)
  "Open SESSION's local multimodal queue, or select a retained queue."
  (interactive)
  (setq session (or session agent-dash-queue--owner
                    (and (boundp 'agent-dash--session) agent-dash--session)
                    (let* ((choices (mapcar (lambda (s)
                                              (cons (format "%s %s [%s]"
                                                            (agent-dash-session-backend s)
                                                            (agent-dash-session-root s)
                                                            (agent-dash-session-id s)) s))
                                            agent-dash-queue--sessions)))
                      (cdr (assoc (completing-read "Queue: " choices nil t) choices)))))
  (unless session (user-error "No queue session"))
  (let ((buffer (get-buffer-create (format "*agent-queue:%s*" (agent-dash-session-id session)))))
    (with-current-buffer buffer
      (agent-dash-queue-mode)
      (setq agent-dash-queue--owner session)
      (setq-local default-directory (agent-dash-session-root session))
      (agent-dash-queue--render))
    (agent-dash-pop-to-buffer buffer)))
(defun agent-dash-queue--render ()
  "Render pending Steer/Follow groups and separate read-only deliveries."
  (interactive)
  (let* ((session agent-dash-queue--owner)
         (id (tabulated-list-get-id))
         (entries (cl-remove-if (lambda (e)
                                  (and (eq (plist-get e :status) 'sent)
                                       (not (agent-dash-queue--sent-dsh-steer-p session e))))
                                (agent-dash-queue-entries session)))
         (native (agent-dash-session-queue session))
         (inhibit-read-only t))
    (setq header-line-format
          (propertize (format (concat " Queue · %s │ n/p select · M-n/p move"
                                      " · e edit · d delete · ? help")
                              (if (agent-dash-data session :queue-paused) "Paused" "Auto follow"))
                      'help-echo
                      "Memory only: closing the chat pauses delivery; Emacs exit discards it."))
    (erase-buffer)
    (setq tabulated-list-entries nil)
    (dolist (kind '(steer follow-up deliveries))
      (let ((group (if (eq kind 'deliveries)
                       (cl-remove-if (lambda (e) (eq (plist-get e :status) 'pending)) entries)
                     (agent-dash-queue-pending session kind))))
        (when (and (eq kind 'deliveries) (not (agent-dash-queue-pending session)))
          (insert (propertize "No local pending messages.\n\n" 'face 'shadow)))
        (when (or group (not (eq kind 'deliveries)))
          (insert (propertize
                   (format "%s (%d)\n"
                           (pcase kind
                             ('steer "Steer") ('follow-up "Follow")
                             (_ "Deliveries · read-only"))
                           (length group))
                   'face 'bold 'agent-dash-queue-heading kind))
          (dolist (entry group)
            (let* ((status (plist-get entry :status))
                   (images (or (plist-get entry :image-count) (length (plist-get entry :images))))
                   (summary (replace-regexp-in-string "[\n\r\t]+" " " (plist-get entry :text)))
                   (row (vector
                         (concat (if (eq status 'pending)
                                     (when (buffer-live-p (plist-get entry :editor)) "[editing] ")
                                   (format "[%s · %s] " status
                                           (if (eq (plist-get entry :kind) 'steer)
                                               "Steer" "Follow")))
                                 (truncate-string-to-width summary 100 nil nil "…")
                                 (when (> images 0) (format "  [%d image%s]" images
                                                            (if (= images 1) "" "s")))))))
              (push (list (plist-get entry :id) row) tabulated-list-entries)
              (tabulated-list-print-entry (plist-get entry :id) row)))
          (insert "\n"))))
    (setq tabulated-list-entries (nreverse tabulated-list-entries))
    (when (or (plist-get native :steering) (plist-get native :follow-up))
      (insert (propertize "Backend · read-only\n" 'face 'shadow))
      (dolist (kind '(:steering :follow-up))
        (dolist (entry (plist-get native kind))
          (let ((text (agent-dash-queue--native-text entry)))
            (insert (propertize
                     (concat "  " (if (eq kind :steering) "S · " "F · ")
                             (truncate-string-to-width
                              (replace-regexp-in-string "[\n\r\t]+" " " text) 100 nil nil "…")
                             "\n")
                     'agent-dash-native-text text 'face 'shadow))))))
    (goto-char (point-min))
    (while (and (not (eobp)) (not (equal id (tabulated-list-get-id)))) (forward-line 1))
    (unless (tabulated-list-get-id)
      (goto-char (point-min))
      (while (and (not (eobp)) (not (tabulated-list-get-id))) (forward-line 1))
      (when (eobp) (goto-char (point-min))))))
(defun agent-dash-queue--step (delta)
  "Move DELTA lines, skipping group headings and non-message lines."
  (let ((start (point)))
    (forward-line delta)
    (while (and (not (bobp)) (not (eobp)) (not (tabulated-list-get-id)))
      (forward-line delta))
    (unless (tabulated-list-get-id) (goto-char start))))
(defun agent-dash-queue-next ()
  "Select the next local queue message."
  (interactive) (agent-dash-queue--step 1))
(defun agent-dash-queue-previous ()
  "Select the previous local queue message."
  (interactive) (agent-dash-queue--step -1))
(defun agent-dash-queue-toggle-pause ()
  "Toggle automatic follow-up delivery without applying steering."
  (interactive)
  (if (agent-dash-data agent-dash-queue--owner :queue-paused)
      (agent-dash-queue-continue agent-dash-queue--owner)
    (agent-dash-queue-pause agent-dash-queue--owner)))
(defun agent-dash-queue-safety-help ()
  "Show detailed queue controls and delivery safety information."
  (interactive)
  (with-help-window "*agent-queue-help*"
    (princ (concat
            "Queue\n\n"
            "n / p       Select next / previous message\n"
            "M-n / M-p   Move down / up; cross Steer/Follow at the boundary\n"
            "e / a       Edit / add a text-and-image message\n"
            "RET         View a message\n"
            "d           Delete an unsent message\n"
            "f / s       Convert to follow / steer (active unpaused DSH applies steer now)\n"
            "x           Apply the selected steering message\n"
            "SPC         Toggle automatic follow-up delivery\n"
            "P / r       Pause / continue follow-ups\n"
            "c           Recover failed/unknown payload into a NEW paused draft\n"
            "D           Forget a failed/unknown receipt, not its delivery\n"
            "o / g / q   Owner chat / redraw / close view\n\n"
            "Sent receipts are hidden. Handed-off entries are read-only.\n"
            "Moving across groups pauses delivery and never sends a message.\n"
            "Editing holds the head entry; later follow-ups cannot overtake it.\n"
            "Memory only: closing a chat pauses its queue; Emacs exit discards it.\n"))))
(transient-define-prefix agent-dash-queue-help ()
  "Operate the queue through a transient menu without submitting anything on open."
  ["Queue · Steer → Follow"
   ["导航与顺序"
    ("n" "下一条" agent-dash-queue-next :transient t)
    ("p" "上一条" agent-dash-queue-previous :transient t)
    ("M-n" "下移 / 降为 Follow" agent-dash-queue-down :transient t)
    ("M-p" "上移 / 升为 Steer" agent-dash-queue-up :transient t)
    ("g" "刷新" agent-dash-queue--render :transient t)]
   ["图文消息"
    ("RET" "查看" agent-dash-queue-view)
    ("e" "编辑" agent-dash-queue-edit)
    ("a" "新建" agent-dash-queue-new)
    ("d" "删除待发项" agent-dash-queue-remove :transient t)
    ("c" "恢复为新草稿" agent-dash-queue-copy)
    ("D" "清理失败回执" agent-dash-queue-forget :transient t)]
   ["类型与发送"
    ("f" "暂存为 Follow" agent-dash-queue-follow :transient t)
    ("s" "转为 Steer（DSH 运行中且未暂停时立即发送）" agent-dash-queue-steer :transient t)
    ("x" "应用选中 Steer" agent-dash-queue-send-steer)
    ("SPC" "切换自动发送" agent-dash-queue-toggle-pause :transient t)
    ("P" "暂停 Follow" agent-dash-queue-stop :transient t)
    ("r" "继续 Follow" agent-dash-queue-resume :transient t)]
   ["其他"
    ("o" "所属聊天" agent-dash-queue-chat)
    ("h" "完整说明" agent-dash-queue-safety-help)
    ("q" "关闭菜单" transient-quit-one)]]
  (interactive)
  (unless (derived-mode-p 'agent-dash-queue-mode) (user-error "Open the queue first"))
  (transient-setup 'agent-dash-queue-help))

(defun agent-dash-queue--native-text (entry)
  "Return disclosed text of native ENTRY, without formatting image blobs."
  (or (and (stringp entry) entry)
      (let ((text (or (agent-dash-jget entry "text") (agent-dash-jget entry "message"))))
        (and (stringp text) text))
      "(Backend did not provide message details)"))
(defun agent-dash-queue--selected ()
  "Return the stable ID selected in the queue view."
  (or (tabulated-list-get-id) (user-error "No local message on this line")))
(defun agent-dash-queue-remove ()
  "Delete the selected unsent message."
  (interactive)
  (agent-dash-queue-delete agent-dash-queue--owner (agent-dash-queue--selected)))
(defun agent-dash-queue-follow ()
  "Stage the selected entry as a follow-up and pause automatic delivery."
  (interactive)
  (agent-dash-queue-convert agent-dash-queue--owner (agent-dash-queue--selected) 'follow-up))
(defun agent-dash-queue-steer ()
  "Select steering, applying it immediately to an active, unpaused DSH run."
  (interactive)
  (agent-dash-queue-convert agent-dash-queue--owner (agent-dash-queue--selected) 'steer))
(defun agent-dash-queue-up ()
  "Move up, promoting the first follow-up to the end of steering."
  (interactive)
  (agent-dash-queue-move agent-dash-queue--owner (agent-dash-queue--selected) -1))
(defun agent-dash-queue-down ()
  "Move down, demoting the last steer to the front of follow-ups."
  (interactive)
  (agent-dash-queue-move agent-dash-queue--owner (agent-dash-queue--selected) 1))
(defun agent-dash-queue-send-steer ()
  "Apply exactly the selected steering entry, preserving its images."
  (interactive)
  (agent-dash-queue-apply agent-dash-queue--owner (agent-dash-queue--selected)))
(defun agent-dash-queue-stop ()
  "Pause local automatic follow-up delivery."
  (interactive) (agent-dash-queue-pause agent-dash-queue--owner))
(defun agent-dash-queue-resume ()
  "Continue unsent follow-ups after checking the connection."
  (interactive) (agent-dash-queue-continue agent-dash-queue--owner))
(defun agent-dash-queue-forget ()
  "Forget a read-only receipt, without retracting or resending anything."
  (interactive)
  (let* ((session agent-dash-queue--owner) (id (agent-dash-queue--selected))
         (entry (agent-dash-queue-entry session id)))
    (when (or (eq (plist-get entry :status) 'pending)
              (equal id (agent-dash-data session :queue-inflight)))
      (user-error "Use d for pending entries; outstanding deliveries cannot be forgotten"))
    (when (yes-or-no-p "Forget this receipt (does not cancel or resend the message)? ")
      (agent-dash-set-data session :local-queue (delq entry (agent-dash-queue-entries session)))
      (agent-dash-queue--touch session))))
(defun agent-dash-queue-chat ()
  "Show the owner chat without reconnecting or starting a task."
  (interactive)
  (let* ((session agent-dash-queue--owner) (buffer (agent-dash-session-buffer session)))
    (unless (buffer-live-p buffer)
      (setf (agent-dash-session-state session) 'dead)
      (setq buffer (agent-dash--setup-buffer session))
      (with-current-buffer buffer (agent-dash-refresh-chat)))
    (agent-dash-pop-to-buffer buffer)))
(defun agent-dash-queue-view ()
  "Read a selected local or native message without making it editable."
  (interactive)
  (let* ((native (get-text-property (point) 'agent-dash-native-text))
         (entry (if native (list :text native :kind 'native :status 'backend)
                  (agent-dash-queue-entry agent-dash-queue--owner (agent-dash-queue--selected)))))
    (agent-dash-select-tab)
    (with-help-window "*agent-queue-message*"
      (princ (format "%s · %s · images: %s\n\n%s"
                     (plist-get entry :kind) (plist-get entry :status)
                     (if native "not reported"
                       (number-to-string
                        (or (plist-get entry :image-count) (length (plist-get entry :images)))))
                     (plist-get entry :text)))
      (when (plist-get entry :images)
        (with-current-buffer standard-output
          (insert "\n\n" (agent-dash-images-string (plist-get entry :images))))))))
(defvar agent-dash-queue-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c ?") #'agent-dash-queue-edit-help)
    (define-key map (kbd "C-c C-c") #'agent-dash-queue-edit-save)
    (define-key map (kbd "C-y") #'agent-dash-paste)
    (define-key map (kbd "s-v") #'agent-dash-paste-image)
    (define-key map (kbd "C-c C-v") #'agent-dash-paste-image)
    (define-key map (kbd "C-c C-f") #'agent-dash-attach-image)
    (define-key map (kbd "C-c C-d") #'agent-dash-remove-image)
    (define-key map (kbd "C-c C-o") #'agent-dash-open-image-external)
    map))
(define-key agent-dash-queue-edit-mode-map (kbd "C-c C-q") nil)
(define-key agent-dash-queue-edit-mode-map (kbd "C-c C-k") #'agent-dash-queue-edit-cancel)
(transient-define-prefix agent-dash-queue-edit-help ()
  "Edit a queued message's text and images without sending it."
  ["Queue message editor · changes apply only on save"
   ["图片附件"
    ("a" "新增图片文件 (C-c C-f)" agent-dash-attach-image :transient t)
    ("v" "粘贴图片 (s-v / C-c C-v)" agent-dash-paste-image :transient t)
    ("d" "删除图片 (C-c C-d)" agent-dash-remove-image :transient t)
    ("o" "系统图片程序打开 (C-c C-o)" agent-dash-open-image-external :transient t)]
   ["编辑结果"
    ("s" "保存文字和图片 (C-c C-c)" agent-dash-queue-edit-save)
    ("q" "取消，不改原消息 (C-c C-k)" agent-dash-queue-edit-cancel)]])

(defconst agent-dash-queue--editor-header
  (concat "Queue editor · C-c C-f add image · C-c C-d remove image"
          " · s-v paste image · C-c C-o open externally"
          " · C-c C-c save · C-c C-k cancel · C-c ? help")
  "Attachment and save controls for an isolated queue editor.")

(define-derived-mode agent-dash-queue-edit-mode agent-dash-mode "Queue Edit"
  "Edit an isolated queue message with the shared image composer."
  ;; Do not inherit any backend-send/quit/model command from the live chat.
  (set-keymap-parent agent-dash-queue-edit-mode-map text-mode-map)
  (use-local-map agent-dash-queue-edit-mode-map))
(defun agent-dash-queue-edit ()
  "Open an isolated editor and hold the selected pending message."
  (interactive)
  (agent-dash-queue--edit agent-dash-queue--owner (agent-dash-queue--selected)))
(defun agent-dash-queue-new ()
  "Compose a new follow-up; nothing is queued until saved."
  (interactive) (agent-dash-queue--edit agent-dash-queue--owner nil))
(defun agent-dash-queue-copy ()
  "Recover a failed or uncertain payload into a NEW draft, keeping delivery paused."
  (interactive)
  (let* ((session agent-dash-queue--owner)
         (entry (agent-dash-queue-entry session (agent-dash-queue--selected))))
    (unless (memq (plist-get entry :status) '(failed unknown))
      (user-error "Copy recovery is only for failed or unknown deliveries"))
    (agent-dash-queue-pause session)
    (let ((buffer (agent-dash-queue--edit session nil)))
      (with-current-buffer buffer
        (setq agent-dash--attachments (copy-tree (plist-get entry :images)))
        (agent-dash--set-input (plist-get entry :text))
        (agent-dash--decorate-input)
        (setq header-line-format
              (concat "Recovered NEW draft · may already have executed · "
                      agent-dash-queue--editor-header)))
      buffer)))
(defun agent-dash-queue--edit (session id)
  "Open an isolated composer for SESSION's entry ID, or a new message."
  (let* ((entry (and id (agent-dash-queue--editable session id)))
         (buffer (generate-new-buffer "*agent-queue-edit*"))
         (copy (copy-agent-dash-session session)))
    (setf (agent-dash-session-buffer copy) buffer
          (agent-dash-session-state copy) 'idle
          (agent-dash-session-data copy)
          (list :images-supported (agent-dash-data session :images-supported))
          (agent-dash-session-requests copy) nil)
    (with-current-buffer buffer
      (agent-dash-queue-edit-mode)
      (remove-hook 'kill-buffer-hook #'agent-dash--on-kill t)
      (remove-hook 'post-command-hook #'agent-dash--schedule-answer t)
      (setq-local tab-line-format nil)
      (setq-local agent-dash--session copy)
      (setq-local agent-dash-queue--owner session)
      (setq-local default-directory (agent-dash-session-root session))
      (setq-local agent-dash-queue--entry-id id)
      (setq-local header-line-format agent-dash-queue--editor-header)
      (setq-local mode-line-format '(" Queue edit (not sent)"))
      (agent-dash--insert-composer-separator "\n")
      (setq-local agent-dash--input-start (copy-marker (point-max)))
      (setq-local agent-dash--transcript-end (copy-marker (point-min)))
      (setq-local agent-dash--attachments (copy-tree (plist-get entry :images)))
      (agent-dash--set-input (or (plist-get entry :text) ""))
      (agent-dash--decorate-input)
      (add-hook 'kill-buffer-hook #'agent-dash-queue--editor-killed nil t)
      (add-hook 'change-major-mode-hook #'agent-dash-queue--editor-mode-change nil t)
      (add-hook 'kill-buffer-query-functions #'agent-dash-queue--editor-query nil t)
      (set-buffer-modified-p nil))
    (when entry (plist-put entry :editor buffer))
    (agent-dash-queue--touch session)
    (agent-dash-pop-to-buffer buffer)
    buffer))
(defun agent-dash-queue--editor-query ()
  "Confirm abandoning edits, including image-only changes."
  (or agent-dash-queue--saved
      (yes-or-no-p "Discard editor draft (queued message stays unchanged)? ")))
(defun agent-dash-queue--editor-mode-change ()
  "Release an editor lease safely if the buffer changes major mode."
  (agent-dash-queue-pause agent-dash-queue--owner)
  (agent-dash-queue--editor-killed))
(defun agent-dash-queue--editor-killed ()
  "Release the edit lease without detaching any backend."
  (when (overlayp agent-dash--input-overlay) (delete-overlay agent-dash--input-overlay))
  (when-let* ((entry (agent-dash-queue-entry agent-dash-queue--owner agent-dash-queue--entry-id)))
    (when (eq (plist-get entry :editor) (current-buffer)) (plist-put entry :editor nil)))
  (agent-dash-queue--touch agent-dash-queue--owner)
  (agent-dash-queue--schedule agent-dash-queue--owner))
(defun agent-dash-queue-edit-save ()
  "Atomically save this editor's text and images without touching the live draft."
  (interactive)
  (let* ((session agent-dash-queue--owner)
         (entry (and agent-dash-queue--entry-id
                     (agent-dash-queue-entry session agent-dash-queue--entry-id)))
         (text (string-trim (agent-dash--input)))
         (payload (agent-dash-queue--payload session text agent-dash--attachments
                                             agent-dash-queue--entry-id)))
    (if agent-dash-queue--entry-id
        (progn
          (unless (and (eq (plist-get entry :status) 'pending)
                       (eq (plist-get entry :editor) (current-buffer)))
            (user-error "The queue entry changed; this editor cannot overwrite it"))
          (agent-dash--plist-merge entry payload))
      (agent-dash-queue-add session text agent-dash--attachments 'follow-up))
    (setq agent-dash-queue--saved t)
    (agent-dash-queue--close-view t)))
(defun agent-dash-queue-edit-cancel ()
  "Close this isolated editor, preserving the original queue message."
  (interactive) (agent-dash-queue--close-view t))

(add-hook 'agent-dash-event-functions #'agent-dash-queue--event)
(provide 'agent-dash-queue)
;;; agent-dash-queue.el ends here
