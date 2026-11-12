;;; agent-dash-pi.el --- Pi backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; `pi --mode rpc' run by the generic holder.  Translates Pi 1.5 RPC
;; records into unified events; see docs/DESIGN.md §5.1.  The Pi session
;; id is chosen up front with `--session-id', so it also names the
;; holder directory: resuming a session reattaches its live holder.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-holder)
(require 'ansi-color)

(defgroup agent-dash-pi nil "Pi backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-pi-executable "pi"
  "Pi executable."
  :type 'string)

(defcustom agent-dash-pi-arguments nil
  "Extra arguments for new Pi processes, e.g. (\"--model\" \"sonnet\")."
  :type '(repeat string))

(defcustom agent-dash-pi-sessions-directory "~/.pi/agent/sessions/"
  "Directory where Pi saves sessions."
  :type 'directory)

(add-to-list 'agent-dash-backends 'pi t)

(cl-defmethod agent-dash-backend-capabilities ((_ (eql pi)))
  "Pi implementation of `agent-dash-backend-capabilities'."
  (list :quit 'stop :steer t :images t :models t))

;;;; Requests

(defun agent-dash-pi--request (session command &optional callback)
  "Send COMMAND plist to SESSION's Pi; call CALLBACK with (OK DATA ERROR)."
  (let* ((n (1+ (or (agent-dash-data session :counter) 0)))
         (id (format "ad-%d" n))
         (table (or (agent-dash-data session :callbacks)
                    (agent-dash-set-data session :callbacks
                                         (make-hash-table :test #'equal)))))
    (agent-dash-set-data session :counter n)
    (puthash id (or callback #'agent-dash-pi--report) table)
    (agent-dash-holder-write session (append (list :id id) command))))

(defun agent-dash-pi--report (ok _data error)
  "Default request callback: OK or show ERROR."
  (unless ok (message "Pi: %s" error)))

(defun agent-dash-pi--response (session record)
  "Settle the request answered by response RECORD of SESSION."
  (let* ((table (agent-dash-data session :callbacks))
         (id (agent-dash-jget record "id"))
         (callback (and table id (gethash id table))))
    (when callback
      (remhash id table)
      (funcall callback (agent-dash-jget record "success")
               (agent-dash-jget record "data") (agent-dash-jget record "error")))))

;;;; Messages

(defun agent-dash-pi--args (args)
  "Return a one-line summary of tool ARGS."
  (cond ((null args) "")
        ((stringp args) args)
        (t (or (agent-dash-jget args "command") (agent-dash-jget args "path")
               (agent-dash-jget args "file_path")
               (mapconcat (lambda (k) (format "%s=%s" k (gethash k args)))
                          (hash-table-keys args) " ")))))

(defun agent-dash-pi--tool-output (result)
  "Return the text of tool RESULT."
  (agent-dash-json-text (agent-dash-jget result "content")))

(defun agent-dash-pi--blocks (content type key)
  "Concatenate field KEY of CONTENT blocks whose type is TYPE."
  (mapconcat (lambda (b) (if (equal (agent-dash-jget b "type") type)
                             (or (agent-dash-jget b key) "")
                           ""))
             content ""))

(defun agent-dash-pi--message (session message &optional id)
  "Emit the events of complete Pi MESSAGE for SESSION, using ID if given."
  (let ((id (or id (format "%s" (agent-dash-jget message "timestamp"))))
        (content (agent-dash-jget message "content")))
    (pcase (agent-dash-jget message "role")
      ("user"
       (agent-dash-emit session (list :type 'user :id (concat "u" id)
                                      :text (agent-dash-json-text content))))
      ("assistant"
       (let ((text (agent-dash-pi--blocks content "text" "text"))
             (thinking (agent-dash-pi--blocks content "thinking" "thinking")))
         (unless (and (string-empty-p text) (string-empty-p thinking))
           (agent-dash-emit session (list :type 'assistant :id (concat "a" id)
                                          :text text :thinking thinking :final t)))
         (dolist (block content)
           (when (equal (agent-dash-jget block "type") "toolCall")
             (agent-dash-emit session
                              (list :type 'tool :id (agent-dash-jget block "id")
                                    :name (agent-dash-jget block "name")
                                    :args (agent-dash-pi--args
                                           (agent-dash-jget block "arguments"))))))
         (when-let* ((error (agent-dash-jget message "errorMessage")))
           (agent-dash-emit session (list :type 'notice :id (concat "e" id)
                                          :level 'error :text error)))
         (when-let* ((model (agent-dash-jget message "model")))
           (agent-dash-emit session (list :type 'meta :model model)))))
      ("toolResult"
       (agent-dash-emit session
                        (list :type 'tool :id (agent-dash-jget message "toolCallId")
                              :name (agent-dash-jget message "toolName")
                              :output (agent-dash-json-text content)
                              :status (if (agent-dash-jget message "isError")
                                          'error 'success))))
      ("compactionSummary"
       (agent-dash-emit session (list :type 'notice :id (concat "c" id)
                                      :text "earlier context compacted")))
      ;; ponytail: bashExecution, custom and branchSummary are not shown.
      (_ nil))))

(defun agent-dash-pi--stream (session update)
  "Apply streaming assistant UPDATE to SESSION's partial message."
  (let* ((blocks (agent-dash-data session :blocks))
         (index (agent-dash-jget update "contentIndex"))
         (type (agent-dash-jget update "type")))
    (pcase type
      ((or "text_delta" "thinking_delta")
       (let ((old (alist-get index blocks)))
         (setf (alist-get index blocks)
               (cons (if (equal type "text_delta") 'text 'thinking)
                     (concat (cdr old) (agent-dash-jget update "delta"))))))
      ((or "text_end" "thinking_end")
       (setf (alist-get index blocks)
             (cons (if (equal type "text_end") 'text 'thinking)
                   (agent-dash-jget update "content"))))
      ("toolcall_start"
       (agent-dash-emit session (list :type 'tool :id (agent-dash-jget update "id")
                                      :name (agent-dash-jget update "toolName")
                                      :args "" :status 'running))))
    (agent-dash-set-data session :blocks blocks)
    (when (string-match-p "\\`\\(text\\|thinking\\)_" type)
      (let ((sorted (sort (copy-sequence blocks) (lambda (a b) (< (car a) (car b))))))
        (cl-flet ((join (kind) (mapconcat (lambda (b) (if (eq (cadr b) kind) (cddr b) ""))
                                          sorted "")))
          (agent-dash-emit session
                           (list :type 'assistant
                                 :id (concat "a" (agent-dash-data session :live-id))
                                 :text (join 'text) :thinking (join 'thinking))))))))

(defun agent-dash-pi--ui-request (session record)
  "Handle extension UI RECORD of SESSION."
  (let ((id (agent-dash-jget record "id"))
        (title (or (agent-dash-jget record "title") "")))
    (pcase (agent-dash-jget record "method")
      ((and (or "select" "confirm" "input" "editor") method)
       (agent-dash-emit
        session
        (list :type 'request :id id
              :kind (pcase method ("select" 'select) ("confirm" 'confirm) (_ 'input))
              :title (string-trim (concat title " " (or (agent-dash-jget record "message") "")))
              :options (agent-dash-jget record "options")
              :default (agent-dash-jget record "prefill")))
       ;; Pi resolves a timed-out dialog by itself.
       (when-let* ((timeout (agent-dash-jget record "timeout")))
         (run-at-time (/ timeout 1000.0) nil #'agent-dash-emit session
                      (list :type 'request-done :id id))))
      ("notify"
       (agent-dash-emit session
                        (list :type 'notice
                              :level (intern (or (agent-dash-jget record "notifyType") "info"))
                              :text (ansi-color-filter-apply
                                     (or (agent-dash-jget record "message") "")))))
      ("setStatus"
       (agent-dash-emit session
                        (list :type 'meta
                              :status (ansi-color-filter-apply
                                       (or (agent-dash-jget record "statusText") "")))))
      ("setTitle" (agent-dash-emit session (list :type 'meta :title title)))
      ;; ponytail: widgets and set_editor_text are not shown.
      (_ nil))))

(defun agent-dash-pi--record (session record)
  "Translate Pi RPC RECORD into events of SESSION."
  (pcase (agent-dash-jget record "type")
    ("response" (agent-dash-pi--response session record))
    ("agent_start" (agent-dash-emit session '(:type run :state running)))
    ("agent_settled" (agent-dash-emit session '(:type run :state idle)))
    ("message_start"
     (when (equal (agent-dash-jget record "message" "role") "assistant")
       (agent-dash-set-data session :blocks nil)
       (agent-dash-set-data session :live-id
                            (format "%s" (agent-dash-jget record "message" "timestamp")))))
    ("message_update"
     (agent-dash-pi--stream session (agent-dash-jget record "assistantMessageEvent")))
    ("message_end"
     (let ((message (agent-dash-jget record "message")))
       (agent-dash-pi--message
        session message
        (and (equal (agent-dash-jget message "role") "assistant")
             (agent-dash-data session :live-id)))))
    ((or "tool_execution_start" "tool_execution_update" "tool_execution_end")
     (let ((end (equal (agent-dash-jget record "type") "tool_execution_end")))
       (agent-dash-emit
        session
        (append (list :type 'tool :id (agent-dash-jget record "toolCallId")
                      :name (agent-dash-jget record "toolName")
                      :status (cond ((not end) 'running)
                                    ((agent-dash-jget record "isError") 'error)
                                    (t 'success)))
                (when-let* ((args (agent-dash-jget record "args")))
                  (list :args (agent-dash-pi--args args)))
                (when-let* ((result (or (agent-dash-jget record "result")
                                        (agent-dash-jget record "partialResult"))))
                  (list :output (agent-dash-pi--tool-output result)))))))
    ("queue_update"
     (agent-dash-emit session (list :type 'queue
                                    :steering (agent-dash-jget record "steering")
                                    :follow-up (agent-dash-jget record "followUp"))))
    ("thinking_level_changed"
     (agent-dash-emit session (list :type 'meta :thinking (agent-dash-jget record "level"))))
    ("session_info_changed"
     (agent-dash-emit session (list :type 'meta :title (agent-dash-jget record "name"))))
    ("compaction_start"
     (agent-dash-emit session '(:type notice :text "compacting context…")))
    ("auto_retry_start"
     (agent-dash-emit session (list :type 'notice :level 'warning
                                    :text (format "retrying: %s"
                                                  (agent-dash-jget record "errorMessage")))))
    ("extension_error"
     (agent-dash-emit session (list :type 'notice :level 'error
                                    :text (format "extension: %s"
                                                  (agent-dash-jget record "error")))))
    ("extension_ui_request" (agent-dash-pi--ui-request session record))
    ("agent_dash_exit"
     (agent-dash-emit session '(:type run :state dead))
     (agent-dash-emit session (list :type 'notice :level 'warning
                                    :text (format "Pi exited (code %s); C-c C-r resumes"
                                                  (agent-dash-jget record "code")))))
    ;; agent_end, turn_*, compaction_end, auto_retry_end, summarization_*:
    ;; their content arrives through other records.
    (_ nil)))

;;;; Backend methods

(defun agent-dash-pi--on-state (session ok data error)
  "Apply get_state DATA (or ERROR when not OK) to SESSION."
  (if (not ok)
      (agent-dash-emit session (list :type 'notice :level 'error :text error))
    (agent-dash-emit session (list :type 'meta
                                   :model (agent-dash-jget data "model" "id")
                                   :thinking (agent-dash-jget data "thinkingLevel")
                                   :title (agent-dash-jget data "sessionName")))
    (when (agent-dash-jget data "isStreaming")
      (agent-dash-emit session '(:type run :state running)))))

(cl-defmethod agent-dash-backend-start ((_ (eql pi)) session &optional resume-id)
  "Pi `agent-dash-backend-start' for SESSION and RESUME-ID."
  (let* ((sid (or resume-id (agent-dash-uuid)))
         (dir (agent-dash-holder-dir 'pi sid)))
    (agent-dash-set-data session :sid sid)
    (unless (agent-dash-holder-alive-p dir)
      (agent-dash-holder-start
       dir (agent-dash-session-root session)
       (append (list (or (executable-find agent-dash-pi-executable)
                         (user-error "Cannot find `%s'" agent-dash-pi-executable))
                     "--mode" "rpc" "--session-id" sid)
               agent-dash-pi-arguments)))
    ;; RPC has no session header: ask for state and history.
    ;; ponytail: a message that ends between attach and get_messages shows twice.
    (agent-dash-holder-attach session dir #'agent-dash-pi--record)
    (agent-dash-pi--request session '(:type "get_state")
                            (apply-partially #'agent-dash-pi--on-state session))
    (agent-dash-pi--request
     session '(:type "get_messages")
     (lambda (ok data error)
       (if ok
           (dolist (m (agent-dash-jget data "messages"))
             (agent-dash-pi--message session m))
         (agent-dash-emit session (list :type 'notice :level 'error :text error)))))))

(cl-defmethod agent-dash-backend-send ((_ (eql pi)) session text images mode)
  "Pi `agent-dash-backend-send' for SESSION, TEXT, IMAGES and MODE."
  (agent-dash-pi--request
   session
   (append (list :type "prompt" :message text)
           (when images
             (list :images (vconcat (mapcar (lambda (i) (list :type "image"
                                                              :data (plist-get i :data)
                                                              :mimeType (plist-get i :mime-type)))
                                            images))))
           (pcase mode
             ('follow-up '(:streamingBehavior "followUp"))
             ('steer '(:streamingBehavior "steer"))))
   (lambda (ok _data error)
     (unless ok
       (agent-dash-emit session (list :type 'notice :level 'error
                                      :text (format "Not sent (%s); M-p recalls it" error)))))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql pi)) session)
  "Pi `agent-dash-backend-cancel' for SESSION."
  (agent-dash-pi--request session '(:type "abort")))

(cl-defmethod agent-dash-backend-quit ((_ (eql pi)) session)
  "Pi `agent-dash-backend-quit' for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql pi)) session)
  "Pi `agent-dash-backend-detach' for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql pi)) session request answer)
  "Pi `agent-dash-backend-respond' for SESSION, REQUEST and ANSWER."
  (agent-dash-holder-write
   session
   (append (list :type "extension_ui_response" :id (plist-get request :id))
           (if (eq (plist-get request :kind) 'confirm)
               (list :confirmed (if answer t :false))
             (list :value answer)))))

(cl-defmethod agent-dash-backend-models ((_ (eql pi)) session)
  "Pi `agent-dash-backend-models' for SESSION."
  (let (models done)
    (agent-dash-pi--request
     session '(:type "get_available_models")
     (lambda (ok data error)
       (setq done t)
       (if ok
           (setq models (mapcar (lambda (m) (format "%s/%s" (agent-dash-jget m "provider")
                                                    (agent-dash-jget m "id")))
                                (agent-dash-jget data "models")))
         (message "Pi: %s" error))))
    (with-timeout (10 (user-error "Pi did not answer get_available_models"))
      (while (not done) (accept-process-output nil 0.05)))
    models))

(cl-defmethod agent-dash-backend-set-model ((_ (eql pi)) session model)
  "Pi `agent-dash-backend-set-model' for SESSION and MODEL."
  (let ((slash (string-search "/" model)))
    (agent-dash-pi--request session (list :type "set_model"
                                          :provider (substring model 0 slash)
                                          :modelId (substring model (1+ slash)))
                            (lambda (ok _data error)
                              (if ok
                                  (agent-dash-emit session
                                                   (list :type 'meta
                                                         :model (substring model (1+ slash))))
                                (message "Pi: %s" error))))))

(defun agent-dash-pi--session-info (file)
  "Return the session plist of Pi session FILE, or nil if it is not one."
  ;; ponytail: reads only the first 64 KiB for header and first prompt.
  (let* ((lines (agent-dash-file-lines file 65536))
         (header (and lines (agent-dash-json-read (car lines))))
         (prompt (seq-find (lambda (l) (string-search "\"role\":\"user\"" l)) (cdr lines))))
    (when (equal (agent-dash-jget header "type") "session")
      (let ((id (agent-dash-jget header "id")))
        (list :id id :root (agent-dash-jget header "cwd")
              :time (substring (or (agent-dash-jget header "timestamp") "") 0 16)
              :title (if prompt
                         (agent-dash-json-text
                          (agent-dash-jget (agent-dash-json-read prompt) "message" "content"))
                       "(empty)")
              :running (agent-dash-holder-alive-p (agent-dash-holder-dir 'pi id)))))))

(defun agent-dash-pi--file (id)
  "Return the saved session file of Pi session ID, or nil."
  (car (file-expand-wildcards
        (expand-file-name (format "*/*_%s.jsonl" id) agent-dash-pi-sessions-directory))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql pi)) id)
  "Pi `agent-dash-backend-transcript' for ID: the active branch only."
  (let* ((file (or (agent-dash-pi--file id) (user-error "No saved Pi session %s" id)))
         (entries (mapcar #'agent-dash-json-read (agent-dash-file-lines file)))
         (by-id (make-hash-table :test #'equal))
         (entry (car (last entries)))
         turns)
    (dolist (e entries) (puthash (agent-dash-jget e "id") e by-id))
    ;; The file also holds abandoned branches: walk back from the leaf.
    (while entry
      (let ((role (agent-dash-jget entry "message" "role")))
        (when (and (equal (agent-dash-jget entry "type") "message")
                   (member role '("user" "assistant")))
          (let ((text (agent-dash-pi--blocks-text (agent-dash-jget entry "message" "content"))))
            (unless (string-blank-p text)
              (push (cons (intern role) text) turns)))))
      (setq entry (gethash (agent-dash-jget entry "parentId") by-id)))
    turns))

(defun agent-dash-pi--blocks-text (content)
  "Return the text of message CONTENT, a string or blocks."
  (if (stringp content) content (agent-dash-pi--blocks content "text" "text")))

(cl-defmethod agent-dash-backend-sessions ((_ (eql pi)) root)
  "Pi `agent-dash-backend-sessions' for ROOT."
  (let* ((base (expand-file-name agent-dash-pi-sessions-directory))
         (dirs (if root
                   (list (expand-file-name
                          (concat "--" (replace-regexp-in-string
                                        "/" "-" (string-remove-prefix
                                                 "/" (directory-file-name
                                                      (expand-file-name root))))
                                  "--")
                          base))
                 (and (file-directory-p base)
                      (directory-files base t "\\`--")))))
    (sort (delq nil (mapcan (lambda (dir)
                              (and (file-directory-p dir)
                                   (mapcar #'agent-dash-pi--session-info
                                           (directory-files dir t "\\.jsonl\\'"))))
                            dirs))
          (lambda (a b) (string> (plist-get a :time) (plist-get b :time))))))

(provide 'agent-dash-pi)
;;; agent-dash-pi.el ends here
