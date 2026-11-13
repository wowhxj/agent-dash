;;; agent-dash-claude-test.el --- Claude backend tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: records are fed by hand or by test/bin/fake-claude.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defun agent-dash-claude-test-feed (session &rest records)
  "Feed JSON RECORDS (strings) to the Claude translator of SESSION."
  (dolist (r records)
    (agent-dash-claude--record session (agent-dash-json-read r))))

(ert-deftest agent-dash-claude-test-blocks-merge-into-one-message ()
  (let ((s (agent-dash-session-create 'claude "/tmp")))
    (agent-dash-claude-test-feed
     s
     "{\"type\":\"stream_event\",\"uuid\":\"e1\",\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"m1\"}}}"
     "{\"type\":\"stream_event\",\"uuid\":\"e2\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hm\"}}}"
     "{\"type\":\"assistant\",\"uuid\":\"b1\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hm\"}]}}"
     "{\"type\":\"stream_event\",\"uuid\":\"e3\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}}")
    (should (eq (agent-dash-session-state s) 'running))
    (let ((m (agent-dash-item s "m1")))
      (should (equal (plist-get m :thinking) "hm"))
      (should (equal (plist-get m :text) "Hi"))
      (should-not (plist-get m :final)))
    (agent-dash-claude-test-feed
     s
     "{\"type\":\"assistant\",\"uuid\":\"b2\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"text\",\"text\":\"Hi!\"}]}}"
     "{\"type\":\"stream_event\",\"uuid\":\"e4\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\"}}}"
     "{\"type\":\"assistant\",\"uuid\":\"b3\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}"
     "{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"a b\"}]}}"
     ;; Replayed duplicates are skipped by uuid.
     "{\"type\":\"assistant\",\"uuid\":\"b2\",\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"text\",\"text\":\"Hi!\"}]}}"
     "{\"type\":\"result\",\"uuid\":\"r1\",\"subtype\":\"success\",\"result\":\"Hi!\"}")
    (let ((m (agent-dash-item s "m1")) (tool (agent-dash-item s "t1")))
      (should (equal (plist-get m :text) "Hi!"))
      (should (plist-get m :final))
      (should (equal (plist-get tool :args) "ls"))
      (should (equal (plist-get tool :output) "a b"))
      (should (eq (plist-get tool :status) 'success)))
    (should (eq (agent-dash-session-state s) 'idle))
    (should (equal (mapcar (lambda (i) (plist-get i :id)) (agent-dash-session-items s))
                   '("m1" "t1")))))

(ert-deftest agent-dash-claude-test-user-prompts-filtered ()
  (let ((s (agent-dash-session-create 'claude "/tmp")))
    (agent-dash-claude-test-feed
     s
     "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"real\"}}"
     "{\"type\":\"user\",\"uuid\":\"u2\",\"isMeta\":true,\"message\":{\"content\":\"meta\"}}"
     "{\"type\":\"user\",\"uuid\":\"u3\",\"message\":{\"content\":\"<command-name>x</command-name>\"}}"
     "{\"type\":\"user\",\"uuid\":\"u4\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"[Request interrupted by user]\"}]}}"
     "{\"type\":\"user\",\"uuid\":\"u5\",\"parent_tool_use_id\":\"t9\",\"message\":{\"content\":\"sub\"}}")
    (should (equal (mapcar (lambda (i) (list (plist-get i :type) (plist-get i :text)))
                           (agent-dash-session-items s))
                   '((user "real") (notice "interrupted"))))))

(ert-deftest agent-dash-claude-test-permission-and-questions ()
  (let ((s (agent-dash-session-create 'claude "/tmp")) (written nil))
    (cl-letf (((symbol-function 'agent-dash-holder-write)
               (lambda (_session object) (push object written))))
      (agent-dash-claude-test-feed
       s
       "{\"type\":\"control_request\",\"request_id\":\"p1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"rm x\"}}}"
       "{\"type\":\"control_request\",\"request_id\":\"q1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Color?\",\"options\":[{\"label\":\"red\"},{\"label\":\"blue\"}]}]}}}")
      (let ((requests (agent-dash-session-requests s)))
        (should (equal (mapcar (lambda (r) (plist-get r :kind)) requests) '(permission questions)))
        (should (equal (plist-get (car requests) :title) "Claude wants Bash: rm x"))
        (should (equal (plist-get (cadr requests) :questions)
                       '((:question "Color?" :options ("red" "blue") :multi nil))))
        (agent-dash-backend-respond 'claude s (car requests) 'deny)
        (agent-dash-backend-respond 'claude s (cadr requests) '("blue")))
      (let ((deny (plist-get (plist-get (cadr written) :response) :response))
            (allow (plist-get (plist-get (car written) :response) :response)))
        (should (equal (plist-get deny :behavior) "deny"))
        (should (equal (plist-get allow :behavior) "allow"))
        (should (equal (agent-dash-jget (plist-get allow :updatedInput) "answers" "Color?")
                       "blue")))
      ;; Claude echoes the answer; a replay then drops the request.
      (agent-dash-claude-test-feed
       s "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"p1\"}}")
      (should (equal (mapcar (lambda (r) (plist-get r :id)) (agent-dash-session-requests s))
                     '("q1"))))))

(ert-deftest agent-dash-claude-test-queue ()
  (let ((s (agent-dash-session-create 'claude "/tmp")))
    (puthash "c1" "later" (agent-dash-claude--table s :sent))
    (agent-dash-claude-test-feed
     s "{\"type\":\"command_lifecycle\",\"command_uuid\":\"c1\",\"state\":\"queued\"}")
    (should (equal (agent-dash-session-queue s) '(:steering nil :follow-up ("later"))))
    (agent-dash-claude-test-feed
     s "{\"type\":\"command_lifecycle\",\"command_uuid\":\"c1\",\"state\":\"started\"}")
    (should (equal (agent-dash-session-queue s) '(:steering nil :follow-up nil)))))

(ert-deftest agent-dash-claude-test-holder-reattach-replays-once ()
  (agent-dash-test-with-holders
    (let* ((agent-dash-claude-config-directory (make-temp-file "agent-dash-claude" t))
           (agent-dash-claude-executable (expand-file-name "fake-claude" agent-dash-test--bin))
           (session (agent-dash-open 'claude temporary-file-directory))
           (sid (agent-dash-data session :sid))
           (dir (agent-dash-holder-dir 'claude sid))
           (transcript (lambda (s)
                         (with-current-buffer (agent-dash-session-buffer s)
                           (buffer-substring-no-properties (point-min) agent-dash--transcript-end)))))
      (unwind-protect
          (progn
            (agent-dash-test-wait (lambda () (agent-dash-data session :models)))
            (should (equal (agent-dash-backend-models 'claude session) '("opus")))
            (with-current-buffer (agent-dash-session-buffer session)
              (insert "hi")
              (agent-dash-send))
            (agent-dash-test-wait (lambda () (and (agent-dash-session-items session)
                                                  (eq (agent-dash-session-state session) 'idle))))
            (should (equal (funcall transcript session) "\nYou: hi\n\nClaude: Hello\n"))
            (kill-buffer (agent-dash-session-buffer session))
            (should (agent-dash-holder-alive-p dir))
            (let ((again (agent-dash-open 'claude temporary-file-directory sid)))
              (agent-dash-test-wait
               (lambda () (equal (funcall transcript again) "\nYou: hi\n\nClaude: Hello\n")))
              ;; Let the rest of the log replay; nothing may appear twice.
              (accept-process-output nil 0.3)
              (should (equal (funcall transcript again) "\nYou: hi\n\nClaude: Hello\n"))
              (with-current-buffer (agent-dash-session-buffer again)
                (cl-letf (((symbol-function 'yes-or-no-p) #'always))
                  (agent-dash-quit))))
            (agent-dash-test-wait (lambda () (not (agent-dash-holder-alive-p dir)))))
        (delete-directory agent-dash-claude-config-directory t)))))

(provide 'agent-dash-claude-test)
;;; agent-dash-claude-test.el ends here
