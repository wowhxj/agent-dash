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
          (agent-dash-hub--lifecycle-pending (make-hash-table))
          (agent-dash-hub--lifecycle-timer nil)
          (agent-dash-summary--cache (make-hash-table :test #'equal))
          (agent-dash-fake-calls nil)
          (session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect (progn ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))
         (when (timerp agent-dash-hub--lifecycle-timer)
           (cancel-timer agent-dash-hub--lifecycle-timer))))))

(ert-deftest agent-dash-input-test-contexts ()
  (agent-dash-input-test-with-chat
   (dolist (sample '(("/co" slash "co")
                     ("read @src/ma" file "src/ma")
                     ("see @session parser fix" session "parser fix")
                     ("see @session pi parser" session "pi parser")
                     ("compare @session earlier and @session last" session "last")
                     ("read @dash" file "dash")
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

(ert-deftest agent-dash-input-test-explicit-file-paths ()
  (agent-dash-input-test-with-chat
   (let ((insert-default-directory t)
         (read-file-name-function nil)
         (use-dialog-box nil))
     (dolist (query '("/" "~/" "~/org/no" "/tmp/no" "../notes/no" "./notes/no"))
       (agent-dash--set-input (concat "read @" query))
       (cl-letf (((symbol-function 'agent-dash-input--files)
                  (lambda (_) (ert-fail "Explicit paths must not scan project files")))
                 ((symbol-function 'completing-read)
                  (lambda (prompt table _predicate mustmatch initial &rest _)
                    (should (equal prompt "Reference: "))
                    (should (eq table #'read-file-name-internal))
                    (should (equal default-directory (agent-dash-session-root session)))
                    (should mustmatch)
                    (with-temp-buffer
                      (insert (if (consp initial) (car initial) initial))
                      (goto-char (+ (point-min) (if (consp initial)
                                                    (cdr initial) (length initial))))
                      (run-hooks 'minibuffer-setup-hook)
                      (should (equal (buffer-string) query))
                      (should (= (point) (point-max)))
                      (when (equal query "/")
                        (let* ((completion-styles '(basic partial-completion))
                               (candidates (completion-all-completions
                                            query table nil (- (point) (point-min))))
                               (names (cl-loop for tail = candidates then (cdr tail)
                                               while (consp tail) collect (car tail))))
                          (should (equal (sort names #'string-lessp)
                                         (sort (file-name-all-completions "" "/")
                                               #'string-lessp))))))
                    "~/org/space name.org")))
         (agent-dash-tab))
       (should (equal (agent-dash--input) "read @\"~/org/space name.org\""))))
   (agent-dash--set-input "read @~/org/")
   (cl-letf (((symbol-function 'read-file-name)
              (lambda (&rest _) (signal 'quit nil))))
     (should (eq (condition-case nil (agent-dash-tab) (quit 'canceled)) 'canceled)))
   (should (equal (agent-dash--input) "read @~/org/"))))

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
                  (should (= (length choices) 3))
                  (should-not (equal (car choices) (cadr choices)))
                  (seq-find (lambda (c) (string-search "full-id-two" c)) choices)))))
     (agent-dash-tab))
   (should (string-search "agent-dash:fake:full-id-two" (agent-dash--input)))
   (agent-dash--set-input "use @session broken parser")
   (cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt table &rest _)
                (let ((choices (all-completions "" table)))
                  (should (= (length choices) 3))
                  (seq-find (lambda (c) (string-search "other-agent" c)) choices))))
             ((symbol-function 'agent-dash-backend-transcript)
              (lambda (backend id)
                (should (eq backend 'broken))
                (should (equal id "other-agent"))
                '((user . "question") (assistant . "answer")))))
     (agent-dash-tab)
     (agent-dash-send))
   (should (string-search "Agent: answer" (nth 1 (car agent-dash-fake-calls))))))

(ert-deftest agent-dash-input-test-reference-columns-and-search ()
  (agent-dash-input-test-with-chat
   (let* ((id "shared-prefix-00000001")
          (root "/tmp/很长的中文项目目录/full-project-path")
          (summary (concat (make-string 100 ?中) " tail-summary-token")))
     (puthash 'fake (list :status 'ok :rows
                          (list (list :backend 'fake :id id :root root
                                      :first summary :last "用户末句" :time 2000 :exact t)
                                (list :backend 'fake :id "shared-prefix-00000002"
                                      :root "/tmp/a" :first "短摘要" :time 1000)))
              agent-dash-hub--sources)
     (puthash 'broken '(:status ok :rows
                                ((:backend broken :id "other-agent-id" :root "/tmp/项目"
                                           :first "English summary" :last "last line" :time 1500)))
              agent-dash-hub--sources)
     (dolist (width '(60 80 120 200))
       (dolist (backend '(nil fake))
         (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) width))
                   ((symbol-function 'completing-read)
                    (lambda (_prompt table &rest _)
                      (let ((candidates (all-completions "" table)) columns)
                        (should (= (length candidates) (if backend 2 3)))
                        (dolist (candidate candidates)
                          (let* ((end (next-single-property-change
                                       0 'display candidate (length candidate)))
                                 (visible (substring candidate 0 end))
                                 (start 0) positions)
                            (should (<= (string-width visible) (- width 4)))
                            (should-not (string-match-p "[\n\t]" visible))
                            (while (string-match " │ " visible start)
                              (push (string-width (substring visible 0 (match-beginning 0)))
                                    positions)
                              (setq start (match-end 0)))
                            (should (= (length positions) 2))
                            (push positions columns)))
                        (should (seq-every-p
                                 (lambda (positions) (equal positions (car columns))) columns)))
                      (dolist (query (list id root "tail-summary-token"))
                        (let ((matches (completion-all-completions query table nil (length query))))
                          (should (string-search id (car matches)))
                          (should-not (consp (cdr matches)))))
                      (substring-no-properties
                       (seq-find (lambda (candidate) (string-search id candidate))
                                 (all-completions "" table))))))
           (should (string-search (concat "agent-dash:fake:" id)
                                  (agent-dash-hub-read-reference backend)))))))))

(ert-deftest agent-dash-input-test-reference-uses-hub-default-visibility ()
  "References exclude Hub-hidden rows, not rows merely missing metadata."
  (agent-dash-input-test-with-chat
   (let ((agent-dash-summary--loaded t)
         (rows '((:backend fake :id "normal" :first "first" :last "last" :time 5)
                 (:backend fake :id "blank" :empty t :time 6)
                 (:backend fake :id "child" :subagent t :time 7)
                 (:backend fake :id "archive" :archived t :first "old" :time 8)
                 (:backend fake :id "no-dialogue" :time 9)
                 (:backend fake :id "cached" :empty t :last "cached last" :time 4)
                 (:backend fake :id "title-only" :title "Saved title" :time 3))))
     (puthash 'fake (list :status 'ok :rows rows) agent-dash-hub--sources)
     (puthash 'broken '(:status ok :rows nil) agent-dash-hub--sources)
     (puthash "fake:no-dialogue" '(:no-dialogue t) agent-dash-summary--cache)
     (puthash "fake:cached" '(:summary "Cached summary") agent-dash-summary--cache)
     (let ((expected (agent-dash-hub--visible))
           (agent-dash-hub--agent 'broken)
           (agent-dash-hub--project "unrelated")
           (agent-dash-hub--live-only t)
           (agent-dash-hub--show-hidden t))
       (cl-letf (((symbol-function 'agent-dash-input-read)
                  (lambda (_prompt choices &optional _query)
                    (should (equal (mapcar #'cdr choices) expected))
                    (should (equal (mapcar (lambda (row) (plist-get row :id)) expected)
                                   '("normal" "cached" "title-only")))
                    (should (string-search "Cached summary" (car (nth 1 choices))))
                    (should (string-search "[标题] Saved title" (car (nth 2 choices))))
                    (cdar choices)))
                 ((symbol-function 'agent-dash-backend-transcript)
                  (lambda (&rest _) (ert-fail "Reference inventory must not read transcripts"))))
         (should (string-search "agent-dash:fake:normal" (agent-dash-hub-read-reference))))))))

(ert-deftest agent-dash-input-test-reference-live-markers-and-all-columns ()
  "All columns remain visible; both attached and background sessions have green dots."
  (agent-dash-input-test-with-chat
   (agent-dash-set-data session :sid "ATTACHED1")
   (let ((agent-dash-summary--loaded t)
         (rows '((:backend fake :id "ATTACHED1" :root "/tmp/P" :first "S" :last "L" :time 1)
                 (:backend broken :id "RUNNING2" :running t :root "/tmp/P"
                           :first "S" :last "L" :time 1)
                 (:backend fake :id "OFFLINE3" :root "/tmp/P" :first "S" :last "L" :time 1))))
     (dolist (width '(40 60 80 120 200))
       (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) width)))
         (dolist (choice (agent-dash-hub--reference-choices rows))
           (let* ((candidate (car choice))
                  (visible (substring candidate 0 (next-single-property-change
                                                   0 'display candidate (length candidate))))
                  (row (cdr choice))
                  (dot (string-search "●" visible)))
             (should (<= (string-width visible) (- width 4)))
             (should (string-search (substring (plist-get row :id) 0 3) visible))
             (should (string-match-p " │ S.* │ L" visible))
             (should (string-search "P" visible))
             (should (string-search "1970" visible))
             (if (agent-dash-hub-live-p row)
                 (progn (should dot) (should (eq (get-text-property dot 'face visible) 'success)))
               (should-not dot)))))))))

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
                    "session — all agents' sessions"
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
