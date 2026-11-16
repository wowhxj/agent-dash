;;; agent-dash-requests-test.el --- Interactive request tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline coverage for minibuffer dialogs and Pi's RPC fallback.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-request-test-with-chat (&rest body)
  "Run BODY in an offline chat; expose its session as `session'."
  (declare (indent 0))
  `(let* ((agent-dash-fake-calls nil)
          (session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect (progn ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))))))

(ert-deftest agent-dash-request-is-visible-and-preserves-draft ()
  (agent-dash-request-test-with-chat
   (agent-dash--set-input "unfinished draft")
   (agent-dash-emit session '(:type request :id "choice" :kind select
                                    :title "请选择排版" :options ("自然段" "项目列表")))
   (should (string-search "请选择排版" (buffer-string)))
   (should (string-search "自然段" (buffer-string)))
   (should (string-search "C-c C-a" (buffer-string)))
   (should (equal (agent-dash--input) "unfinished draft"))
   (agent-dash-emit session '(:type request-done :id "choice" :status cancelled))
   (should (string-search "cancelled" (buffer-string)))
   (should-not (agent-dash-session-requests session))
   (agent-dash-refresh-chat)
   (should (equal (agent-dash--input) "unfinished draft"))))

(ert-deftest agent-dash-request-answers-remain-visible-after-refresh ()
  "Retain exact non-secret answers, including negative confirmations."
  (dolist (case '((select "项目列表" "You: 项目列表")
                  (input "第一行\n第二行" "You: 第一行\n第二行")
                  (input "" "You: (skipped)")
                  (confirm t "You: Yes") (confirm nil "You: No")
                  (permission allow "You: Allow") (permission deny "You: Deny")))
    (agent-dash-request-test-with-chat
     (agent-dash--set-input "unfinished draft")
     (agent-dash-emit session (list :type 'request :id "answer" :title "Question"
                                    :kind (nth 0 case) :options '("项目列表")))
     (cl-letf (((symbol-function 'agent-dash--ask) (lambda (_) (nth 1 case))))
       (agent-dash-answer))
     (let ((dialog (agent-dash-item session '(request . "answer"))))
       (should (plist-member dialog :answer))
       (should (equal (plist-get dialog :answer) (nth 1 case))))
     (should (string-search (nth 2 case) (buffer-string)))
     (agent-dash-refresh-chat)
     (should (string-search (nth 2 case) (buffer-string)))
     (should (equal (agent-dash--input) "unfinished draft")))))

(ert-deftest agent-dash-request-question-answers-are-paired-with-their-questions ()
  "Show each answer beside its own question, not as an unlabelled list."
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "questions" :kind questions
                                    :questions ((:question "First")
                                                (:question "Second" :multi t)
                                                (:question "Third"))))
   (cl-letf (((symbol-function 'agent-dash--ask)
              (lambda (_) '("A" ("B" "自定义") ""))))
     (agent-dash-answer))
   (let ((text (agent-dash--request-text
                (agent-dash-item session '(request . "questions")))))
     (should (string-search "First\nYou: A\n" text))
     (should (string-search "Second\nYou: B, 自定义\n" text))
     (should (string-search "Third\nYou: (skipped)\n" text)))))

(ert-deftest agent-dash-request-answer-survives-synchronous-backend-completion ()
  "A backend acknowledgement can arrive before the local completion event."
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "race" :kind input))
   (cl-letf (((symbol-function 'agent-dash--ask) (lambda (_) "my answer"))
             ((symbol-function 'agent-dash-backend-respond)
              (lambda (&rest _)
                (agent-dash-emit session '(:type request-done :id "race")))))
     (agent-dash-answer))
   (should (string-search "You: my answer" (buffer-string)))
   (agent-dash-emit session '(:type request-done :id "race" :answer "duplicate"))
   (should (equal (plist-get (agent-dash-item session '(request . "race")) :answer)
                  "my answer"))))

(ert-deftest agent-dash-request-secret-answer-is-never-retained ()
  "Send secrets only to the backend, not timeline items or event hooks."
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "secret" :kind secret))
   (let (events sent
                (agent-dash-event-functions nil))
     (add-hook 'agent-dash-event-functions (lambda (_session event) (push event events)))
     (cl-letf (((symbol-function 'agent-dash--ask) (lambda (_) "PRIVATE-ANSWER"))
               ((symbol-function 'agent-dash-backend-respond)
                (lambda (_backend _session _request answer) (setq sent answer))))
       (agent-dash-answer))
     (should (equal sent "PRIVATE-ANSWER"))
     (should-not (plist-member (agent-dash-item session '(request . "secret")) :answer))
     (should-not (string-search "PRIVATE-ANSWER"
                                (format "%S" (list events (agent-dash-session-items session))))))
   (agent-dash-refresh-chat)
   (should-not (string-search "PRIVATE-ANSWER" (buffer-string)))
   (should (string-search "You: [hidden]" (buffer-string)))))

(ert-deftest agent-dash-request-failed-response-does-not-claim-an-answer ()
  "An unsuccessful backend write leaves the question pending and retryable."
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "failed" :kind input))
   (cl-letf (((symbol-function 'agent-dash--ask) (lambda (_) "not delivered"))
             ((symbol-function 'agent-dash-backend-respond)
              (lambda (&rest _) (error "Offline backend"))))
     (should-error (agent-dash-answer)))
   (let ((dialog (agent-dash-item session '(request . "failed"))))
     (should (eq (plist-get dialog :status) 'pending))
     (should-not (plist-member dialog :answer)))
   (should-not (string-search "You: not delivered" (buffer-string)))))

(ert-deftest agent-dash-request-auto-answer-is-scheduled-not-inline ()
  (agent-dash-request-test-with-chat
   (let ((noninteractive nil) scheduled asked)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (_time _repeat fn &rest args)
                  (setq scheduled (cons fn args)) 'fake-timer))
               ((symbol-function 'agent-dash-answer) (lambda () (setq asked t)))
               ((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer))))
       (agent-dash-emit session '(:type request :id "auto" :kind input :title "Name"))
       (should scheduled)
       (should-not asked)
       (apply (car scheduled) (cdr scheduled))
       (should asked)))))

(ert-deftest agent-dash-request-auto-answer-defers-existing-minibuffer ()
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "defer" :kind input :title "Name"))
   (let ((noninteractive nil) scheduled asked)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (&rest _) (setq scheduled t) 'fake-timer))
               ((symbol-function 'active-minibuffer-window) #'always)
               ((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer)))
               ((symbol-function 'agent-dash-answer) (lambda () (setq asked t))))
       (agent-dash--maybe-answer (current-buffer))
       (should scheduled)
       (should-not asked)))))

(ert-deftest agent-dash-request-ret-opens-pending-dialog-without-sending-draft ()
  (agent-dash-request-test-with-chat
   (agent-dash--set-input "keep this draft")
   (agent-dash-emit session '(:type request :id "ret" :kind input :title "Name"))
   (let (asked)
     (cl-letf (((symbol-function 'agent-dash-answer) (lambda () (setq asked t))))
       (goto-char (point-max))
       (agent-dash-ret)
       (should asked)
       (should (equal (agent-dash--input) "keep this draft"))
       (should-not (eq (caar agent-dash-fake-calls) 'send))))))

(ert-deftest agent-dash-request-minibuffer-single-multi-freeform-and-confirm ()
  (let (require-match multi)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _options _predicate match &rest _)
                 (setq require-match match) "自然段")))
      (should (equal (agent-dash--ask '(:kind select :title "格式" :options ("自然段")))
                     "自然段"))
      (should require-match))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (_prompt _options _predicate match &rest _)
                 (setq multi t require-match match) '("A" "自定义"))))
      (should (equal (agent-dash--ask '(:kind questions :questions
                                              ((:question "Pick" :multi t :options ("A" "B")))))
                     '(("A" "自定义"))))
      (should multi)
      (should-not require-match))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt initial &rest _) (should (equal initial "draft")) "自由输入")))
      (should (equal (agent-dash--ask '(:kind input :title "Other" :default "draft")) "自由输入")))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt)
                                             (should (string-search "删除文件" prompt)) nil)))
      (should-not (agent-dash--ask '(:kind confirm :title "确认" :message "删除文件"))))))

(ert-deftest agent-dash-request-c-g-cancels-pi-dialog-and-keeps-draft ()
  (agent-dash-request-test-with-chat
   (setf (agent-dash-session-backend session) 'pi)
   (agent-dash--set-input "draft")
   (agent-dash-emit session '(:type request :id "cancel" :kind select :title "Pick" :options ("A")))
   (let (sent)
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil)))
               ((symbol-function 'agent-dash-holder-write) (lambda (_s value) (setq sent value))))
       (agent-dash-answer)
       (should (equal sent '(:type "extension_ui_response" :id "cancel" :cancelled t)))
       (should-not (agent-dash-session-requests session))
       (should (equal (agent-dash--input) "draft"))))))

(ert-deftest agent-dash-request-no-response-after-server-withdrawal ()
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "gone" :kind input :title "Name"))
   (cl-letf (((symbol-function 'read-string)
              (lambda (&rest _)
                (agent-dash-emit session '(:type request-done :id "gone" :status cancelled))
                "too late")))
     (agent-dash-answer)
     (should-not (eq (caar agent-dash-fake-calls) 'respond)))))

(ert-deftest agent-dash-pi-dialog-metadata-and-editor-are-preserved ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)))
    (dolist (json '("{\"id\":\"c\",\"method\":\"confirm\",\"title\":\"Confirm\",\"message\":\"Delete files?\"}"
                    "{\"id\":\"i\",\"method\":\"input\",\"title\":\"Name\",\"placeholder\":\"hint\"}"
                    "{\"id\":\"e\",\"method\":\"editor\",\"title\":\"Edit\",\"prefill\":\"original\"}"))
      (agent-dash-pi--ui-request session (agent-dash-json-read json)))
    (let ((requests (agent-dash-session-requests session)))
      (should (equal (plist-get (nth 0 requests) :message) "Delete files?"))
      (should (equal (plist-get (nth 1 requests) :placeholder) "hint"))
      (should-not (plist-get (nth 1 requests) :default))
      (should (eq (plist-get (nth 2 requests) :kind) 'input))
      (should (equal (plist-get (nth 2 requests) :default) "original")))))

(ert-deftest agent-dash-pi-agent-end-clears-withdrawn-dialogs ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)))
    (agent-dash-pi--ui-request session (agent-dash-json-read "{\"id\":\"stale\",\"method\":\"select\",\"title\":\"Pick\",\"options\":[\"A\"]}"))
    (agent-dash-pi--record session (agent-dash-json-read "{\"type\":\"agent_end\"}"))
    (should-not (agent-dash-session-requests session))))

(ert-deftest agent-dash-request-repeated-id-and-expiry-do-not-duplicate-or-reopen ()
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "same" :kind input :title "First"))
   (agent-dash-emit session '(:type request :id "same" :kind input :title "Updated"))
   (should (= 1 (length (agent-dash-session-items session))))
   (should (= 1 (length (agent-dash-session-requests session))))
   (should (equal (plist-get (car (agent-dash-session-items session)) :id) '(request . "same")))
   (agent-dash-emit session '(:type request-done :id "same"))
   (agent-dash-emit session '(:type request-done :id "same" :status cancelled))
   (should (eq (plist-get (car (agent-dash-session-items session)) :status) 'answered))))

(ert-deftest agent-dash-request-auto-answer-does-not-steal-background-focus ()
  (agent-dash-request-test-with-chat
   (agent-dash-emit session '(:type request :id "background" :kind input :title "Name"))
   (let ((noninteractive nil) scheduled asked)
     (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (setq scheduled t)))
               ((symbol-function 'window-buffer) (lambda (&rest _) nil))
               ((symbol-function 'agent-dash-answer) (lambda () (setq asked t))))
       (agent-dash--schedule-answer)
       (agent-dash--maybe-answer (current-buffer))
       (should-not scheduled)
       (should-not asked)))))

(ert-deftest agent-dash-request-cancellation-never-approves-permissions ()
  (let ((request '(:id "permission" :kind permission)) sent)
    (cl-letf (((symbol-function 'agent-dash-holder-write) (lambda (_s v) (setq sent v)))
              ((symbol-function 'agent-dash-holder-reply) (lambda (_s _id v) (setq sent v)))
              ((symbol-function 'agent-dash-dsh--events-result) (lambda (_id v) (setq sent v))))
      (dolist (kind '(confirm select input))
        (agent-dash-backend-respond 'pi nil (list :id "permission" :kind kind) :cancelled)
        (should (eq (plist-get sent :cancelled) t))
        (should-not (plist-member sent :confirmed)))
      (agent-dash-backend-respond 'pi nil '(:id "no" :kind confirm) nil)
      (should (eq (plist-get sent :confirmed) :false))
      (let ((s (agent-dash-session-create 'codex temporary-file-directory)))
        (agent-dash-backend-respond 'codex s request :cancelled)
        (should (equal (plist-get sent :decision) "decline"))
        (agent-dash-backend-respond 'codex s '(:id "q" :kind questions) :cancelled)
        (should (zerop (hash-table-count (plist-get sent :answers)))))
      (let ((s (agent-dash-session-create 'claude temporary-file-directory)))
        (agent-dash-backend-respond 'claude s '(:id "q" :kind questions) :cancelled)
        (should (equal (plist-get (plist-get (plist-get sent :response) :response) :behavior) "deny")))
      (agent-dash-backend-respond 'dsh nil request :cancelled)
      (should (equal (plist-get sent :value) "rejected"))
      (agent-dash-backend-respond 'dsh nil '(:id "q" :kind questions) :cancelled)
      (should (equal (plist-get (plist-get sent :value) :answers) []))
      (let ((s (agent-dash-session-create 'hermes temporary-file-directory)))
        (agent-dash-backend-respond 'hermes s request :cancelled)
        (should (equal (plist-get (plist-get sent :outcome) :outcome) "cancelled"))))))

(ert-deftest agent-dash-pi-ask-user-rpc-multiselect-and-freeform-round-trip ()
  (agent-dash-request-test-with-chat
   (setf (agent-dash-session-backend session) 'pi)
   ;; Pi's ask_user fallback sends a select for each toggle, then an input
   ;; for Other.  The client must return exact labels, not parsed titles.
   (let* ((dialogs '("{\"type\":\"extension_ui_request\",\"id\":\"s1\",\"method\":\"select\",\"title\":\"Choose tools\",\"options\":[\"[ ] A\",\"[ ] B\",\"Other\",\"Done (0)\"]}"
                     "{\"type\":\"extension_ui_request\",\"id\":\"s2\",\"method\":\"select\",\"title\":\"Choose tools\",\"options\":[\"[x] A\",\"[ ] B\",\"Other\",\"Done (1)\"]}"
                     "{\"type\":\"extension_ui_request\",\"id\":\"s3\",\"method\":\"select\",\"title\":\"Choose tools\",\"options\":[\"[x] A\",\"[x] B\",\"Other\",\"Done (2)\"]}"
                     "{\"type\":\"extension_ui_request\",\"id\":\"s4\",\"method\":\"input\",\"title\":\"Other\"}"))
          (answers '("[ ] A" "[ ] B" "Other" "自定义工具")) sent)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt options &rest _)
                  (let ((a (pop answers))) (should (member a options)) a)))
               ((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
               ((symbol-function 'agent-dash-holder-write)
                (lambda (_s v)
                  (push v sent)
                  (when dialogs
                    (agent-dash-pi--record session (agent-dash-json-read (pop dialogs)))))))
       (agent-dash-pi--record session (agent-dash-json-read (pop dialogs)))
       (agent-dash-answer)
       (should (equal (mapcar (lambda (v) (plist-get v :value)) (reverse sent))
                      '("[ ] A" "[ ] B" "Other" "自定义工具")))
       (should (equal (mapcar (lambda (v) (plist-get v :id)) (reverse sent))
                      '("s1" "s2" "s3" "s4")))
       (should-not (agent-dash-session-requests session))))))

(ert-deftest agent-dash-pi-tool-args-show-readable-questions-not-lisp-objects ()
  (should (equal (agent-dash-pi--args (agent-dash-json-read
                                       "{\"question\":\"如何排版？\",\"options\":[{\"title\":\"自然段\"}]}"))
                 "如何排版？"))
  (let ((text (agent-dash-pi--args (agent-dash-json-read "{\"options\":[{\"title\":\"自然段\"}]}"))))
    (should (string-search "自然段" text))
    (should-not (string-search "#s(hash-table" text))))

(provide 'agent-dash-requests-test)
;;; agent-dash-requests-test.el ends here
