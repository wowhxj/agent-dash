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
(require 'agent-dash-images)
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
  "Bridge file published by DSH Desktop; it holds credentials, never share it.
The default filename is a Desktop protocol contract, not a package dependency."
  :type 'file)

(defcustom agent-dash-dsh-max-messages 100
  "Messages of history in the first snapshot of a session."
  :type 'integer)

(defcustom agent-dash-dsh-permission "danger-full-access"
  "Permission preset for new DSH sessions; nil keeps the Host default.
Resuming a session preserves its existing permission preset."
  :type '(choice (const nil) (const "auto") (const "read-only")
                 (const "workspace-write") (const "danger-full-access")))

(add-to-list 'agent-dash-backends 'dsh t)

(defvar agent-dash-dsh--host nil
  "Plist (:base URL :cookie STRING) of the authenticated Host, or nil.
The cookie lives only in memory.")

(defvar agent-dash-dsh--events nil
  "Plist (:socket WS :client ID) of the Host-wide `$events' stream.")

(cl-defmethod agent-dash-backend-capabilities ((_ (eql dsh)))
  "DSH implementation of `agent-dash-backend-capabilities'."
  (list :quit 'detach :steer t :images t :models t))

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
    ;; waits synchronously; the Host is local, so calls are short.
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

(defun agent-dash-dsh--socket (on-open on-item &optional on-close)
  "Open remote.mux with ON-OPEN, ON-ITEM and optional ON-CLOSE callbacks."
  (let ((host (or agent-dash-dsh--host (agent-dash-dsh--login))))
    (websocket-open
     (concat "ws" (string-remove-prefix "http" (plist-get host :base)) "api/remote.mux")
     :custom-header-alist (list (cons "Cookie" (plist-get host :cookie)))
     :on-open on-open
     :on-message (lambda (_ws frame)
                   (funcall on-item (agent-dash-json-read (websocket-frame-payload frame))))
     :on-close (or on-close #'ignore))))

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

(defun agent-dash-dsh--model-reasoning (session provider model)
  "Return the cached reasoning metadata for SESSION's PROVIDER and MODEL."
  (let* ((groups (agent-dash-jget (agent-dash-data session :model-catalog) "groups"))
         (group (seq-find (lambda (entry) (equal (agent-dash-jget entry "id") provider))
                          groups))
         (entry (seq-find (lambda (entry) (equal (agent-dash-jget entry "id") model))
                          (agent-dash-jget group "models"))))
    (agent-dash-jget entry "reasoning")))

(defun agent-dash-dsh--selection-thinking (session selection)
  "Return SESSION's header label for the reasoning effort in SELECTION."
  (or (agent-dash-jget selection "reasoningEffort")
      (let ((reasoning (agent-dash-dsh--model-reasoning
                        session (agent-dash-jget selection "provider")
                        (agent-dash-jget selection "model"))))
        (or (agent-dash-jget reasoning "defaultEffort")
            (when (agent-dash-jget reasoning "efforts") "Default")))))

(defun agent-dash-dsh--publish-metrics (session values)
  "Normalize cached DSH projection VALUES into SESSION's shared UI metadata."
  (let* ((pressure (gethash "contextPressure" values))
         (selection (or (agent-dash-jget (gethash "modelSelection" values) "next")
                        (agent-dash-data session :default-model-selection)))
         (usage (gethash "tokenUsage" values))
         (raw (gethash "sessionStats" values))
         (tokens (make-hash-table :test #'equal))
         (stats (make-hash-table :test #'equal)))
    (dolist (pair '(("uncachedInputTokens" . "input")
                    ("cacheReadTokens" . "cacheRead")
                    ("cacheWriteTokens" . "cacheWrite")
                    ("outputTokens" . "output")))
      (puthash (cdr pair) (agent-dash-jget usage (car pair)) tokens))
    (let ((counts (mapcar (lambda (key) (gethash key tokens))
                          '("input" "cacheRead" "cacheWrite" "output"))))
      (when (cl-every #'numberp counts)
        (puthash "total" (apply #'+ counts) tokens)))
    (puthash "tokens" tokens stats)
    (dolist (key '("turns" "steps" "decodeTokens" "decodeMs"))
      (puthash key (agent-dash-jget raw key) stats))
    (agent-dash-emit
     session (list :type 'meta :stats stats
                   :context-usage
                   (when pressure
                     (let ((context (make-hash-table :test #'equal)))
                       (puthash "tokens" (or (agent-dash-jget pressure "projectedTokens")
                                             (agent-dash-jget pressure "pressureTokens"))
                                context)
                       (puthash "contextWindow"
                                (agent-dash-jget pressure "contextWindow") context)
                       context))
                   :model (agent-dash-jget selection "model")
                   :provider (agent-dash-jget selection "provider")
                   :thinking (agent-dash-dsh--selection-thinking session selection)
                   :agent-preset (gethash "agentPreset" values)
                   :permission (agent-dash-jget (gethash "permissions" values)
                                                "currentValue")
                   :title (gethash "title" values)))))

(defun agent-dash-dsh--apply-projections (session values seq)
  "Apply replacement projection VALUES at SEQ to SESSION.
Absent keys retain their values; explicit null clears a key.  Older
replacements cannot overwrite a newer value of the same projection."
  (when (hash-table-p values)
    (let ((cache (or (agent-dash-data session :projections)
                     (agent-dash-set-data session :projections
                                          (make-hash-table :test #'equal))))
          (stamps (or (agent-dash-data session :projection-seqs)
                      (agent-dash-set-data session :projection-seqs
                                           (make-hash-table :test #'equal))))
          (seq (if (numberp seq) seq -1)) changed)
      (maphash
       (lambda (key value)
         (when (and (member key '("contextPressure" "sessionStats" "tokenUsage"
                                  "modelSelection" "agentPreset" "permissions" "title"))
                    (>= seq (gethash key stamps -1)))
           (puthash key value cache)
           (puthash key seq stamps)
           (setq changed t)))
       values)
      (when changed (agent-dash-dsh--publish-metrics session cache)))))

(defun agent-dash-dsh--control-item (session value)
  "Apply current or legacy control projection VALUE for SESSION only."
  (pcase (agent-dash-jget value "type")
    ("baseline"
     (when-let* ((entry (agent-dash-jget value "value" "projections"
                                         (agent-dash-data session :sid))))
       (agent-dash-dsh--apply-projections
        session (agent-dash-jget entry "values") (agent-dash-jget entry "asOfSeq"))))
    ("projection"
     (when (equal (agent-dash-jget value "sessionId") (agent-dash-data session :sid))
       (let ((changes (agent-dash-jget value "changes"))
             (values (make-hash-table :test #'equal)))
         (cond
          ((hash-table-p changes) (setq values changes))
          ((listp changes)
           (dolist (change changes)
             (cond ((hash-table-p change)
                    (when-let* ((key (agent-dash-jget change "key")))
                      (puthash key (agent-dash-jget change "val") values)))
                   ((and (consp change) (stringp (car change)))
                    (puthash (car change) (cadr change) values))))))
         (when-let* ((key (agent-dash-jget value "key")))
           (puthash key (agent-dash-jget value "value") values))
         (agent-dash-dsh--apply-projections
          session values (agent-dash-jget value "seq")))))))

(defun agent-dash-dsh--images (session blocks)
  "Normalize images in BLOCKS, loading Host-owned attachments once per SESSION.
This runs on protocol input, never during display-only redraw."
  (let ((cache (or (agent-dash-data session :attachment-images)
                   (agent-dash-set-data session :attachment-images
                                        (make-hash-table :test #'equal)))) images)
    (dolist (block blocks)
      (when (equal (agent-dash-jget block "type") "image")
        (let* ((attachment (agent-dash-jget block "attachment"))
               (key (and attachment (json-serialize attachment)))
               (image (and key (gethash key cache))))
          (unless image
            (setq image
                  (if (and attachment (not (agent-dash-jget block "data")))
                      (condition-case nil
                          (let ((reply (agent-dash-dsh--call
                                        "session/attachment"
                                        (list :request
                                              (list :sessionId (agent-dash-data session :sid)
                                                    :attachment attachment)))))
                            (list :data (agent-dash-jget reply "data")
                                  :mime-type (agent-dash-jget reply "attachment" "mediaType")
                                  :name (or (agent-dash-jget attachment "name") "Host image")))
                        (error (list :name "Host image unavailable")))
                    (car (agent-dash-images-from-blocks (list block)))))
            (when key (puthash key image cache)))
          (push image images))))
    (nreverse images)))

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
                                           (agent-dash-jget message "content") "text")
                                    :images (agent-dash-dsh--images
                                             session (agent-dash-jget message "content")))))))
        ("assistant/message"
         (let* ((blocks (agent-dash-jget data "message" "content"))
                ;; The streamed preview becomes the final message in place.
                (id (or (agent-dash-data session :live-id)
                        (agent-dash-jget data "message" "id") (format "s%s" seq))))
           (agent-dash-set-data session :live-id nil)
           (let ((text (agent-dash-dsh--text blocks "text"))
                 (thinking (agent-dash-dsh--text blocks "reasoning"))
                 (images (agent-dash-dsh--images session blocks)))
             (unless (and (string-empty-p text) (string-empty-p thinking) (not images)
                          (not (agent-dash-item session id)))
               (agent-dash-emit session (list :type 'assistant :id id :text text
                                              :thinking thinking :images images :final t))))))
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
                                    :images (agent-dash-dsh--images session blocks)
                                    :status (if (or (agent-dash-jget data "error")
                                                    (seq-some (lambda (b)
                                                                (agent-dash-jget b "isError"))
                                                              blocks))
                                                'error 'success))))))
        ("turn/start" (agent-dash-emit session '(:type run :state running)))
        ("turn/end"
         (unless (member (agent-dash-jget data "reason" "kind") '(nil "completed"))
           (agent-dash-delivery-result session (agent-dash-data session :queue-inflight) nil))
         (agent-dash-emit session
                          (list :type 'run :state 'idle
                                :outcome (cond
                                          ((agent-dash-jget data "reason" "error") 'error)
                                          ((equal (agent-dash-jget data "reason" "kind")
                                                  "cancelled") 'cancelled)
                                          (t 'ended))))
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
         (let ((values (make-hash-table :test #'equal))
               (selection (make-hash-table :test #'equal)))
           (puthash "next" data selection)
           (puthash "modelSelection" selection values)
           (agent-dash-dsh--apply-projections session values seq)))
        ("session/title"
         (let ((values (make-hash-table :test #'equal)))
           (puthash "title" (agent-dash-jget data "title") values)
           (agent-dash-dsh--apply-projections session values seq)))
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
            (let ((agent-dash-replaying t))
              (agent-dash-dsh--event session (agent-dash-jget record "event"))))
          (let ((values (copy-hash-table
                         (or (agent-dash-jget value "projections" "values")
                             (make-hash-table :test #'equal)))))
            (when (and (eq (gethash "agentPreset" values 'absent) 'absent)
                       (agent-dash-jget value "header" "agentPreset"))
              (puthash "agentPreset" (agent-dash-jget value "header" "agentPreset") values))
            (agent-dash-dsh--apply-projections
             session values (or (agent-dash-jget value "projections" "asOfSeq")
                                (agent-dash-jget value "cursor")))))
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
               (memq (websocket-ready-state (plist-get agent-dash-dsh--events :socket))
                     '(open connecting)))
    (setq agent-dash-dsh--events
          (list :socket (agent-dash-dsh--socket
                         (lambda (ws)
                           (websocket-send-text
                            ws (agent-dash-dsh--open-frame "dsh-events" "$events"
                                                           (make-hash-table))))
                         #'agent-dash-dsh--events-item
                         (lambda (ws)
                           (when (eq ws (plist-get agent-dash-dsh--events :socket))
                             (setq agent-dash-dsh--events nil)
                             ;; Old client IDs can no longer answer these requests.
                             (maphash
                              (lambda (id entry)
                                (agent-dash-emit
                                 (car entry) (list :type 'request-done :id id
                                                   :status 'interrupted)))
                              agent-dash-dsh--waiting)
                             (clrhash agent-dash-dsh--waiting)
                             (dolist (session agent-dash-dsh--session-list)
                               (agent-dash-dsh--disconnected session)))))))))

;;;; Backend methods

(defun agent-dash-dsh--read-model-catalog (session)
  "Fetch and cache the DSH model catalog for SESSION."
  (agent-dash-set-data
   session :model-catalog
   (agent-dash-dsh--call "session/modelCatalog" (make-hash-table :test #'equal))))

(defun agent-dash-dsh--load-default-model (session)
  "Read SESSION's Host default model without selecting it or invoking inference."
  (condition-case err
      (agent-dash-set-data
       session :default-model-selection
       (agent-dash-jget (agent-dash-dsh--read-model-catalog session) "default"))
    (error
     (agent-dash-set-data session :model-catalog nil)
     (agent-dash-set-data session :default-model-selection nil)
     (agent-dash-emit session (list :type 'notice :id "dsh-default-model-error"
                                    :level 'warning :text (error-message-string err)))))
  (agent-dash-dsh--publish-metrics
   session (or (agent-dash-data session :projections) (make-hash-table :test #'equal))))

(defun agent-dash-dsh--disconnected (session)
  "Mark SESSION disconnected and schedule a single bounded-backoff retry."
  (unless (agent-dash-data session :detached)
    (agent-dash-emit session '(:type run :state dead))
    (unless (timerp (agent-dash-data session :reconnect-timer))
      (let ((delay (or (agent-dash-data session :reconnect-delay) 2)))
        (agent-dash-set-data session :reconnect-delay (min 30 (* 2 delay)))
        (agent-dash-set-data
         session :reconnect-timer
         (run-at-time delay nil #'agent-dash-dsh--reconnect session))))))

(defun agent-dash-dsh--reconnect (session)
  "Reconnect SESSION without prompting, cancelling or changing permissions."
  (agent-dash-set-data session :reconnect-timer nil)
  (unless (agent-dash-data session :detached)
    (let ((old (agent-dash-data session :socket)))
      (agent-dash-set-data session :socket nil)
      (when (and old (websocket-openp old)) (websocket-close old)))
    (condition-case err
        (progn
          ;; Desktop may have restarted and published a new bridge URL.
          (setq agent-dash-dsh--host nil)
          (agent-dash-dsh--ensure-events)
          (agent-dash-dsh--follow session))
      (error
       (agent-dash-emit session (list :type 'notice :id "dsh-reconnect-error"
                                      :level 'warning :text (error-message-string err)))
       (agent-dash-dsh--disconnected session)))))

(defun agent-dash-dsh--follow (session)
  "Follow SESSION's events on a new websocket."
  (agent-dash-dsh--load-default-model session)
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
                                  :assistantStream t))))
        (websocket-send-text
         ws (agent-dash-dsh--open-frame "agent-dash-control" "session/control"
                                        (make-hash-table)))
        (websocket-send-text
         ws (agent-dash-dsh--open-frame "agent-dash-state" "session/observeState"
                                        (list :request (list :sessionId sid)))))
      (lambda (data)
        (cond ((equal (agent-dash-jget data "streamId") sid)
               (agent-dash-dsh--item session data)
               (when (member (agent-dash-jget data "type") '("error" "end"))
                 (agent-dash-dsh--disconnected session))
               (when (equal (agent-dash-jget data "value" "type") "snapshot")
                 (agent-dash-set-data session :reconnect-delay nil)))
              ((equal (agent-dash-jget data "streamId") "agent-dash-state")
               (when (equal (agent-dash-jget data "type") "item")
                 (agent-dash-emit
                  session (list :type 'run :snapshot t
                                :state (if (agent-dash-jget data "value" "running")
                                           'running 'idle)))))
              ((equal (agent-dash-jget data "streamId") "agent-dash-control")
               (pcase (agent-dash-jget data "type")
                 ("item" (agent-dash-dsh--control-item
                          session (agent-dash-jget data "value")))
                 ("error"
                  (agent-dash-emit
                   session '(:type notice :id "dsh-metrics-error" :level warning
                                   :text "DSH metrics unavailable; reconnect")))))))
      (lambda (ws)
        (when (eq ws (agent-dash-data session :socket))
          (agent-dash-dsh--disconnected session)))))))

(defun agent-dash-dsh--live-directory ()
  "Return the directory of DSH chats kept open across Emacs restarts."
  (expand-file-name "dsh-live/" agent-dash-directory))

(defun agent-dash-dsh--remember-chat (sid open)
  "Remember SID as an OPEN chat or clear its marker when explicitly closed."
  (when (and (stringp sid) (string-match-p "\\`[[:alnum:]_-][[:alnum:]_.-]*\\'" sid))
    (let* ((dir (agent-dash-dsh--live-directory))
           (file (expand-file-name sid dir)))
      (if open
          (progn
            (make-directory dir t)
            (write-region "" nil file nil 'silent))
        (condition-case nil
            (delete-file file)
          (file-missing nil))))))

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
    (agent-dash-set-data session :detached nil)
    (when (and (not resume-id) agent-dash-dsh-permission)
      (agent-dash-backend-send
       'dsh session (concat "/permission " agent-dash-dsh-permission) nil nil))
    (push session agent-dash-dsh--session-list)
    (agent-dash-dsh--ensure-events)
    (agent-dash-dsh--follow session)
    (agent-dash-dsh--remember-chat sid t)))

(cl-defmethod agent-dash-backend-models ((_ (eql dsh)) session)
  "Return provider-qualified model choices for SESSION from the DSH catalog."
  (let ((catalog (agent-dash-dsh--read-model-catalog session)) choices)
    (dolist (group (agent-dash-jget catalog "groups"))
      (dolist (model (agent-dash-jget group "models"))
        (let ((provider (agent-dash-jget group "id"))
              (id (agent-dash-jget model "id")))
          (push (cons (concat provider "/" id)
                      (list :provider provider :model id)) choices))))
    (unless choices
      (user-error "DSH model catalog is empty: %s"
                  (mapconcat (lambda (failure) (or (agent-dash-jget failure "message") ""))
                             (agent-dash-jget catalog "failures") "; ")))
    (agent-dash-set-data session :model-choices (nreverse choices))
    (mapcar #'car (agent-dash-data session :model-choices))))

(defun agent-dash-dsh--select-model (session selection)
  "Send model SELECTION to the DSH Host and update SESSION's header."
  (let* ((result (agent-dash-dsh--call
                  "session/selectModel"
                  (list :request
                        (append (list :sessionId (agent-dash-data session :sid)) selection))))
         (selected (agent-dash-jget result "selected")))
    (agent-dash-emit
     session (list :type 'meta
                   :model (agent-dash-jget selected "model")
                   :provider (agent-dash-jget selected "provider")
                   :thinking (agent-dash-dsh--selection-thinking session selected)))))

(cl-defmethod agent-dash-backend-set-model ((_ (eql dsh)) session model)
  "Select MODEL for SESSION via the DSH API, not the slash command registry."
  (unless (agent-dash-data session :model-choices)
    (agent-dash-backend-models 'dsh session))
  (let ((selection (cdr (assoc model (agent-dash-data session :model-choices)))))
    (unless selection (user-error "Unknown DSH model: %s" model))
    (agent-dash-dsh--select-model session selection)))

(defun agent-dash-dsh-set-thinking (session args)
  "Set the reasoning effort for SESSION's current model, or pick it if ARGS is empty."
  (agent-dash-dsh--read-model-catalog session)
  (let* ((meta (agent-dash-session-meta session))
         (provider (plist-get meta :provider))
         (model (plist-get meta :model))
         (reasoning (agent-dash-dsh--model-reasoning session provider model))
         (levels (mapcar (lambda (entry) (agent-dash-jget entry "id"))
                         (agent-dash-jget reasoning "efforts"))))
    (unless model (user-error "Select a DSH model with /model first"))
    (unless levels (user-error "No reasoning levels are available for %s/%s" provider model))
    (let* ((choices (cons "default" levels))
           (input (if (string-empty-p args)
                      (completing-read "Thinking: " choices nil t) args))
           (level (assoc-string input choices t))
           (current (agent-dash-session-meta session)))
      (unless level (user-error "Unknown DSH thinking level: %s" input))
      (unless (and (equal provider (plist-get current :provider))
                   (equal model (plist-get current :model)))
        (user-error "The DSH model changed; run /thinking again"))
      (agent-dash-dsh--select-model
       session (append (list :provider provider :model model)
                       (unless (equal level "default") (list :reasoningEffort level)))))))

(cl-defmethod agent-dash-backend-send ((_ (eql dsh)) session text images mode)
  "DSH `agent-dash-backend-send' for SESSION, TEXT, IMAGES and MODE."
  (when (and images (string-prefix-p "/" text))
    (user-error "Remove images before running DSH slash commands"))
  (let ((sid (agent-dash-data session :sid)))
    (if (string-match-p "\\`/[a-z]" text)
        ;; Host commands use this endpoint; registered skills bypass it below.
        (let* ((reply (agent-dash-dsh--call
                       "commands/execute"
                       (list :agentId sid :line text :submittedAttachments [])))
               (result (agent-dash-jget reply "result"))
               (output (agent-dash-jget result "text")))
          (unless (equal (agent-dash-jget result "kind") "success")
            (user-error "%s" (or output "DSH command unavailable or rejected")))
          (agent-dash-emit session (list :type 'notice
                                         :text (format "%s: %s" text (or output "done")))))
      (agent-dash-dsh--prompt session text mode images))))

(defun agent-dash-dsh--prompt (session text mode &optional images)
  "Submit TEXT and optional IMAGES as a normal prompt to SESSION using MODE."
  (when (and (agent-dash-data session :queue-sending) (not agent-dash-dsh--host))
    (user-error "Reconnect DSH before sending the local queue"))
  (apply #'agent-dash-dsh--call
         "session/prompt"
         (list :request (list :requestId (agent-dash-uuid)
                              :sessionId (agent-dash-data session :sid)
                              :mode (if (eq mode 'steer) "steer" "queue")
                              :content (vconcat
                                        (unless (string-empty-p text)
                                          (list (list :type "text" :text text)))
                                        (mapcar (lambda (image)
                                                  (list :type "image"
                                                        :mediaType (plist-get image :mime-type)
                                                        :data (plist-get image :data))) images))))
         ;; A lost reply must never automatically replay a queued model request.
         (when (agent-dash-data session :queue-sending) '(t))))

(cl-defmethod agent-dash-backend-commands ((_ (eql dsh)) session)
  "Read SESSION's Host commands and registered skills without invoking a model."
  (let* ((sid (agent-dash-data session :sid))
         (commands (agent-dash-dsh--call "commands/list" (list :agentId sid)))
         (skills (condition-case nil
                     (agent-dash-jget
                      (agent-dash-dsh--call "skills/list"
                                            (list :request (list :sessionId sid))) "skills")
                   (error nil))))
    (agent-dash-set-data session :dsh-host-commands (agent-dash-command-entries commands))
    (agent-dash-set-data session :dsh-skills (agent-dash-command-entries skills))
    (agent-dash-set-data session :dsh-catalog-loaded t)
    (append (agent-dash-data session :dsh-host-commands)
            (agent-dash-data session :dsh-skills))))

(cl-defmethod agent-dash-backend-command ((_ (eql dsh)) session text mode)
  "Execute Host command TEXT or a verified skill for SESSION in MODE."
  (let ((name (and (string-match "\\`/\\([^[:space:]]+\\)" text)
                   (match-string 1 text))))
    (unless (agent-dash-data session :dsh-catalog-loaded)
      (agent-dash-backend-commands 'dsh session))
    (if (and (not (assoc name (agent-dash-data session :dsh-host-commands)))
             (assoc name (agent-dash-data session :dsh-skills)))
        (agent-dash-dsh--prompt session text mode)
      (agent-dash-backend-send 'dsh session text nil mode))))

(cl-defmethod agent-dash-backend-cancel ((_ (eql dsh)) session)
  "DSH `agent-dash-backend-cancel' for SESSION."
  (agent-dash-dsh--call "session/cancel"
                        (list :request (list :sessionId (agent-dash-data session :sid)))))

(cl-defmethod agent-dash-backend-detach ((_ (eql dsh)) session)
  "DSH `agent-dash-backend-detach' for SESSION."
  (let ((sid (agent-dash-data session :sid)))
    (unless (seq-some (lambda (other)
                        (and (not (eq session other))
                             (equal sid (agent-dash-data other :sid))))
                      agent-dash-dsh--session-list)
      (agent-dash-dsh--remember-chat sid nil)))
  (agent-dash-set-data session :detached t)
  (when-let* ((timer (agent-dash-data session :reconnect-timer)))
    (cancel-timer timer)
    (agent-dash-set-data session :reconnect-timer nil))
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
                                    for a in (unless (eq answer :cancelled) answer)
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

(defun agent-dash-dsh--dialogue-message (event &optional session)
  "Extract dialogue from EVENT, including images when given SESSION."
  (let* ((data (agent-dash-jget event "data"))
         (message (agent-dash-jget data "message"))
         (role (pcase (agent-dash-jget event "type")
                 ("user/message"
                  (setq message (or message data))
                  (when (member (agent-dash-jget message "source" "kind") '(nil "user"))
                    'user))
                 ("assistant/message" 'assistant))))
    (when role
      (let* ((blocks (agent-dash-jget message "content"))
             (text (agent-dash-dsh--text blocks "text")))
        (if session
            (list :type role :text text :images (agent-dash-dsh--images session blocks))
          (unless (string-blank-p text) (cons role text)))))))

(defun agent-dash-dsh--dialogue (id &optional session)
  "Read ID's dialogue in chronological order, including images for SESSION."
  (let ((address (list :kind "session" :sessionId id))
        (more t) before transcript)
    (while more
      (let* ((page (agent-dash-dsh--call
                    "session/events"
                    (list :request (append (list :address address :maxMessages 100)
                                           (when before (list :beforeSeq before))))))
             (records (agent-dash-jget page "records")))
        ;; Each page is chronological, and beforeSeq is exclusive.
        (dolist (record (reverse records))
          (when-let* ((message (agent-dash-dsh--dialogue-message
                                (agent-dash-jget record "event") session)))
            (push message transcript)))
        (setq more (agent-dash-jget page "hasMore"))
        (when more
          (let ((next (agent-dash-jget (car records) "event" "seq")))
            (unless (and (integerp next) (> next 0) (or (not before) (< next before)))
              (error "DSH history pagination did not advance for %s" id))
            (setq before next)))))
    (if session
        (dolist (message transcript session) (agent-dash-emit session message))
      transcript)))

(cl-defmethod agent-dash-backend-transcript ((_ (eql dsh)) id)
  "Read dialogue text for saved session ID."
  (agent-dash-dsh--dialogue id))

(cl-defmethod agent-dash-backend-history-items ((_ (eql dsh)) row)
  "Read saved dialogue and images for ROW."
  (let ((id (plist-get row :id))
        (session (agent-dash-session-create 'dsh (or (plist-get row :root) default-directory))))
    (agent-dash-set-data session :sid id)
    (agent-dash-dsh--dialogue id session)))

(defun agent-dash-dsh--prompts (id)
  "Return the user prompts of session ID from the Host's projection cache.
The Host keeps each session's turn outline there; session/list omits it.
Best effort: nil when the file is missing or of another version."
  (let ((file (expand-file-name
               (concat "storages/session_projcache/sessions/" id ".json")
               (file-name-directory agent-dash-dsh-bridge-file))))
    (when (and (string-match-p "\\`[A-Za-z0-9_-]+\\'" id) (file-readable-p file))
      (let ((row (agent-dash-jget (agent-dash-json-read
                                   (with-temp-buffer (insert-file-contents file) (buffer-string)))
                                  "record" "rows" "turnOutline")))
        ;; The same version check the Host applies before trusting a row.
        (when (eql (agent-dash-jget row "ver") 2)
          (seq-filter (lambda (prompt) (and (stringp prompt) (not (string-blank-p prompt))))
                      (mapcar (lambda (turn) (agent-dash-jget turn "prompt"))
                              (agent-dash-jget row "val" "turns"))))))))

(cl-defmethod agent-dash-backend-sessions ((_ (eql dsh)) root)
  "DSH `agent-dash-backend-sessions' for ROOT."
  (let* ((want (and root (directory-file-name (expand-file-name root))))
         (dir (agent-dash-dsh--live-directory))
         (open (when (file-directory-p dir) (directory-files dir nil nil t))))
    (sort
     (delq nil
           (mapcar (lambda (item)
                     (let ((cwd (agent-dash-jget item "cwd")))
                       (when (or (not want) (equal cwd want))
                         (let* ((id (agent-dash-jget item "sessionId"))
                                (prompt (agent-dash-jget item "projections" "values"
                                                         "sessionListMetadata" "lastPromptAt"))
                                (updated (agent-dash-jget item "updatedAt"))
                                (empty (agent-dash-jget item "blank"))
                                (prompts (unless empty (agent-dash-dsh--prompts id))))
                           (list :id id :root cwd :empty empty
                                 :first (car prompts) :last (car (last prompts))
                                 :subagent (equal (agent-dash-jget item "origin") "subagent")
                                 :title (agent-dash-jget item "projections" "values" "title")
                                 :time (/ (or prompt updated 0) 1000.0) :exact (and prompt t)
                                 :running (or (agent-dash-jget item "running")
                                              (and (member id open) t)))))))
                   (agent-dash-jget (agent-dash-dsh--call "session/list"
                                                          (list :_request (make-hash-table)))
                                    "items")))
     (lambda (a b) (> (plist-get a :time) (plist-get b :time))))))

(provide 'agent-dash-dsh)
;;; agent-dash-dsh.el ends here
