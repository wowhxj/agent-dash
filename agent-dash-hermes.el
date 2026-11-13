;;; agent-dash-hermes.el --- Hermes (ACP) backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; `hermes acp' speaks the Agent Client Protocol (JSON-RPC 2.0 on stdio)
;; and runs under the generic holder.  ACP streams chunks without ids
;; and never echoes live prompts, so prompts are logged as
;; `agent_dash_user' records and items are numbered in log order;
;; attaching replays the whole log, giving the same ids every time.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-images)
(require 'agent-dash-holder)

(defgroup agent-dash-hermes nil "Hermes backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-hermes-executable "hermes"
  "Hermes executable."
  :type 'string)

(defcustom agent-dash-hermes-directory (or (getenv "HERMES_HOME") "~/.hermes/")
  "Hermes native history directory."
  :type 'directory)

(add-to-list 'agent-dash-backends 'hermes t)

(defconst agent-dash-hermes--client
  (list :protocolVersion 1
        :clientCapabilities '(:fs (:readTextFile :false :writeTextFile :false)
                                  :terminal :false))
  "Initialize parameters: the client offers no file system or terminal.")

(cl-defmethod agent-dash-backend-capabilities ((_ (eql hermes)))
  "Hermes implementation of `agent-dash-backend-capabilities'."
  (list :quit 'stop :steer nil :images t :models nil))

(defun agent-dash-hermes--command ()
  "Return the ACP command line."
  (list (or (executable-find agent-dash-hermes-executable)
            (user-error "Cannot find `%s'" agent-dash-hermes-executable))
        "acp"))

;;;; Records

(defun agent-dash-hermes--segment (session kind)
  "Return the item id for a chunk of KIND (`user' or `assistant') in SESSION.
A change of kind, or a tool call in between, starts a new item."
  (unless (eq kind (agent-dash-data session :kind))
    (agent-dash-set-data session :seg (1+ (or (agent-dash-data session :seg) 0)))
    (agent-dash-set-data session :kind kind))
  (format "%s%d" (if (eq kind 'user) "u" "a") (agent-dash-data session :seg)))

(defun agent-dash-hermes--append (session id key text)
  "Append TEXT to field KEY of item ID in SESSION; return the whole field."
  (concat (or (plist-get (agent-dash-item session id) key) "") text))

(defun agent-dash-hermes--tool-text (content)
  "Return the text of ACP tool-call CONTENT."
  (mapconcat (lambda (c) (or (agent-dash-jget c "content" "text") "")) content "\n"))

(defun agent-dash-hermes--update (session update)
  "Apply ACP session UPDATE to SESSION."
  (let* ((content (agent-dash-jget update "content")))
    (let ((text (or (agent-dash-jget content "text") "")))
      (pcase (agent-dash-jget update "sessionUpdate")
        ("user_message_chunk"
         (let ((id (agent-dash-hermes--segment session 'user)))
           (agent-dash-emit session (list :type 'user :id id
                                          :text (agent-dash-hermes--append session id :text text)
                                          :images (append
                                                   (plist-get (agent-dash-item session id) :images)
                                                   (agent-dash-images-from-blocks
                                                    (list content) t))))))
        ((and (or "agent_message_chunk" "agent_thought_chunk") kind)
         (let ((id (agent-dash-hermes--segment session 'assistant))
               (key (if (equal kind "agent_message_chunk") :text :thinking)))
           (agent-dash-emit session (list :type 'assistant :id id :final t
                                          key (agent-dash-hermes--append session id key text)
                                          :images (append
                                                   (plist-get (agent-dash-item session id) :images)
                                                   (agent-dash-images-from-blocks
                                                    (list content)))))))
        ((and (or "tool_call" "tool_call_update") kind)
         (when (equal kind "tool_call") (agent-dash-set-data session :kind 'tool))
         (agent-dash-emit
          session
          (append (list :type 'tool :id (agent-dash-jget update "toolCallId")
                        :status (pcase (agent-dash-jget update "status")
                                  ("completed" 'success) ("failed" 'error) (_ 'running)))
                  (when-let* ((title (agent-dash-jget update "title")))
                    (list :name (or (agent-dash-jget update "kind") "tool") :args title))
                  (when-let* ((content (agent-dash-jget update "content")))
                    (list :output (agent-dash-hermes--tool-text content)
                          :images (agent-dash-images-from-blocks
                                   (mapcar (lambda (block) (agent-dash-jget block "content"))
                                           content)))))))
        ("session_info_update"
         (agent-dash-emit session (list :type 'meta :title (agent-dash-jget update "title"))))
        ("available_commands_update"
         (agent-dash-set-data session :command-catalog
                              (agent-dash-command-entries
                               (agent-dash-jget update "availableCommands"))))
        ;; Plans and modes are not shown.
        (_ nil)))))

(defun agent-dash-hermes--record (session record)
  "Translate ACP RECORD into events of SESSION."
  (let ((method (agent-dash-jget record "method"))
        (params (agent-dash-jget record "params")))
    (pcase (agent-dash-jget record "type")
      ("agent_dash_user"
       (agent-dash-set-data session :kind 'user)
       (agent-dash-set-data session :seg (1+ (or (agent-dash-data session :seg) 0)))
       (agent-dash-emit session (list :type 'user :id (agent-dash-jget record "id")
                                      :text (agent-dash-jget record "text")
                                      :images (agent-dash-images-from-blocks
                                               (agent-dash-jget record "images"))))
       (agent-dash-emit session '(:type run :state running)))
      ("agent_dash_exit"
       (agent-dash-emit session '(:type run :state dead))
       (agent-dash-emit session (list :type 'notice :level 'warning
                                      :text (format "Hermes exited (code %s); C-c C-r resumes"
                                                    (agent-dash-jget record "code")))))
      (_
       (cond
        ((not method)
         (progn
           (agent-dash-holder-settle session record)
           (let ((result (agent-dash-jget record "result")))
             (when-let* ((sid (agent-dash-jget result "sessionId")))
               (unless (agent-dash-data session :sid) (agent-dash-holder-set-sid session sid)))
             (when-let* ((reason (agent-dash-jget result "stopReason")))
               (agent-dash-emit session '(:type run :state idle))
               (unless (equal reason "end_turn")
                 (agent-dash-emit session
                                  (list :type 'notice :text (format "stopped: %s" reason)))))
             (when-let* ((error (agent-dash-jget record "error" "message")))
               (agent-dash-emit session '(:type run :state idle))
               (agent-dash-emit session (list :type 'notice :level 'error :text error))))))
        ((equal method "session/update")
         (agent-dash-hermes--update session (agent-dash-jget params "update")))
        ((equal method "session/request_permission")
         (let ((id (agent-dash-jget record "id")))
           (agent-dash-set-data session :options
                                (cons (cons id (agent-dash-jget params "options"))
                                      (agent-dash-data session :options)))
           (agent-dash-emit session
                            (list :type 'request :id id :kind 'permission
                                  :title (format "Hermes wants %s"
                                                 (or (agent-dash-jget params "toolCall" "title")
                                                     "a tool"))))))
        ((agent-dash-jget record "id")
         (agent-dash-holder-reply session (agent-dash-jget record "id") nil
                                  (format "%s is not supported by agent-dash" method))))))))

(cl-defmethod agent-dash-backend-commands ((_ (eql hermes)) session)
  "Return SESSION's advertised ACP commands."
  (agent-dash-data session :command-catalog))

;;;; Backend methods

(defun agent-dash-hermes--place (session)
  "Return the cwd and MCP parameters of SESSION."
  (list :cwd (directory-file-name (agent-dash-session-root session)) :mcpServers []))

(cl-defmethod agent-dash-backend-start ((_ (eql hermes)) session &optional resume-id)
  "Hermes `agent-dash-backend-start' for SESSION and RESUME-ID."
  (let ((live (and resume-id (agent-dash-holder-find 'hermes resume-id))))
    (if live
        (progn (agent-dash-set-data session :sid resume-id)
               (agent-dash-holder-attach session live #'agent-dash-hermes--record t))
      (let ((dir (agent-dash-holder-dir 'hermes (agent-dash-uuid))))
        (agent-dash-holder-start dir (agent-dash-session-root session)
                                 (agent-dash-hermes--command))
        (agent-dash-holder-attach session dir #'agent-dash-hermes--record t)
        (agent-dash-holder-request
         session "initialize" agent-dash-hermes--client
         (lambda (result _error)
           (when (agent-dash-jget result "agentCapabilities")
             (agent-dash-set-data session :images-supported
                                  (if (agent-dash-jget result "agentCapabilities"
                                                       "promptCapabilities" "image") t :false)))))
        (if (not resume-id)
            (agent-dash-holder-request session "session/new" (agent-dash-hermes--place session))
          (agent-dash-holder-set-sid session resume-id)
          ;; The agent replays the saved conversation as session updates.
          (agent-dash-holder-request session "session/load"
                                     (append (list :sessionId resume-id)
                                             (agent-dash-hermes--place session))))))))

(cl-defmethod agent-dash-backend-send ((_ (eql hermes)) session text images _mode)
  "Hermes `agent-dash-backend-send' for SESSION, TEXT and IMAGES."
  (when (and images (eq (agent-dash-data session :images-supported) :false))
    (user-error "This Hermes server does not support image prompts"))
  (let* ((sid (or (agent-dash-data session :sid) (user-error "Hermes has no session yet")))
         (token (agent-dash-data session :image-draft-token))
         (queue-id (agent-dash-data session :queue-sending))
         (blocks (mapcar (lambda (image) (list :type "image" :data (plist-get image :data)
                                               :mimeType (plist-get image :mime-type))) images)))
    (agent-dash-holder-log session (list :type "agent_dash_user" :id (agent-dash-uuid)
                                         :text text :images (vconcat blocks)))
    (agent-dash-holder-request
     session "session/prompt"
     (list :sessionId sid :prompt (vconcat (unless (string-empty-p text)
                                             (list (list :type "text" :text text))) blocks))
     (when (or images queue-id)
       (lambda (result error)
         (agent-dash-delivery-result
          session queue-id (and (not error)
                                (member (agent-dash-jget result "stopReason") '(nil "end_turn"))))
         (when (and error images (not queue-id))
           (agent-dash-image-send-failed session token error)))))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql hermes)) session)
  "Hermes `agent-dash-backend-cancel' for SESSION."
  (agent-dash-holder-notify session "session/cancel"
                            (list :sessionId (agent-dash-data session :sid))))

(cl-defmethod agent-dash-backend-quit ((_ (eql hermes)) session)
  "Hermes `agent-dash-backend-quit' for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql hermes)) session)
  "Hermes `agent-dash-backend-detach' for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql hermes)) session request answer)
  "Hermes `agent-dash-backend-respond' for SESSION, REQUEST and ANSWER."
  (let* ((id (plist-get request :id))
         (wanted (if (eq answer 'allow) "allow_once" "reject_once"))
         (option (unless (eq answer :cancelled)
                   (seq-find (lambda (o) (equal (agent-dash-jget o "kind") wanted))
                             (cdr (assoc id (agent-dash-data session :options)))))))
    (agent-dash-holder-reply
     session id
     (list :outcome (if option
                        (list :outcome "selected" :optionId (agent-dash-jget option "optionId"))
                      '(:outcome "cancelled"))))))

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
    (mapcar (lambda (s)
              (let ((id (agent-dash-jget s "sessionId")))
                (list :id id :root (agent-dash-jget s "cwd")
                      :title (agent-dash-jget s "title")
                      :time (agent-dash-iso-seconds (agent-dash-jget s "updatedAt"))
                      :running (and (agent-dash-holder-find 'hermes id) t))))
            (agent-dash-jget (agent-dash-holder-oneshot
                              (agent-dash-hermes--command)
                              `(("initialize" . ,agent-dash-hermes--client)
                                ("session/list" . ,(when root
                                                     (list :cwd (directory-file-name
                                                                 (expand-file-name root)))))))
                             "sessions"))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql hermes)) id)
  "Hermes `agent-dash-backend-transcript' for ID from native history or ACP."
  (if-let* ((index (agent-dash-hermes--index)))
      (mapcar (lambda (message) (cons (intern (plist-get message :role))
                                      (plist-get message :text)))
              (agent-dash-hermes--saved-messages index id))
    (let* ((info (or (seq-find (lambda (s) (equal (plist-get s :id) id))
                               (agent-dash-backend-sessions 'hermes nil))
                     (user-error "No saved Hermes session %s" id)))
           (turns nil))
      (agent-dash-holder-oneshot
       (agent-dash-hermes--command)
       `(("initialize" . ,agent-dash-hermes--client)
         ("session/load" . (:sessionId ,id :cwd ,(plist-get info :root) :mcpServers [])))
       (lambda (record)
         (let* ((update (agent-dash-jget record "params" "update"))
                (role (pcase (agent-dash-jget update "sessionUpdate")
                        ("user_message_chunk" 'user)
                        ("agent_message_chunk" 'assistant)))
                (text (agent-dash-jget update "content" "text")))
           (when (and role text)
             (if (eq (car (car turns)) role)
                 (setcdr (car turns) (concat (cdr (car turns)) text))
               (push (cons role text) turns))))))
      (nreverse turns))))

(provide 'agent-dash-hermes)
;;; agent-dash-hermes.el ends here
