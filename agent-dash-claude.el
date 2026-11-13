;;; agent-dash-claude.el --- Claude Code backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; `claude -p' with stream-json on both sides, run by the generic holder.
;; See docs/DESIGN.md §5.2.  Every record carries a uuid that also
;; appears in Claude's saved transcript, so attaching replays the
;; transcript and then the whole holder log, skipping uuids already
;; seen; a permission request still pending is therefore never lost.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-images)
(require 'agent-dash-holder)

(defgroup agent-dash-claude nil "Claude Code backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-claude-executable "claude"
  "Claude Code executable."
  :type 'string)

(defcustom agent-dash-claude-arguments nil
  "Extra arguments for new Claude processes, e.g. (\"--model\" \"sonnet\")."
  :type '(repeat string))

(defcustom agent-dash-claude-config-directory
  (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")
  "Claude Code configuration directory, where transcripts are saved."
  :type 'directory)

(add-to-list 'agent-dash-backends 'claude t)

(cl-defmethod agent-dash-backend-capabilities ((_ (eql claude)))
  "Claude implementation of `agent-dash-backend-capabilities'."
  (list :quit 'stop :steer t :images t :models t :delete t))

(defun agent-dash-claude--transcript (root id)
  "Return the transcript file of Claude session ID under ROOT."
  (expand-file-name
   (concat id ".jsonl")
   (expand-file-name
    (replace-regexp-in-string "[^a-zA-Z0-9]" "-"
                              (directory-file-name (expand-file-name root)))
    (expand-file-name "projects" agent-dash-claude-config-directory))))

(defun agent-dash-claude--table (session key)
  "Return SESSION's private hash table KEY, creating it."
  (or (agent-dash-data session key)
      (agent-dash-set-data session key (make-hash-table :test #'equal))))

(defun agent-dash-claude--control (session subtype &optional pairs callback)
  "Send SESSION's Claude control request SUBTYPE with plist PAIRS.
CALLBACK, if non-nil, receives the response."
  (let ((id (agent-dash-uuid)))
    (when callback (puthash id callback (agent-dash-claude--table session :callbacks)))
    (agent-dash-holder-write
     session (list :type "control_request" :request_id id
                   :request (append (list :subtype subtype) pairs)))))

;;;; Records

(defun agent-dash-claude--prompt-text (event)
  "Return the human-written text of user EVENT, or nil."
  (unless (or (agent-dash-jget event "isMeta") (agent-dash-jget event "isSidechain")
              (agent-dash-jget event "isCompactSummary"))
    (let* ((content (agent-dash-jget event "message" "content"))
           (text (agent-dash-json-text content)))
      ;; ponytail: "<" also drops a real prompt that starts with a tag; it is
      ;; how Claude Code marks command output and injected reminders.
      (cond ((and (not (string-blank-p text)) (not (string-prefix-p "<" text))) text)
            ((agent-dash-images-from-blocks content)
             (if (string-blank-p text) "[image]" text))))))

(defun agent-dash-claude--args (input)
  "Return a one-line summary of tool INPUT."
  (if (hash-table-p input)
      (or (agent-dash-jget input "command") (agent-dash-jget input "file_path")
          (agent-dash-jget input "pattern") (agent-dash-jget input "description")
          (mapconcat (lambda (k) (format "%s=%s" k (gethash k input)))
                     (hash-table-keys input) " "))
    ""))

(defun agent-dash-claude--emit-assistant (session id final)
  "Emit the assistant message ID of SESSION; FINAL when no block streams."
  (let* ((acc (gethash id (agent-dash-claude--table session :acc) '("" . "")))
         (partial (if (equal id (agent-dash-data session :live-id))
                      (or (agent-dash-data session :partial) '("" . ""))
                    '("" . "")))
         (text (concat (car acc) (car partial)))
         (thinking (concat (cdr acc) (cdr partial)))
         (images (gethash id (agent-dash-claude--table session :image-acc))))
    (unless (and (string-empty-p text) (string-empty-p thinking) (not images))
      (agent-dash-emit session (list :type 'assistant :id id :text text
                                     :thinking thinking :images images :final final)))))

(defun agent-dash-claude--stream (session event)
  "Apply streaming EVENT of SESSION."
  (pcase (agent-dash-jget event "type")
    ("message_start"
     (agent-dash-set-data session :live-id (agent-dash-jget event "message" "id"))
     (agent-dash-set-data session :partial nil)
     (agent-dash-emit session '(:type run :state running)))
    ("content_block_start"
     (let ((block (agent-dash-jget event "content_block")))
       (when (equal (agent-dash-jget block "type") "tool_use")
         (agent-dash-emit session (list :type 'tool :id (agent-dash-jget block "id")
                                        :name (agent-dash-jget block "name")
                                        :args "" :status 'running)))))
    ("content_block_delta"
     (let* ((delta (agent-dash-jget event "delta"))
            (partial (or (agent-dash-data session :partial) (cons "" ""))))
       (pcase (agent-dash-jget delta "type")
         ("text_delta" (setcar partial (concat (car partial) (agent-dash-jget delta "text"))))
         ("thinking_delta"
          (setcdr partial (concat (cdr partial) (agent-dash-jget delta "thinking")))))
       (agent-dash-set-data session :partial partial)
       (when-let* ((id (agent-dash-data session :live-id)))
         (agent-dash-claude--emit-assistant session id nil))))))

(defun agent-dash-claude--assistant (session event)
  "Apply complete assistant EVENT (one or more content blocks) of SESSION."
  (let* ((id (agent-dash-jget event "message" "id"))
         (acc-table (agent-dash-claude--table session :acc))
         (acc (gethash id acc-table (cons "" ""))))
    (when-let* ((images (agent-dash-images-from-blocks
                         (agent-dash-jget event "message" "content"))))
      (let ((table (agent-dash-claude--table session :image-acc)))
        (puthash id (append (gethash id table) images) table)))
    (dolist (block (agent-dash-jget event "message" "content"))
      (pcase (agent-dash-jget block "type")
        ("text" (setcar acc (concat (car acc) (agent-dash-jget block "text"))))
        ("thinking" (setcdr acc (concat (cdr acc) (agent-dash-jget block "thinking"))))
        ("tool_use"
         (let ((tool-id (agent-dash-jget block "id")))
           (agent-dash-emit session
                            (append (list :type 'tool :id tool-id
                                          :name (agent-dash-jget block "name")
                                          :args (agent-dash-claude--args
                                                 (agent-dash-jget block "input")))
                                    (unless (plist-get (agent-dash-item session tool-id) :status)
                                      (list :status 'running))))))))
    (puthash id acc acc-table)
    (agent-dash-set-data session :partial nil)
    (agent-dash-claude--emit-assistant session id t)
    (when-let* ((model (agent-dash-jget event "message" "model")))
      (agent-dash-emit session (list :type 'meta :model model)))))

(defun agent-dash-claude--user (session event)
  "Apply user EVENT of SESSION: tool results and prompts."
  (let ((content (agent-dash-jget event "message" "content")))
    (when (listp content)
      (dolist (block content)
        (when (equal (agent-dash-jget block "type") "tool_result")
          (let ((output (agent-dash-jget block "content")))
            (agent-dash-emit session
                             (list :type 'tool :id (agent-dash-jget block "tool_use_id")
                                   :output (if (stringp output) output
                                             (agent-dash-json-text output))
                                   :images (agent-dash-images-from-blocks output)
                                   :status (if (agent-dash-jget block "is_error")
                                               'error 'success)))))))
    (let ((uuid (agent-dash-jget event "uuid")))
      (cond
       ((agent-dash-jget event "isCompactSummary")
        (agent-dash-emit session (list :type 'notice :id uuid
                                       :text "earlier context compacted")))
       ((when-let* ((text (agent-dash-claude--prompt-text event)))
          (agent-dash-emit session
                           (if (string-prefix-p "[Request interrupted" text)
                               (list :type 'notice :id uuid :text "interrupted")
                             (list :type 'user :id uuid
                                   :text (agent-dash-json-text content)
                                   :images (agent-dash-images-from-blocks content t))))))))))

(defun agent-dash-claude--permission (session event)
  "Turn can_use_tool control request EVENT of SESSION into a request event."
  (let* ((id (agent-dash-jget event "request_id"))
         (request (agent-dash-jget event "request"))
         (tool (agent-dash-jget request "tool_name"))
         (input (agent-dash-jget request "input")))
    (puthash id input (agent-dash-claude--table session :inputs))
    (agent-dash-emit
     session
     (if (equal tool "AskUserQuestion")
         (list :type 'request :id id :kind 'questions :title "Claude asks"
               :questions (mapcar (lambda (q)
                                    (list :question (agent-dash-jget q "question")
                                          :options (agent-dash-labels (agent-dash-jget q "options"))
                                          :multi (agent-dash-jget q "multiSelect")))
                                  (agent-dash-jget input "questions")))
       (list :type 'request :id id :kind 'permission
             :title (format "Claude wants %s: %s" tool
                            (agent-dash-claude--args input)))))))

(defun agent-dash-claude--queue (session)
  "Emit SESSION's queue of prompts Claude has not started."
  (let ((sent (agent-dash-claude--table session :sent)))
    (agent-dash-emit session
                     (list :type 'queue :steering nil
                           :follow-up (mapcar (lambda (uuid) (gethash uuid sent "(prompt)"))
                                              (agent-dash-data session :queued))))))

(defun agent-dash-claude--record (session e)
  "Translate Claude stream-json record E into events of SESSION."
  (let ((uuid (agent-dash-jget e "uuid"))
        (seen (agent-dash-claude--table session :seen)))
    (unless (or (and uuid (gethash uuid seen))
                ;; ponytail: subagent activity is not shown.
                (stringp (agent-dash-jget e "parent_tool_use_id")))
      (when uuid (puthash uuid t seen))
      (pcase (agent-dash-jget e "type")
        ("system"
         (pcase (agent-dash-jget e "subtype")
           ("init"
            (agent-dash-set-data session :command-catalog
                                 (agent-dash-command-entries
                                  (agent-dash-jget e "slash_commands")))
            (agent-dash-emit session (list :type 'meta :model (agent-dash-jget e "model")
                                           :status (agent-dash-jget e "permissionMode"))))
           ("status" (when-let* ((mode (agent-dash-jget e "permissionMode")))
                       (agent-dash-emit session (list :type 'meta :status mode))))))
        ("stream_event" (agent-dash-claude--stream session (agent-dash-jget e "event")))
        ("assistant" (agent-dash-claude--assistant session e))
        ("user" (agent-dash-claude--user session e))
        ("result"
         (let ((text (agent-dash-jget e "result"))
               (last (car (last (agent-dash-session-items session)))))
           (cond
            ((agent-dash-jget e "is_error")
             (agent-dash-emit session (list :type 'notice :id uuid :level 'error
                                            :text (if (stringp text) text
                                                    (agent-dash-jget e "subtype")))))
            ;; A local slash command answers through the result alone.
            ((and (eq (plist-get last :type) 'user) (stringp text)
                  (not (string-blank-p text)))
             (agent-dash-emit session (list :type 'assistant :id (concat "r" uuid)
                                            :text text :final t)))))
         (agent-dash-emit session '(:type run :state idle)))
        ("command_lifecycle"
         (let ((id (agent-dash-jget e "command_uuid"))
               (queued (agent-dash-data session :queued)))
           (setq queued (delete id queued))
           (when (equal (agent-dash-jget e "state") "queued")
             (setq queued (append queued (list id))))
           (agent-dash-set-data session :queued queued)
           (agent-dash-claude--queue session)))
        ("control_request"
         (if (equal (agent-dash-jget e "request" "subtype") "can_use_tool")
             (agent-dash-claude--permission session e)
           (agent-dash-holder-write
            session (list :type "control_response"
                          :response (list :subtype "error"
                                          :request_id (agent-dash-jget e "request_id")
                                          :error "Not supported by agent-dash")))))
        ("control_cancel_request"
         (agent-dash-emit session (list :type 'request-done :id (agent-dash-jget e "request_id"))))
        ("control_response"
         ;; Claude echoes our answers, so a replay learns which logged
         ;; requests were already answered.
         (let* ((response (agent-dash-jget e "response"))
                (id (agent-dash-jget response "request_id"))
                (callbacks (agent-dash-claude--table session :callbacks))
                (callback (gethash id callbacks)))
           (agent-dash-emit session (list :type 'request-done :id id))
           (when (equal id "init")
             (agent-dash-set-data session :models
                                  (agent-dash-jget response "response" "models")))
           (when callback
             (remhash id callbacks)
             (funcall callback response))))
        ("agent_dash_exit"
         (agent-dash-emit session '(:type run :state dead))
         (agent-dash-emit session (list :type 'notice :level 'warning
                                        :text (format "Claude exited (code %s); C-c C-r resumes"
                                                      (agent-dash-jget e "code")))))
        ;; rate_limit_event, system hooks and thinking_tokens: not shown.
        (_ nil)))))

(cl-defmethod agent-dash-backend-commands ((_ (eql claude)) session)
  "Return SESSION's command catalog advertised by Claude initialization.
Recover the startup record for sessions opened before this feature loaded."
  (or (agent-dash-data session :command-catalog)
      (when-let* ((directory (agent-dash-data session :holder))
                  (file (expand-file-name "out.jsonl" directory))
                  (_ (file-readable-p file)))
        (agent-dash-set-data
         session :command-catalog
         (seq-some
          (lambda (line)
            (when (string-search "\"slash_commands\"" line)
              (condition-case nil
                  (let ((record (agent-dash-json-read line)))
                    (when (and (equal (agent-dash-jget record "type") "system")
                               (equal (agent-dash-jget record "subtype") "init"))
                      (agent-dash-command-entries (agent-dash-jget record "slash_commands"))))
                (error nil))))
          (reverse (append (agent-dash-file-lines file (* 512 1024))
                           (agent-dash-file-tail-lines file (* 512 1024)))))))))

;;;; Backend methods

(defun agent-dash-claude--replay-file (session file)
  "Feed every record of FILE to SESSION."
  (when (file-readable-p file)
    (dolist (line (agent-dash-file-lines file))
      (unless (string-empty-p line)
        (agent-dash-claude--record session (agent-dash-json-read line))))))

(cl-defmethod agent-dash-backend-start ((_ (eql claude)) session &optional resume-id)
  "Claude `agent-dash-backend-start' for SESSION and RESUME-ID."
  (let* ((sid (or resume-id (agent-dash-uuid)))
         (root (agent-dash-session-root session))
         (dir (agent-dash-holder-dir 'claude sid))
         (transcript (agent-dash-claude--transcript root sid)))
    (agent-dash-set-data session :sid sid)
    (unless (agent-dash-holder-alive-p dir)
      (let ((process-environment
             (cons (concat "CLAUDE_CONFIG_DIR="
                           (expand-file-name agent-dash-claude-config-directory))
                   process-environment)))
        (agent-dash-holder-start
         dir root
         (append (list (or (executable-find agent-dash-claude-executable)
                           (user-error "Cannot find `%s'" agent-dash-claude-executable))
                       "-p" "--input-format" "stream-json" "--output-format" "stream-json"
                       "--verbose" "--include-partial-messages" "--replay-user-messages"
                       "--permission-prompt-tool" "stdio")
                 (if (file-exists-p transcript)
                     (list "--resume" sid)
                   (list "--session-id" sid))
                 agent-dash-claude-arguments)))
      (agent-dash-set-data session :holder dir)
      (agent-dash-holder-write session '(:type "control_request" :request_id "init"
                                               :request (:subtype "initialize"))))
    (agent-dash-claude--replay-file session transcript)
    (agent-dash-holder-attach session dir #'agent-dash-claude--record t)))

(defun agent-dash-claude--content (text images)
  "Return Claude message content for TEXT and IMAGES."
  (if (null images)
      text
    (vconcat (mapcar (lambda (i) (list :type "image"
                                       :source (list :type "base64"
                                                     :media_type (plist-get i :mime-type)
                                                     :data (plist-get i :data))))
                     images)
             (unless (string-empty-p text) (list (list :type "text" :text text))))))

(cl-defmethod agent-dash-backend-send ((_ (eql claude)) session text images mode)
  "Claude `agent-dash-backend-send' for SESSION, TEXT, IMAGES and MODE."
  (when (eq mode 'steer) (agent-dash-claude--control session "interrupt"))
  (let ((uuid (agent-dash-uuid)))
    (agent-dash-holder-write
     session (list :type "user" :uuid uuid
                   :message (list :role "user"
                                  :content (agent-dash-claude--content text images))))
    ;; Queue events carry only the uuid.
    (puthash uuid text (agent-dash-claude--table session :sent))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql claude)) session)
  "Claude `agent-dash-backend-cancel' for SESSION."
  (agent-dash-claude--control session "interrupt"))

(cl-defmethod agent-dash-backend-quit ((_ (eql claude)) session)
  "Claude `agent-dash-backend-quit' for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql claude)) session)
  "Claude `agent-dash-backend-detach' for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql claude)) session request answer)
  "Claude `agent-dash-backend-respond' for SESSION, REQUEST and ANSWER."
  (let* ((id (plist-get request :id))
         (input (gethash id (agent-dash-claude--table session :inputs)))
         (response
          (pcase (if (eq answer :cancelled) 'cancelled (plist-get request :kind))
            ('cancelled (list :behavior "deny" :message "The user cancelled this request."))
            ('questions
             (let ((answers (make-hash-table :test #'equal))
                   (updated (copy-hash-table input)))
               (cl-loop for q in (plist-get request :questions)
                        for a in answer
                        do (puthash (plist-get q :question)
                                    (if (listp a) (string-join a ", ") a)
                                    answers))
               (puthash "answers" answers updated)
               (list :behavior "allow" :updatedInput updated)))
            (_ (if (eq answer 'allow)
                   (list :behavior "allow" :updatedInput input)
                 (list :behavior "deny" :message "The user denied this tool call."))))))
    (agent-dash-holder-write
     session (list :type "control_response"
                   :response (list :subtype "success" :request_id id :response response)))))

(cl-defmethod agent-dash-backend-models ((_ (eql claude)) session)
  "Claude `agent-dash-backend-models' for SESSION."
  (or (mapcar (lambda (m) (agent-dash-jget m "value")) (agent-dash-data session :models))
      (user-error "Claude has not reported its models yet")))

(cl-defmethod agent-dash-backend-set-model ((_ (eql claude)) session model)
  "Claude `agent-dash-backend-set-model' for SESSION and MODEL."
  (agent-dash-claude--control session "set_model" (list :model model))
  (agent-dash-emit session (list :type 'meta :model model)))

(defun agent-dash-claude--prompt-event (line)
  "Return the parsed event of LINE if it is a human-written prompt."
  (when (string-search "\"type\":\"user\"" line)
    (let ((e (agent-dash-json-read line)))
      (and (agent-dash-claude--prompt-text e)
           (not (string-prefix-p "[Request interrupted" (agent-dash-claude--prompt-text e)))
           e))))

(defun agent-dash-claude--session-info (file)
  "Return the session plist of transcript FILE."
  ;; ponytail: the first prompt is looked for in the first 256 KiB only.
  (let* ((id (file-name-base file))
         (first (seq-some #'agent-dash-claude--prompt-event
                          (agent-dash-file-lines file (* 256 1024))))
         (last (agent-dash-file-find-last file #'agent-dash-claude--prompt-event))
         (time (agent-dash-iso-seconds (agent-dash-jget last "timestamp"))))
    (list :id id :file file
          :root (agent-dash-jget (or first last) "cwd")
          :first (and first (agent-dash-claude--prompt-text first))
          :last (and last (agent-dash-claude--prompt-text last))
          :time (or time (agent-dash-mtime file)) :exact (and time t)
          :empty (not first)
          :running (agent-dash-holder-alive-p (agent-dash-holder-dir 'claude id)))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql claude)) id)
  "Claude `agent-dash-backend-transcript' for ID."
  (let ((file (or (car (file-expand-wildcards
                        (expand-file-name (format "projects/*/%s.jsonl" id)
                                          agent-dash-claude-config-directory)))
                  (user-error "No saved Claude session %s" id)))
        turns)
    (dolist (line (agent-dash-file-lines file))
      (let ((e (agent-dash-json-read line)))
        (unless (agent-dash-jget e "isSidechain")
          (pcase (agent-dash-jget e "type")
            ("user" (when-let* ((text (agent-dash-claude--prompt-text e)))
                      (push (cons 'user text) turns)))
            ("assistant"
             (let ((text (mapconcat (lambda (b) (if (equal (agent-dash-jget b "type") "text")
                                                    (agent-dash-jget b "text") ""))
                                    (agent-dash-jget e "message" "content") "")))
               (unless (string-blank-p text) (push (cons 'assistant text) turns))))))))
    (nreverse turns)))

(cl-defmethod agent-dash-backend-delete ((_ (eql claude)) session)
  "Claude `agent-dash-backend-delete' for SESSION."
  (agent-dash-delete-file (plist-get session :file)
                          (expand-file-name "projects" agent-dash-claude-config-directory)
                          (plist-get session :id)))

(cl-defmethod agent-dash-backend-sessions ((_ (eql claude)) root)
  "Claude `agent-dash-backend-sessions' for ROOT."
  (let* ((projects (expand-file-name "projects" agent-dash-claude-config-directory))
         (dirs (if root
                   (list (file-name-directory (agent-dash-claude--transcript root "x")))
                 (and (file-directory-p projects) (directory-files projects t "\\`[^.]")))))
    (sort (delq nil (mapcan (lambda (dir)
                              (and (file-directory-p dir)
                                   (mapcar #'agent-dash-claude--session-info
                                           (directory-files dir t "\\.jsonl\\'"))))
                            dirs))
          (lambda (a b) (> (plist-get a :time) (plist-get b :time))))))

(provide 'agent-dash-claude)
;;; agent-dash-claude.el ends here
