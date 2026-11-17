;;; agent-dash-notify.el --- Adaptive run notifications -*- lexical-binding: t; -*-

;;; Commentary:

;; Observe unified lifecycle events, not individual assistant/tool messages.
;; Defer delivery outside process filters and let automatic follow-ups settle.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-queue)

(defvar agent-dash--sessions nil)

(declare-function agent-dash--backend-name "agent-dash-ui" (backend))
(declare-function notifications-notify "notifications" (&rest params))

(defcustom agent-dash-notify t
  "Whether background chats notify when a live run ends.
Use the echo area within Emacs and desktop notifications outside Emacs.
Desktop delivery failures fall back to the echo area.  Notifications contain
only the backend, project and short session ID, never conversation text."
  :type 'boolean
  :group 'agent-dash)

(defun agent-dash-notify--clear (session)
  "Discard pending notification and timer for SESSION."
  (when-let* ((timer (agent-dash-data session :notify-timer)))
    (cancel-timer timer))
  (agent-dash-set-data session :notify-timer nil)
  (agent-dash-set-data session :notify-pending nil))

(defun agent-dash-notify--schedule (session)
  "Defer SESSION's pending notification, without duplicate timers."
  (unless (agent-dash-data session :notify-timer)
    (agent-dash-set-data session :notify-timer
                         (run-at-time 0.2 nil #'agent-dash-notify--deliver session))))

(defun agent-dash-notify--focused-frame ()
  "Return a focused frame, treating unknown focus conservatively."
  (or (seq-find (lambda (frame) (eq (frame-focus-state frame) t)) (frame-list))
      (when (eq (frame-focus-state) 'unknown) (selected-frame))))

(defun agent-dash-notify--targets (kind)
  "Return live chat sessions with pending requests or unread ends of KIND."
  (seq-filter
   (lambda (session)
     (and (buffer-live-p (agent-dash-session-buffer session))
          (if (eq kind 'request) (agent-dash-session-requests session)
            (agent-dash-data session :notify-unread))))
   agent-dash--sessions))

(defun agent-dash-notify--seen (&rest _)
  "Acknowledge completion in the focused, selected chat, never its requests."
  (when-let* ((frame (agent-dash-notify--focused-frame))
              (buffer (window-buffer (frame-selected-window frame))))
    (dolist (session agent-dash--sessions)
      (when (and (eq buffer (agent-dash-session-buffer session))
                 (or (agent-dash-data session :notify-unread)
                     (agent-dash-data session :notify-pending)))
        (agent-dash-set-data session :notify-unread nil)
        (agent-dash-notify--clear session)
        (force-mode-line-update t)))))

(defun agent-dash-notify--show (kind)
  "Switch to the next session needing attention of KIND."
  (when (mouse-event-p last-input-event)
    (let ((window (posn-window (event-start last-input-event))))
      (when (window-live-p window) (select-window window))))
  (let* ((targets (agent-dash-notify--targets kind))
         (current (seq-find (lambda (session)
                              (eq (agent-dash-session-buffer session)
                                  (window-buffer (selected-window)))) targets))
         (target (or (cadr (memq current targets)) (car targets))))
    (unless target (user-error "No agent chats need attention"))
    (agent-dash-pop-to-buffer (agent-dash-session-buffer target))
    (agent-dash-notify--seen)))

(defun agent-dash-notify-show-requests ()
  "Switch to the next chat awaiting confirmation or an answer."
  (interactive)
  (agent-dash-notify--show 'request))

(defun agent-dash-notify-show-completed ()
  "Switch to the next chat with an unread run completion."
  (interactive)
  (agent-dash-notify--show 'completed))

(defconst agent-dash-notify--request-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'agent-dash-notify-show-requests)
    map)
  "Mouse bindings for the pending-request count.")

(defconst agent-dash-notify--completed-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'agent-dash-notify-show-completed)
    map)
  "Mouse bindings for the unread-completion count.")

(defun agent-dash-notify--mode-line ()
  "Return compact global request and unread-completion counts, or nil."
  (when agent-dash-notify
    (let ((requests (length (agent-dash-notify--targets 'request)))
          (completed (length (agent-dash-notify--targets 'completed))))
      (when (> (+ requests completed) 0)
        (concat
         " "
         (when (> requests 0)
           (propertize (format "?%d" requests) 'face 'warning
                       'help-echo "Agent chats awaiting answers; mouse-1: next chat"
                       'mouse-face 'mode-line-highlight
                       'local-map agent-dash-notify--request-map))
         (when (and (> requests 0) (> completed 0)) " ")
         (when (> completed 0)
           (propertize (format "✓%d" completed)
                       'help-echo "Agent chats with unread completions; mouse-1: next chat"
                       'mouse-face 'mode-line-highlight
                       'local-map agent-dash-notify--completed-map)))))))

(defun agent-dash-notify--desktop (title body)
  "Send TITLE and BODY via user `notify-send', or built-in notifications."
  ;; Load deferred notifications configuration before choosing its wrapper.
  (require 'notifications)
  (unless (funcall (if (fboundp 'notify-send) 'notify-send #'notifications-notify)
                   :title title :body body :app-name "agent-dash"
                   :app-icon nil :urgency 'normal)
    (error "Desktop notification unavailable")))

(defun agent-dash-notify--waiting-p (session)
  "Whether SESSION has outstanding delivery or automatic follow-ups."
  (let ((native (agent-dash-session-queue session)))
    (or (agent-dash-data session :queue-inflight)
        (agent-dash-data session :pi-native-pending)
        (plist-get native :steering) (plist-get native :follow-up)
        (and (not (agent-dash-data session :queue-paused))
             (agent-dash-queue-pending session 'follow-up)))))

(defun agent-dash-notify--deliver (session)
  "Deliver SESSION's pending reminder, rechecking focus and lifecycle."
  (agent-dash-set-data session :notify-timer nil)
  (when (agent-dash-data session :notify-pending)
    (let ((buffer (agent-dash-session-buffer session))
          (frame (agent-dash-notify--focused-frame)))
      (cond
       ((or (not agent-dash-notify) noninteractive (not (buffer-live-p buffer))
            (eq (agent-dash-session-state session) 'dead)
            (agent-dash-data session :notify-cancelled)
            (and frame (eq (window-buffer (frame-selected-window frame)) buffer)))
        (agent-dash-notify--clear session))
       ((or (not (eq (agent-dash-session-state session) 'idle))
            (agent-dash-session-requests session) (agent-dash-notify--waiting-p session))
        nil) ; Queue/dialog events will schedule another check.
       (t
        (agent-dash-set-data session :notify-unread t)
        (force-mode-line-update t)
        (if (and frame (active-minibuffer-window))
            (agent-dash-notify--schedule session)
          (let ((title (format "%s · %s · %s"
                               (agent-dash--backend-name (agent-dash-session-backend session))
                               (file-name-nondirectory
                                (directory-file-name (agent-dash-session-root session)))
                               (substring (agent-dash-session-id session) 0 8)))
                (body (if (eq (agent-dash-data session :notify-pending) 'error)
                          "Run failed" "Run ended")))
            (agent-dash-notify--clear session)
            (if frame
                (message "%s: %s" title body)
              (condition-case nil
                  (agent-dash-notify--desktop title body)
                (error (message "%s: %s" title body)))))))))))

(defun agent-dash-notify--event (session event)
  "Observe unified EVENT for SESSION, ignoring historical completions."
  (when (eq (plist-get event :type) 'run)
    (pcase (plist-get event :state)
      ('running
       (unless (and (plist-get event :snapshot)
                    (agent-dash-data session :notify-pending))
         (unless (agent-dash-data session :notify-running)
           (agent-dash-set-data session :notify-cancelled nil))
         (agent-dash-set-data session :notify-running t)
         (agent-dash-notify--clear session)))
      ('idle
       (when (and (agent-dash-data session :notify-running)
                  (not agent-dash-replaying)
                  (not (plist-get event :snapshot))
                  (not (eq (plist-get event :outcome) 'cancelled)))
         (agent-dash-set-data session :notify-pending
                              (or (plist-get event :outcome) 'ended)))
       ;; State observation can precede the actual turn/end on another stream.
       (unless (plist-get event :snapshot)
         (agent-dash-set-data session :notify-running nil)))
      ('dead
       (agent-dash-set-data session :notify-running nil)
       (agent-dash-notify--clear session))))
  (when (and agent-dash-notify (not noninteractive) (not agent-dash-replaying)
             (agent-dash-data session :notify-pending))
    (agent-dash-notify--schedule session))
  (when (memq (plist-get event :type) '(run request request-done))
    (force-mode-line-update t)))

(cl-defmethod agent-dash-backend-cancel :before (_backend session)
  "Suppress reminders for SESSION's explicitly cancelled run."
  (when (agent-dash-data session :notify-running)
    (agent-dash-set-data session :notify-cancelled t)
    (agent-dash-notify--clear session)))

(add-hook 'agent-dash-event-functions #'agent-dash-notify--event t)
(add-hook 'window-selection-change-functions #'agent-dash-notify--seen)
(add-hook 'window-buffer-change-functions #'agent-dash-notify--seen)
(add-function :after after-focus-change-function #'agent-dash-notify--seen)

(defun agent-dash-notify--install-mode-line ()
  "Append one global indicator, preserving any existing mode-line construct."
  (let ((indicator '(:eval (agent-dash-notify--mode-line))))
    (unless (and (listp global-mode-string) (member indicator global-mode-string))
      ;; A leading string makes this a concatenation, even if OLD is :eval.
      (setq global-mode-string (list "" global-mode-string indicator)))))

(agent-dash-notify--install-mode-line)

(provide 'agent-dash-notify)
;;; agent-dash-notify.el ends here
