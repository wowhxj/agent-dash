;;; agent-dash-pi.el --- Pi backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; `pi --mode rpc' run by the generic holder.  Translates Pi 1.5 RPC
;; records into unified events; see docs/DESIGN.md §5.1.  The Pi session
;; id is chosen up front with `--session-id', so it also names the
;; holder directory: resuming a session reattaches its live holder.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-images)
(require 'agent-dash-pi-commands)
(require 'agent-dash-holder)
(require 'ansi-color)
(require 'json)

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
  (list :quit 'stop :steer t :images t :models t :delete t))

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
               (agent-dash-jget args "question")
               (json-encode args)))))

(defun agent-dash-pi--tool-output (result)
  "Return the text of tool RESULT."
  (agent-dash-json-text (agent-dash-jget result "content")))

(defun agent-dash-pi--blocks (content type key)
  "Concatenate field KEY of CONTENT blocks whose type is TYPE."
  (mapconcat (lambda (b) (if (equal (agent-dash-jget b "type") type)
                             (or (agent-dash-jget b key) "")
                           ""))
             content ""))

(defun agent-dash-pi--blocks-text (content)
  "Return the text of message CONTENT, a string or blocks."
  (if (stringp content) content (agent-dash-pi--blocks content "text" "text")))

(defun agent-dash-pi--message (session message &optional id)
  "Emit the events of complete Pi MESSAGE for SESSION, using ID if given."
  (let ((id (or id (format "%s" (agent-dash-jget message "timestamp"))))
        (content (agent-dash-jget message "content")))
    (pcase (agent-dash-jget message "role")
      ("user"
       (agent-dash-emit session (list :type 'user :id (concat "u" id)
                                      :text (agent-dash-json-text content)
                                      :images (agent-dash-images-from-blocks content t))))
      ("assistant"
       (let ((text (agent-dash-pi--blocks content "text" "text"))
             (thinking (agent-dash-pi--blocks content "thinking" "thinking"))
             (images (agent-dash-images-from-blocks content)))
         (unless (and (string-empty-p text) (string-empty-p thinking) (not images))
           (agent-dash-emit session (list :type 'assistant :id (concat "a" id)
                                          :text text :thinking thinking :images images :final t
                                          :process (seq-some
                                                    (lambda (b)
                                                      (equal (agent-dash-jget b "type")
                                                             "toolCall"))
                                                    content))))
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
                              :images (agent-dash-images-from-blocks content)
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
  (let* ((id (agent-dash-jget record "id"))
         (title (or (agent-dash-jget record "title") ""))
         (secret (string-prefix-p "[agent-dash:secret] " title)))
    (pcase (agent-dash-jget record "method")
      ((and (or "select" "confirm" "input" "editor") method)
       (agent-dash-emit
        session
        (append
         (list :type 'request :id id
               :kind (if secret 'secret
                       (pcase method ("select" 'select) ("confirm" 'confirm) (_ 'input)))
               :title (if secret (substring title 20) title)
               :options (agent-dash-jget record "options")
               :default (unless secret (agent-dash-jget record "prefill")))
         (when-let* ((message (agent-dash-jget record "message")))
           (list :message message))
         (when-let* ((placeholder (and (not secret) (agent-dash-jget record "placeholder"))))
           (list :placeholder placeholder))))
       ;; Pi resolves a timed-out dialog by itself.
       (when-let* ((timeout (agent-dash-jget record "timeout")))
         (run-at-time (/ timeout 1000.0) nil #'agent-dash-emit session
                      (list :type 'request-done :id id :status 'cancelled))))
      ("dismiss_dialog"
       (agent-dash-emit session (list :type 'request-done :id id :status 'cancelled)))
      ("notify"
       (let ((message (or (agent-dash-jget record "message") "")))
         (if (string-prefix-p "[agent-dash:native] " message)
             (condition-case nil
                 (agent-dash-pi-native-record
                  session (agent-dash-json-read (substring message 20)))
               (json-error (message "Pi sent an invalid native-command result")))
           (agent-dash-emit
            session (list :type 'notice
                          :level (intern (or (agent-dash-jget record "notifyType") "info"))
                          :text (ansi-color-filter-apply message))))))
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
    ((or "agent_dash_native_started" "agent_dash_native_result")
     (agent-dash-pi-native-record session record))
    ("response" (agent-dash-pi--response session record))
    ("agent_start"
     (agent-dash-emit session '(:type meta :phase "waiting for model"))
     (agent-dash-emit session '(:type run :state running)))
    ("agent_end"
     (dolist (request (copy-sequence (agent-dash-session-requests session)))
       (agent-dash-emit session (list :type 'request-done :id (plist-get request :id)
                                      :status 'cancelled))))
    ("agent_settled"
     (agent-dash-emit session '(:type run :state idle))
     (agent-dash-pi--refresh-stats session))
    ("message_start"
     (when (equal (agent-dash-jget record "message" "role") "assistant")
       (agent-dash-set-data session :blocks nil)
       (agent-dash-set-data session :live-id
                            (format "%s" (agent-dash-jget record "message" "timestamp")))))
    ("message_update"
     (agent-dash-emit session '(:type meta :phase "responding"))
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
                  (list :output (agent-dash-pi--tool-output result)
                        :images (agent-dash-images-from-blocks
                                 (agent-dash-jget result "content"))))))))
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
     (agent-dash-pi-native-reset session)
     (agent-dash-emit session '(:type run :state dead))
     (agent-dash-emit session (list :type 'notice :level 'warning
                                    :text (format "Pi exited (code %s); C-c C-r resumes"
                                                  (agent-dash-jget record "code")))))
    ;; turn_*, compaction_end, auto_retry_end, summarization_*:
    ;; their content arrives through other records.
    (_ nil)))

;;;; Backend methods

(defun agent-dash-pi--refresh-stats (session)
  "Refresh cached SESSION statistics without invoking a model."
  (when-let* ((writer (agent-dash-data session :writer)))
    (when (process-live-p writer)
      (condition-case nil
          (agent-dash-pi--request
           session '(:type "get_session_stats")
           (lambda (ok data _error)
             (when ok
               (agent-dash-emit
                session (list :type 'meta :stats data
                              :context-usage (agent-dash-jget data "contextUsage"))))))
        ;; The process can exit between the settled event and this query.
        (user-error nil)))))

(defun agent-dash-pi--on-state (session ok data error)
  "Apply get_state DATA (or ERROR when not OK) to SESSION."
  (if (not ok)
      (agent-dash-emit session (list :type 'notice :level 'error :text error))
    (agent-dash-emit session (list :type 'meta
                                   :model (agent-dash-jget data "model" "id")
                                   :provider (agent-dash-jget data "model" "provider")
                                   :thinking (agent-dash-jget data "thinkingLevel")
                                   :title (agent-dash-jget data "sessionName")))
    (when (agent-dash-jget data "isStreaming")
      (agent-dash-emit session '(:type run :state running)))))

(defun agent-dash-pi--branch-messages (entries leaf-id)
  "Return chronological messages on LEAF-ID's branch of ENTRIES.
Keep pre-compaction messages, but never replay abandoned branches."
  (let ((by-id (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal)) messages)
    (dolist (entry entries) (puthash (agent-dash-jget entry "id") entry by-id))
    (while (gethash leaf-id by-id)
      (when (gethash leaf-id seen) (error "Cycle in Pi session history"))
      (puthash leaf-id t seen)
      (let ((entry (gethash leaf-id by-id)))
        (when (equal (agent-dash-jget entry "type") "message")
          (push (agent-dash-jget entry "message") messages))
        (setq leaf-id (agent-dash-jget entry "parentId"))))
    messages))

(defun agent-dash-pi--load-history (session &optional context-only)
  "Replay SESSION's complete active branch, or CONTEXT-ONLY for older Pi."
  (agent-dash-pi--request
   session (list :type (if context-only "get_messages" "get_entries"))
   (lambda (ok data error)
     (cond
      (ok
       (dolist (message (if context-only (agent-dash-jget data "messages")
                          (agent-dash-pi--branch-messages
                           (agent-dash-jget data "entries") (agent-dash-jget data "leafId"))))
         (agent-dash-pi--message session message))
       (agent-dash-set-data session :history-loaded t)
       (agent-dash-pi--refresh-stats session))
      ((not context-only)
       (agent-dash-emit session '(:type notice :level warning
                                        :text "Full history unavailable; showing current context"))
       (agent-dash-pi--load-history session t))
      (t (agent-dash-emit session (list :type 'notice :level 'error :text error)))))))

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
                     "--mode" "rpc" "--extension" agent-dash-pi-bridge-file)
               (if resume-id
                   (list "--session"
                         (or (agent-dash-pi--file resume-id)
                             (user-error "No saved Pi session %s" resume-id)))
                 (list "--session-id" sid))
               agent-dash-pi-arguments)))
    ;; RPC has no session header: ask for state and the complete active branch.
    (agent-dash-holder-attach session dir #'agent-dash-pi--record)
    (agent-dash-pi--request session '(:type "get_state")
                            (apply-partially #'agent-dash-pi--on-state session))
    (agent-dash-pi--load-history session)))

(cl-defmethod agent-dash-backend-send ((_ (eql pi)) session text images mode)
  "Pi `agent-dash-backend-send' for SESSION, TEXT, IMAGES and MODE."
  (when (agent-dash-data session :pi-native-pending)
    (user-error "Finish the pending Pi native command first"))
  (if (agent-dash-pi-native-command-p session text)
      (progn
        (when images (user-error "Remove images before running Pi commands"))
        (agent-dash-backend-command 'pi session text mode))
    (let ((token (agent-dash-data session :image-draft-token)))
      (agent-dash-pi--request
       session
       (append (list :type "prompt" :message text)
               (when images
                 (list :images (vconcat (mapcar (lambda (i)
                                                  (list :type "image" :data (plist-get i :data)
                                                        :mimeType (plist-get i :mime-type)))
                                                images))))
               (pcase mode
                 ('follow-up '(:streamingBehavior "followUp"))
                 ('steer '(:streamingBehavior "steer"))))
       (lambda (ok _data error)
         (unless ok
           (if images (agent-dash-image-send-failed session token error)
             (agent-dash-emit session (list :type 'notice :level 'error
                                            :text (format "Not sent (%s); M-p recalls it"
                                                          error))))))))))

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
           (cond
            ((eq answer :cancelled) '(:cancelled t))
            ((eq (plist-get request :kind) 'confirm)
             (list :confirmed (if answer t :false)))
            (t (list :value answer))))))

(cl-defmethod agent-dash-backend-commands ((_ (eql pi)) session)
  "Read Pi's RPC command catalog for SESSION without invoking a model."
  (let (done commands)
    (agent-dash-pi--request
     session '(:type "get_commands")
     (lambda (ok data _error)
       (setq done t)
       (when ok
         (setq commands (agent-dash-pi-command-catalog session
                                                       (agent-dash-jget data "commands")))
         (agent-dash-set-data session :command-catalog commands))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (unless done
      (message "Pi command catalog is loading; reopen TAB completion when ready"))
    (or commands (agent-dash-pi-native-commands session))))

(cl-defmethod agent-dash-backend-command ((_ (eql pi)) session text mode)
  "Execute native Pi TEXT in SESSION with MODE, using RPC for /compact."
  (if (string-match "\\`/compact\\(?:[[:space:]]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'" text)
      (progn
        (unless (eq (agent-dash-session-state session) 'idle)
          (user-error "Stop the current task before compacting"))
        (agent-dash-pi--request
         session (append '(:type "compact")
                         (when (match-string 1 text)
                           (list :customInstructions (match-string 1 text))))
         (lambda (ok _data error)
           (agent-dash-emit session (list :type 'notice :level (if ok 'info 'error)
                                          :text (if ok "Context compacted" error)))
           (when ok (agent-dash-pi--refresh-stats session)))))
    (unless (string-match
             "\\`/\\([^[:space:]]+\\)\\(?:[[:space:]]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'" text)
      (user-error "Invalid Pi command"))
    (let ((name (match-string 1 text)) (args (string-trim (or (match-string 2 text) ""))))
      (if (assoc name (agent-dash-pi-native-commands session))
          (agent-dash-pi-native-execute session name args)
        (unless (and (not (equal name "agent-dash-native"))
                     (assoc name (or (agent-dash-data session :command-catalog)
                                     (agent-dash-backend-commands 'pi session))))
          (user-error "Unknown Pi command /%s; not sent to a model" name))
        (agent-dash-backend-send 'pi session text nil mode)))))

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
                                                         :provider (substring model 0 slash)
                                                         :model (substring model (1+ slash))))
                                (message "Pi: %s" error))))))

(defun agent-dash-pi--user-entry (line)
  "Return the parsed entry of LINE if it is a user message with text or an image."
  (when (string-match-p "\"role\"[ \t]*:[ \t]*\"user\"" line)
    (condition-case nil
        (let ((entry (agent-dash-json-read line)))
          (when (and (equal (agent-dash-jget entry "message" "role") "user")
                     (not (string-blank-p (agent-dash-pi--entry-text entry))))
            entry))
      (json-error
       (push "Pi: malformed user record" agent-dash-history-warnings)
       nil))))

(defun agent-dash-pi--entry-text (entry)
  "Return the user text of message ENTRY."
  (let* ((content (agent-dash-jget entry "message" "content")))
    (let ((text (agent-dash-pi--blocks-text content)))
      (if (and (string-blank-p text) (agent-dash-images-from-blocks content)) "[image]" text))))

(defun agent-dash-pi--session-info (file)
  "Return the session plist of Pi session FILE, or nil if it is not one."
  ;; ponytail: the first prompt is looked for in the first 256 KiB only.
  (let* ((head (agent-dash-file-lines file (* 256 1024)))
         (header (and head (agent-dash-json-read (car head)))))
    (when (equal (agent-dash-jget header "type") "session")
      (let* ((id (agent-dash-jget header "id"))
             (first (seq-some #'agent-dash-pi--user-entry (cdr head)))
             (last (agent-dash-file-find-last file #'agent-dash-pi--user-entry))
             (time (agent-dash-iso-seconds (agent-dash-jget last "timestamp"))))
        (list :id id :root (agent-dash-jget header "cwd") :file file
              :first (and first (agent-dash-pi--entry-text first))
              :last (and last (agent-dash-pi--entry-text last))
              :time (or time (agent-dash-mtime file)) :exact (and time t)
              :empty (not (or first last))
              :running (agent-dash-holder-alive-p (agent-dash-holder-dir 'pi id)))))))

(defun agent-dash-pi--file (id)
  "Return the saved session file of Pi session ID, or nil."
  (seq-find (lambda (file)
              (equal id (plist-get (agent-dash-pi--session-info file) :id)))
            (agent-dash-pi--files id)))

(defun agent-dash-pi--files (&optional id)
  "Return saved Pi JSONL files in every layout, optionally matching ID."
  (let ((base (expand-file-name agent-dash-pi-sessions-directory)))
    (when (file-directory-p base)
      (directory-files-recursively
       base (if id (concat "\\(?:\\`\\|_\\)" (regexp-quote id) "\\.jsonl\\'")
              "\\.jsonl\\'")))))

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

(cl-defmethod agent-dash-backend-delete ((_ (eql pi)) session)
  "Pi `agent-dash-backend-delete' for SESSION."
  (agent-dash-delete-file (plist-get session :file) agent-dash-pi-sessions-directory
                          (plist-get session :id)))

(cl-defmethod agent-dash-backend-sessions ((_ (eql pi)) root)
  "Pi `agent-dash-backend-sessions' for ROOT."
  (let ((want (and root (directory-file-name (expand-file-name root)))))
    (sort (delq nil
                (mapcar
                 (lambda (file)
                   (condition-case err
                       (let* ((row (agent-dash-pi--session-info file))
                              (cwd (plist-get row :root)))
                         (when (and row (or (not want)
                                            (and cwd (equal want (directory-file-name
                                                                  (expand-file-name cwd))))))
                           row))
                     (error
                      (push (format "%s: %s" file (car err)) agent-dash-history-warnings)
                      nil)))
                 (agent-dash-pi--files)))
          (lambda (a b) (> (plist-get a :time) (plist-get b :time))))))

(provide 'agent-dash-pi)
;;; agent-dash-pi.el ends here
