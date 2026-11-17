;;; agent-dash-holder-lifecycle-test.el --- Holder exit delivery -*- lexical-binding: t; -*-

;;; Commentary:
;; Stopping must keep the exit listener until observers see the final record.

;;; Code:
(require 'ert)
(require 'agent-dash)

(ert-deftest agent-dash-holder-lifecycle-test-stop-follows-final-exit ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)) events)
    (agent-dash-set-data session :holder temporary-file-directory)
    (cl-letf (((symbol-function 'agent-dash-holder-pid) (lambda (_) 1234))
              ((symbol-function 'signal-process)
               (lambda (pid signal)
                 (should (= pid 1234)) (should (eq signal 'TERM))
                 (push 'signal events) 0))
              ((symbol-function 'agent-dash-holder-detach)
               (lambda (s) (should (eq s session)) (push 'detach events))))
      (agent-dash-holder-stop session)
      (should (equal events '(signal)))
      (let ((filter (agent-dash-holder--lines
                     session (lambda (_session record)
                               (should (equal (agent-dash-jget record "type") "agent_dash_exit"))
                               (push 'exit events)))))
        (funcall filter nil "{\"type\":\"agent_dash_exit\",\"code\":0}\n"))
      (should (equal (reverse events) '(signal exit detach))))))

(ert-deftest agent-dash-holder-lifecycle-test-exit-cleanup-survives-handler-error ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)) detached)
    (cl-letf (((symbol-function 'agent-dash-holder-detach) (lambda (_) (setq detached t))))
      (let ((filter (agent-dash-holder--lines session (lambda (&rest _) (error "Bad backend")))))
        (funcall filter nil "{\"type\":\"agent_dash_exit\",\"code\":1}\n"))
      (should detached))))

(ert-deftest agent-dash-holder-lifecycle-test-native-id-triggers-change-hook ()
  (let* ((dir (make-temp-file "dash-holder-id-" t))
         (session (agent-dash-session-create 'codex dir))
         (agent-dash-session-change-functions
          (list (lambda (s)
                  (should (eq s session))
                  (should (equal (agent-dash-data s :sid) "native-id"))
                  (agent-dash-set-data s :change-observed t)))))
    (unwind-protect
        (progn
          (agent-dash-set-data session :holder dir)
          (agent-dash-holder-set-sid session "native-id")
          (should (agent-dash-data session :change-observed)))
      (delete-directory dir t))))

(provide 'agent-dash-holder-lifecycle-test)
;;; agent-dash-holder-lifecycle-test.el ends here
