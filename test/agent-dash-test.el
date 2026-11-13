;;; agent-dash-test.el --- Tests for agent-dash -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline ERT tests.  Never touch real sessions, credentials
;; or paid models.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-test-with-chat (&rest body)
  "Run BODY in a fresh fake chat buffer; `session' names its session."
  (declare (indent 0))
  `(let* ((agent-dash-fake-calls nil)
          (session (agent-dash-open (quote fake) temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect (progn ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))))))

(defun agent-dash-test-transcript ()
  "Return the transcript text above the separator."
  (buffer-substring-no-properties (point-min) agent-dash--transcript-end))

(ert-deftest agent-dash-test-send-clears-draft-and-records-history ()
  (agent-dash-test-with-chat
   (should (equal (car agent-dash-fake-calls)
                  (list 'start (agent-dash-session-id session) nil)))
   (goto-char (point-max))
   (insert "  hello  ")
   (agent-dash-send)
   (should (equal (car agent-dash-fake-calls) '(send "hello" nil prompt)))
   (should (equal (agent-dash--input) ""))
   (should (equal agent-dash--history '("hello")))))

(ert-deftest agent-dash-test-send-while-running-is-follow-up ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type run :state running))
   (goto-char (point-max))
   (insert "next")
   (agent-dash-send)
   (should (equal (car agent-dash-fake-calls) '(send "next" nil follow-up)))
   (insert "turn")
   (agent-dash-steer)
   (should (equal (car agent-dash-fake-calls) '(send "turn" nil steer)))))

(ert-deftest agent-dash-test-empty-draft-is-not-sent ()
  (agent-dash-test-with-chat
   (should-error (agent-dash-send) :type 'user-error)
   (should (= 1 (length agent-dash-fake-calls)))))

(ert-deftest agent-dash-test-streaming-replaces-and-keeps-draft ()
  (agent-dash-test-with-chat
   (goto-char (point-max))
   (insert "draft")
   (agent-dash-emit session '(:type user :id "u1" :text "hi"))
   (agent-dash-emit session '(:type assistant :id "a1" :text "He"))
   (agent-dash-emit session '(:type assistant :id "a1" :text "Hello"))
   (agent-dash-emit session '(:type assistant :id "a1" :text "Hello!" :final t))
   (should (equal (agent-dash-test-transcript) "\nYou: hi\n\nFake: Hello!\n"))
   (should (equal (agent-dash--input) "draft"))
   (should (= (point) (point-max)))))

(ert-deftest agent-dash-test-same-id-shows-once ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type user :id "u1" :text "hi"))
   (agent-dash-emit session '(:type user :id "u1" :text "hi"))
   (should (equal (agent-dash-test-transcript) "\nYou: hi\n\n"))
   (should (= 1 (length (agent-dash-session-items session))))))

(ert-deftest agent-dash-test-tool-folds ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type tool :id "t1" :name "bash" :args "ls"
                                    :status running))
   (agent-dash-emit session '(:type assistant :id "a1" :text "done" :final t))
   (should (equal (agent-dash-test-transcript)
                  "▸ Process · 1 steps\n… bash  ls\nFake: done\n"))
   (agent-dash-emit session '(:type tool :id "t1" :status success
                                    :output "a\nb"))
   (should (equal (agent-dash-test-transcript)
                  "▸ Process · 1 steps\n✓ bash  ls\nFake: done\n"))
   (goto-char (point-min))
   (agent-dash-toggle)
   (forward-line 1)
   (agent-dash-toggle)
   (should (equal (agent-dash-test-transcript)
                  "▾ Process · 1 steps\n✓ bash  ls\n    a\n    b\nFake: done\n"))
   (agent-dash-toggle)
   (should (equal (agent-dash-test-transcript)
                  "▾ Process · 1 steps\n✓ bash  ls\nFake: done\n"))))

(ert-deftest agent-dash-test-thinking-folds ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type assistant :id "a1" :thinking "plan\nmore"
                                    :text "ok"))
   (should (equal (agent-dash-test-transcript) "▸ Thinking  plan more\nFake: ok\n"))))

(ert-deftest agent-dash-test-transcript-is-read-only ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type user :id "u1" :text "hi"))
   (goto-char (point-min))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char agent-dash--input-start)
   (insert "ok")
   (should (equal (agent-dash--input) "ok"))))

(ert-deftest agent-dash-test-queue-and-requests-in-mode-line ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type queue :steering ("a") :follow-up ("b")))
   (agent-dash-emit session '(:type meta :model "m1"))
   (agent-dash-emit session '(:type request :id "r1" :kind confirm :title "Ok?"))
   (should (equal (agent-dash--mode-line) " Fake waiting [S1 F1] ?1"))))

(ert-deftest agent-dash-test-prompt-history ()
  (agent-dash-test-with-chat
   (goto-char (point-max))
   (dolist (text '("one" "two"))
     (insert text)
     (agent-dash-send))
   (insert "draft")
   (agent-dash-previous-prompt)
   (should (equal (agent-dash--input) "two"))
   (agent-dash-previous-prompt)
   (should (equal (agent-dash--input) "one"))
   (should-error (agent-dash-previous-prompt) :type 'user-error)
   (agent-dash-next-prompt)
   (agent-dash-next-prompt)
   (should (equal (agent-dash--input) "draft"))))

(ert-deftest agent-dash-test-answer-requests ()
  (agent-dash-test-with-chat
   (agent-dash-emit session '(:type request :id "r1" :kind permission :title "Run?"))
   (agent-dash-emit session '(:type request :id "r2" :kind input :title "Name?"))
   (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?y "yes")))
             ((symbol-function 'read-string) (lambda (&rest _) "bob")))
     (agent-dash-answer))
   (should (equal (seq-take agent-dash-fake-calls 2)
                  '((respond "r2" "bob") (respond "r1" allow))))
   (should-not (agent-dash-session-requests session))))

(ert-deftest agent-dash-test-kill-buffer-detaches ()
  (let* ((agent-dash-fake-calls nil)
         (session (agent-dash-open (quote fake) temporary-file-directory)))
    (kill-buffer (agent-dash-session-buffer session))
    (should (equal (car agent-dash-fake-calls) '(detach)))
    (should-not (memq session agent-dash--sessions))))

(ert-deftest agent-dash-test-quit-stop-confirms-detach-does-not ()
  (let ((agent-dash-fake-calls nil) (asked nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t))))
      (with-current-buffer (agent-dash-session-buffer
                            (agent-dash-open 'fake temporary-file-directory))
        (agent-dash-quit))
      (should asked)
      (should (equal (car agent-dash-fake-calls) '(quit)))
      (setq asked nil)
      (let ((agent-dash-fake-quit 'detach))
        (with-current-buffer (agent-dash-session-buffer
                              (agent-dash-open 'fake temporary-file-directory))
          (agent-dash-quit)))
      (should-not asked)
      (should (equal (car agent-dash-fake-calls) '(quit))))))

(ert-deftest agent-dash-test-autoloads-load-whole-package ()
  "Package autoloads must load agent-dash.el, which requires every backend."
  (let* ((source (file-name-directory (locate-library "agent-dash")))
         (dir (make-temp-file "agent-dash-loaddefs" t))
         (file (expand-file-name "agent-dash-autoloads.el" dir)))
    (unwind-protect
        (progn
          (dolist (el (directory-files source t "\\`agent-dash.*\\.el\\'"))
            (copy-file el (file-name-as-directory dir)))
          (loaddefs-generate dir file)
          (with-temp-buffer
            (insert-file-contents file)
            (dolist (command '("agent-dash" "agent-dash-hub"))
              (goto-char (point-min))
              (should (re-search-forward
                       (format "(autoload '%s \"\\([^\"]+\\)\"" (regexp-quote command)) nil t))
              (should (equal (match-string 1) "agent-dash")))))
      (delete-directory dir t))))

(ert-deftest agent-dash-test-tests-run-without-summaries ()
  "The test run must not summarize real sessions through gptel."
  (should-not agent-dash-summary-enable)
  (should-not agent-dash-summary-mode))

(provide 'agent-dash-test)
;;; agent-dash-test.el ends here
