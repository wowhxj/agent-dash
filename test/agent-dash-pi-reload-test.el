;;; agent-dash-pi-reload-test.el --- Safe Pi restart tests -*- lexical-binding: t; -*-

;;; Commentary:
;; All process and RPC actions are intercepted; no models or real signals.

;;; Code:
(require 'ert)
(require 'agent-dash)

(defmacro agent-dash-pi-reload-test-with-session (&rest body)
  "Run BODY with a saved idle SESSION and intercepted process operations."
  (declare (indent 0))
  `(let* ((root (make-temp-file "dash-pi-reload-" t))
          (file (expand-file-name "saved.jsonl" root))
          (agent-dash-pi-arguments nil)
          (session (agent-dash-session-create 'pi root))
          (state (make-hash-table :test #'equal))
          (alive t) events)
     (unwind-protect
         (progn
           (write-region "{\"type\":\"session\",\"id\":\"saved\"}\n" nil file nil 'silent)
           (agent-dash-set-data session :sid "saved")
           (agent-dash-set-data session :holder root)
           (puthash "sessionId" "saved" state)
           (puthash "sessionFile" file state)
           (puthash "model" (agent-dash-json-read "{\"provider\":\"test\",\"id\":\"model\"}") state)
           (puthash "thinkingLevel" "high" state)
           (cl-letf (((symbol-function 'agent-dash-pi--native-query)
                      (lambda (_session request)
                        (should (equal (plist-get request :type) "get_state")) state))
                     ((symbol-function 'executable-find) (lambda (_) "/fixture/pi"))
                     ((symbol-function 'agent-dash-holder-pid) (lambda (_) 1234))
                     ((symbol-function 'agent-dash-holder-alive-p) (lambda (_) alive))
                     ((symbol-function 'yes-or-no-p) (lambda (_) t))
                     ((symbol-function 'signal-process)
                      (lambda (pid signal)
                        (should (= pid 1234)) (should (eq signal 'TERM))
                        (push 'stop events)
                        (setq alive nil)
                        (setf (agent-dash-session-state session) 'dead) 0))
                     ((symbol-function 'agent-dash-holder-detach)
                      (lambda (s) (should (eq s session)) (push 'detach events)))
                     ((symbol-function 'agent-dash-holder-start)
                      (lambda (dir cwd command)
                        (should-not alive)
                        (should (eq (agent-dash-session-state session) 'dead))
                        (should (equal dir root)) (should (equal (directory-file-name cwd) root))
                        (should (equal (cadr (member "--session" command)) file))
                        (should (equal (cadr (member "--provider" command)) "test"))
                        (should (equal (cadr (member "--thinking" command)) "high"))
                        (should-not (member "--session-id" command))
                        (push 'start events)))
                     ((symbol-function 'agent-dash-pi--attach)
                      (lambda (s dir)
                        (should (eq s session)) (should (equal dir root))
                        (push 'attach events))))
             ,@body))
       (delete-directory root t))))

(ert-deftest agent-dash-pi-reload-test-native-route-is-not-a-prompt ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)) called)
    (cl-letf (((symbol-function 'agent-dash-pi-reload)
               (lambda (s) (should (eq s session)) (setq called t)))
              ((symbol-function 'agent-dash-pi--request)
               (lambda (&rest _) (ert-fail "Reload became a prompt"))))
      (agent-dash-pi-native-execute session "reload" "")
      (should called)
      (should-error (agent-dash-pi-native-execute session "reload" "extra")
                    :type 'user-error))))

(ert-deftest agent-dash-pi-reload-test-completion-advertises-confirmed-restart ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)))
    (agent-dash-set-data session :pi-local-native-commands '(("reload" . "Reload")))
    (let ((description (cdr (assoc "reload" (agent-dash-pi-command-catalog session nil)))))
      (should (string-search "Restart Pi" description))
      (should-not (string-search "terminal UI" description)))))

(ert-deftest agent-dash-pi-reload-test-confirmed-saved-session-restores-in-order ()
  (agent-dash-pi-reload-test-with-session
    (agent-dash-emit session '(:type meta :fast-mode t :service-tier "priority"))
    (agent-dash-pi-reload session)
    (should (equal (reverse events) '(stop detach start attach)))
    (should (equal (agent-dash-data session :sid) "saved"))
    (should-not (plist-get (agent-dash-session-meta session) :fast-mode))
    (should-not (plist-get (agent-dash-session-meta session) :service-tier))))

(ert-deftest agent-dash-pi-reload-test-keeps-buffer-and-unsent-draft ()
  (agent-dash-pi-reload-test-with-session
    (let ((buffer (agent-dash--setup-buffer session)))
      (unwind-protect
          (with-current-buffer buffer
            (agent-dash--set-input "UNSENT DRAFT")
            (agent-dash-pi-reload session)
            (should (eq buffer (agent-dash-session-buffer session)))
            (should (equal (agent-dash--input) "UNSENT DRAFT")))
        (let ((agent-dash--quitting t)) (kill-buffer buffer))))))

(ert-deftest agent-dash-pi-reload-test-cancel-preserves-running-process ()
  (agent-dash-pi-reload-test-with-session
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (agent-dash-pi-reload session))
    (should alive)
    (should-not events)))

(ert-deftest agent-dash-pi-reload-test-unsaved-unreadable-or-other-session-never-stops ()
  (agent-dash-pi-reload-test-with-session
    (dolist (path (list nil (expand-file-name "missing.jsonl" root)))
      (puthash "sessionFile" path state)
      (should-error (agent-dash-pi-reload session) :type 'user-error))
    (puthash "sessionFile" file state)
    (puthash "sessionId" "another-session" state)
    (should-error (agent-dash-pi-reload session) :type 'user-error)
    (should alive)
    (should-not events)))

(ert-deftest agent-dash-pi-reload-test-busy-compacting-or-queued-never-stops ()
  (agent-dash-pi-reload-test-with-session
    (setf (agent-dash-session-state session) 'running)
    (should-error (agent-dash-pi-reload session) :type 'user-error)
    (setf (agent-dash-session-state session) 'idle)
    (dolist (entry '(("isStreaming" . t) ("isCompacting" . t) ("pendingMessageCount" . 1)))
      (puthash (car entry) (cdr entry) state)
      (should-error (agent-dash-pi-reload session) :type 'user-error)
      (remhash (car entry) state))
    (agent-dash-set-data session :pi-native-pending '("pending" . "login"))
    (should-error (agent-dash-pi-reload session) :type 'user-error)
    (agent-dash-set-data session :pi-native-pending nil)
    (setf (agent-dash-session-requests session) '((:id "dialog")))
    (should-error (agent-dash-pi-reload session) :type 'user-error)
    (setf (agent-dash-session-requests session) nil)
    (cl-letf (((symbol-function 'agent-dash-queue-managed-p) (lambda (_) t)))
      (should-error (agent-dash-pi-reload session) :type 'user-error))
    (should alive)
    (should-not events)))

(ert-deftest agent-dash-pi-reload-test-revalidates-after-confirmation ()
  (agent-dash-pi-reload-test-with-session
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (puthash "isStreaming" t state) t)))
      (should-error (agent-dash-pi-reload session) :type 'user-error))
    (should alive)
    (should-not events)))

(ert-deftest agent-dash-pi-reload-test-launch-preflight-never-stops ()
  (agent-dash-pi-reload-test-with-session
    (let ((agent-dash-pi-arguments '("--no-session")))
      (should-error (agent-dash-pi-reload session) :type 'user-error))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should-error (agent-dash-pi-reload session) :type 'user-error))
    (should alive)
    (should-not events)))

(ert-deftest agent-dash-pi-reload-test-slow-exit-never-starts-second-process ()
  (agent-dash-pi-reload-test-with-session
    (let ((clock 0))
      (cl-letf (((symbol-function 'signal-process)
                 (lambda (&rest _) (push 'stop events) 0))
                ((symbol-function 'float-time) (lambda (&rest _) (cl-incf clock 10))))
        (should-error (agent-dash-pi-reload session) :type 'user-error)))
    (should (equal events '(stop)))))

(ert-deftest agent-dash-pi-reload-test-dead-pid-alone-is-not-a-drained-holder ()
  (agent-dash-pi-reload-test-with-session
    (let ((clock 0))
      (cl-letf (((symbol-function 'signal-process)
                 (lambda (&rest _) (push 'stop events) (setq alive nil) 0))
                ((symbol-function 'float-time) (lambda (&rest _) (cl-incf clock 10))))
        (should-error (agent-dash-pi-reload session) :type 'user-error)))
    (should (equal events '(stop)))))

(provide 'agent-dash-pi-reload-test)
;;; agent-dash-pi-reload-test.el ends here
