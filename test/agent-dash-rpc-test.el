;;; agent-dash-rpc-test.el --- Codex and Hermes backend tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: JSON-RPC records are fed by hand; writes are captured.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-rpc-test-capture (&rest body)
  "Run BODY with holder writes collected in `written', newest first."
  (declare (indent 0))
  `(let ((written nil))
     (cl-letf (((symbol-function 'agent-dash-holder-write)
                (lambda (_session object) (push object written)))
               ((symbol-function 'agent-dash-holder-set-sid)
                (lambda (session sid) (agent-dash-set-data session :sid sid))))
       ,@body)))

(defun agent-dash-rpc-test-feed (fn session &rest records)
  "Feed JSON RECORDS (strings) to translator FN of SESSION."
  (dolist (r records) (funcall fn session (agent-dash-json-read r))))

(ert-deftest agent-dash-codex-test-turn ()
  (agent-dash-rpc-test-capture
   (let ((s (agent-dash-session-create 'codex "/tmp")))
     (agent-dash-rpc-test-feed
      #'agent-dash-codex--record s
      ;; A replayed thread/start response carries the thread and its history.
      "{\"id\":\"old\",\"result\":{\"thread\":{\"id\":\"T1\",\"turns\":[{\"items\":[{\"type\":\"userMessage\",\"id\":\"i0\",\"content\":[{\"type\":\"text\",\"text\":\"before\"}]}]}]}}}"
      "{\"method\":\"turn/started\",\"params\":{\"turn\":{\"id\":\"turn1\"}}}"
      "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"i1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}}"
      "{\"method\":\"item/reasoning/summaryTextDelta\",\"params\":{\"itemId\":\"r1\",\"delta\":\"think\"}}"
      "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"commandExecution\",\"id\":\"c1\",\"command\":\"ls\",\"status\":\"inProgress\"}}}"
      "{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"itemId\":\"c1\",\"delta\":\"a\\n\"}}"
      "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"commandExecution\",\"id\":\"c1\",\"command\":\"ls\",\"aggregatedOutput\":\"a\\nb\",\"status\":\"completed\"}}}"
      "{\"method\":\"item/agentMessage/delta\",\"params\":{\"itemId\":\"m1\",\"delta\":\"Do\"}}"
      "{\"method\":\"item/agentMessage/delta\",\"params\":{\"itemId\":\"m1\",\"delta\":\"ne\"}}")
     (should (equal (agent-dash-data s :sid) "T1"))
     (should (eq (agent-dash-session-state s) 'running))
     (should (equal (plist-get (agent-dash-item s "m1") :text) "Done"))
     (should (equal (plist-get (agent-dash-item s "r1") :thinking) "think"))
     (agent-dash-rpc-test-feed
      #'agent-dash-codex--record s
      "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"m1\",\"text\":\"Done.\"}}}"
      "{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn1\",\"status\":\"completed\"}}}")
     (should (equal (mapcar (lambda (i) (plist-get i :id)) (agent-dash-session-items s))
                    '("i0" "i1" "r1" "c1" "m1")))
     (should (equal (plist-get (agent-dash-item s "c1") :output) "a\nb"))
     (should (eq (plist-get (agent-dash-item s "c1") :status) 'success))
     (should (plist-get (agent-dash-item s "m1") :final))
     (should (eq (agent-dash-session-state s) 'idle))
     (agent-dash-backend-send 'codex s "more" nil 'steer)
     (let ((params (plist-get (car written) :params)))
       (should (equal (plist-get (car written) :method) "turn/steer"))
       (should (equal (plist-get params :expectedTurnId) "turn1"))
       (should (equal (plist-get params :threadId) "T1"))))))

(ert-deftest agent-dash-codex-test-approvals ()
  (agent-dash-rpc-test-capture
   (let ((s (agent-dash-session-create 'codex "/tmp")))
     (agent-dash-rpc-test-feed
      #'agent-dash-codex--record s
      "{\"id\":7,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"rm x\",\"reason\":\"cleanup\"}}"
      "{\"id\":8,\"method\":\"item/tool/requestUserInput\",\"params\":{\"questions\":[{\"id\":\"q1\",\"question\":\"Which?\",\"options\":[{\"label\":\"A\"}]}]}}"
      "{\"id\":9,\"method\":\"attestation/generate\",\"params\":{}}")
     (should (equal (plist-get (car written) :error)
                    '(:code -32601 :message "attestation/generate is not supported by agent-dash")))
     (let ((requests (agent-dash-session-requests s)))
       (should (equal (plist-get (car requests) :title) "Codex wants to rm x (cleanup)"))
       (agent-dash-backend-respond 'codex s (car requests) 'deny)
       (should (equal (plist-get (car written) :result) '(:decision "decline")))
       (agent-dash-backend-respond 'codex s (cadr requests) '("A"))
       (should (equal (agent-dash-jget (plist-get (plist-get (car written) :result) :answers) "q1")
                      '(:answers ["A"]))))
     (agent-dash-rpc-test-feed #'agent-dash-codex--record s
                               "{\"method\":\"serverRequest/resolved\",\"params\":{\"requestId\":7}}")
     (should (equal (mapcar (lambda (r) (plist-get r :id)) (agent-dash-session-requests s)) '(8))))))

(ert-deftest agent-dash-hermes-test-turn ()
  (agent-dash-rpc-test-capture
   (let ((s (agent-dash-session-create 'hermes "/tmp")))
     (agent-dash-rpc-test-feed
      #'agent-dash-hermes--record s
      "{\"id\":\"x\",\"result\":{\"sessionId\":\"H1\"}}"
      "{\"type\":\"agent_dash_user\",\"id\":\"p1\",\"text\":\"hi\"}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hm\"}}}}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Let me \"}}}}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"look.\"}}}}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"ls\",\"kind\":\"execute\",\"status\":\"pending\"}}}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"a b\"}}]}}}"
      "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Done\"}}}}")
     (should (equal (agent-dash-data s :sid) "H1"))
     (should (eq (agent-dash-session-state s) 'running))
     (agent-dash-rpc-test-feed #'agent-dash-hermes--record s
                               "{\"id\":\"y\",\"result\":{\"stopReason\":\"end_turn\"}}")
     (should (eq (agent-dash-session-state s) 'idle))
     (should (equal (mapcar (lambda (i) (list (plist-get i :id) (plist-get i :text)))
                            (agent-dash-session-items s))
                    '(("p1" "hi") ("a2" "Let me look.") ("t1" nil) ("a3" "Done"))))
     (should (equal (plist-get (agent-dash-item s "a2") :thinking) "hm"))
     (should (equal (plist-get (agent-dash-item s "t1") :output) "a b"))
     (should (eq (plist-get (agent-dash-item s "t1") :status) 'success)))))

(ert-deftest agent-dash-hermes-test-permission ()
  (agent-dash-rpc-test-capture
   (let ((s (agent-dash-session-create 'hermes "/tmp")))
     (agent-dash-rpc-test-feed
      #'agent-dash-hermes--record s
      "{\"id\":5,\"method\":\"session/request_permission\",\"params\":{\"toolCall\":{\"title\":\"rm x\"},\"options\":[{\"optionId\":\"o1\",\"kind\":\"allow_once\"},{\"optionId\":\"o2\",\"kind\":\"reject_once\"}]}}"
      "{\"id\":6,\"method\":\"fs/read_text_file\",\"params\":{}}")
     (should (equal (plist-get (car written) :error)
                    '(:code -32601 :message "fs/read_text_file is not supported by agent-dash")))
     (let ((request (car (agent-dash-session-requests s))))
       (should (equal (plist-get request :title) "Hermes wants rm x"))
       (agent-dash-backend-respond 'hermes s request 'allow)
       (should (equal (plist-get (car written) :result)
                      '(:outcome (:outcome "selected" :optionId "o1"))))))))

(provide 'agent-dash-rpc-test)
;;; agent-dash-rpc-test.el ends here
