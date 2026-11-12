;;; agent-dash-dsh.el --- DeepSeek Harness backend for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; Talks to a local DSH Web Host (docs/DESIGN.md §5.3): RPC over HTTP
;; POST, session events over the `api/remote.mux' websocket, approvals
;; and questions over the Host-wide `$events' stream.
;;
;; The Host is either DSH Desktop, found through its bridge file, or a
;; `dsh web' started by the generic holder.  Both outlive Emacs, so
;; quitting a chat only detaches.  The launch URL can be exchanged for a
;; cookie more than once, which is how a restarted Emacs logs in again.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-holder)
(require 'url)
(require 'websocket)

(defgroup agent-dash-dsh nil "DSH backend of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-dsh-connection 'auto
  "How to reach a DSH Host.
`auto' uses DSH Desktop when its bridge file exists, else `managed'.
`desktop' requires the bridge.  `managed' runs `dsh web' detached."
  :type '(choice (const auto) (const desktop) (const managed)))

(defcustom agent-dash-dsh-executable "dsh"
  "DSH executable, used for the managed Host."
  :type 'string)

(defcustom agent-dash-dsh-bridge-file
  (expand-file-name "emacs-dsh-bridge.json" (or (getenv "DSH_HOME") "~/.dsh"))
  "Bridge file published by DSH Desktop; it holds credentials, never share it."
  :type 'file)

(defcustom agent-dash-dsh-max-messages 100
  "Messages of history in the first snapshot of a session."
  :type 'integer)

(add-to-list 'agent-dash-backends 'dsh t)

(defvar agent-dash-dsh--host nil
  "Plist (:base URL :cookie STRING) of the authenticated Host, or nil.
The cookie lives only in memory.")

(defvar agent-dash-dsh--events nil
  "Plist (:socket WS :client ID) of the Host-wide `$events' stream.")

(cl-defmethod agent-dash-backend-capabilities ((_ (eql dsh)))
  "DSH implementation of `agent-dash-backend-capabilities'."
  (list :quit 'detach :steer t :images nil :models nil))

;;;; Host discovery and authentication

(defconst agent-dash-dsh--launch-regexp
  "\\(http://127\\.0\\.0\\.1:[0-9]+/\\)[?]token=[A-Za-z0-9_-]+"
  "A trusted local launch URL; group 1 is the base URL.")

(defun agent-dash-dsh--desktop-launch ()
  "Return the launch URL from the Desktop bridge file."
  (let* ((file agent-dash-dsh-bridge-file)
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (agent-dash-json-read (buffer-string))))
         (launch (agent-dash-jget data "launch" "value")))
    (unless (and (equal (agent-dash-jget data "version") 1)
                 (equal (agent-dash-jget data "launch" "encoding") "plain")
                 (stringp launch)
                 (string-match-p (concat "\\`" agent-dash-dsh--launch-regexp "\\'") launch))
      (error "DSH bridge %s is invalid or not from a local Host" file))
    launch))

(defun agent-dash-dsh--managed-launch ()
  "Return the launch URL of the managed Host, starting it if needed."
  (let* ((dir (agent-dash-holder-dir 'dsh "host"))
         (log (expand-file-name "out.jsonl" dir)))
    (unless (agent-dash-holder-alive-p dir)
      (agent-dash-holder-start
       dir (expand-file-name "~")
       (list (or (executable-find agent-dash-dsh-executable)
                 (user-error "Cannot find `%s'" agent-dash-dsh-executable))
             "web" "--host" "127.0.0.1" "--port" "0" "--no-open")))
    (let ((deadline (+ (float-time) 45)) launch)
      (while (and (not launch) (< (float-time) deadline))
        (with-temp-buffer
          (insert-file-contents log)
          (when (re-search-forward (concat "dsh web:[[:space:]]*\\(" agent-dash-dsh--launch-regexp
                                           "\\)")
                                   nil t)
            (setq launch (match-string 1))))
        (unless launch (sleep-for 0.2)))
      (or launch (error "The managed DSH Host published no launch URL; see %s" dir)))))

(defun agent-dash-dsh--retrieve (url &optional method body cookie)
  "Fetch URL with METHOD, BODY and COOKIE; return (STATUS-CODE HEADERS BODY)."
  (let ((url-request-method (or method "GET"))
        (url-request-data body)
        (url-request-extra-headers
         (append '(("Content-Type" . "application/json"))
                 (and cookie (list (cons "Cookie" cookie)))))
        (url-max-redirections 0)
        (url-show-status nil)
        (url-cookie-storage nil)
        (url-cookie-secure-storage nil)
        (url-proxy-services (cons '("no_proxy" . "127\\.0\\.0\\.1") url-proxy-services))
        (result nil))
    ;; ponytail: waits synchronously; the Host is local, so calls are short.
    (url-retrieve url (lambda (_status)
                        (goto-char (point-min))
                        (let* ((code (and (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                                          (string-to-number (match-string 1))))
                               (start (and (re-search-forward "\r?\n\r?\n" nil t) (point))))
                          (setq result (list (or code 0)
                                             (buffer-substring (point-min) (or start (point-max)))
                                             (if start
                                                 (decode-coding-string
                                                  (buffer-substring-no-properties start (point-max))
                                                  'utf-8)
                                               ""))))
                        (kill-buffer))
                  nil t t)
    (with-timeout (60 (error "DSH Host did not answer %s" url))
      (while (not result) (accept-process-output nil 0.02)))
    result))

(defun agent-dash-dsh--login ()
  "Authenticate to the configured Host and return `agent-dash-dsh--host'."
  (let* ((launch (if (or (eq agent-dash-dsh-connection 'desktop)
                         (and (eq agent-dash-dsh-connection 'auto)
                              (file-exists-p agent-dash-dsh-bridge-file)))
                     (agent-dash-dsh--desktop-launch)
                   (agent-dash-dsh--managed-launch)))
         (base (progn (string-match agent-dash-dsh--launch-regexp launch)
                      (match-string 1 launch)))
         (reply (agent-dash-dsh--retrieve launch)))
    (unless (and (= (car reply) 303)
                 (string-match "^[Ss]et-[Cc]ookie: \\(dsh-auth-[^;\r\n]+\\)" (nth 1 reply)))
      (error "DSH Host refused login (HTTP %s)" (car reply)))
    (setq agent-dash-dsh--host (list :base base :cookie (match-string 1 (nth 1 reply))))))

(defun agent-dash-dsh--call (method args &optional retried)
  "Call Host RPC METHOD with ARGS plist; return its value or signal an error.
When the Host answers 401 or not at all (a restarted Host), log in again
once; RETRIED marks that second attempt."
  (let* ((host (or agent-dash-dsh--host (agent-dash-dsh--login)))
         (id (agent-dash-uuid))
         (reply (agent-dash-dsh--retrieve
                 (concat (plist-get host :base) "api/" method) "POST"
                 (encode-coding-string
                  (json-serialize (list :type "client-request" :rpcId id :method method
                                        :payload (list :args args))
                                  :false-object :false)
                  'utf-8)
                 (plist-get host :cookie))))
    (cond
     ((and (memq (car reply) '(0 401)) (not retried))
      (setq agent-dash-dsh--host nil)
      (agent-dash-dsh--call method args t))
     ((/= (car reply) 200) (error "DSH %s: HTTP %s" method (car reply)))
     (t
      (let* ((json (agent-dash-json-read (nth 2 reply)))
             (result (agent-dash-jget json "result")))
        (unless (equal (agent-dash-jget json "rpcId") id)
          (error "DSH %s: mismatched response" method))
        (if (agent-dash-jget result "ok")
            (agent-dash-jget result "value")
          (error "DSH %s: %s %s" method (agent-dash-jget result "error" "code")
                 (agent-dash-jget result "error" "message"))))))))

(defun agent-dash-dsh--socket (on-open on-item)
  "Open a remote.mux websocket; ON-OPEN gets the socket, ON-ITEM each frame."
  (let ((host (or agent-dash-dsh--host (agent-dash-dsh--login))))
    (websocket-open
     (concat "ws" (string-remove-prefix "http" (plist-get host :base)) "api/remote.mux")
     :custom-header-alist (list (cons "Cookie" (plist-get host :cookie)))
     :on-open on-open
     :on-message (lambda (_ws frame)
                   (funcall on-item (agent-dash-json-read (websocket-frame-payload frame))))
     :on-close #'ignore)))

(defun agent-dash-dsh--open-frame (stream endpoint args)
  "Return the frame opening STREAM on ENDPOINT with ARGS."
  (json-serialize (list :type "open" :streamId stream :endpoint endpoint
                        :payload (list :args args))
                  :false-object :false))

;;;; Events

(defun agent-dash-dsh--text (blocks type)
  "Join the text of BLOCKS whose type is TYPE."
  (mapconcat (lambda (b) (if (equal (agent-dash-jget b "type") type)
                             (or (agent-dash-jget b "text") "")
                           ""))
             blocks ""))

(defun agent-dash-dsh--args (arguments)
  "Return a one-line summary of tool ARGUMENTS."
  (cond ((stringp arguments) arguments)
        ((hash-table-p arguments)
         (or (agent-dash-jget arguments "command") (agent-dash-jget arguments "path")
             (mapconcat (lambda (k) (format "%s=%s" k (gethash k arguments)))
                        (hash-table-keys arguments) " ")))
        (t "")))

(defun agent-dash-dsh--event (session event)
  "Translate DSH session EVENT into events of SESSION; skip seen seqs."
  (let ((seq (agent-dash-jget event "seq"))
        (data (agent-dash-jget event "data"))
        (seen (or (agent-dash-data session :seen)
                  (agent-dash-set-data session :seen (make-hash-table)))))
    (unless (and seq (gethash seq seen))
      (when seq (puthash seq t seen))
      (pcase (agent-dash-jget event "type")
        ("user/message"
         (let ((message (or (agent-dash-jget data "message") data)))
           (when (member (agent-dash-jget message "source" "kind") '(nil "user"))
             (agent-dash-emit session
                              (list :type 'user
                                    :id (or (agent-dash-jget message "id") (format "s%s" seq))
                                    :text (agent-dash-dsh--text
                                           (agent-dash-jget message "content") "text"))))))
        ("assistant/message"
         (let* ((blocks (agent-dash-jget data "message" "content"))
                ;; The streamed preview becomes the final message in place.
                (id (or (agent-dash-data session :live-id)
                        (agent-dash-jget data "message" "id") (format "s%s" seq))))
           (agent-dash-set-data session :live-id nil)
           (let ((text (agent-dash-dsh--text blocks "text"))
                 (thinking (agent-dash-dsh--text blocks "reasoning")))
             (unless (and (string-empty-p text) (string-empty-p thinking)
                          (not (agent-dash-item session id)))
               (agent-dash-emit session (list :type 'assistant :id id :text text
                                              :thinking thinking :final t))))))
        ("tool/call"
         (agent-dash-emit session (list :type 'tool
                                        :id (or (agent-dash-jget data "callId") (format "s%s" seq))
                                        :name (or (agent-dash-jget data "name") "tool")
                                        :args (agent-dash-dsh--args
                                               (agent-dash-jget data "arguments"))
                                        :status 'running)))
        ("tool/result"
         (let* ((message (agent-dash-jget data "message"))
                (blocks (agent-dash-jget message "content")))
           (when-let* ((id (or (agent-dash-jget message "callId")
                               (agent-dash-jget message "source" "callId")
                               (agent-dash-jget data "callId"))))
             (agent-dash-emit session
                              (list :type 'tool :id id
                                    :output (agent-dash-dsh--text blocks "text")
                                    :status (if (or (agent-dash-jget data "error")
                                                    (seq-some (lambda (b)
                                                                (agent-dash-jget b "isError"))
                                                              blocks))
                                                'error 'success))))))
        ("turn/start" (agent-dash-emit session '(:type run :state running)))
        ("turn/end"
         (agent-dash-emit session '(:type run :state idle))
         (let ((kind (agent-dash-jget data "reason" "kind")))
           (unless (member kind '(nil "completed"))
             (agent-dash-emit session
                              (list :type 'notice :id (format "s%s" seq)
                                    :level (if (agent-dash-jget data "reason" "error") 'error 'info)
                                    :text (let ((m (agent-dash-jget data "reason" "error"
                                                                    "message")))
                                            (format "turn %s%s" kind
                                                    (if m (concat ": " m) ""))))))))
        ("model/selection"
         (agent-dash-emit session (list :type 'meta :model (agent-dash-jget data "model"))))
        ("session/title"
         (agent-dash-emit session (list :type 'meta :title (agent-dash-jget data "title"))))
        ;; Inbox, team, preset and working-directory events are not shown.
        (_ nil)))))

(defun agent-dash-dsh--stream (session frame)
  "Show assistant-stream FRAME of SESSION as a growing preview."
  (pcase (agent-dash-jget frame "type")
    ("start"
     (agent-dash-set-data session :live-id (format "live-%s" (agent-dash-jget frame "attemptId")))
     (agent-dash-set-data session :live-text ""))
    ("chunk"
     (when (and (agent-dash-data session :live-id)
                (equal (agent-dash-jget frame "chunk" "type") "text-delta"))
       (agent-dash-emit session
                        (list :type 'assistant :id (agent-dash-data session :live-id)
                              :text (agent-dash-set-data
                                     session :live-text
                                     (concat (agent-dash-data session :live-text)
                                             (agent-dash-jget frame "chunk" "text")))))))))

(defun agent-dash-dsh--item (session data)
  "Handle remote.mux frame DATA of SESSION's follow stream."
  (let ((value (agent-dash-jget data "value")))
    (pcase (agent-dash-jget data "type")
      ("error"
       (agent-dash-emit session (list :type 'notice :level 'error
                                      :text (format "DSH: %s"
                                                    (agent-dash-jget data "error" "message")))))
      ("item"
       (pcase (agent-dash-jget value "type")
         ("snapshot"
          (dolist (record (agent-dash-jget value "records"))
            (agent-dash-dsh--event session (agent-dash-jget record "event")))
          (let ((values (agent-dash-jget value "projections" "values")))
            (agent-dash-emit session
                             (list :type 'meta :title (agent-dash-jget values "title")
                                   :model (agent-dash-jget values "modelSelection"
                                                           "next" "model")))))
         ("event" (agent-dash-dsh--event session (agent-dash-jget value "event")))
         ("assistant-stream" (agent-dash-dsh--stream session (agent-dash-jget value "frame"))))))))

;;;; Approvals and questions (Host-wide $events stream)

(defvar agent-dash-dsh--waiting (make-hash-table :test #'equal)
  "Event id -> (SESSION . REQUEST) of interactions shown in a chat.")

(defun agent-dash-dsh--events-result (event-id outcome)
  "Answer interaction EVENT-ID with OUTCOME plist."
  (agent-dash-dsh--call "$events/result"
                        (list :clientId (plist-get agent-dash-dsh--events :client)
                              :eventId event-id :outcome outcome)))

(defun agent-dash-dsh--events-item (data)
  "Route $events frame DATA to the chat of its session."
  (let* ((value (agent-dash-jget data "value"))
         (event-id (agent-dash-jget value "eventId")))
    (when (equal (agent-dash-jget data "type") "item")
      (pcase (agent-dash-jget value "type")
        ("ready" (setq agent-dash-dsh--events
                       (plist-put agent-dash-dsh--events
                                  :client (agent-dash-jget value "clientId"))))
        ("cancel"
         (when-let* ((entry (gethash event-id agent-dash-dsh--waiting)))
           (remhash event-id agent-dash-dsh--waiting)
           (agent-dash-emit (car entry) (list :type 'request-done :id event-id))))
        ("waterfall"
         (let* ((request (agent-dash-jget value "request"))
                (session (seq-find (lambda (s) (and (eq (agent-dash-session-backend s) 'dsh)
                                                    (equal (agent-dash-data s :sid)
                                                           (agent-dash-jget value "agentId"))))
                                   (agent-dash-dsh--sessions))))
           (if (not session)
               ;; Not ours: let another client (Desktop, a browser) answer.
               (agent-dash-dsh--events-result event-id '(:kind "next"))
             (puthash event-id (cons session request) agent-dash-dsh--waiting)
             (agent-dash-emit
              session
              (pcase (agent-dash-jget value "event")
                ("approval/request"
                 (list :type 'request :id event-id :kind 'permission
                       :title (format "DSH wants %s%s"
                                      (or (agent-dash-jget request "toolName") "a tool")
                                      (if-let* ((r (agent-dash-jget request "reason")))
                                          (format " (%s)" r) ""))))
                (_
                 (list :type 'request :id event-id :kind 'questions :title "DSH asks"
                       :questions
                       (mapcar (lambda (q)
                                 (list :question (agent-dash-jget q "question")
                                       :options (agent-dash-labels (agent-dash-jget q "options"))
                                       :multi (agent-dash-jget q "multiSelect")))
                               (agent-dash-jget request "questions")))))))))))))

(defvar agent-dash-dsh--session-list nil "Live DSH sessions of this Emacs.")

(defun agent-dash-dsh--sessions ()
  "Return the live DSH sessions."
  (setq agent-dash-dsh--session-list
        (seq-filter (lambda (s) (buffer-live-p (agent-dash-session-buffer s)))
                    agent-dash-dsh--session-list)))

(defun agent-dash-dsh--ensure-events ()
  "Subscribe once to the Host-wide $events stream."
  (unless (and (plist-get agent-dash-dsh--events :socket)
               (websocket-openp (plist-get agent-dash-dsh--events :socket)))
    (setq agent-dash-dsh--events
          (list :socket (agent-dash-dsh--socket
                         (lambda (ws)
                           (websocket-send-text
                            ws (agent-dash-dsh--open-frame "dsh-events" "$events"
                                                           (make-hash-table))))
                         #'agent-dash-dsh--events-item)))))

;;;; Backend methods

(defun agent-dash-dsh--follow (session)
  "Follow SESSION's events on a new websocket."
  (let ((sid (agent-dash-data session :sid)))
    (agent-dash-set-data
     session :socket
     (agent-dash-dsh--socket
      (lambda (ws)
        (websocket-send-text
         ws (agent-dash-dsh--open-frame
             sid "session/follow"
             (list :request (list :address (list :kind "session" :sessionId sid)
                                  :maxMessages agent-dash-dsh-max-messages
                                  :assistantStream t)))))
      (lambda (data)
        (when (equal (agent-dash-jget data "streamId") sid)
          (agent-dash-dsh--item session data)))))))

(cl-defmethod agent-dash-backend-start ((_ (eql dsh)) session &optional resume-id)
  "DSH `agent-dash-backend-start' for SESSION and RESUME-ID."
  (let ((sid (or resume-id
                 (let* ((path (directory-file-name (agent-dash-session-root session)))
                        (workspace (agent-dash-jget
                                    (agent-dash-dsh--call "workspace/create"
                                                          (list :request (list :path path)))
                                    "workspace" "workspaceId")))
                   (agent-dash-jget
                    (agent-dash-dsh--call "session/create"
                                          (list :request (if workspace
                                                             (list :workspaceId workspace
                                                                   :agentPreset "standard")
                                                           (list :cwd path
                                                                 :agentPreset "standard"))))
                    "sessionId")))))
    (unless sid (error "DSH Host did not return a session id"))
    (agent-dash-set-data session :sid sid)
    (push session agent-dash-dsh--session-list)
    (agent-dash-dsh--ensure-events)
    (agent-dash-dsh--follow session)))

(cl-defmethod agent-dash-backend-send ((_ (eql dsh)) session text _images mode)
  "DSH `agent-dash-backend-send' for SESSION, TEXT and MODE."
  (let ((sid (agent-dash-data session :sid)))
    (if (string-match-p "\\`/[a-z]" text)
        ;; Slash commands and skills run through the command endpoint.
        (agent-dash-dsh--call "commands/execute"
                              (list :agentId sid :line text :submittedAttachments []))
      (agent-dash-dsh--call "session/prompt"
                            (list :request (list :requestId (agent-dash-uuid) :sessionId sid
                                                 :mode (if (eq mode 'steer) "steer" "queue")
                                                 :content (vector (list :type "text"
                                                                        :text text))))))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql dsh)) session)
  "DSH `agent-dash-backend-cancel' for SESSION."
  (agent-dash-dsh--call "session/cancel"
                        (list :request (list :sessionId (agent-dash-data session :sid)))))

(cl-defmethod agent-dash-backend-detach ((_ (eql dsh)) session)
  "DSH `agent-dash-backend-detach' for SESSION."
  (setq agent-dash-dsh--session-list (delq session agent-dash-dsh--session-list))
  (let ((socket (agent-dash-data session :socket)))
    (when (and socket (websocket-openp socket))
      (websocket-close socket))))

(cl-defmethod agent-dash-backend-quit ((_ (eql dsh)) session)
  "DSH `agent-dash-backend-quit' for SESSION: only detach; the Host keeps it."
  (agent-dash-backend-detach 'dsh session))

(cl-defmethod agent-dash-backend-respond ((_ (eql dsh)) _session request answer)
  "DSH `agent-dash-backend-respond' for REQUEST and ANSWER."
  (let* ((id (plist-get request :id))
         (raw (cdr (gethash id agent-dash-dsh--waiting))))
    (remhash id agent-dash-dsh--waiting)
    (agent-dash-dsh--events-result
     id
     (if (eq (plist-get request :kind) 'permission)
         (list :kind "result" :value (if (eq answer 'allow) "allowed-once" "rejected"))
       (list :kind "result"
             :value (list :answers
                          (vconcat
                           (cl-loop for q in (agent-dash-jget raw "questions")
                                    for a in answer
                                    for labels = (agent-dash-labels (agent-dash-jget q "options"))
                                    for picked = (if (listp a) a (list a))
                                    collect
                                    (append (list :id (agent-dash-jget q "id")
                                                  :selected (vconcat (seq-filter
                                                                      (lambda (x) (member x labels))
                                                                      picked)))
                                            (when-let* ((custom (seq-remove
                                                                 (lambda (x) (member x labels))
                                                                 picked)))
                                              (list :custom (string-join custom ", "))))))))))))

(cl-defmethod agent-dash-backend-sessions ((_ (eql dsh)) root)
  "DSH `agent-dash-backend-sessions' for ROOT."
  (let ((want (and root (directory-file-name (expand-file-name root)))))
    (sort
     (delq nil
           (mapcar (lambda (item)
                     (let ((cwd (agent-dash-jget item "cwd")))
                       (when (and (not (agent-dash-jget item "blank"))
                                  (or (not want) (equal cwd want)))
                         (list :id (agent-dash-jget item "sessionId") :root cwd
                               :title (or (agent-dash-jget item "projections" "values" "title")
                                          "(untitled)")
                               :time (format-time-string
                                      "%Y-%m-%dT%H:%M"
                                      (/ (or (agent-dash-jget item "updatedAt") 0) 1000.0))
                               :running (agent-dash-jget item "running")))))
                   (agent-dash-jget (agent-dash-dsh--call "session/list"
                                                          (list :_request (make-hash-table)))
                                    "items")))
     (lambda (a b) (string> (plist-get a :time) (plist-get b :time))))))

(provide 'agent-dash-dsh)
;;; agent-dash-dsh.el ends here
