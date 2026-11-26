;;; agent-dash-hermes.el --- Hermes (ACP) backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; Hermes uses ACP for live chat and SQLite for native history.

;;; Code:

(require 'agent-dash-acp)

(defgroup agent-dash-hermes nil "Hermes backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-hermes-executable "hermes"
  "Hermes executable."
  :type 'string)

(defcustom agent-dash-hermes-directory (or (getenv "HERMES_HOME") "~/.hermes/")
  "Hermes native history directory."
  :type 'directory)

(add-to-list 'agent-dash-backends 'hermes t)

(cl-defmethod agent-dash-backend-capabilities ((_ (eql hermes)))
  "Hermes implementation of `agent-dash-backend-capabilities'."
  (list :quit 'stop :steer nil :images t :models nil))

(defun agent-dash-hermes--command ()
  "Return the ACP command line."
  (list (or (executable-find agent-dash-hermes-executable)
            (user-error "Cannot find `%s'" agent-dash-hermes-executable))
        "acp"))

(cl-defmethod agent-dash-backend-commands ((_ (eql hermes)) session)
  "Return SESSION's advertised ACP commands."
  (agent-dash-data session :command-catalog))

(cl-defmethod agent-dash-backend-start ((_ (eql hermes)) session &optional resume-id)
  "Start SESSION or reconnect to RESUME-ID."
  (agent-dash-acp-start session (agent-dash-hermes--command) resume-id))

(cl-defmethod agent-dash-backend-send ((_ (eql hermes)) session text images _mode)
  "Send TEXT and IMAGES to SESSION."
  (agent-dash-acp-send session text images))

(cl-defmethod agent-dash-backend-cancel ((_ (eql hermes)) session)
  "Cancel the current turn in SESSION."
  (agent-dash-acp-cancel session))

(cl-defmethod agent-dash-backend-quit ((_ (eql hermes)) session)
  "Hermes `agent-dash-backend-quit' for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql hermes)) session)
  "Hermes `agent-dash-backend-detach' for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql hermes)) session request answer)
  "Send ANSWER to the permission REQUEST in SESSION."
  (agent-dash-acp-respond session request answer))

(defun agent-dash-hermes--index ()
  "Return the existing native history index, or nil."
  (let ((file (expand-file-name "state.db" agent-dash-hermes-directory)))
    (when (file-exists-p file) file)))

(defun agent-dash-hermes--saved-messages (file id)
  "Read active dialogue of session ID from native index FILE."
  (delq
   nil
   (mapcar
    (lambda (message)
      (let* ((role (agent-dash-jget message "role"))
             (raw (agent-dash-jget message "content"))
             (content (if (stringp raw)
                          (condition-case nil (agent-dash-json-read raw)
                            (json-error raw)) raw))
             (text (if (or (stringp content) (listp content))
                       (agent-dash-json-text content) ""))
             (images (agent-dash-images-from-blocks content)))
        (when (and (member role '("user" "assistant"))
                   (member (agent-dash-jget message "display_kind") '(nil ""))
                   (member (agent-dash-jget message "_compressed_summary") '(nil 0 ""))
                   (not (and (equal (agent-dash-jget message "active") 0)
                             (equal (agent-dash-jget message "compacted") 0)))
                   (or (not (string-blank-p text)) images)
                   (not (string-match-p
                         (concat "\\`\\(?:\\[CONTEXT COMPACTION — REFERENCE ONLY\\]"
                                 "\\|\\[CONTEXT SUMMARY\\]:\\)")
                         (string-trim-left text)))
                   (not (string-search "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]" text)))
          (list :role role :text text :images images
                :time (agent-dash-jget message "timestamp")))))
    (agent-dash-sqlite-rows
     file (concat "SELECT * FROM messages WHERE session_id=" (agent-dash-sqlite-quote id)
                  " ORDER BY timestamp, rowid")))))

(defun agent-dash-hermes--saved-sessions (file root)
  "Read native sessions from FILE, optionally filtered to ROOT."
  (mapcar
   (lambda (row)
     (let* ((id (agent-dash-jget row "id"))
            (users (seq-filter (lambda (m) (equal (plist-get m :role) "user"))
                               (agent-dash-hermes--saved-messages file id)))
            (time (plist-get (car (last users)) :time))
            (config (condition-case nil
                        (agent-dash-json-read (or (agent-dash-jget row "model_config") "{}"))
                      (json-error nil))))
       (list :id id :root (agent-dash-jget row "cwd") :title (agent-dash-jget row "title")
             :first (plist-get (car users) :text) :last (plist-get (car (last users)) :text)
             :time (or (and (numberp time) time) (agent-dash-iso-seconds time)
                       (agent-dash-jget row "started_at") 0)
             :exact (and time t) :empty (not users)
             :archived (equal (agent-dash-jget row "archived") 1)
             :subagent (or (equal (agent-dash-jget row "source") "subagent")
                           (and (agent-dash-jget config "_delegate_from") t))
             :running (and (agent-dash-holder-find 'hermes id) t))))
   (agent-dash-sqlite-rows
    file (concat "SELECT * FROM sessions"
                 (when root (concat " WHERE cwd=" (agent-dash-sqlite-quote
                                                   (directory-file-name
                                                    (expand-file-name root)))))))))

(cl-defmethod agent-dash-backend-sessions ((_ (eql hermes)) root)
  "Hermes `agent-dash-backend-sessions' for ROOT.
Read the native index when present; ACP listing alone omits CLI history."
  (if-let* ((index (agent-dash-hermes--index)))
      (agent-dash-hermes--saved-sessions index root)
    (agent-dash-acp-sessions 'hermes (agent-dash-hermes--command) root)))

(cl-defmethod agent-dash-backend-transcript ((_ (eql hermes)) id)
  "Hermes `agent-dash-backend-transcript' for ID from native history or ACP."
  (if-let* ((index (agent-dash-hermes--index)))
      (mapcar (lambda (message) (cons (intern (plist-get message :role))
                                      (plist-get message :text)))
              (agent-dash-hermes--saved-messages index id))
    (let* ((info (or (seq-find (lambda (s) (equal (plist-get s :id) id))
                               (agent-dash-backend-sessions 'hermes nil))
                     (user-error "No saved Hermes session %s" id))))
      (agent-dash-acp-transcript (agent-dash-hermes--command) id (plist-get info :root)))))

(provide 'agent-dash-hermes)
;;; agent-dash-hermes.el ends here
