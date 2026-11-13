;;; agent-dash-pi-test.el --- Pi backend and holder tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: records are fed by hand or by test/bin/fake-pi, never Pi.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defun agent-dash-test-feed (session &rest records)
  "Feed JSON RECORDS (strings) to the Pi translator of SESSION."
  (dolist (r records)
    (agent-dash-pi--record session (agent-dash-json-read r))))

(defun agent-dash-test-items (session)
  "Return SESSION's items as (TYPE ID TEXT-OR-STATUS) lists."
  (mapcar (lambda (i) (list (plist-get i :type) (plist-get i :id)
                            (or (plist-get i :text) (plist-get i :status))))
          (agent-dash-session-items session)))

(ert-deftest agent-dash-pi-test-streaming-then-final-is-one-item ()
  (let ((s (agent-dash-session-create 'pi "/tmp")))
    (agent-dash-test-feed
     s
     "{\"type\":\"agent_start\"}"
     "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"timestamp\":7}}"
     "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"hm\"}}"
     "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":1,\"delta\":\"He\"}}"
     "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":1,\"delta\":\"llo\"}}")
    (should (eq (agent-dash-session-state s) 'running))
    (let ((item (agent-dash-item s "a7")))
      (should (equal (plist-get item :text) "Hello"))
      (should (equal (plist-get item :thinking) "hm"))
      (should-not (plist-get item :final)))
    (agent-dash-test-feed
     s
     "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"model\":\"m2\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hm.\"},{\"type\":\"text\",\"text\":\"Hello!\"}],\"timestamp\":7}}"
     "{\"type\":\"turn_end\",\"message\":{\"role\":\"assistant\"}}"
     "{\"type\":\"agent_end\",\"messages\":[]}")
    (should (equal (agent-dash-test-items s) '((assistant "a7" "Hello!"))))
    (should (plist-get (agent-dash-item s "a7") :final))
    (should (eq (agent-dash-session-state s) 'running))
    (agent-dash-test-feed s "{\"type\":\"agent_settled\",\"aborted\":false}")
    (should (eq (agent-dash-session-state s) 'idle))
    (should (equal (plist-get (agent-dash-session-meta s) :model) "m2"))))

(ert-deftest agent-dash-pi-test-tool-lifecycle ()
  (let ((s (agent-dash-session-create 'pi "/tmp")))
    (agent-dash-test-feed
     s
     "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_start\",\"contentIndex\":0,\"id\":\"c1\",\"toolName\":\"bash\"}}"
     "{\"type\":\"tool_execution_start\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"args\":{\"command\":\"ls\"}}"
     "{\"type\":\"tool_execution_update\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"args\":{\"command\":\"ls\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}}")
    (should (equal (plist-get (agent-dash-item s "c1") :output) "a"))
    (agent-dash-test-feed
     s
     "{\"type\":\"tool_execution_end\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\\nb\"}]},\"isError\":true}")
    (let ((tool (agent-dash-item s "c1")))
      (should (equal (plist-get tool :args) "ls"))
      (should (equal (plist-get tool :output) "a\nb"))
      (should (eq (plist-get tool :status) 'error)))))

(ert-deftest agent-dash-pi-test-history-replay ()
  (let ((s (agent-dash-session-create 'pi "/tmp")))
    (dolist (m '("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"q\"}],\"timestamp\":1}"
                 "{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"read\",\"arguments\":{\"path\":\"x.el\"}}],\"timestamp\":2}"
                 "{\"role\":\"toolResult\",\"toolCallId\":\"c1\",\"toolName\":\"read\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":false,\"timestamp\":3}"
                 "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"timestamp\":4}"))
      (agent-dash-pi--message s (agent-dash-json-read m)))
    (should (equal (agent-dash-test-items s)
                   '((user "u1" "q") (tool "c1" success) (assistant "a4" "done"))))
    (should (equal (plist-get (agent-dash-item s "c1") :args) "x.el"))))

(ert-deftest agent-dash-pi-test-queue-and-extension-ui ()
  (let ((s (agent-dash-session-create 'pi "/tmp")))
    (agent-dash-test-feed
     s
     "{\"type\":\"queue_update\",\"steering\":[\"s\"],\"followUp\":[\"f1\",\"f2\"]}"
     "{\"type\":\"extension_ui_request\",\"id\":\"x1\",\"method\":\"select\",\"title\":\"Pick\",\"options\":[\"A\",\"B\"]}"
     "{\"type\":\"extension_ui_request\",\"id\":\"x2\",\"method\":\"setStatus\",\"statusKey\":\"k\",\"statusText\":\"busy\"}"
     "{\"type\":\"extension_ui_request\",\"id\":\"x3\",\"method\":\"notify\",\"message\":\"hey\",\"notifyType\":\"warning\"}")
    (should (equal (agent-dash-session-queue s) '(:steering ("s") :follow-up ("f1" "f2"))))
    (should (equal (agent-dash-session-requests s)
                   '((:type request :id "x1" :kind select :title "Pick"
                            :options ("A" "B") :default nil))))
    (should (equal (plist-get (agent-dash-session-meta s) :status) "busy"))
    (should (equal (mapcar (lambda (i) (plist-get i :type)) (agent-dash-session-items s))
                   '(request notice)))
    (should (equal (plist-get (cadr (agent-dash-session-items s)) :text) "hey"))))

(ert-deftest agent-dash-pi-test-holder-end-to-end ()
  (agent-dash-test-with-holders
    (let* ((agent-dash-pi-executable (expand-file-name "fake-pi" agent-dash-test--bin))
           (session (agent-dash-open 'pi temporary-file-directory))
           (dir (agent-dash-holder-dir 'pi (agent-dash-data session :sid))))
      (with-current-buffer (agent-dash-session-buffer session)
        (agent-dash-test-wait (lambda () (agent-dash-item session "u1")))
        (should (equal (plist-get (agent-dash-session-meta session) :model) "m1"))
        (insert "hello 你好")
        (agent-dash-send)
        (agent-dash-test-wait
         (lambda () (and (eq (agent-dash-session-state session) 'idle)
                         (plist-get (agent-dash-item session "a5") :final))))
        (should (equal (buffer-substring-no-properties (point-min) agent-dash--transcript-end)
                       "\nYou: old\n\n\nYou: hello 你好\n\nPi: hi!\n"))
        ;; Killing the buffer only detaches; resuming reattaches the same agent.
        (let ((pid (agent-dash-holder-pid dir)))
          (kill-buffer)
          (should (agent-dash-holder-alive-p dir))
          (let ((again (agent-dash-open 'pi temporary-file-directory
                                        (agent-dash-data session :sid))))
            (should (equal (agent-dash-holder-pid dir) pid))
            (agent-dash-test-wait (lambda () (agent-dash-item again "u1")))
            (with-current-buffer (agent-dash-session-buffer again)
              (cl-letf (((symbol-function 'yes-or-no-p) #'always))
                (agent-dash-quit))))
          (agent-dash-test-wait (lambda () (not (agent-dash-holder-alive-p dir)))))))))

(ert-deftest agent-dash-holder-test-stdout-is-pipe-and-exit-recorded ()
  (agent-dash-test-with-holders
    (let ((s (agent-dash-session-create 'fake "/tmp"))
          (dir (agent-dash-holder-dir 'fake "h1"))
          (records nil))
      (agent-dash-holder-start
       dir "/tmp" (list "sh" "-c" "[ -p /dev/stdout ] && echo '{\"pipe\":true}'; exit 3"))
      (agent-dash-holder-attach s dir (lambda (_s r) (push r records)) t)
      (agent-dash-test-wait (lambda () (= 2 (length records))))
      (should (agent-dash-jget (cadr records) "pipe"))
      (should (equal (agent-dash-jget (car records) "type") "agent_dash_exit"))
      (should (equal (agent-dash-jget (car records) "code") 3))
      (agent-dash-holder-detach s))))

(provide 'agent-dash-pi-test)
;;; agent-dash-pi-test.el ends here
