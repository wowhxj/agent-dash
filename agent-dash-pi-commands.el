;;; agent-dash-pi-commands.el --- Pi native command routing -*- lexical-binding: t; -*-

;;; Commentary:
;; Pi's RPC catalog omits TUI builtins.  Read the installed Pi catalog, and
;; use a no-inference control channel for the optional authentication bridge.

;;; Code:
(require 'agent-dash-core)
(require 'agent-dash-holder)
(require 'subr-x)
(defvar agent-dash-pi-executable)
(declare-function agent-dash-pi--request "agent-dash-pi")
(declare-function agent-dash-pi--refresh-stats "agent-dash-pi")
(declare-function agent-dash-pi--on-state "agent-dash-pi")
(declare-function agent-dash-backend-commands "agent-dash-core")

(defconst agent-dash-pi-bridge-file
  (expand-file-name "agent-dash-pi-bridge.mjs"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Extension shipped alongside the Pi client.")

(defconst agent-dash-pi--reserved-commands
  '("settings" "model" "tree" "thinking" "scoped-models" "export" "import"
    "share" "bug" "copy" "name" "session" "changelog" "hotkeys" "fork" "clone"
    "trust" "login" "logout" "new" "compact" "resume" "reload" "quit")
  "Fail-closed reserve when the installed Pi directory cannot be read.")

(defun agent-dash-pi-native-commands (session)
  "Return native commands for SESSION, preferring the running Pi's catalog."
  (or (agent-dash-data session :pi-native-commands)
      (agent-dash-data session :pi-local-native-commands)
      (let ((commands
             (condition-case nil
                 (with-temp-buffer
                   (let ((coding-system-for-read 'utf-8-unix))
                     (when (eq 0 (process-file
                                  "node" nil (list (current-buffer) nil) nil
                                  agent-dash-pi-bridge-file "--catalog"
                                  (or (executable-find agent-dash-pi-executable)
                                      agent-dash-pi-executable)))
                       (agent-dash-command-entries
                        (agent-dash-json-read (buffer-string))))))
               (error nil))))
        (setq commands (or commands
                           (mapcar (lambda (name)
                                     (cons name "Pi native command (catalog unavailable)"))
                                   agent-dash-pi--reserved-commands)))
        (agent-dash-set-data session :pi-local-native-commands commands)
        commands)))

(defun agent-dash-pi-native-command-p (session text)
  "Whether TEXT starts a native command for SESSION."
  (and (string-match "\\`/\\([^[:space:]]+\\)" text)
       (assoc (match-string 1 text) (agent-dash-pi-native-commands session))))

(defun agent-dash-pi-command-catalog (session entries)
  "Merge native commands into RPC ENTRIES for SESSION; hide the bridge entry."
  (let (ordinary)
    (agent-dash-set-data session :pi-bridge nil)
    (agent-dash-set-data session :pi-native-commands nil)
    (dolist (entry entries)
      (let ((name (agent-dash-jget entry "name"))
            (description (or (agent-dash-jget entry "description") "")))
        (if (equal name "agent-dash-native")
            (when (string-prefix-p "agent-dash-native-v1:" description)
              (condition-case nil
                  (let ((commands (agent-dash-command-entries
                                   (agent-dash-json-read (substring description 21)))))
                    (when commands
                      (agent-dash-set-data session :pi-native-commands commands)
                      (agent-dash-set-data session :pi-bridge t)))
                (json-error nil)))
          (push entry ordinary))))
    (append (mapcar (lambda (entry)
                      (cons (car entry)
                            (concat (cdr entry)
                                    (unless (member (car entry)
                                                    '("model" "thinking" "export" "copy" "hotkeys"
                                                      "name" "session" "login" "logout"
                                                      "new" "compact" "resume" "quit"))
                                      " [Pi terminal UI; never sent to a model]"))))
                    (agent-dash-pi-native-commands session))
            (agent-dash-command-entries (nreverse ordinary)))))

(defun agent-dash-pi--native-timeout (session id)
  "Report a missing bridge acknowledgement for SESSION operation ID."
  (when (equal id (car (agent-dash-data session :pi-native-pending)))
    (agent-dash-set-data session :pi-native-pending nil)
    (agent-dash-set-data session :pi-native-timer nil)
    (agent-dash-emit session
                     '(:type notice :level error
                             :text "Pi bridge unavailable; stop/resume Pi. Nothing was resent."))))

(defun agent-dash-pi--native-refresh (session)
  "Refresh native SESSION metadata after a command, without inference."
  (agent-dash-pi--request session '(:type "get_state")
                          (apply-partially #'agent-dash-pi--on-state session))
  (agent-dash-pi--refresh-stats session))

(defun agent-dash-pi-native-record (session record)
  "Handle a private native-command RECORD for SESSION, without storing input."
  (let ((id (agent-dash-jget record "id"))
        (kind (agent-dash-jget record "type")))
    (when (and (stringp id)
               (member kind '("agent_dash_native_started" "agent_dash_native_result"))
               (equal id (car (agent-dash-data session :pi-native-pending))))
      (when-let* ((timer (agent-dash-data session :pi-native-timer)))
        (cancel-timer timer)
        (agent-dash-set-data session :pi-native-timer nil))
      (when (equal kind "agent_dash_native_result")
        (agent-dash-set-data session :pi-native-pending nil)
        (agent-dash-set-data session :command-catalog nil)
        (agent-dash-set-data session :commands-loaded nil)
        (agent-dash-emit session
                         (list :type 'notice
                               :level (if (agent-dash-jget record "success") 'info 'error)
                               :text (or (agent-dash-jget record "message") "Pi command finished")))
        (agent-dash-pi--native-refresh session)))))

(defun agent-dash-pi--bridge-command (session name args)
  "Execute NAME and ARGS in SESSION through the non-model bridge channel."
  (unless (agent-dash-data session :pi-bridge)
    (agent-dash-backend-commands 'pi session))
  (unless (agent-dash-data session :pi-bridge)
    (user-error "Pi bridge is not loaded: /quit, then restore from Hub (not sent)"))
  (when (agent-dash-data session :pi-native-pending)
    (user-error "A Pi native command is already pending"))
  (let* ((id (agent-dash-uuid))
         (payload (base64-encode-string
                   (encode-coding-string (json-serialize (list :id id :command name :args args))
                                         'utf-8-unix) t)))
    (agent-dash-set-data session :pi-native-pending (cons id name))
    (agent-dash-set-data session :pi-native-timer
                         (run-at-time 5 nil #'agent-dash-pi--native-timeout session id))
    (condition-case err
        (agent-dash-holder-write
         session (list :type "extension_ui_response"
                       :id (concat "agent-dash-native:" id) :value payload))
      (error
       (cancel-timer (agent-dash-data session :pi-native-timer))
       (agent-dash-set-data session :pi-native-pending nil)
       (agent-dash-set-data session :pi-native-timer nil)
       (signal (car err) (cdr err))))))

(defun agent-dash-pi-native-reset (session)
  "Forget bridge operation state after SESSION's process exits."
  (when-let* ((timer (agent-dash-data session :pi-native-timer))) (cancel-timer timer))
  (dolist (key '(:pi-native-pending :pi-native-timer :pi-bridge :commands-loaded :command-catalog))
    (agent-dash-set-data session key nil)))

(defun agent-dash-pi--native-query (session request)
  "Read REQUEST from SESSION, or fail without sending a model prompt."
  (let (done result failure)
    (agent-dash-pi--request session request
                            (lambda (ok data error)
                              (setq done t result data failure (unless ok error))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    (unless done (user-error "Pi query timed out; command not sent to a model"))
    (when failure (user-error "Pi: %s" failure))
    result))

(defun agent-dash-pi-native-execute (session name args)
  "Execute native NAME with ARGS for SESSION, or refuse it without inference."
  (unless (eq (agent-dash-session-state session) 'idle)
    (user-error "Wait for Pi to become idle before /%s" name))
  (when (and (member name '("login" "logout"))
             (not (string-match-p "\\`[a-zA-Z0-9_.-]*\\'" args)))
    (user-error "Use /%s [provider-id]; enter credentials only in the secure dialog" name))
  (pcase name
    ((or "login" "logout") (agent-dash-pi--bridge-command session name args))
    ("model"
     (let ((model (if (string-empty-p args)
                      (completing-read "Pi model: " (agent-dash-backend-models 'pi session) nil t)
                    args)))
       (unless (string-match-p "\\`[^/]+/.+\\'" model)
         (user-error "Use /model provider/model-id"))
       (agent-dash-backend-set-model 'pi session model)))
    ("name"
     (when (string-empty-p args) (user-error "Use /name <session name>"))
     (agent-dash-pi--native-query session (list :type "set_session_name" :name args))
     (agent-dash-pi--native-refresh session))
    ("session"
     (let ((stats (agent-dash-pi--native-query session '(:type "get_session_stats"))))
       (agent-dash-emit session
                        (list :type 'notice :level 'info
                              :text (format "Session: %s\nFile: %s\nUsers: %s · Assistants: %s"
                                            (agent-dash-jget stats "sessionId")
                                            (agent-dash-jget stats "sessionFile")
                                            (agent-dash-jget stats "userMessages")
                                            (agent-dash-jget stats "assistantMessages"))))))
    ("copy"
     (let ((text (agent-dash-jget (agent-dash-pi--native-query
                                   session '(:type "get_last_assistant_text")) "text")))
       (unless (and (stringp text) (not (string-empty-p text)))
         (user-error "No Pi assistant reply to copy"))
       (kill-new text)
       (message "Copied Pi's last reply")))
    ("hotkeys" (describe-mode))
    ("thinking"
     (let* ((levels (agent-dash-jget (agent-dash-pi--native-query
                                      session '(:type "get_available_thinking_levels")) "levels"))
            (level (if (string-empty-p args)
                       (completing-read "Thinking: " levels nil t) args)))
       (unless (member level levels)
         (user-error "Unknown Pi thinking level"))
       (agent-dash-pi--request session (list :type "set_thinking_level" :level level)
                               (lambda (ok _data error)
                                 (if ok (agent-dash-pi--native-refresh session)
                                   (agent-dash-emit session (list :type 'notice :level 'error
                                                                  :text error)))))))
    ("export"
     (when (and (not (string-empty-p args))
                (not (member (file-name-extension args) '("html" "htm"))))
       (user-error "RPC exports HTML; use Pi terminal for other formats (not sent)"))
     (agent-dash-pi--request
      session (append '(:type "export_html")
                      (unless (string-empty-p args) (list :outputPath (expand-file-name args))))
      (lambda (ok data error)
        (agent-dash-emit session (list :type 'notice :level (if ok 'info 'error)
                                       :text (if ok (format "Exported: %s"
                                                            (agent-dash-jget data "path"))
                                               error))))))
    (_ (user-error "/%s needs the Pi terminal UI; it was not sent to a model" name))))

(provide 'agent-dash-pi-commands)
;;; agent-dash-pi-commands.el ends here
