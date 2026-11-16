;;; agent-dash-notify-test.el --- Adaptive reminder regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline lifecycle tests; never send actual desktop notifications.

;;; Code:
(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-notify-test-with-session (&rest body)
  "Run BODY with SESSION, captured ECHO/DESKTOP and stubbed timers/focus."
  (declare (indent 0))
  `(let* ((session (agent-dash-session-create 'fake "/tmp/project/"))
          (buffer (generate-new-buffer " *notify-test*"))
          (agent-dash--sessions (list session))
          (agent-dash-notify t)
          (agent-dash-event-functions (list #'agent-dash-notify--event))
          (agent-dash-update-functions nil)
          (agent-dash-fake-calls nil)
          (noninteractive nil)
          echo desktop)
     (setf (agent-dash-session-buffer session) buffer)
     (unwind-protect
         (save-window-excursion
           (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (timer-create)))
                     ((symbol-function 'frame-focus-state) (lambda (&optional _) t))
                     ((symbol-function 'active-minibuffer-window) (lambda () nil))
                     ((symbol-function 'message)
                      (lambda (fmt &rest args) (push (apply #'format fmt args) echo)))
                     ((symbol-function 'agent-dash-notify--desktop)
                      (lambda (title text) (push (list title text) desktop))))
             ,@body))
       (agent-dash-notify--clear session)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun agent-dash-notify-test--finish (session &optional outcome)
  "Start and finish SESSION with OUTCOME, then deliver its reminder."
  (agent-dash-emit session '(:type run :state running))
  (agent-dash-emit session (list :type 'run :state 'idle :outcome outcome))
  (agent-dash-notify--deliver session))

(ert-deftest agent-dash-notify-test-routing ()
  "Selected chat stays quiet; background chats use echo or desktop by focus."
  (agent-dash-notify-test-with-session
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify-test--finish session)
   (should-not echo)
   (should-not desktop)
   (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
   (agent-dash-notify-test--finish session)
   (should (= (length echo) 1))
   (should (string-match-p "Fake · project · .*: Run ended" (car echo)))
   (should-not desktop)
   (set-window-buffer (split-window) buffer)
   (agent-dash-notify-test--finish session)
   (should (= (length echo) 2))
   (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) nil)))
     (set-window-buffer (selected-window) buffer)
     (agent-dash-notify-test--finish session))
   (should (= (length desktop) 1))
   (should (= (length echo) 2))))

(ert-deftest agent-dash-notify-test-focus-unknown ()
  "Unknown terminal focus is treated as in-Emacs, not definitely away."
  (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) 'unknown)))
    (should (eq (agent-dash-notify--focused-frame) (selected-frame)))))

(ert-deftest agent-dash-notify-test-fallback-and-privacy ()
  "Desktop errors fall back to echo, without quoting conversation content."
  (agent-dash-notify-test-with-session
   (agent-dash-emit session '(:type assistant :id "a" :text "SECRET" :final t))
   (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) nil))
             ((symbol-function 'agent-dash-notify--desktop)
              (lambda (&rest _) (error "Unavailable"))))
     (agent-dash-notify-test--finish session 'error))
   (should (= (length echo) 1))
   (should (string-suffix-p "Run failed" (car echo)))
   (should-not (string-search "SECRET" (car echo)))
   (agent-dash-notify--deliver session)
   (should (= (length echo) 1))))

(ert-deftest agent-dash-notify-test-minibuffer-and-focus-recheck ()
  "Delivery waits for the minibuffer and rechecks the selected chat."
  (agent-dash-notify-test-with-session
   (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
     (agent-dash-notify-test--finish session))
   (should-not echo)
   (should (agent-dash-data session :notify-pending))
   (should (timerp (agent-dash-data session :notify-timer)))
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should-not (agent-dash-data session :notify-pending))))

(ert-deftest agent-dash-notify-test-no-false-completions ()
  "Initial idle, tools, history, cancellation and disconnect stay quiet."
  (agent-dash-notify-test-with-session
   (agent-dash-emit session '(:type run :state idle))
   (agent-dash-emit session '(:type assistant :id "a" :final t :text "Done"))
   (agent-dash-emit session '(:type tool :id "t" :status success))
   (should-not (agent-dash-data session :notify-pending))
   (let ((agent-dash-replaying t)) (agent-dash-notify-test--finish session))
   (should-not echo)
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-backend-cancel 'fake session)
   (agent-dash-emit session '(:type run :state idle))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (agent-dash-notify-test--finish session 'cancelled)
   (should-not echo)
   (agent-dash-notify-test--finish session)
   (should (= (length echo) 1))
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type run :state dead))
   (agent-dash-notify--deliver session)
   (should (= (length echo) 1))))

(ert-deftest agent-dash-notify-test-disabled-batch-and-killed-buffer ()
  "Opt-out, batch processing and buffer death must not send notifications."
  (agent-dash-notify-test-with-session
   (let ((agent-dash-notify nil)) (agent-dash-notify-test--finish session))
   (let ((noninteractive t)) (agent-dash-notify-test--finish session))
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type run :state idle))
   (kill-buffer buffer)
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should-not desktop)))

(ert-deftest agent-dash-notify-test-queues-and-requests ()
  "Wait for native/local delivery and requests, not paused or staged work."
  (agent-dash-notify-test-with-session
   (agent-dash-set-data session :local-queue '((:id "q" :kind follow-up :status pending)))
   (agent-dash-notify-test--finish session)
   (should-not echo)
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-set-data session :local-queue nil)
   (agent-dash-set-data session :queue-inflight "q")
   (agent-dash-emit session '(:type run :state idle))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (agent-dash-set-data session :queue-inflight nil)
   (agent-dash-emit session '(:type queue :follow-up ("native")))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (agent-dash-emit session '(:type queue))
   (agent-dash-emit session '(:type request :id "r" :kind confirm))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (agent-dash-emit session '(:type request-done :id "r"))
   (should (timerp (agent-dash-data session :notify-timer)))
   (agent-dash-notify--deliver session)
   (should (= (length echo) 1))
   (agent-dash-set-data session :local-queue '((:id "q" :kind follow-up :status pending)))
   (agent-dash-set-data session :queue-paused t)
   (agent-dash-notify-test--finish session)
   (should (= (length echo) 2))
   (agent-dash-set-data session :queue-paused nil)
   (agent-dash-set-data session :local-queue '((:id "q" :kind steer :status pending)))
   (agent-dash-notify-test--finish session)
   (should (= (length echo) 3))))

(ert-deftest agent-dash-notify-test-holder-history-boundary ()
  "Chunked multibyte replay stays silent; live completion still notifies."
  (agent-dash-notify-test-with-session
   (let* ((history "{\"state\":\"running\",\"text\":\"历史\"}\r\n{\"state\":\"idle\"}\n")
          (filter (agent-dash-holder--lines
                   session (lambda (s record)
                             (agent-dash-emit s (list :type 'run :state
                                                      (intern (agent-dash-jget record "state")))))
                   (string-bytes history))))
     (funcall filter nil (substring history 0 13))
     (funcall filter nil (concat (substring history 13) "{\"state\":\"running\"}\n"))
     (should-not (agent-dash-data session :notify-pending))
     (funcall filter nil "{\"state\":\"idle\"}\n")
     (agent-dash-notify--deliver session)
     (should (= (length echo) 1)))))

(ert-deftest agent-dash-notify-test-dsh-snapshot ()
  "DSH snapshot history never notifies, including reconnect snapshots."
  (agent-dash-notify-test-with-session
   (agent-dash-dsh--item
    session (agent-dash-json-read
             "{\"type\":\"item\",\"value\":{\"type\":\"snapshot\",\"records\":[{\"event\":{\"seq\":1,\"type\":\"turn/start\"}},{\"event\":{\"seq\":2,\"type\":\"turn/end\"}}]}}"))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type run :state idle :snapshot t))
   (agent-dash-notify--deliver session)
   (should-not echo)
   ;; observeState and follow are separate streams; idle may arrive first.
   (agent-dash-dsh--event session (agent-dash-json-read "{\"seq\":3,\"type\":\"turn/end\"}"))
   (agent-dash-notify--deliver session)
   (should (= (length echo) 1))))

(ert-deftest agent-dash-notify-test-backend-outcomes ()
  "All adapters report failures through the unified lifecycle event."
  (dolist (record '((agent-dash-pi--record . "{\"type\":\"agent_settled\"}")
                    (agent-dash-claude--record . "{\"type\":\"result\",\"uuid\":\"r\",\"is_error\":true}")
                    (agent-dash-codex--record . "{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"status\":\"failed\"}}}")
                    (agent-dash-hermes--record . "{\"error\":{\"message\":\"failed\"}}")
                    (agent-dash-dsh--event . "{\"seq\":1,\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"failed\",\"error\":{\"message\":\"failed\"}}}}")))
    (agent-dash-notify-test-with-session
     (agent-dash-set-data session :queue-pi-stop "error")
     (agent-dash-emit session '(:type run :state running))
     (funcall (car record) session (agent-dash-json-read (cdr record)))
     (agent-dash-notify--deliver session)
     (should (string-suffix-p "Run failed" (car echo))))))

(ert-deftest agent-dash-notify-test-desktop-platforms ()
  "Use native AppleScript on macOS and notifications elsewhere."
  (require 'notifications)
  (let (script params)
    (cl-letf (((symbol-function 'ns-do-applescript) (lambda (text) (setq script text)))
              ((symbol-function 'notifications-notify) (lambda (&rest args) (setq params args) 1)))
      (let ((system-type 'darwin))
        (agent-dash-notify--desktop "Title \"quoted\"" "Run ended"))
      (should (string-search "display notification" script))
      (should (string-search "\\\"quoted\\\"" script))
      (should-not params)
      (let ((system-type 'gnu/linux))
        (agent-dash-notify--desktop "Title" "Run failed"))
      (should (equal (plist-get params :title) "Title"))
      (should (equal (plist-get params :body) "Run failed")))))

(ert-deftest agent-dash-notify-test-away-with-active-minibuffer ()
  "An abandoned minibuffer must not block desktop reminders."
  (agent-dash-notify-test-with-session
   (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) nil))
             ((symbol-function 'active-minibuffer-window) (lambda () t)))
     (agent-dash-notify-test--finish session))
   (should (= (length desktop) 1))
   (should-not echo)))

(ert-deftest agent-dash-notify-test-claude-before-stream ()
  "Real user echoes start a run before output, but replay/tool results do not."
  (dolist (failed '(nil t))
    (agent-dash-notify-test-with-session
     (let ((prompt (agent-dash-json-read
                    "{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"content\":\"question\"}}")))
       (let ((agent-dash-replaying t)) (agent-dash-claude--user session prompt))
       (should (eq (agent-dash-session-state session) 'idle))
       (agent-dash-claude--user
        session (agent-dash-json-read
                 "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t\",\"content\":\"output\"}]}}"))
       (should (eq (agent-dash-session-state session) 'idle))
       (agent-dash-claude--record session prompt)
       (should (eq (agent-dash-session-state session) 'running))
       (agent-dash-claude--record
        session (agent-dash-json-read
                 (if failed "{\"type\":\"result\",\"uuid\":\"r\",\"is_error\":true}"
                   "{\"type\":\"result\",\"uuid\":\"r\",\"result\":\"answer\"}")))
       (agent-dash-notify--deliver session)
       (should (= (length echo) 1))
       (should (string-suffix-p (if failed "Run failed" "Run ended") (car echo)))))))

(ert-deftest agent-dash-notify-test-pi-aborted-between-messages ()
  "Settled aborted wins over a previous successful or tool-use stop reason."
  (agent-dash-notify-test-with-session
   (agent-dash-pi--record session (agent-dash-json-read "{\"type\":\"agent_start\"}"))
   (agent-dash-set-data session :queue-pi-stop "toolUse")
   (agent-dash-pi--record session (agent-dash-json-read "{\"type\":\"agent_settled\",\"aborted\":true}"))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should-not (agent-dash-data session :notify-pending))))

(ert-deftest agent-dash-notify-test-dsh-late-state-snapshot ()
  "Late state snapshots cannot consume an already observed completion."
  (agent-dash-notify-test-with-session
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type run :state idle))
   (agent-dash-emit session '(:type run :state running :snapshot t))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should (agent-dash-data session :notify-pending))
   (agent-dash-emit session '(:type run :state idle :snapshot t))
   (agent-dash-notify--deliver session)
   (should (= (length echo) 1))))

(ert-deftest agent-dash-notify-test-pi-abort-pauses-follow-ups ()
  "An authoritative Pi abort must not drain the next automatic follow-up."
  (agent-dash-notify-test-with-session
   (let ((agent-dash-event-functions (list #'agent-dash-queue--event
                                           #'agent-dash-notify--event)))
     (agent-dash-set-data session :local-queue
                          '((:id "first" :kind follow-up :status accepted :accepted t :started t)
                            (:id "next" :kind follow-up :status pending :wire-text "next task")))
     (agent-dash-set-data session :queue-inflight "first")
     (agent-dash-emit session '(:type run :state running))
     (agent-dash-set-data session :queue-pi-stop "toolUse")
     (agent-dash-pi--record session (agent-dash-json-read "{\"type\":\"agent_settled\",\"aborted\":true}"))
     (should (agent-dash-data session :queue-paused))
     (should (eq (plist-get (agent-dash-queue-entry session "first") :status) 'failed))
     (agent-dash-queue--pump session)
     (agent-dash-notify--deliver session)
     (should-not agent-dash-fake-calls)
     (should-not echo))))

(ert-deftest agent-dash-notify-test-global-mode-line-requests ()
  "Count sessions, not questions; visiting does not acknowledge a request."
  (agent-dash-notify-test-with-session
   (should-not (agent-dash-notify--mode-line))
   (agent-dash-emit session '(:type request :id "a" :kind permission))
   (agent-dash-emit session '(:type request :id "b" :kind questions))
   (agent-dash-emit session '(:type request :id "a" :kind permission))
   (let* ((text (agent-dash-notify--mode-line))
          (map (get-text-property 1 'local-map text)))
     (should (equal text " ?1"))
     (should (eq (get-text-property 1 'face text) 'warning))
     (should (eq (lookup-key map [mode-line mouse-1]) #'agent-dash-notify-show-requests)))
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify--seen)
   (should (equal (agent-dash-notify--mode-line) " ?1"))
   (agent-dash-emit session '(:type request-done :id "a"))
   (should (equal (agent-dash-notify--mode-line) " ?1"))
   (agent-dash-emit session '(:type request-done :id "b" :status cancelled))
   (should-not (agent-dash-notify--mode-line))))

(ert-deftest agent-dash-notify-test-global-mode-line-completed ()
  "Unread completion survives transient delivery, and coexists with requests."
  (agent-dash-notify-test-with-session
   (agent-dash-notify-test--finish session)
   (should-not (agent-dash-data session :notify-pending))
   (should (equal (agent-dash-notify--mode-line) " ✓1"))
   (let* ((text (agent-dash-notify--mode-line))
          (map (get-text-property 1 'local-map text)))
     (should (eq (lookup-key map [mode-line mouse-1]) #'agent-dash-notify-show-completed)))
   (agent-dash-notify-test--finish session)
   (should (equal (agent-dash-notify--mode-line) " ✓1"))
   (agent-dash-emit session '(:type request :id "r" :kind confirm))
   (should (equal (agent-dash-notify--mode-line) " ?1 ✓1"))
   (set-window-buffer (split-window) buffer)
   (agent-dash-notify--seen)
   (should (equal (agent-dash-notify--mode-line) " ?1 ✓1"))
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify--seen)
   (should (equal (agent-dash-notify--mode-line) " ?1"))))

(ert-deftest agent-dash-notify-test-mode-line-focus-return ()
  "A visible selected chat stays unread while away, but is read on focus return."
  (agent-dash-notify-test-with-session
   (set-window-buffer (selected-window) buffer)
   (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _) nil)))
     (agent-dash-notify-test--finish session)
     (agent-dash-notify--seen)
     (should (equal (agent-dash-notify--mode-line) " ✓1")))
   (agent-dash-notify--seen)
   (should-not (agent-dash-notify--mode-line))))

(ert-deftest agent-dash-notify-test-mode-line-minibuffer-and-early-visit ()
  "A deferred echo still has a count, and visiting cancels stale delivery."
  (agent-dash-notify-test-with-session
   (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
     (agent-dash-notify-test--finish session))
   (should (equal (agent-dash-notify--mode-line) " ✓1"))
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify--seen)
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should-not (agent-dash-notify--mode-line))
   ;; A visit even before the delivery timer fires acknowledges this end.
   (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type run :state idle))
   (set-window-buffer (selected-window) buffer)
   (agent-dash-notify--seen)
   (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
   (agent-dash-notify--deliver session)
   (should-not echo)
   (should-not (agent-dash-notify--mode-line))))

(ert-deftest agent-dash-notify-test-mode-line-jump-and-cycle ()
  "Buttons choose their category, cycle requests, and clear only viewed ends."
  (agent-dash-notify-test-with-session
   (let* ((other (agent-dash-session-create 'fake "/tmp/other/"))
          (other-buffer (generate-new-buffer " *notify-other*"))
          (agent-dash--sessions (list session other))
          (last-input-event nil))
     (setf (agent-dash-session-buffer other) other-buffer)
     (unwind-protect
         (cl-letf (((symbol-function 'agent-dash-pop-to-buffer)
                    (lambda (target) (set-window-buffer (selected-window) target))))
           (agent-dash-notify-test--finish session)
           (agent-dash-notify-test--finish other)
           (agent-dash-emit session '(:type request :id "r1" :kind confirm))
           (agent-dash-emit other '(:type request :id "r2" :kind questions))
           (should (equal (agent-dash-notify--mode-line) " ?2 ✓2"))
           (agent-dash-notify-show-requests)
           (should (eq (window-buffer (selected-window)) buffer))
           (should (equal (agent-dash-notify--mode-line) " ?2 ✓1"))
           (agent-dash-notify-show-requests)
           (should (eq (window-buffer (selected-window)) other-buffer))
           (agent-dash-notify-show-requests)
           (should (eq (window-buffer (selected-window)) buffer))
           (agent-dash-set-data other :notify-unread t)
           (agent-dash-notify-show-completed)
           (should (eq (window-buffer (selected-window)) other-buffer))
           (should (equal (agent-dash-notify--mode-line) " ?2"))
           (should-error (agent-dash-notify-show-completed) :type 'user-error))
       (agent-dash-notify--clear other)
       (kill-buffer other-buffer)))))

(ert-deftest agent-dash-notify-test-mode-line-hidden-and-historical ()
  "History/cancellation do not count, and closed chats and opt-out hide counts."
  (agent-dash-notify-test-with-session
   (let ((agent-dash-replaying t)) (agent-dash-notify-test--finish session))
   (should-not (agent-dash-notify--mode-line))
   (agent-dash-notify-test--finish session 'cancelled)
   (should-not (agent-dash-notify--mode-line))
   (agent-dash-notify-test--finish session)
   (agent-dash-emit session '(:type request :id "r" :kind confirm))
   (let ((agent-dash-notify nil)) (should-not (agent-dash-notify--mode-line)))
   (kill-buffer buffer)
   (should-not (agent-dash-notify--mode-line))))

(ert-deftest agent-dash-notify-test-mode-line-integration ()
  "The global segment and read hooks are installed without replacing other UI."
  (should (= 1 (cl-count '(:eval (agent-dash-notify--mode-line)) global-mode-string :test #'equal)))
  (should (memq #'agent-dash-notify--seen window-selection-change-functions))
  (should (memq #'agent-dash-notify--seen window-buffer-change-functions))
  (with-temp-buffer
    (agent-dash-mode)
    (should (memq #'agent-dash-notify--seen post-command-hook))))

(ert-deftest agent-dash-notify-test-mode-line-preserves-existing-constructs ()
  "Keep strings, symbols, concatenations and single constructs intact."
  (dolist (old '(nil "CLOCK" clock (:eval "CLOCK")
                     (:propertize "CLOCK" face warning)
                     (clock "ON" "OFF") ("CLOCK" clock) ((:eval "CLOCK"))))
    (let ((global-mode-string (copy-tree old))
          (indicator '(:eval (agent-dash-notify--mode-line))))
      (agent-dash-notify--install-mode-line)
      (should (equal global-mode-string (list "" old indicator)))
      (let ((installed global-mode-string))
        (agent-dash-notify--install-mode-line)
        (should (eq global-mode-string installed))
        (should (= 1 (cl-count indicator global-mode-string :test #'equal)))))))

(provide 'agent-dash-notify-test)
;;; agent-dash-notify-test.el ends here
