;;; agent-dash-history-test.el --- Native history discovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Temporary fixtures and stubbed protocols only.  Never read real histories.

;;; Code:
(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defun agent-dash-history-test--pi-file (base path id root &optional parent-session)
  "Write a minimal session ID under BASE/PATH with metadata ROOT and PARENT-SESSION."
  (let ((file (expand-file-name path base)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-serialize (append (list :type "session" :id id :cwd root)
                                      (when parent-session
                                        (list :parentSession parent-session)))) "\n")
      (insert (json-serialize (list :type "message" :id "u" :parentId nil
                                    :timestamp "2026-01-01T00:00:00Z"
                                    :message '(:role "user" :content "prompt"))) "\n"))
    file))

(defun agent-dash-history-test--database (file sql)
  "Create fixture FILE with SQL, independently of the read-only production reader."
  (unless (executable-find "sqlite3") (ert-skip "SQLite3 is not installed"))
  (should (zerop (process-file "sqlite3" nil nil nil file sql))))

(ert-deftest agent-dash-history-test-pi-all-layouts-and-root-metadata ()
  (let* ((base (make-temp-file "dash-history-" t))
         (agent-dash-pi-sessions-directory base)
         (agent-dash-history-warnings nil))
    (unwind-protect
        (progn
          (agent-dash-history-test--pi-file base "flat.jsonl" "flat" "/tmp/project")
          (agent-dash-history-test--pi-file base "--old--/date_legacy.jsonl"
                                            "legacy" "/tmp/project")
          (agent-dash-history-test--pi-file base "--old--/parent/child/run-0/date_child.jsonl"
                                            "child" "/tmp/other" "parent")
          (with-temp-file (expand-file-name "broken.jsonl" base) (insert "not JSON\n"))
          (with-temp-file (expand-file-name "events.jsonl" base) (insert "{\"type\":\"event\"}\n"))
          (should (= (length (agent-dash-backend-sessions 'pi nil)) 3))
          (should (= (length agent-dash-history-warnings) 1))
          (should (= (length (agent-dash-backend-sessions 'pi "/tmp/project/")) 2))
          (let ((child (car (agent-dash-backend-sessions 'pi "/tmp/other"))))
            (should (equal (plist-get child :id) "child"))
            (should (plist-get child :subagent))
            (should (equal (agent-dash-summary-skip-reason child) "子代理")))
          (dolist (id '("flat" "legacy" "child"))
            (should (agent-dash-pi--file id))
            (should (equal (agent-dash-backend-transcript 'pi id) '((user . "prompt")))))
          ;; A malformed complete user record cannot discard the valid session.
          (write-region "{\"message\":{\"role\":\"user\"}\n" nil
                        (expand-file-name "flat.jsonl" base) t 'silent)
          (should (= (length (agent-dash-backend-sessions 'pi nil)) 3)))
      (delete-directory base t))))

(ert-deftest agent-dash-history-test-codex-last-prompt-compressed-and-plain ()
  (unless (executable-find "zstd") (ert-skip "zstd is not installed"))
  (let* ((base (make-temp-file "dash-rollout-" t))
         (file (expand-file-name "rollout.jsonl" base))
         (compressed (concat file ".zst"))
         (expected '("latest 用户消息" . "2026-01-02T00:00:00Z")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"payload\":{\"role\":\"user\",\"content\":[{\"text\":\"first\"}]}}\n")
            (insert "{\"timestamp\":\"2026-01-02T00:00:00Z\",\"payload\":{\"role\": \"user\",\"content\":[{\"text\":\"latest 用户消息\"}]}}\n")
            (insert "{\"payload\":{\"role\":\"user\",\"content\":[{\"text\":\"<environment_context>injected\"}]}}\n")
            (insert "{\"payload\":{\"role\":\"assistant\",\"content\":[{\"text\":\"answer\"}]}}\n"))
          (should (equal (agent-dash-codex--last-prompt file) expected))
          (should (eq 0 (call-process "zstd" nil nil nil "-q" file "-o" compressed)))
          ;; Prefer the original when both exist; resolve stale index paths otherwise.
          (should (equal (agent-dash-codex--rollout-file file) file))
          (delete-file file)
          (should (equal (agent-dash-codex--rollout-file file) compressed))
          (should (equal (agent-dash-codex--last-prompt file) expected))
          (should (equal (agent-dash-codex--last-prompt compressed) expected))
          (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
            (let (agent-dash-history-warnings)
              (should-not (agent-dash-codex--last-prompt file))
              (should agent-dash-history-warnings)))
          (should-not (agent-dash-codex--last-prompt nil))
          (should-not (agent-dash-codex--last-prompt (concat base "/missing"))))
      (delete-directory base t))))

(ert-deftest agent-dash-history-test-sqlite-readonly-and-quoting ()
  (let ((file (make-temp-file "dash-history-" nil ".sqlite")))
    (unwind-protect
        (progn
          (agent-dash-history-test--database
           file "CREATE TABLE items(id TEXT); INSERT INTO items VALUES('a''b');")
          (let ((before (with-temp-buffer (insert-file-contents-literally file)
                                          (secure-hash 'sha256 (current-buffer)))))
            (should (= (length (agent-dash-sqlite-rows
                                file (concat "SELECT * FROM items WHERE id="
                                             (agent-dash-sqlite-quote "a'b")))) 1))
            (should-error (agent-dash-sqlite-rows file "DELETE FROM items"))
            (should (equal before (with-temp-buffer
                                    (insert-file-contents-literally file)
                                    (secure-hash 'sha256 (current-buffer)))))))
      (delete-file file))))

(ert-deftest agent-dash-history-test-sqlite-errors-include-original-reason ()
  "A failed query must report SQLite's reason, not just the database path."
  (let ((file (make-temp-file "dash-sqlite-error-" nil ".sqlite")))
    (unwind-protect
        (progn
          (agent-dash-history-test--database file "CREATE TABLE present(id TEXT);")
          (let ((failure (should-error (agent-dash-sqlite-rows file "SELECT * FROM missing"))))
            (should (string-match-p "Cannot read history index" (error-message-string failure)))
            (should (string-match-p "no such table: missing" (error-message-string failure)))))
      (delete-file file))))

(ert-deftest agent-dash-history-test-codex-native-index-includes-metadata-only ()
  (let* ((base (make-temp-file "dash-codex-" t))
         (agent-dash-codex-directory base)
         (new (expand-file-name "state_12.sqlite" base)))
    (unwind-protect
        (progn
          (agent-dash-history-test--database (expand-file-name "state_2.sqlite" base)
                                             "CREATE TABLE irrelevant(id TEXT);")
          (agent-dash-history-test--database
           new (concat "CREATE TABLE threads(id TEXT,cwd TEXT,title TEXT,"
                       "first_user_message TEXT,updated_at INTEGER,archived INTEGER,source TEXT,"
                       "rollout_path TEXT);"
                       "INSERT INTO threads VALUES('old','/tmp/project','title','real prompt',"
                       "1,1,'subAgent','/missing/rollout.jsonl');"))
          (cl-letf (((symbol-function 'agent-dash-holder-oneshot)
                     (lambda (&rest _) (ert-fail "Native index should not start Codex"))))
            (should (equal (agent-dash-codex--index) new))
            (let ((row (car (agent-dash-backend-sessions 'codex nil))))
              (should (equal (plist-get row :first) "real prompt"))
              (should (plist-get row :archived))
              (should (plist-get row :subagent))
              (should (plist-get row :metadata-only)))
            (should (= (length (agent-dash-backend-sessions 'codex "/tmp/project/")) 1))
            (should-not (agent-dash-backend-sessions 'codex "/tmp/x' OR 1=1 --"))))
      (delete-directory base t))))

(ert-deftest agent-dash-history-test-codex-protocol-pagination-and-archives ()
  (let (requests)
    (cl-letf (((symbol-function 'agent-dash-codex--command) (lambda () '("unused")))
              ((symbol-function 'agent-dash-holder-oneshot)
               (lambda (_command calls &rest _)
                 (let ((params (cdr (assoc "thread/list" calls))))
                   (push params requests)
                   (agent-dash-json-read
                    (cond ((eq (plist-get params :archived) t)
                           "{\"data\":[{\"id\":\"archived\"}]}")
                          ((plist-get params :cursor) "{\"data\":[{\"id\":\"second\"}]}")
                          (t "{\"data\":[{\"id\":\"first\"}],\"nextCursor\":\"next\"}")))))))
      (let ((rows (agent-dash-codex--listed-threads nil)))
        (should (= (length rows) 3))
        (should-not (agent-dash-jget (car rows) "archived"))
        (should (agent-dash-jget (car (last rows)) "archived")))
      (should (= (length requests) 3))
      (dolist (params requests)
        (should (member "subAgent" (append (plist-get params :sourceKinds) nil)))
        (should (equal (plist-get params :modelProviders) []))))))

(ert-deftest agent-dash-history-test-hermes-cli-dialogue-and-empty-sessions ()
  (let* ((base (make-temp-file "dash-hermes-" t))
         (agent-dash-hermes-directory base)
         (file (expand-file-name "state.db" base)))
    (unwind-protect
        (progn
          (agent-dash-history-test--database
           file (concat
                 "CREATE TABLE sessions(id TEXT,cwd TEXT,title TEXT,source TEXT,"
                 "model_config TEXT,started_at REAL,archived INTEGER);"
                 "CREATE TABLE messages(session_id TEXT,role TEXT,content TEXT,timestamp REAL,"
                 "active INTEGER,compacted INTEGER,display_kind TEXT,_compressed_summary INTEGER);"
                 "INSERT INTO sessions VALUES('s','/tmp/p','CLI session','cli','{}',1,0);"
                 "INSERT INTO sessions VALUES('empty','/tmp/p',NULL,'subagent','{}',1,1);"
                 "INSERT INTO messages VALUES('s','user','discarded',1,0,0,NULL,0);"
                 "INSERT INTO messages VALUES('s','user','[CONTEXT SUMMARY]: old',2,1,0,NULL,0);"
                 "INSERT INTO messages VALUES('s','user','synthetic summary',2,1,0,NULL,1);"
                 "INSERT INTO messages VALUES('s','user','"
                 "[{\"type\":\"text\",\"text\":\"hello\"}]',"
                 "3,1,0,NULL,0);"
                 "INSERT INTO messages VALUES('s','assistant','reply',4,1,0,'',0);"
                 "INSERT INTO messages VALUES('s','user','last',5,1,0,NULL,0);"))
          (cl-letf (((symbol-function 'agent-dash-holder-oneshot)
                     (lambda (&rest _) (ert-fail "Native history should not start Hermes"))))
            (let* ((rows (agent-dash-backend-sessions 'hermes nil)) (row (car rows)))
              (should (= (length rows) 2))
              (should (equal (plist-get row :first) "hello"))
              (should (equal (plist-get row :last) "last"))
              (should (plist-get (cadr rows) :empty))
              (should (plist-get (cadr rows) :subagent)))
            (should (equal (agent-dash-backend-transcript 'hermes "s")
                           '((user . "hello") (assistant . "reply") (user . "last"))))))
      (delete-directory base t))))

(ert-deftest agent-dash-history-test-dsh-counts-empty-but-does-not-read-it ()
  (let (prompts-read)
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (_method _params)
                 (agent-dash-json-read
                  (concat "{\"items\":[{\"sessionId\":\"empty\",\"cwd\":\"/tmp/p\",\"blank\":true},"
                          "{\"sessionId\":\"chat\",\"cwd\":\"/tmp/p\",\"blank\":false}]}"))))
              ((symbol-function 'agent-dash-dsh--prompts)
               (lambda (id) (push id prompts-read) '("first" "last"))))
      (let* ((rows (agent-dash-backend-sessions 'dsh nil))
             (empty (seq-find (lambda (row) (equal (plist-get row :id) "empty")) rows)))
        (should (= (length rows) 2))
        (should (plist-get empty :empty))
        (should (equal prompts-read '("chat")))))))

(ert-deftest agent-dash-history-test-user-highlight-excludes-leading-separator ()
  (let* ((session (agent-dash-session-create 'fake temporary-file-directory))
         (text (agent-dash--item-body session '(:type user :text "one\ntwo"))))
    (should (equal text "\nYou: one\ntwo\n"))
    (should-not (get-text-property 0 'face text))
    (should (eq (get-text-property 1 'face text) 'agent-dash-user-face))
    (should (eq (get-text-property (1- (length text)) 'face text) 'agent-dash-user-face))))

(ert-deftest agent-dash-history-test-partial-source-keeps-healthy-rows ()
  (let ((agent-dash-hub--sources (make-hash-table))
        (agent-dash-backends '(fake)))
    (cl-letf (((symbol-function 'agent-dash-backend-sessions)
               (lambda (&rest _)
                 (push "bad file" agent-dash-history-warnings)
                 '((:id "healthy" :root "/tmp" :time 1))))
              ((symbol-function 'agent-dash-summary-register) #'ignore)
              ((symbol-function 'agent-dash-history-request) #'agent-dash-fake-history-request))
      (agent-dash-hub--load 'fake)
      (let ((source (gethash 'fake agent-dash-hub--sources)))
        (should (eq (plist-get source :status) 'ok))
        (should (= (length (plist-get source :rows)) 1))
        (should (equal (plist-get source :warnings) '("bad file")))
        (should (string-search "读取警告" (agent-dash-hub--status-line nil)))))))

(ert-deftest agent-dash-history-test-archived-summaries-are-preserved-but-not-scheduled ()
  (cl-letf (((symbol-function 'agent-dash-summary-entry)
             (lambda (_) '(:summary "kept"))))
    (should (equal (agent-dash-summary-skip-reason '(:archived t)) "归档"))
    (should (equal (agent-dash-summary-text '(:archived t)) "kept"))
    (should-not (agent-dash-summary-skip-reason '(:archived nil)))))

(provide 'agent-dash-history-test)
;;; agent-dash-history-test.el ends here
