;;; agent-dash-codex.el --- Codex backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; `codex app-server' (JSON-RPC 2.0 on stdio) run by the generic holder.
;; The server chooses the thread id, recorded in the holder directory so
;; a later resume finds the live instance.  Attaching replays the whole
;; holder log: item ids are stable, so replay and live updates merge.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-holder)

(defgroup agent-dash-codex nil "Codex backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-codex-executable "codex"
  "Codex executable."
  :type 'string)

(defcustom agent-dash-codex-directory (or (getenv "CODEX_HOME") "~/.codex/")
  "Codex native history directory."
  :type 'directory)

(add-to-list 'agent-dash-backends 'codex t)

(defconst agent-dash-codex--client
  '(:clientInfo (:name "agent-dash" :version "0.1.0"))
  "Initialize parameters.")

(cl-defmethod agent-dash-backend-capabilities ((_ (eql codex)))
  "Codex implementation of `agent-dash-backend-capabilities'."
  (list :quit 'stop :steer t :images nil :models t))

(defun agent-dash-codex--command ()
  "Return the app-server command line."
  (list (or (executable-find agent-dash-codex-executable)
            (user-error "Cannot find `%s'" agent-dash-codex-executable))
        "app-server"))

;;;; Records

(defun agent-dash-codex--input-text (content)
  "Return the text of UserInput list CONTENT."
  (mapconcat (lambda (i)
               (if (equal (agent-dash-jget i "type") "text") (agent-dash-jget i "text") ""))
             content ""))

(defun agent-dash-codex--tool-status (status)
  "Map Codex item STATUS to a tool status."
  (pcase status
    ("completed" 'success)
    ((or "failed" "declined") 'error)
    (_ 'running)))

(defun agent-dash-codex--item (session item)
  "Emit the event of Codex thread ITEM for SESSION."
  (let ((id (agent-dash-jget item "id")))
    (pcase (agent-dash-jget item "type")
      ("userMessage"
       (agent-dash-emit session (list :type 'user :id id
                                      :text (agent-dash-codex--input-text
                                             (agent-dash-jget item "content")))))
      ("agentMessage"
       (agent-dash-emit session (list :type 'assistant :id id :final t
                                      :text (or (agent-dash-jget item "text") ""))))
      ("reasoning"
       (let ((text (string-join (or (agent-dash-jget item "summary")
                                    (agent-dash-jget item "content"))
                                "\n")))
         (unless (string-empty-p text)
           (agent-dash-emit session (list :type 'assistant :id id :text "" :thinking text
                                          :final t)))))
      ("commandExecution"
       (agent-dash-emit session (list :type 'tool :id id :name "bash"
                                      :args (agent-dash-jget item "command")
                                      :output (agent-dash-jget item "aggregatedOutput")
                                      :status (agent-dash-codex--tool-status
                                               (agent-dash-jget item "status")))))
      ("fileChange"
       (agent-dash-emit session (list :type 'tool :id id :name "edit"
                                      :args (mapconcat (lambda (c)
                                                         (or (agent-dash-jget c "path") ""))
                                                       (agent-dash-jget item "changes") " ")
                                      :status (agent-dash-codex--tool-status
                                               (agent-dash-jget item "status")))))
      ("mcpToolCall"
       (agent-dash-emit session (list :type 'tool :id id
                                      :name (format "%s.%s" (agent-dash-jget item "server")
                                                    (agent-dash-jget item "tool"))
                                      :args (format "%s" (or (agent-dash-jget item "arguments") ""))
                                      :output (or (agent-dash-jget item "error" "message")
                                                  (agent-dash-json-text
                                                   (agent-dash-jget item "result" "content")))
                                      :status (agent-dash-codex--tool-status
                                               (agent-dash-jget item "status")))))
      ("contextCompaction"
       (agent-dash-emit session (list :type 'notice :id id :text "earlier context compacted")))
      ;; ponytail: plans, web searches, images and subagents are not shown.
      (_ nil))))

(defun agent-dash-codex--thread (session thread)
  "Adopt THREAD from a thread/start, /resume or /read result for SESSION."
  (unless (agent-dash-data session :sid)
    (agent-dash-holder-set-sid session (agent-dash-jget thread "id")))
  (when-let* ((name (agent-dash-jget thread "name")))
    (agent-dash-emit session (list :type 'meta :title name)))
  (dolist (turn (agent-dash-jget thread "turns"))
    (dolist (item (agent-dash-jget turn "items"))
      (agent-dash-codex--item session item))))

(defun agent-dash-codex--append (session key params)
  "Append the delta in PARAMS to SESSION's text KEY of its item.
Return (ITEM-ID . WHOLE-TEXT)."
  (let ((table (or (agent-dash-data session key)
                   (agent-dash-set-data session key (make-hash-table :test #'equal))))
        (id (agent-dash-jget params "itemId")))
    (cons id (puthash id (concat (gethash id table "") (agent-dash-jget params "delta")) table))))

(defun agent-dash-codex--server-request (session record)
  "Turn server request RECORD of SESSION into a request event, or refuse it."
  (let ((id (agent-dash-jget record "id"))
        (params (agent-dash-jget record "params")))
    (pcase (agent-dash-jget record "method")
      ((or "item/commandExecution/requestApproval" "item/fileChange/requestApproval")
       (agent-dash-emit session
                        (list :type 'request :id id :kind 'permission
                              :title (format "Codex wants to %s%s"
                                             (or (agent-dash-jget params "command") "change files")
                                             (if-let* ((r (agent-dash-jget params "reason")))
                                                 (format " (%s)" r) "")))))
      ("item/tool/requestUserInput"
       (let ((questions (agent-dash-jget params "questions")))
         (agent-dash-set-data session :questions
                              (cons (cons id questions) (agent-dash-data session :questions)))
         (agent-dash-emit session
                          (list :type 'request :id id :kind 'questions :title "Codex asks"
                                :questions
                                (mapcar (lambda (q)
                                          (list :question (agent-dash-jget q "question")
                                                :options (agent-dash-labels
                                                          (agent-dash-jget q "options"))))
                                        questions)))))
      (method (agent-dash-holder-reply session id nil
                                       (format "%s is not supported by agent-dash" method))))))

(defun agent-dash-codex--record (session record)
  "Translate app-server RECORD into events of SESSION."
  (let ((method (agent-dash-jget record "method"))
        (params (agent-dash-jget record "params")))
    (cond
     ((equal (agent-dash-jget record "type") "agent_dash_exit")
      (agent-dash-emit session '(:type run :state dead))
      (agent-dash-emit session (list :type 'notice :level 'warning
                                     :text (format "Codex exited (code %s); C-c C-r resumes"
                                                   (agent-dash-jget record "code")))))
     ;; A response: ours, or one from the replayed log that carries a thread.
     ((not method)
      (unless (agent-dash-holder-settle session record)
        (when-let* ((thread (agent-dash-jget record "result" "thread")))
          (agent-dash-codex--thread session thread))))
     ((agent-dash-jget record "id") (agent-dash-codex--server-request session record))
     (t
      (pcase method
        ("turn/started"
         (agent-dash-set-data session :turn (agent-dash-jget params "turn" "id"))
         (agent-dash-emit session '(:type run :state running)))
        ("turn/completed"
         (agent-dash-emit session '(:type run :state idle))
         (when-let* ((error (agent-dash-jget params "turn" "error" "message")))
           (agent-dash-emit session (list :type 'notice :level 'error :text error))))
        ((or "item/started" "item/completed")
         (agent-dash-codex--item session (agent-dash-jget params "item")))
        ("item/agentMessage/delta"
         (let ((text (agent-dash-codex--append session :texts params)))
           (agent-dash-emit session (list :type 'assistant :id (car text) :text (cdr text)))))
        ((or "item/reasoning/summaryTextDelta" "item/reasoning/textDelta")
         (let ((text (agent-dash-codex--append session :thoughts params)))
           (agent-dash-emit session (list :type 'assistant :id (car text) :text ""
                                          :thinking (cdr text)))))
        ("item/commandExecution/outputDelta"
         (let ((text (agent-dash-codex--append session :outputs params)))
           (agent-dash-emit session (list :type 'tool :id (car text) :output (cdr text)))))
        ("serverRequest/resolved"
         (agent-dash-emit session (list :type 'request-done
                                        :id (agent-dash-jget params "requestId"))))
        ("thread/name/updated"
         (agent-dash-emit session (list :type 'meta :title (agent-dash-jget params "name"))))
        ("error"
         (agent-dash-emit session (list :type 'notice :level 'error
                                        :text (or (agent-dash-jget params "error" "message")
                                                  "Codex error"))))
        ;; Token usage, diffs, plans, account and MCP status: not shown.
        (_ nil))))))

;;;; Backend methods

(cl-defmethod agent-dash-backend-start ((_ (eql codex)) session &optional resume-id)
  "Codex `agent-dash-backend-start' for SESSION and RESUME-ID."
  (let ((live (and resume-id (agent-dash-holder-find 'codex resume-id))))
    (if live
        (agent-dash-holder-attach session live #'agent-dash-codex--record t)
      (let ((dir (agent-dash-holder-dir 'codex (agent-dash-uuid))))
        (agent-dash-holder-start dir (agent-dash-session-root session)
                                 (agent-dash-codex--command))
        (agent-dash-holder-attach session dir #'agent-dash-codex--record t)
        (agent-dash-holder-request session "initialize" agent-dash-codex--client)
        (agent-dash-holder-notify session "initialized" nil)
        (if resume-id
            (agent-dash-holder-request session "thread/resume" (list :threadId resume-id))
          (agent-dash-holder-request session "thread/start"
                                     (list :cwd (directory-file-name
                                                 (agent-dash-session-root session)))))))))

(defun agent-dash-codex--report (session)
  "Return a callback showing a failed request in SESSION."
  (lambda (_result error)
    (when error (agent-dash-emit session (list :type 'notice :level 'error :text error)))))

(cl-defmethod agent-dash-backend-send ((_ (eql codex)) session text _images mode)
  "Codex `agent-dash-backend-send' for SESSION, TEXT and MODE."
  (let ((sid (or (agent-dash-data session :sid) (user-error "Codex has no thread yet")))
        (input (vector (list :type "text" :text text))))
    (if (eq mode 'steer)
        (agent-dash-holder-request session "turn/steer"
                                   (list :threadId sid :input input
                                         :expectedTurnId (agent-dash-data session :turn))
                                   (agent-dash-codex--report session))
      (agent-dash-holder-request session "turn/start"
                                 (append (list :threadId sid :input input)
                                         (when-let* ((model (agent-dash-data session :model)))
                                           (list :model model)))
                                 (agent-dash-codex--report session)))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql codex)) session)
  "Codex `agent-dash-backend-cancel' for SESSION."
  (agent-dash-holder-request session "turn/interrupt"
                             (list :threadId (agent-dash-data session :sid)
                                   :turnId (agent-dash-data session :turn))
                             (agent-dash-codex--report session)))

(cl-defmethod agent-dash-backend-quit ((_ (eql codex)) session)
  "Codex `agent-dash-backend-quit' for SESSION."
  (agent-dash-holder-stop session))

(cl-defmethod agent-dash-backend-detach ((_ (eql codex)) session)
  "Codex `agent-dash-backend-detach' for SESSION."
  (agent-dash-holder-detach session))

(cl-defmethod agent-dash-backend-respond ((_ (eql codex)) session request answer)
  "Codex `agent-dash-backend-respond' for SESSION, REQUEST and ANSWER."
  (let ((id (plist-get request :id)))
    (agent-dash-holder-reply
     session id
     (if (eq (plist-get request :kind) 'permission)
         (list :decision (if (eq answer 'allow) "accept" "decline"))
       (let ((answers (make-hash-table :test #'equal)))
         (cl-loop for q in (cdr (assoc id (agent-dash-data session :questions)))
                  for a in answer
                  do (puthash (agent-dash-jget q "id")
                              (list :answers (vconcat (if (listp a) a (list a))))
                              answers))
         (list :answers answers))))))

(cl-defmethod agent-dash-backend-models ((_ (eql codex)) _session)
  "Codex `agent-dash-backend-models'."
  (mapcar (lambda (m) (agent-dash-jget m "id"))
          (agent-dash-jget (agent-dash-holder-oneshot
                            (agent-dash-codex--command)
                            `(("initialize" . ,agent-dash-codex--client) ("model/list")))
                           "data")))

(cl-defmethod agent-dash-backend-set-model ((_ (eql codex)) session model)
  "Codex `agent-dash-backend-set-model' for SESSION and MODEL: used from the next turn."
  (agent-dash-set-data session :model model)
  (agent-dash-emit session (list :type 'meta :model model)))

(defconst agent-dash-codex--injected
  "\\`\\(?:<environment_context>\\|<user_instructions>\\|# AGENTS\\.md\\)"
  "Start of context Codex injects as a user message.")

(defun agent-dash-codex--last-prompt (file)
  "Return (TEXT . TIMESTAMP) of the latest user prompt in rollout FILE, or nil."
  (when (and (stringp file) (file-readable-p file))
    (agent-dash-file-find-last
     file
     (lambda (line)
       (when (string-search "\"role\":\"user\"" line)
         (let* ((record (agent-dash-json-read line))
                (text (string-trim
                       (mapconcat (lambda (c) (or (agent-dash-jget c "text") ""))
                                  (agent-dash-jget record "payload" "content") ""))))
           (unless (or (string-empty-p text) (string-match-p agent-dash-codex--injected text))
             (cons text (agent-dash-jget record "timestamp")))))))))

(defun agent-dash-codex--index ()
  "Return the latest versioned native state index, or nil."
  (let ((base (expand-file-name agent-dash-codex-directory)))
    (when (file-directory-p base)
      (car (sort (directory-files base t "\\`state_[0-9]+\\.sqlite\\'")
                 (lambda (a b)
                   (> (string-to-number (substring (file-name-base a) 6))
                      (string-to-number (substring (file-name-base b) 6)))))))))

(defun agent-dash-codex--indexed-sessions (file root)
  "Read every native Codex session from FILE, optionally scoped to ROOT."
  (mapcar
   (lambda (thread)
     (let* ((path (agent-dash-jget thread "rollout_path"))
            (last (agent-dash-codex--last-prompt path))
            (time (agent-dash-iso-seconds (cdr last)))
            (source (or (agent-dash-jget thread "source") ""))
            (case-fold-search t))
       (list :id (agent-dash-jget thread "id") :root (agent-dash-jget thread "cwd")
             :file path :title (agent-dash-jget thread "title")
             :first (agent-dash-jget thread "first_user_message") :last (car last)
             :time (or time (agent-dash-jget thread "updated_at") 0) :exact (and time t)
             :archived (equal (agent-dash-jget thread "archived") 1)
             :subagent (and (stringp source) (string-match-p "subagent" source))
             :metadata-only (not (and path (file-readable-p path)))
             :running (and (agent-dash-holder-find 'codex (agent-dash-jget thread "id")) t))))
   (agent-dash-sqlite-rows
    file (concat "SELECT * FROM threads"
                 (when root (concat " WHERE cwd=" (agent-dash-sqlite-quote
                                                   (directory-file-name
                                                    (expand-file-name root)))))))))

(defun agent-dash-codex--listed-threads (root)
  "List all source kinds and archived states, following every page for ROOT."
  (let (threads)
    (dolist (archived '(:false t))
      (let (cursor seen done)
        (while (not done)
          (let* ((params (append
                          (list :limit 100 :modelProviders [] :useStateDbOnly t
                                :sourceKinds ["cli" "vscode" "exec" "appServer" "subAgent"
                                              "subAgentReview" "subAgentCompact"
                                              "subAgentThreadSpawn" "subAgentOther" "unknown"]
                                :archived archived)
                          (when root (list :cwd (directory-file-name (expand-file-name root))))
                          (when cursor (list :cursor cursor))))
                 (reply (agent-dash-holder-oneshot
                         (agent-dash-codex--command)
                         `(("initialize" . ,agent-dash-codex--client) ("thread/list" . ,params)))))
            (dolist (thread (agent-dash-jget reply "data"))
              (puthash "archived" (eq archived t) thread))
            (setq threads (append threads (agent-dash-jget reply "data"))
                  cursor (agent-dash-jget reply "nextCursor")
                  done (not cursor))
            (when (member cursor seen) (error "Codex repeated a history page cursor"))
            (when cursor (push cursor seen))))))
    threads))

(cl-defmethod agent-dash-backend-sessions ((_ (eql codex)) root)
  "Codex `agent-dash-backend-sessions' for ROOT."
  (if-let* ((index (agent-dash-codex--index)))
      (agent-dash-codex--indexed-sessions index root)
    (mapcar (lambda (thread)
              (let* ((id (agent-dash-jget thread "id"))
                     (file (agent-dash-jget thread "path"))
                     (last (agent-dash-codex--last-prompt file))
                     (time (agent-dash-iso-seconds (cdr last)))
                     (case-fold-search t))
                (list :id id :root (agent-dash-jget thread "cwd") :file file
                      :archived (agent-dash-jget thread "archived")
                      :subagent (and (string-match-p
                                      "subagent" (format "%s" (agent-dash-jget thread "source"))) t)
                      :first (agent-dash-jget thread "preview")
                      :title (agent-dash-jget thread "name")
                      :last (car last)
                      :time (or time (agent-dash-jget thread "updatedAt")) :exact (and time t)
                      :running (and (agent-dash-holder-find 'codex id) t))))
            (agent-dash-codex--listed-threads root))))

(cl-defmethod agent-dash-backend-transcript ((_ (eql codex)) id)
  "Codex `agent-dash-backend-transcript' for ID."
  (let (turns)
    (dolist (turn (agent-dash-jget (agent-dash-holder-oneshot
                                    (agent-dash-codex--command)
                                    `(("initialize" . ,agent-dash-codex--client)
                                      ("thread/read" . (:threadId ,id :includeTurns t))))
                                   "thread" "turns"))
      (dolist (item (agent-dash-jget turn "items"))
        (pcase (agent-dash-jget item "type")
          ("userMessage" (push (cons 'user (agent-dash-codex--input-text
                                            (agent-dash-jget item "content")))
                               turns))
          ("agentMessage" (push (cons 'assistant (agent-dash-jget item "text")) turns)))))
    (nreverse turns)))

(provide 'agent-dash-codex)
;;; agent-dash-codex.el ends here
