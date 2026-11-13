;;; agent-dash-input-test.el --- Input completion tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline completion tables and protocol stubs only.  No real session scans,
;; credential reads, models or interactive minibuffers.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-input-test-with-chat (&rest body)
  "Run BODY with a fake chat named `session' and isolated Hub inventory."
  (declare (indent 0))
  `(let* ((agent-dash-backends '(fake broken))
          (agent-dash-hub--sources (make-hash-table))
          (agent-dash-summary--cache (make-hash-table :test #'equal))
          (agent-dash-fake-calls nil)
          (session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect (progn ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))))))

(ert-deftest agent-dash-input-test-contexts ()
  (agent-dash-input-test-with-chat
   (dolist (sample '(("/co" slash "co")
                     ("read @src/ma" file "src/ma")
                     ("see @session parser fix" session "parser fix")
                     ("see @dash pi parser" dash "pi parser")
                     ("compare @session earlier and @dash last" dash "last")
                     ("read @\"space na" file "space na")))
     (agent-dash--set-input (car sample))
     (let ((context (agent-dash-input-context)))
       (should (eq (plist-get context :kind) (nth 1 sample)))
       (should (equal (plist-get context :query) (nth 2 sample)))))
   (dolist (text '("hello" "email@example.org now"
                   "see @[a reference](agent-dash:fake:id)"))
     (agent-dash--set-input text)
     (should-not (agent-dash-input-context)))
   (agent-dash-emit session '(:type user :id "u" :text "@dash"))
   (goto-char (point-min))
   (should-not (agent-dash-input-context))))

(ert-deftest agent-dash-input-test-minibuffer-metadata-and-orderless ()
  (let ((before completion-styles))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table _predicate require-match &rest _)
                 (should require-match)
                 (should (eq (completion-metadata-get
                              (completion-metadata "" table nil) 'category)
                             'agent-dash-input))
                 (when (featurep 'orderless)
                   (should (memq 'orderless completion-styles))
                   (should (equal
                            (car (completion-all-completions
                                  "parser pi" table nil (length "parser pi")))
                            "pi — parser")))
                 "pi — parser")))
      (should (equal (agent-dash-input-read
                      "Pick: " '(("pi — parser" . "chosen") ("claude — other" . "other")))
                     "chosen")))
    (should (equal completion-styles before))))

(ert-deftest agent-dash-input-test-slash-markers-and-catalog-cache ()
  (agent-dash-input-test-with-chat
   (let ((reads 0))
     (cl-letf (((symbol-function 'agent-dash-backend-commands)
                (lambda (&rest _) (cl-incf reads) '(("review" . "Review changes"))))
               ((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  ;; Simulate output arriving while the minibuffer is active.
                  (agent-dash-emit session '(:type assistant :id "a" :text "output"))
                  (seq-find (lambda (c) (string-prefix-p "/review " c))
                            (all-completions "" table)))))
       (agent-dash--set-input "/rev later arguments")
       (goto-char (+ agent-dash--input-start 4))
       (agent-dash-tab)
       (should (equal (agent-dash--input) "/review later arguments"))
       (agent-dash-input--commands session)
       (should (= reads 1))
       (agent-dash-input--commands session t)
       (should (= reads 2))))))

(ert-deftest agent-dash-input-test-files-and-cancellation ()
  (agent-dash-input-test-with-chat
   (let ((root (make-temp-file "agent-dash-input-" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "space name.el" root) (insert "fixture"))
           (setf (agent-dash-session-root session) (file-name-as-directory root))
           (should (assoc "space name.el" (agent-dash-input--files root)))
           (agent-dash--set-input "read @sp")
           (cl-letf (((symbol-function 'completing-read)
                      (lambda (&rest _) "space name.el")))
             (agent-dash-tab))
           (should (equal (agent-dash--input) "read @\"space name.el\""))
           (let ((before (agent-dash--input)) canceled)
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (&rest _) (signal 'quit nil))))
               (condition-case nil (agent-dash-tab) (quit (setq canceled t))))
             (should canceled)
             (should (equal before (agent-dash--input)))))
       (delete-directory root t)))))

(ert-deftest agent-dash-input-test-reference-scopes-and-duplicate-labels ()
  (agent-dash-input-test-with-chat
   (puthash 'fake '(:status ok :rows ((:backend fake :id "full-id-one"
                                                :first "same summary" :last "parser"
                                                :root "/tmp/a")
                                      (:backend fake :id "full-id-two"
                                                :first "same summary" :last "parser"
                                                :root "/tmp/a")))
            agent-dash-hub--sources)
   (puthash 'broken '(:status ok :rows ((:backend broken :id "other-agent"
                                                  :first "same summary" :last "parser"
                                                  :root "/tmp/b")))
            agent-dash-hub--sources)
   (agent-dash--set-input "use @session parser")
   (cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt table &rest _)
                (let ((choices (all-completions "" table)))
                  (should (= (length choices) 2))
                  (should-not (equal (car choices) (cadr choices)))
                  (seq-find (lambda (c) (string-search "full-id-two" c)) choices)))))
     (agent-dash-tab))
   (should (string-search "agent-dash:fake:full-id-two" (agent-dash--input)))
   (agent-dash--set-input "use @dash broken parser")
   (cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt table &rest _)
                (let ((choices (all-completions "" table)))
                  (should (= (length choices) 3))
                  (seq-find (lambda (c) (string-prefix-p "broken " c)) choices))))
             ((symbol-function 'agent-dash-backend-transcript)
              (lambda (backend id)
                (should (eq backend 'broken))
                (should (equal id "other-agent"))
                '((user . "question") (assistant . "answer")))))
     (agent-dash-tab)
     (agent-dash-send))
   (should (string-search "Agent: answer" (nth 1 (car agent-dash-fake-calls))))))

(ert-deftest agent-dash-input-test-bare-at-reference-picker ()
  (agent-dash-input-test-with-chat
   (puthash 'fake '(:status ok :rows nil) agent-dash-hub--sources)
   (puthash 'broken '(:status ok :rows ((:backend broken :id "other"
                                                  :first "reference" :root "/tmp/b")))
            agent-dash-hub--sources)
   (agent-dash--set-input "see @")
   (cl-letf (((symbol-function 'agent-dash-input--files) (lambda (_) nil))
             ((symbol-function 'completing-read)
              (lambda (prompt table &rest _)
                (if (equal prompt "Reference: ")
                    "dash — all agents' sessions"
                  (car (all-completions "" table))))))
     (agent-dash-tab))
   (should (equal (agent-dash--input)
                  "see @[reference](agent-dash:broken:other)"))))

(ert-deftest agent-dash-input-test-dsh-skills-use-prompt-endpoint ()
  (let ((session (agent-dash-session-create 'dsh "/tmp")) calls)
    (agent-dash-set-data session :sid "fixture")
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (method args)
                 (push (cons method args) calls)
                 (pcase method
                   ("commands/list" (list (agent-dash-json-read "{\"name\":\"compact\"}")))
                   ("skills/list"
                    (agent-dash-json-read "{\"skills\":[{\"name\":\"review\"}]}"))
                   ("commands/execute"
                    (agent-dash-json-read
                     "{\"result\":{\"kind\":\"success\",\"text\":\"done\"}}"))))))
      (agent-dash-backend-command 'dsh session "/review staged changes" 'steer)
      (should (equal (caar calls) "session/prompt"))
      (should (equal (plist-get (plist-get (cdar calls) :request) :mode) "steer"))
      (agent-dash-backend-command 'dsh session "/compact" 'prompt)
      (should (equal (caar calls) "commands/execute"))
      (should (string-search "done"
                             (plist-get (car (last (agent-dash-session-items session)))
                                        :text))))))

(ert-deftest agent-dash-input-test-changed-draft-is-not-overwritten ()
  (agent-dash-input-test-with-chat
   (agent-dash--set-input "/he")
   (cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt table &rest _)
                (goto-char (point-max))
                (insert " changed")
                (car (all-completions "" table)))))
     (should-error (agent-dash-tab) :type 'user-error))
   (should (equal (agent-dash--input) "/he changed"))))

(ert-deftest agent-dash-input-test-closed-chat-during-picker ()
  (let* ((agent-dash-fake-calls nil)
         (session (agent-dash-open 'fake temporary-file-directory))
         (buffer (agent-dash-session-buffer session)))
    (unwind-protect
        (with-current-buffer buffer
          (agent-dash--set-input "/he")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (let ((choice (car (all-completions "" table))))
                         (with-current-buffer buffer
                           (let ((agent-dash--quitting t)) (kill-buffer)))
                         choice))))
            (should-error (agent-dash-tab) :type 'user-error)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((agent-dash--quitting t)) (kill-buffer)))))))

(ert-deftest agent-dash-input-test-local-command-execution ()
  (agent-dash-input-test-with-chat
   (agent-dash--set-input "/stop")
   (agent-dash-send)
   (should (equal (car agent-dash-fake-calls) '(cancel)))
   (should (equal (agent-dash--input) ""))
   (agent-dash--set-input "/stop ignored args")
   (should-error (agent-dash-send) :type 'user-error)
   (should (equal (agent-dash--input) "/stop ignored args"))
   (agent-dash--set-input "/resume")
   (cl-letf (((symbol-function 'agent-dash-resume)
              (lambda (&rest _) (signal 'quit nil))))
     (condition-case nil (agent-dash-send) (quit nil)))
   (should (equal (agent-dash--input) "/resume"))
   (agent-dash--set-input "/native-command argument")
   (agent-dash-send)
   (should (equal (car agent-dash-fake-calls)
                  '(send "/native-command argument" nil prompt)))))

(ert-deftest agent-dash-input-test-native-catalog-protocols ()
  (let ((pi (agent-dash-session-create 'pi "/tmp"))
        (claude (agent-dash-session-create 'claude "/tmp"))
        (hermes (agent-dash-session-create 'hermes "/tmp"))
        (dsh (agent-dash-session-create 'dsh "/tmp")) requests)
    (cl-letf (((symbol-function 'agent-dash-pi--request)
               (lambda (_session command callback)
                 (push command requests)
                 (funcall callback t
                          (agent-dash-json-read
                           "{\"commands\":[{\"name\":\"review\",\"description\":\"Review\"}]}")
                          nil))))
      (should (assoc "review" (agent-dash-backend-commands 'pi pi)))
      (agent-dash-backend-command 'pi pi "/compact\tfocus on decisions" 'prompt)
      (should (equal (plist-get (car requests) :type) "compact"))
      (should (equal (plist-get (car requests) :customInstructions) "focus on decisions"))
      (agent-dash-backend-command 'pi pi "/compact keep facts\nkeep decisions" 'prompt)
      (should (equal (plist-get (car requests) :customInstructions)
                     "keep facts\nkeep decisions")))
    (agent-dash-claude--record
     claude (agent-dash-json-read
             "{\"type\":\"system\",\"subtype\":\"init\",\"slash_commands\":[\"review\"]}"))
    (should (assoc "review" (agent-dash-backend-commands 'claude claude)))
    (agent-dash-hermes--update
     hermes (agent-dash-json-read
             (concat "{\"sessionUpdate\":\"available_commands_update\","
                     "\"availableCommands\":[{\"name\":\"review\"}]}")))
    (should (assoc "review" (agent-dash-backend-commands 'hermes hermes)))
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (method _args)
                 (if (equal method "commands/list")
                     (list (agent-dash-json-read "{\"name\":\"compact\"}"))
                   (agent-dash-json-read "{\"skills\":[{\"name\":\"review\"}]}")))))
      (should (equal (mapcar #'car (agent-dash-backend-commands 'dsh dsh))
                     '("compact" "review"))))
    (should-not (agent-dash-backend-commands 'codex
                                             (agent-dash-session-create 'codex "/tmp")))))

(provide 'agent-dash-input-test)
;;; agent-dash-input-test.el ends here
