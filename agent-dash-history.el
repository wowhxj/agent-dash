;;; agent-dash-history.el --- Isolated history readers -*- lexical-binding: t; -*-

;;; Commentary:

;; History backends may block on files, SQLite or local RPC.  Run them in
;; batch Emacs processes, never in a GUI timer.  Concurrent callers share
;; one reader for the same backend/operation/session.  No user init or
;; background summary mode is loaded in a reader.

;;; Code:

(require 'agent-dash-core)

(declare-function agent-dash-summary-dialogue "agent-dash-summary")

(defcustom agent-dash-history-timeout 120
  "Maximum seconds allowed for an isolated history reader."
  :type 'number
  :group 'agent-dash)

(defconst agent-dash-history--library
  (expand-file-name "agent-dash-history.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Source loaded by an isolated history reader.")

(defvar agent-dash-history-worker-variables
  '(user-emacs-directory exec-path agent-dash-directory
                         agent-dash-pi-executable agent-dash-pi-arguments
                         agent-dash-pi-sessions-directory
                         agent-dash-claude-executable agent-dash-claude-arguments
                         agent-dash-claude-config-directory
                         agent-dash-codex-executable agent-dash-codex-directory
                         agent-dash-hermes-executable agent-dash-hermes-directory
                         agent-dash-agy-executable agent-dash-agy-directory agent-dash-agy-magpie
                         agent-dash-dsh-executable agent-dash-dsh-connection
                         agent-dash-dsh-bridge-file
                         agent-dash-dsh-max-messages agent-dash-dsh--host)
  "Variables copied to readers over stdin, not command arguments or files.
Additional backend implementations may add their history configuration here.")

(defvar agent-dash-history-update-hook nil
  "Functions called with (BACKEND RESULT) after a session listing finishes.
RESULT has :ok, :value, :warnings, :seconds and, on failure, :error.")

(defvar agent-dash-history--jobs (make-hash-table :test #'equal)
  "Request key -> running reader process.")
(defvar agent-dash-history--completed (make-hash-table)
  "Backend -> time of its last successful session listing.")

(defun agent-dash-history--worker ()
  "Read one request from stdin and write one data result to stdout."
  (let* ((request (read (read-string "")))
         (load-path (cons (file-name-directory agent-dash-history--library)
                          (plist-get request :load-path)))
         (load-prefer-newer t)
         (started (float-time))
         (agent-dash-history-warnings nil)
         result)
    (condition-case err
        (progn
          (dolist (binding (plist-get request :variables))
            (set (car binding) (cdr binding)))
          (require (intern (format "agent-dash-%s" (plist-get request :backend))))
          (let ((backend (plist-get request :backend)))
            (setq result
                  (list :ok t :value
                        (pcase (plist-get request :operation)
                          ('sessions (agent-dash-backend-sessions backend nil))
                          ('dialogue
                           (require 'agent-dash-summary)
                           (agent-dash-summary-dialogue
                            (list :backend backend :id (plist-get request :id))))
                          (_ (error "Unknown history operation")))
                        :warnings (nreverse agent-dash-history-warnings)))))
      (error (setq result (list :ok nil :error (error-message-string err)))))
    (setq result (plist-put result :seconds (- (float-time) started)))
    (let ((print-length nil) (print-level nil) (print-escape-newlines t))
      (prin1 result))))

(defun agent-dash-history--deliver (callback &rest args)
  "Call CALLBACK with ARGS without blocking other history consumers on error."
  (condition-case err
      (apply callback args)
    (error (message "agent-dash history callback failed: %s" (error-message-string err)))))

(defun agent-dash-history--finish (process result)
  "Release PROCESS and deliver RESULT exactly once."
  (let ((key (process-get process 'agent-dash-key)))
    (when (eq process (gethash key agent-dash-history--jobs))
      (remhash key agent-dash-history--jobs)
      (when-let* ((timer (process-get process 'agent-dash-timer))) (cancel-timer timer))
      (when (process-live-p process) (delete-process process))
      (dolist (buffer (list (process-buffer process)
                            (process-get process 'agent-dash-stderr)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (when (eq (cadr key) 'sessions)
        (when (plist-get result :ok)
          (puthash (car key) (float-time) agent-dash-history--completed))
        (run-hook-wrapped 'agent-dash-history-update-hook
                          (lambda (callback)
                            (agent-dash-history--deliver callback (car key) result)
                            nil)))
      (dolist (callback (nreverse (process-get process 'agent-dash-callbacks)))
        (agent-dash-history--deliver callback result)))))

(defun agent-dash-history--sentinel (process _event)
  "Collect the completed reader PROCESS without blocking."
  (when (memq (process-status process) '(exit signal failed))
    (let ((result
           (condition-case nil
               (if (and (eq (process-status process) 'exit)
                        (zerop (process-exit-status process)))
                   (with-current-buffer (process-buffer process)
                     (goto-char (point-min))
                     (let ((value (read (current-buffer))))
                       (unless (and (listp value) (plist-member value :ok))
                         (error "Invalid history result"))
                       value))
                 (list :ok nil :error
                       (format "History reader exited with status %s"
                               (process-exit-status process))))
             (error (list :ok nil :error "History reader returned invalid data")))))
      (agent-dash-history--finish process result))))

(defun agent-dash-history-request (backend operation &optional callback id)
  "Read BACKEND's OPERATION in a child Emacs, optionally for session ID.
OPERATION is `sessions' or `dialogue'.  Call CALLBACK with the result.
Return the shared process; duplicate requests do not start more workers."
  (let* ((key (list backend operation id))
         (process (gethash key agent-dash-history--jobs)))
    (unless process
      (let ((output (generate-new-buffer " *agent-dash-history*"))
            (stderr (generate-new-buffer " *agent-dash-history-stderr*"))
            (default-directory (expand-file-name "~")))
        (condition-case err
            (setq process
                  (make-process
                   :name (format "agent-dash-history-%s-%s" backend operation)
                   :buffer output :stderr stderr :noquery t :connection-type 'pipe
                   :coding 'utf-8-unix
                   :command (list (expand-file-name invocation-name invocation-directory)
                                  "-Q" "--batch"
                                  "-L" (file-name-directory agent-dash-history--library)
                                  "-l" agent-dash-history--library
                                  "-f" "agent-dash-history--worker")
                   :sentinel #'agent-dash-history--sentinel))
          (error (kill-buffer output) (kill-buffer stderr)
                 (signal (car err) (cdr err))))
        (puthash key process agent-dash-history--jobs)
        (process-put process 'agent-dash-key key)
        (process-put process 'agent-dash-stderr stderr)
        (process-put process 'agent-dash-timer
                     (run-at-time
                      agent-dash-history-timeout nil
                      (lambda ()
                        (agent-dash-history--finish
                         process (list :ok nil :error "History reader timed out")))))
        (let ((print-length nil) (print-level nil) (print-escape-newlines t))
          (process-send-string
           process
           (concat
            (prin1-to-string
             (list :backend backend :operation operation :id id :load-path load-path
                   :variables (mapcar (lambda (variable) (cons variable (symbol-value variable)))
                                      (seq-filter #'boundp agent-dash-history-worker-variables))))
            "\n")))
        (process-send-eof process)))
    (when callback
      (process-put process 'agent-dash-callbacks
                   (cons callback (process-get process 'agent-dash-callbacks))))
    process))

(provide 'agent-dash-history)
;;; agent-dash-history.el ends here
