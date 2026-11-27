;;; agent-dash-agy.el --- Google Antigravity CLI backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Run `agy acp' for chat and access saved conversations through ACP.

;;; Code:

(require 'agent-dash-acp)
(require 'url-util)

(defgroup agent-dash-agy nil "Antigravity backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-agy-executable "agy"
  "Google Antigravity CLI executable."
  :type 'string)

(defcustom agent-dash-agy-directory "~/.gemini/antigravity-cli/"
  "Antigravity CLI native session and settings directory."
  :type 'directory)

(defcustom agent-dash-agy-magpie 'auto
  "Whether to use Magpie's active Antigravity gateway for ACP.
With `auto', discover Magpie for the default `agy' executable and profile.
A string specifies a Magpie executable explicitly.  Nil uses native ACP."
  :type '(choice (const :tag "Automatically discover Magpie" auto)
                 (const :tag "Native ACP only" nil)
                 (file :tag "Magpie executable")))

(defcustom agent-dash-agy-default-permission nil
  "Mode to request for new Antigravity sessions when the server offers it.
Nil uses the server default.  Resumed sessions keep their saved mode."
  :type '(choice (const :tag "Server default" nil)
                 (const "default") (const "accept-edits") (const "plan")
                 (const "auto")))

(defconst agent-dash-agy--acp-launcher
  (expand-file-name "agent-dash-agy-acp.py" (file-name-directory load-file-name))
  "Path to the Magpie-aware ACP launcher.")

(add-to-list 'agent-dash-backends 'agy t)

(defun agent-dash-agy--magpie ()
  "Return the configured Magpie executable, if enabled for this profile."
  (cond ((stringp agent-dash-agy-magpie)
         (or (executable-find agent-dash-agy-magpie)
             (user-error "Cannot find Magpie executable %s" agent-dash-agy-magpie)))
        ((and (eq agent-dash-agy-magpie 'auto)
              (equal agent-dash-agy-executable "agy")
              (equal (file-name-as-directory (expand-file-name agent-dash-agy-directory))
                     (expand-file-name "~/.gemini/antigravity-cli/")))
         (or (executable-find "magpie")
             (let ((app "/Applications/magpie.app/Contents/MacOS/magpie"))
               (and (file-executable-p app) app))))))

(defun agent-dash-agy--executable ()
  "Return the absolute Antigravity CLI executable."
  (or (executable-find agent-dash-agy-executable)
      (user-error "Cannot find `%s'" agent-dash-agy-executable)))

(defun agent-dash-agy--command ()
  "Return the Antigravity ACP command line."
  (let ((home (directory-file-name (expand-file-name agent-dash-agy-directory)))
        (magpie (agent-dash-agy--magpie)))
    (append (when magpie
              (list (or (executable-find "python3") (user-error "Cannot find python3"))
                    "-B" agent-dash-agy--acp-launcher magpie))
            (list (agent-dash-agy--executable) "acp"
                  "--gemini-dir" (directory-file-name (file-name-directory home))
                  "--app-data-dir" (file-name-nondirectory home)))))

(cl-defmethod agent-dash-backend-capabilities ((_ (eql agy)))
  "Return the capabilities of Antigravity."
  (list :quit 'stop :images t :models t))

(cl-defmethod agent-dash-backend-start ((_ (eql agy)) session &optional resume-id)
  "Start SESSION or reconnect to RESUME-ID."
  (agent-dash-set-data session :agy-initial-mode
                       (unless resume-id agent-dash-agy-default-permission))
  (agent-dash-acp-start session (agent-dash-agy--command) resume-id #'agent-dash-agy--record))

(cl-defmethod agent-dash-backend-send ((_ (eql agy)) session text images _mode)
  "Send TEXT and IMAGES to SESSION."
  (agent-dash-acp-send session text images))

(cl-defmethod agent-dash-backend-cancel ((_ (eql agy)) session)
  "Cancel the current turn in SESSION."
  (agent-dash-acp-cancel session))

(cl-defmethod agent-dash-backend-quit ((_ (eql agy)) session)
  "Stop the Antigravity process for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql agy)) session)
  "Detach the chat buffer from the Antigravity process for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql agy)) session request answer)
  "Send ANSWER to the permission REQUEST in SESSION."
  (agent-dash-acp-respond session request answer))

(cl-defmethod agent-dash-backend-commands ((_ (eql agy)) session)
  "Return commands announced by SESSION."
  (agent-dash-data session :command-catalog))

(cl-defmethod agent-dash-backend-models ((_ (eql agy)) session)
  "Return model identifiers available in SESSION."
  (or (mapcar (lambda (option) (agent-dash-jget option "value"))
              (agent-dash-jget (agent-dash-data session :acp-model) "options"))
      (user-error "Antigravity has not advertised any models for this session")))

(defun agent-dash-agy--set-option (session option value)
  "Set ACP configuration OPTION to VALUE in SESSION."
  (unless (eq (agent-dash-session-state session) 'idle)
    (user-error "Wait for Antigravity to finish the active turn"))
  (agent-dash-holder-request
   session "session/set_config_option"
   (list :sessionId (or (agent-dash-data session :sid) (user-error "ACP session is not ready"))
         :configId (or (agent-dash-jget option "id") (user-error "ACP option is unavailable"))
         :value value)))

(cl-defmethod agent-dash-backend-set-model ((_ (eql agy)) session model)
  "Select MODEL in SESSION."
  (agent-dash-agy--set-option session (agent-dash-data session :acp-model) model))

(defun agent-dash-agy-set-permission (session args)
  "Select an advertised permission mode for SESSION, optionally via ARGS."
  (let* ((option (agent-dash-data session :agy-mode))
         (options (agent-dash-jget option "options"))
         (modes (mapcar (lambda (row) (agent-dash-jget row "value")) options))
         (current (agent-dash-jget option "currentValue")))
    (unless modes (user-error "Antigravity has not advertised any session modes"))
    (let* ((completion-extra-properties
            (list :annotation-function
                  (lambda (mode)
                    (let ((row (seq-find (lambda (entry)
                                           (equal mode (agent-dash-jget entry "value")))
                                         options)))
                      (concat "  " (agent-dash-jget row "description"))))))
           (mode (if (string-empty-p args)
                     (completing-read "Antigravity permission mode: " modes nil t nil nil current)
                   args)))
      (unless (member mode modes)
        (user-error "Available Antigravity modes: %s" (string-join modes ", ")))
      (agent-dash-agy--set-option session option mode))))

(defun agent-dash-agy-set-thinking (session args)
  "Set the thinking level for SESSION to ARGS, or prompt for a level."
  (let* ((option (agent-dash-data session :acp-thinking))
         (choices (mapcar (lambda (row) (agent-dash-jget row "value"))
                          (agent-dash-jget option "options")))
         (level (if (and choices (string-empty-p args))
                    (completing-read "Thinking: " choices nil t nil nil
                                     (agent-dash-jget option "currentValue"))
                  args)))
    (unless (member level choices)
      (user-error "Antigravity thinking levels: %s" (or (and choices (string-join choices ", "))
                                                        "unavailable")))
    (agent-dash-agy--set-option session option level)))

(defun agent-dash-agy--session-index ()
  "Return native Antigravity inventory metadata keyed by conversation ID."
  (let ((index (make-hash-table :test #'equal))
        (file (expand-file-name "conversation_summaries.db" agent-dash-agy-directory)))
    (when (file-readable-p file)
      (condition-case err
          (dolist (row (agent-dash-sqlite-rows
                        file (concat "SELECT conversation_id, step_count, parent_conversation_id, "
                                     "app_data_dir, workspace_uris, last_modified_time "
                                     "FROM conversation_summaries")))
            (puthash (agent-dash-jget row "conversation_id") row index))
        (error (push (error-message-string err) agent-dash-history-warnings))))
    index))

(defun agent-dash-agy--native-file (id)
  "Return the local trajectory file for ID, if available."
  (when (and (stringp id) (string-match-p "\\`[[:alnum:]_-]+\\'" id))
    (let ((file (expand-file-name (concat "conversations/" id ".db")
                                  agent-dash-agy-directory)))
      (when (and (file-regular-p file) (not (file-symlink-p file))) file))))

(defconst agent-dash-agy--images-reader
  (expand-file-name "agent-dash-agy-images.py" (file-name-directory load-file-name))
  "Reader for embedded images omitted by Antigravity's ACP replay.")

(defun agent-dash-agy--native-prompts (id)
  "Read the ordered native prompts and embedded images of ID, when available."
  (when-let* ((file (agent-dash-agy--native-file id))
              (python (executable-find "python3")))
    (with-temp-buffer
      (when (eq 0 (process-file python nil (list (current-buffer) nil) nil
                                "-B" agent-dash-agy--images-reader file
                                (number-to-string agent-dash-image-max-bytes)))
        (agent-dash-json-read (buffer-string))))))

(defun agent-dash-agy--restore-images (session id &optional allow-prefix)
  "Attach native images to matching user messages of SESSION ID.
With ALLOW-PREFIX, the holder might still be replaying later prompts."
  (let ((users (seq-filter (lambda (item) (eq (plist-get item :type) 'user))
                           (agent-dash-session-items session)))
        (prompts (ignore-errors (agent-dash-agy--native-prompts id))))
    (when allow-prefix
      (setq prompts (seq-take prompts (length users))))
    ;; Match in order so repeated prompts stay associated with their own images.
    (when (equal (mapcar (lambda (item) (plist-get item :text)) users)
                 (mapcar (lambda (prompt) (agent-dash-jget prompt "text")) prompts))
      (cl-mapc
       (lambda (item prompt)
         (unless (plist-get item :images)
           (let ((images
                  (delq nil
                        (mapcar (lambda (data)
                                  (when-let* ((bytes (ignore-errors (base64-decode-string data)))
                                              (mime (agent-dash-image--mime bytes)))
                                    (list :mime-type mime :data data :name "image")))
                                (agent-dash-jget prompt "images")))))
             (when images
               (agent-dash-emit session (list :type 'user :id (plist-get item :id)
                                              :images images))))))
       users prompts))))

(defun agent-dash-agy--record (session record)
  "Apply ACP RECORD to SESSION and supplement the completed history replay."
  (agent-dash-acp-record session record)
  (let* ((update (agent-dash-jget record "params" "update"))
         (result (agent-dash-jget record "result"))
         (options (or (agent-dash-jget result "configOptions")
                      (and (equal (agent-dash-jget update "sessionUpdate") "config_option_update")
                           (agent-dash-jget update "configOptions")))))
    (when-let* ((mode (seq-find (lambda (option) (equal (agent-dash-jget option "id") "mode"))
                                options)))
      (agent-dash-set-data session :agy-mode mode)
      (when-let* ((sid (agent-dash-jget result "sessionId"))
                  (initial (agent-dash-data session :agy-initial-mode)))
        (agent-dash-set-data session :agy-initial-mode nil)
        (condition-case err
            (unless (equal initial (agent-dash-jget mode "currentValue"))
              (agent-dash-agy-set-permission session initial))
          (user-error (message "%s (session %s)" (error-message-string err) sid))))))
  (when-let* ((id (agent-dash-jget record "result" "sessionId")))
    (when (agent-dash-session-items session)
      (agent-dash-agy--restore-images session id agent-dash-replaying))))

(defun agent-dash-agy--workspace (meta)
  "Return a local project directory from native metadata META."
  (let ((uris (ignore-errors (agent-dash-json-read (agent-dash-jget meta "workspace_uris")))))
    (seq-some (lambda (uri)
                (when (and (stringp uri) (string-prefix-p "file:///" uri))
                  (decode-coding-string (url-unhex-string (substring uri 7)) 'utf-8)))
              (and (listp uris) uris))))

(defun agent-dash-agy--sessions (root)
  "List saved Antigravity sessions for ROOT without replaying their dialogue."
  (when (executable-find agent-dash-agy-executable)
    (let ((rows (agent-dash-acp-sessions 'agy (agent-dash-agy--command) root))
          (index (agent-dash-agy--session-index))
          (home (file-name-nondirectory (directory-file-name
                                         (expand-file-name agent-dash-agy-directory))))
          (seen (make-hash-table :test #'equal)) result)
      (dolist (row rows)
        (let* ((id (plist-get row :id))
               (meta (gethash id index))
               (store (agent-dash-jget meta "app_data_dir"))
               (parent (agent-dash-jget meta "parent_conversation_id"))
               (file (agent-dash-agy--native-file id)))
          (puthash id t seen)
          ;; Some versions index Antigravity Desktop as well as the CLI.
          (when (or file (member store (list nil "" home)))
            (when (equal (plist-get row :title) "") (plist-put row :title nil))
            (push (append row (list :file file :empty (equal (agent-dash-jget meta "step_count") 0)
                                    :subagent (and (stringp parent) (not (string-empty-p parent)))))
                  result))))
      ;; ACP may omit empty conversations, including holders just opened in Emacs.
      (maphash
       (lambda (id meta)
         (when-let* (((not (gethash id seen)))
                     ((equal (agent-dash-jget meta "step_count") 0))
                     (cwd (agent-dash-agy--workspace meta))
                     (file (agent-dash-agy--native-file id)))
           (when (or (not root) (file-equal-p root cwd))
             (push (list :id id :root cwd :file file :empty t
                         :time (max 0 (or (agent-dash-iso-seconds
                                           (agent-dash-jget meta "last_modified_time")) 0))
                         :running (and (agent-dash-holder-find 'agy id) t)) result))))
       index)
      (nreverse result))))

(defun agent-dash-agy--transcript (command row &optional timeout)
  "Replay Antigravity ROW via COMMAND, waiting at most TIMEOUT seconds."
  (unless (plist-get row :empty)
    (let ((root (plist-get row :root)))
      (agent-dash-acp-transcript command (plist-get row :id)
                                 (if (and root (not (file-remote-p root)) (file-directory-p root))
                                     root temporary-file-directory)
                                 timeout))))

(cl-defmethod agent-dash-backend-sessions ((_ (eql agy)) root)
  "List saved Antigravity sessions for ROOT with their first and last user prompts."
  (when-let* ((rows (agent-dash-agy--sessions root)))
    (let ((command (agent-dash-agy--command)))
      (mapcar
       (lambda (row)
         (condition-case err
             (let ((users (seq-filter
                           (lambda (turn) (and (eq (car turn) 'user)
                                               (not (string-blank-p (cdr turn)))))
                           (agent-dash-agy--transcript command row 8))))
               (if users (append row (list :first (cdar users) :last (cdr (car (last users)))))
                 row))
           (error
            (push (format "Antigravity %s: %s" (plist-get row :id) (error-message-string err))
                  agent-dash-history-warnings)
            row)))
       rows))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql agy)) id)
  "Read the saved Antigravity conversation with ID."
  (let ((row (seq-find (lambda (session) (equal (plist-get session :id) id))
                       (agent-dash-agy--sessions nil))))
    (unless row (user-error "No saved Antigravity session %s" id))
    (agent-dash-agy--transcript (agent-dash-agy--command) row)))

(cl-defmethod agent-dash-backend-history-items ((_ (eql agy)) row)
  "Replay saved Antigravity history for ROW as a timeline."
  (let* ((root (plist-get row :root))
         (cwd (if (and root (not (file-remote-p root)) (file-directory-p root))
                  root temporary-file-directory))
         (id (plist-get row :id))
         (session (agent-dash-session-create 'agy cwd))
         (agent-dash-event-functions nil)
         (agent-dash-update-functions nil))
    (unless (plist-get row :empty)
      (agent-dash-acp-load-history session (agent-dash-agy--command) id cwd)
      (agent-dash-agy--restore-images session id))
    session))

(provide 'agent-dash-agy)
;;; agent-dash-agy.el ends here
