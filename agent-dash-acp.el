;;; agent-dash-acp.el --- Shared Agent Client Protocol support -*- lexical-binding: t; -*-

;;; Commentary:

;; ACP agents use JSON-RPC 2.0 on stdio under the generic holder.
;; Hermes and Antigravity stream chunks without ids and omit live
;; user prompts, so prompts are logged as
;; `agent_dash_user' records and items are numbered in log order;
;; attaching replays the whole log, giving the same ids every time.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-images)
(require 'agent-dash-holder)

(defconst agent-dash-acp-client
  (list :protocolVersion 1
        :clientCapabilities '(:fs (:readTextFile :false :writeTextFile :false)
                                  :terminal :false))
  "Initialize parameters: the client offers no file system or terminal.")

;;;; Records

(defun agent-dash-acp-segment (session kind)
  "Return the item id for a chunk of KIND (`user' or `assistant') in SESSION.
A change of kind, or a tool call in between, starts a new item."
  (unless (eq kind (agent-dash-data session :kind))
    (agent-dash-set-data session :seg (1+ (or (agent-dash-data session :seg) 0)))
    (agent-dash-set-data session :kind kind))
  (format "%s%d" (if (eq kind 'user) "u" "a") (agent-dash-data session :seg)))

(defun agent-dash-acp-append (session id key text)
  "Append TEXT to field KEY of item ID in SESSION; return the whole field."
  (concat (or (plist-get (agent-dash-item session id) key) "") text))

(defun agent-dash-acp-tool-text (content)
  "Return the text of ACP tool-call CONTENT."
  (mapconcat (lambda (c) (or (agent-dash-jget c "content" "text") "")) content "\n"))

(defun agent-dash-acp-update (session update)
  "Apply ACP session UPDATE to SESSION."
  (let* ((content (agent-dash-jget update "content")))
    (let ((text (or (agent-dash-jget content "text") "")))
      (pcase (agent-dash-jget update "sessionUpdate")
        ("user_message_chunk"
         (let ((id (agent-dash-acp-segment session 'user)))
           (agent-dash-emit session (list :type 'user :id id
                                          :text (agent-dash-acp-append session id :text text)
                                          :images (append
                                                   (plist-get (agent-dash-item session id) :images)
                                                   (agent-dash-images-from-blocks
                                                    (list content) t))))))
        ((and (or "agent_message_chunk" "agent_thought_chunk") kind)
         (let ((id (agent-dash-acp-segment session 'assistant))
               (key (if (equal kind "agent_message_chunk") :text :thinking)))
           (agent-dash-emit session (list :type 'assistant :id id :final t
                                          key (agent-dash-acp-append session id key text)
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
                    (list :output (agent-dash-acp-tool-text content)
                          :images (agent-dash-images-from-blocks
                                   (mapcar (lambda (block) (agent-dash-jget block "content"))
                                           content)))))))
        ("session_info_update"
         (agent-dash-emit session (list :type 'meta :title (agent-dash-jget update "title"))))
        ("available_commands_update"
         (agent-dash-set-data session :command-catalog
                              (agent-dash-command-entries
                               (agent-dash-jget update "availableCommands"))))
        ("config_option_update"
         (agent-dash-acp-config session (agent-dash-jget update "configOptions")))
        ("usage_update"
         (let ((used (agent-dash-jget update "used"))
               (size (agent-dash-jget update "size")))
           (when (and (numberp used) (numberp size) (> size 0))
             (let ((context (make-hash-table :test #'equal)))
               (puthash "tokens" used context)
               (puthash "contextWindow" size context)
               (puthash "percent" (/ (* used 100.0) size) context)
               (agent-dash-emit session (list :type 'meta :context-usage context))))))
        (_ nil)))))

(defun agent-dash-acp-config (session options)
  "Record configuration OPTIONS and display their current values in SESSION."
  (dolist (option options)
    (when-let* ((key (pcase (agent-dash-jget option "category")
                       ("model" :model)
                       ("thought_level" :thinking)))
                (current (agent-dash-jget option "currentValue")))
      (agent-dash-set-data session (if (eq key :model) :acp-model :acp-thinking) option)
      (agent-dash-emit session (list :type 'meta key current)))))

(defun agent-dash-acp-record (session record)
  "Translate ACP RECORD into events of SESSION."
  (let ((name (capitalize (symbol-name (agent-dash-session-backend session))))
        (method (agent-dash-jget record "method"))
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
                                      :text (format "%s exited (code %s); C-c C-r resumes" name
                                                    (agent-dash-jget record "code")))))
      (_
       (cond
        ((not method)
         (progn
           (agent-dash-holder-settle session record)
           (let ((result (agent-dash-jget record "result")))
             (when-let* ((options (agent-dash-jget result "configOptions")))
               (agent-dash-acp-config session options))
             (when-let* ((sid (agent-dash-jget result "sessionId")))
               (unless (agent-dash-data session :sid) (agent-dash-holder-set-sid session sid)))
             (when-let* ((reason (agent-dash-jget result "stopReason")))
               (agent-dash-emit session
                                (list :type 'run :state 'idle
                                      :outcome (if (equal reason "cancelled")
                                                   'cancelled 'ended)))
               (unless (equal reason "end_turn")
                 (agent-dash-emit session
                                  (list :type 'notice :text (format "stopped: %s" reason)))))
             (when-let* ((error (agent-dash-jget record "error" "message")))
               (agent-dash-emit session '(:type run :state idle :outcome error))
               (agent-dash-emit session (list :type 'notice :level 'error :text error))))))
        ((equal method "session/update")
         (agent-dash-acp-update session (agent-dash-jget params "update")))
        ((equal method "session/request_permission")
         (let ((id (agent-dash-jget record "id")))
           (agent-dash-set-data session :options
                                (cons (cons id (agent-dash-jget params "options"))
                                      (agent-dash-data session :options)))
           (agent-dash-emit session
                            (list :type 'request :id id :kind 'permission
                                  :title (format "%s wants %s" name
                                                 (or (agent-dash-jget params "toolCall" "title")
                                                     "a tool"))))))
        ((agent-dash-jget record "id")
         (agent-dash-holder-reply session (agent-dash-jget record "id") nil
                                  (format "%s is not supported by agent-dash" method))))))))

;;;; Backend methods

(defun agent-dash-acp-place (session)
  "Return the cwd and MCP parameters of SESSION."
  (list :cwd (directory-file-name (agent-dash-session-root session)) :mcpServers []))

(defun agent-dash-acp-start (session command &optional resume-id on-record)
  "Run ACP COMMAND for SESSION, optionally restoring RESUME-ID.
Dispatch records to ON-RECORD when supplied."
  (let* ((backend (agent-dash-session-backend session))
         (live (and resume-id (agent-dash-holder-find backend resume-id))))
    (if live
        (progn (agent-dash-set-data session :sid resume-id)
               (agent-dash-holder-attach session live (or on-record #'agent-dash-acp-record) t))
      (let ((dir (agent-dash-holder-dir backend (agent-dash-uuid))))
        (agent-dash-holder-start dir (agent-dash-session-root session)
                                 command)
        (agent-dash-holder-attach session dir (or on-record #'agent-dash-acp-record) t)
        (agent-dash-holder-request
         session "initialize" agent-dash-acp-client
         (lambda (result _error)
           (when (agent-dash-jget result "agentCapabilities")
             (agent-dash-set-data session :images-supported
                                  (if (agent-dash-jget result "agentCapabilities"
                                                       "promptCapabilities" "image") t :false)))))
        (if (not resume-id)
            (agent-dash-holder-request session "session/new" (agent-dash-acp-place session))
          ;; The agent replays the saved conversation as session updates.
          (agent-dash-holder-request
           session "session/load"
           (append (list :sessionId resume-id) (agent-dash-acp-place session))
           (lambda (_result error)
             (unless error (agent-dash-holder-set-sid session resume-id)))))))))

(defun agent-dash-acp-send (session text images)
  "Send TEXT and IMAGES to ACP SESSION."
  (when (and images (eq (agent-dash-data session :images-supported) :false))
    (user-error "This ACP server does not support image prompts"))
  (let* ((sid (or (agent-dash-data session :sid) (user-error "ACP session is not ready")))
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

(defun agent-dash-acp-cancel (session)
  "Cancel the current prompt in ACP SESSION."
  (agent-dash-holder-notify session "session/cancel"
                            (list :sessionId (agent-dash-data session :sid))))

(defun agent-dash-acp-respond (session request answer)
  "Send ANSWER to a permission REQUEST in ACP SESSION."
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

(defun agent-dash-acp-sessions (backend command root)
  "List BACKEND sessions in ROOT via ACP COMMAND."
  (let ((params (when root (list :cwd (directory-file-name (expand-file-name root)))))
        cursor rows)
    (while
        (let ((result (agent-dash-holder-oneshot
                       command `(("initialize" . ,agent-dash-acp-client)
                                 ("session/list" . ,(append params (when cursor
                                                                     (list :cursor cursor))))))))
          (dolist (entry (agent-dash-jget result "sessions"))
            (let ((id (agent-dash-jget entry "sessionId")))
              (push (list :id id :root (agent-dash-jget entry "cwd")
                          :title (agent-dash-jget entry "title")
                          :time (agent-dash-iso-seconds (agent-dash-jget entry "updatedAt"))
                          :running (and (agent-dash-holder-find backend id) t))
                    rows)))
          (setq cursor (agent-dash-jget result "nextCursor"))))
    (nreverse rows)))

(defun agent-dash-acp-load-history (session command id cwd)
  "Populate SESSION from ACP COMMAND replay of ID in CWD."
  (agent-dash-holder-oneshot
   command `(("initialize" . ,agent-dash-acp-client)
             ("session/load" . (:sessionId ,id :cwd ,cwd :mcpServers [])))
   (lambda (record)
     (when (equal (agent-dash-jget record "method") "session/update")
       (let ((update (agent-dash-jget record "params" "update")))
         (pcase (agent-dash-jget update "sessionUpdate")
           ((or "user_message_chunk" "agent_message_chunk")
            (agent-dash-acp-update session update))
           ((or "tool_call" "agent_thought_chunk")
            (agent-dash-set-data session :kind nil))))))))

(defun agent-dash-acp-transcript (command id root &optional timeout)
  "Read session ID under ROOT through ACP COMMAND, with optional TIMEOUT."
  (let (turns)
    (agent-dash-holder-oneshot
     command
     `(("initialize" . ,agent-dash-acp-client)
       ("session/load" . (:sessionId ,id :cwd ,root :mcpServers [])))
     (lambda (record)
       (let* ((update (agent-dash-jget record "params" "update"))
              (role (pcase (agent-dash-jget update "sessionUpdate")
                      ("user_message_chunk" 'user)
                      ("agent_message_chunk" 'assistant)))
              (text (agent-dash-jget update "content" "text")))
         (when (and role text)
           (if (eq (car (car turns)) role)
               (setcdr (car turns) (concat (cdr (car turns)) text))
             (push (cons role text) turns)))))
     timeout)
    (nreverse turns)))

(provide 'agent-dash-acp)
;;; agent-dash-acp.el ends here
