;;; agent-dash-fake.el --- Offline fake backend for tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Records every backend call in `agent-dash-fake-calls'; tests drive
;; the agent side by calling `agent-dash-emit' themselves.

;;; Code:

(require 'agent-dash-core)
(require 'ert)
(require 'agent-dash-holder)

(defconst agent-dash-test--bin
  (expand-file-name "bin/" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory of offline stand-in agent executables.")

(defun agent-dash-test-wait (predicate &optional seconds)
  "Process output until PREDICATE holds, failing after SECONDS (default 5)."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro agent-dash-test-with-holders (&rest body)
  "Run BODY with a temporary `agent-dash-directory'; kill its agents after."
  (declare (indent 0))
  `(let ((agent-dash-directory (make-temp-file "agent-dash-test" t)))
     (unwind-protect (progn ,@body)
       (dolist (dir (directory-files (expand-file-name "instances" agent-dash-directory)
                                     t "\\`[^.]"))
         (when-let* ((pid (agent-dash-holder-pid (file-name-as-directory dir))))
           (signal-process pid 'KILL)))
       (delete-directory agent-dash-directory t))))

(defvar agent-dash-fake-calls nil "Backend calls, newest first.")
(defvar agent-dash-fake-quit 'stop "The fake backend's :quit capability.")

(cl-defmethod agent-dash-backend-capabilities ((_ (eql fake)))
  (list :quit agent-dash-fake-quit :steer t :images nil :models nil :delete t))

(cl-defmethod agent-dash-backend-start ((_ (eql fake)) session &optional resume-id)
  (push (list 'start (agent-dash-session-id session) resume-id) agent-dash-fake-calls))

(cl-defmethod agent-dash-backend-send ((_ (eql fake)) _session text images mode)
  (push (list 'send text images mode) agent-dash-fake-calls))

(cl-defmethod agent-dash-backend-cancel ((_ (eql fake)) _session)
  (push (list 'cancel) agent-dash-fake-calls))

(cl-defmethod agent-dash-backend-quit ((_ (eql fake)) _session)
  (push (list 'quit) agent-dash-fake-calls))

(cl-defmethod agent-dash-backend-detach ((_ (eql fake)) _session)
  (push (list 'detach) agent-dash-fake-calls))

(cl-defmethod agent-dash-backend-respond ((_ (eql fake)) _session request answer)
  (push (list 'respond (plist-get request :id) answer) agent-dash-fake-calls))

(defvar agent-dash-fake-saved nil "Saved sessions the fake backend lists.")

(cl-defmethod agent-dash-backend-sessions ((_ (eql fake)) _root)
  agent-dash-fake-saved)

(cl-defmethod agent-dash-backend-transcript ((_ (eql fake)) id)
  (list (cons 'user (format "question of %s" id)) (cons 'assistant "answer")))

(cl-defmethod agent-dash-backend-delete ((_ (eql fake)) session)
  (push (list 'delete (plist-get session :id)) agent-dash-fake-calls))

(provide 'agent-dash-fake)
;;; agent-dash-fake.el ends here
