;;; agent-dash-pi-commands-test.el --- No-inference Pi commands -*- lexical-binding: t; -*-

;;; Commentary:
;; All protocol and credential interactions are intercepted; no real Pi or auth.

;;; Code:
(require 'ert)
(require 'agent-dash)

(defmacro agent-dash-pi-commands-test-with-chat (&rest body)
  "Run BODY in an idle Pi chat with a synthetic native catalog."
  (declare (indent 0))
  `(let* ((agent-dash--sessions nil)
          (agent-dash-auto-answer nil)
          (session (agent-dash-session-create 'pi temporary-file-directory))
          (buffer (agent-dash--setup-buffer session)))
     (agent-dash-set-data session :pi-local-native-commands
                          (mapcar (lambda (name) (cons name "Native"))
                                  agent-dash-pi--reserved-commands))
     (agent-dash-set-data session :pi-bridge t)
     (agent-dash-set-data session :command-catalog '(("skill:inspect" . "Known skill")))
     (with-current-buffer buffer
       (unwind-protect (progn ,@body)
         (when-let* ((timer (agent-dash-data session :pi-native-timer))) (cancel-timer timer))
         (let ((agent-dash--quitting t)) (kill-buffer buffer))))))

(ert-deftest agent-dash-pi-commands-test-merges-running-directory-and-hides-internal-command ()
  (let* ((session (agent-dash-session-create 'pi "/tmp"))
         (directory (vector '(:name "login" :description "Native login")
                            '(:name "new-builtin" :description "Future command"))))
    (let* ((description (concat "agent-dash-native-v1:" (json-serialize directory)))
           (entries (agent-dash-json-read
                     (json-serialize
                      (vector (list :name "agent-dash-native" :description description)
                              '(:name "skill:inspect" :description "Skill")))))
           (catalog (agent-dash-pi-command-catalog session entries)))
      (should (assoc "login" catalog))
      (should (assoc "skill:inspect" catalog))
      (should (string-search "terminal UI" (cdr (assoc "new-builtin" catalog))))
      (should-not (assoc "agent-dash-native" catalog))
      (should (agent-dash-data session :pi-bridge)))))

(ert-deftest agent-dash-pi-commands-test-login-is-not-a-prompt-or-history-entry ()
  (agent-dash-pi-commands-test-with-chat
   (let ((agent-dash-prompt-filter-functions
          (list (lambda (_) (ert-fail "Authentication passed through a prompt filter"))))
         sent)
     (cl-letf (((symbol-function 'agent-dash-holder-write)
                (lambda (_session message) (setq sent message)))
               ((symbol-function 'agent-dash-pi--request)
                (lambda (&rest _) (ert-fail "Authentication sent through model RPC"))))
       (agent-dash--set-input "/login cliproxyapi")
       (agent-dash-send)
       (should (equal (plist-get sent :type) "extension_ui_response"))
       (should (string-prefix-p "agent-dash-native:" (plist-get sent :id)))
       (let ((payload (agent-dash-json-read
                       (decode-coding-string
                        (base64-decode-string (plist-get sent :value)) 'utf-8))))
         (should (equal (agent-dash-jget payload "command") "login"))
         (should (equal (agent-dash-jget payload "args") "cliproxyapi")))
       (should (equal (agent-dash--input) ""))
       (should-not agent-dash--history)))))

(ert-deftest agent-dash-pi-commands-test-direct-backend-login-also-avoids-inference ()
  (agent-dash-pi-commands-test-with-chat
   (let (sent)
     (cl-letf (((symbol-function 'agent-dash-holder-write) (lambda (&rest _) (setq sent t)))
               ((symbol-function 'agent-dash-pi--request)
                (lambda (&rest _) (ert-fail "Native command became a prompt"))))
       (agent-dash-backend-send 'pi session "/login cliproxyapi" nil 'prompt)
       (should sent)
       (should-error (agent-dash-backend-send 'pi session "next prompt" nil 'prompt)
                     :type 'user-error)))))

(ert-deftest agent-dash-pi-commands-test-inline-credentials-and-terminal-commands-never-send ()
  (agent-dash-pi-commands-test-with-chat
   (cl-letf (((symbol-function 'agent-dash-holder-write)
              (lambda (&rest _) (ert-fail "Unwanted write")))
             ((symbol-function 'agent-dash-pi--request)
              (lambda (&rest _) (ert-fail "Unwanted model/RPC request"))))
     (dolist (text '("/login cliproxyapi FAKE-KEY" "/trust" "/share" "/clone" "/unlisted-command"))
       (agent-dash--set-input text)
       (should-error (agent-dash-send) :type 'user-error)
       (should (equal (agent-dash--input) text))
       (should-not agent-dash--history)))))

(ert-deftest agent-dash-pi-commands-test-old-holder-does-not-fall-back-to-model ()
  (agent-dash-pi-commands-test-with-chat
   (agent-dash-set-data session :pi-bridge nil)
   (cl-letf (((symbol-function 'agent-dash-pi--request)
              (lambda (_session request callback)
                (should (equal (plist-get request :type) "get_commands"))
                (funcall callback t (agent-dash-json-read "{\"commands\":[]}") nil)))
             ((symbol-function 'agent-dash-holder-write)
              (lambda (&rest _) (ert-fail "Old holder received a command"))))
     (should-error (agent-dash-backend-command 'pi session "/login" 'prompt) :type 'user-error))))

(ert-deftest agent-dash-pi-commands-test-secret-dialog-does-not-use-text-input-or-log-answer ()
  (agent-dash-pi-commands-test-with-chat
   (let (response)
     (agent-dash-pi--ui-request
      session (agent-dash-json-read
               (concat "{\"id\":\"secret\",\"method\":\"input\","
                       "\"title\":\"[agent-dash:secret] API key\",\"prefill\":\"ignored\"}")))
     (let ((request (car (agent-dash-session-requests session))))
       (should (eq (plist-get request :kind) 'secret))
       (should (equal (plist-get request :title) "API key"))
       (should-not (plist-get request :default)))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (ert-fail "Plain auth input")))
               ((symbol-function 'read-passwd) (lambda (&rest _) "FAKE-SECRET"))
               ((symbol-function 'agent-dash-holder-write)
                (lambda (_session record) (setq response record))))
       (agent-dash-answer))
     (should (equal (plist-get response :value) "FAKE-SECRET"))
     (should-not (string-search "FAKE-SECRET" (format "%S" (agent-dash-session-items session)))))))

(ert-deftest agent-dash-pi-commands-test-secret-cancellation-is-a-cancelled-ui-response ()
  (agent-dash-pi-commands-test-with-chat
   (let (response)
     (agent-dash-emit session '(:type request :id "secret" :kind secret :title "Key"))
     (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (signal 'quit nil)))
               ((symbol-function 'agent-dash-holder-write)
                (lambda (_session record) (setq response record))))
       (agent-dash-answer))
     (should (plist-get response :cancelled))
     (should-not (plist-member response :value)))))

(ert-deftest agent-dash-pi-commands-test-bridge-ack-and-result-are-correlated ()
  (agent-dash-pi-commands-test-with-chat
   (cl-letf (((symbol-function 'agent-dash-holder-write) #'ignore)
             ((symbol-function 'agent-dash-pi--native-refresh) #'ignore))
     (agent-dash-backend-command 'pi session "/login" 'prompt)
     (let ((id (car (agent-dash-data session :pi-native-pending))))
       (agent-dash-pi-native-record
        session (agent-dash-json-read "{\"id\":\"stale\",\"type\":\"agent_dash_native_result\"}"))
       (should (agent-dash-data session :pi-native-pending))
       (agent-dash-pi-native-record
        session (agent-dash-json-read (json-serialize
                                       (list :id id :type "agent_dash_native_started"))))
       (should-not (agent-dash-data session :pi-native-timer))
       (agent-dash-pi-native-record
        session (agent-dash-json-read (json-serialize
                                       (list :id id :type "agent_dash_native_result"
                                             :success :false :message "Cancelled"))))
       (should-not (agent-dash-data session :pi-native-pending))))))

(ert-deftest agent-dash-pi-commands-test-thinking-uses-runtime-supported-levels ()
  (agent-dash-pi-commands-test-with-chat
   (let (requests)
     (cl-letf (((symbol-function 'agent-dash-pi--native-refresh) #'ignore)
               ((symbol-function 'agent-dash-pi--request)
                (lambda (_session request callback)
                  (push request requests)
                  (funcall callback t
                           (agent-dash-json-read "{\"levels\":[\"off\",\"low\"]}") nil))))
       (should-error (agent-dash-backend-command 'pi session "/thinking high" 'prompt)
                     :type 'user-error)
       (agent-dash-backend-command 'pi session "/thinking low" 'prompt)
       (should (equal (plist-get (car requests) :type) "set_thinking_level"))
       (should (equal (plist-get (car requests) :level) "low"))))))

(ert-deftest agent-dash-pi-commands-test-explicit-model-and-registered-skill-routing ()
  (agent-dash-pi-commands-test-with-chat
   (let (chosen sent)
     (cl-letf (((symbol-function 'agent-dash-backend-set-model)
                (lambda (_backend _session model) (setq chosen model))))
       (agent-dash--set-input "/model provider/model/with/slashes")
       (agent-dash-send)
       (should (equal chosen "provider/model/with/slashes")))
     (agent-dash-set-data session :command-catalog '(("skill:inspect" . "Known skill")))
     (cl-letf (((symbol-function 'agent-dash-pi--request)
                (lambda (_session request _callback) (setq sent request))))
       (agent-dash-backend-command 'pi session "/skill:inspect" 'prompt)
       (should (equal (plist-get sent :type) "prompt"))
       (should (equal (plist-get sent :message) "/skill:inspect"))))))

(ert-deftest agent-dash-pi-commands-test-notification-transport-is-not-chat-text ()
  (agent-dash-pi-commands-test-with-chat
   (cl-letf (((symbol-function 'agent-dash-holder-write) #'ignore)
             ((symbol-function 'agent-dash-pi--native-refresh) #'ignore))
     (agent-dash-backend-command 'pi session "/login" 'prompt)
     (let* ((id (car (agent-dash-data session :pi-native-pending)))
            (message (concat "[agent-dash:native] "
                             (json-serialize (list :id id :type "agent_dash_native_result"
                                                   :success t :message "Authenticated")))))
       (agent-dash-pi--ui-request
        session (agent-dash-json-read (json-serialize
                                       (list :method "notify" :message message))))
       (should-not (agent-dash-data session :pi-native-pending))
       (should-not (agent-dash-data session :pi-native-timer))
       (should-not (string-search "[agent-dash:native]"
                                  (format "%S" (agent-dash-session-items session))))))))

(ert-deftest agent-dash-pi-commands-test-pi-completion-does-not-add-client-only-aliases ()
  (agent-dash-pi-commands-test-with-chat
   (agent-dash-set-data session :commands-loaded t)
   (agent-dash-set-data session :command-catalog (agent-dash-pi-native-commands session))
   (let ((commands (agent-dash-input--commands session)))
     (should (assoc "login" commands))
     (should (assoc "model" commands))
     (should-not (assoc "dash" commands))
     (should-not (assoc "stop" commands))
     (should-not (assoc "help" commands)))))

(ert-deftest agent-dash-pi-commands-test-exit-clears-control-state ()
  (agent-dash-pi-commands-test-with-chat
   (cl-letf (((symbol-function 'agent-dash-holder-write) #'ignore))
     (agent-dash-backend-command 'pi session "/login" 'prompt)
     (agent-dash-pi--record
      session (agent-dash-json-read "{\"type\":\"agent_dash_exit\",\"code\":0}"))
     (should-not (agent-dash-data session :pi-native-pending))
     (should-not (agent-dash-data session :pi-native-timer))
     (should-not (agent-dash-data session :pi-bridge)))))

(provide 'agent-dash-pi-commands-test)
;;; agent-dash-pi-commands-test.el ends here
