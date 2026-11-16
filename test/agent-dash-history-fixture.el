;;; agent-dash-history-fixture.el --- Offline worker backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Only loaded by history-worker integration tests.  Never starts an agent.

;;; Code:

(require 'agent-dash-core)

(defvar agent-dash-history-fixture-delay 0.2)
(defvar agent-dash-history-fixture-mode 'ok)
(defvar agent-dash-history-fixture-id "worker-session")

(cl-defmethod agent-dash-backend-sessions ((_ (eql history-fixture)) _root)
  "Return fixture rows after a configurable delay."
  (sleep-for agent-dash-history-fixture-delay)
  (pcase agent-dash-history-fixture-mode
    ('error (error "Fixture history unavailable"))
    ('exit (kill-emacs 7))
    ('invalid (princ "invalid output ")))
  (push "Fixture warning" agent-dash-history-warnings)
  (list (list :id agent-dash-history-fixture-id :first "测试 worker"
              :root temporary-file-directory :running t :worker-pid (emacs-pid))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql history-fixture)) _id)
  "Return fixture dialogue after a configurable delay."
  (sleep-for agent-dash-history-fixture-delay)
  '((user . "测试问题") (assistant . "worker reply")))

(provide 'agent-dash-history-fixture)
;;; agent-dash-history-fixture.el ends here
