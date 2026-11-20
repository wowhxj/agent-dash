;;; agent-dash-convert-test.el --- Hub conversion tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise scope selection, native paths and asynchronous converter results.

;;; Code:

(require 'ert)
(require 'agent-dash)

(ert-deftest agent-dash-convert-hub-scopes ()
  (let* ((a '(:backend claude :root "/project" :id "a"))
         (b '(:backend codex :root "/project" :id "b"))
         (c '(:backend claude :root "/elsewhere" :id "c"))
         (rows (list a b c '(:backend pi :root "/project" :id "p"))))
    (cl-letf (((symbol-function 'agent-dash-hub--all) (lambda () rows))
              ((symbol-function 'agent-dash-hub--convert-rows) #'identity))
      (with-temp-buffer
        (insert (propertize "heading" 'agent-dash-project-root "/project") "\n"
                (propertize "session" 'agent-dash-row a))
        (goto-char (point-min))
        (should (equal (agent-dash-hub-convert-project) (list a b)))
        (forward-line)
        (should (equal (agent-dash-hub-convert-session) (list a)))
        (should (equal (agent-dash-hub-convert-project) (list a b)))
        (should (equal (agent-dash-hub-convert-backend 'claude) (list a c)))))
    (should (eq (lookup-key agent-dash-hub-mode-map "v") #'agent-dash-hub-convert-menu))
    (dolist (key-command '(("d" . agent-dash-hub-import-dsh) ("e" . agent-dash-hub-export-dsh)))
      (let ((suffix (transient-get-suffix 'agent-dash-hub-convert-menu (car key-command))))
        (should (memq (cdr key-command) (flatten-tree suffix)))))))

(ert-deftest agent-dash-convert-hub-native-path ()
  (let* ((source (make-temp-file "rollout with space" nil ".jsonl.zst"))
         (row (list :backend 'codex :file source :id "abc" :root "/new/project"))
         (agent-dash-pi-sessions-directory "/pi") (agent-dash-directory "/state"))
    (unwind-protect
        (progn
          (should (equal (agent-dash-hub--convert-command row)
                         (list "node" agent-dash-hub--convert-file "codex" source "abc"
                               "/new/project" "/pi" "/state/conversion-archives")))
          (should (equal (agent-dash-hub--convert-command row 'export)
                         (list "node" agent-dash-hub--dsh-export-file "codex" source "abc"
                               "/new/project" "/pi" "/state/conversion-archives")))
          (should-error (agent-dash-hub--convert-command (plist-put (copy-sequence row) :file nil))
                        :type 'user-error)
          (should-error
           (agent-dash-hub--convert-command (plist-put (copy-sequence row) :backend 'pi))
           :type 'user-error))
      (delete-file source))))

(ert-deftest agent-dash-convert-hub-continues-after-error ()
  (let ((deadline (+ (float-time) 10)) refreshed report)
    (cl-letf (((symbol-function 'agent-dash-hub--convert-command)
               (lambda (row &optional _dsh-export)
                 (list "node" "-e"
                       (pcase (plist-get row :key)
                         ('bad "console.error('bad source'); process.exit(1)")
                         ('retained
                          (concat "console.log(JSON.stringify({id:'dest',file:'/pi',"
                                  "archive:'/archive',migration:'retained',"
                                  "migrationError:'source changed'}))"))
                         (_ (concat "console.log(JSON.stringify({id:'dest',file:'/pi',"
                                    "archive:'/archive',warnings:['omitted'],"
                                    "notes:['mode (2)']}))"))))))
              ((symbol-function 'agent-dash-hub--load)
               (lambda (backend &optional callback)
                 (push backend refreshed)
                 (when callback (funcall callback nil))))
              ((symbol-function 'display-buffer) #'ignore))
      (unwind-protect
          (progn
            (setq report (agent-dash-hub--convert-rows '((:key bad) (:key retained) (:key good))))
            (while (and (not refreshed) (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (should (equal refreshed '(pi)))
            (with-current-buffer report
              (dolist (text '("✗ bad" "bad source" "⚠ retained" "Claude 原件保留：source changed"
                              "✓ good" "dest" "/archive" "⚠ omitted"
                              "仅归档：1 类记录" "mode (2)"
                              "完成 · 成功 2，失败 1，成功项中源保留 2，有警示 2 条"))
                (should (string-search text (buffer-string))))))
        (when report (kill-buffer report))))))

(ert-deftest agent-dash-convert-report-toggle-and-legacy ()
  (with-temp-buffer
    (insert "转换到 Pi · 2 条\n\n✓ claude:source-full-123  target-full-456  /tmp/pi\n"
            "  归档 /tmp/archive\n  Claude 原件已迁出\n"
            "  ⚠ archived Claude last-prompt record (90)\n"
            "  ⚠ Claude attachment image is available only in the original archive (2)\n"
            "  ⚠ archived orphan tool result (5)\n"
            "  ⚠ archived inactive Claude branch (1079)\n"
            "  仅归档：1 类记录（查看明细）\n✗ codex:s2  bad source\n")
    (agent-dash-hub-compact-report)
    (should buffer-read-only)
    (should (looking-at-p ".*完成 · 成功 1，失败 1，成功项中源保留 0，有警示 1 条"))
    (search-forward "✓ claude:source-f… → pi:target-f…  已迁出")
    (should (looking-at-p " · 当前上下文外1079条记录仅归档、部分工具记录仅归档$"))
    (let ((row (point)) (detail (progn (search-forward "/tmp/archive") (1- (point)))))
      (should (invisible-p detail))
      (goto-char row)
      (call-interactively (key-binding (kbd "RET")))
      (should-not (invisible-p detail))
      (goto-char detail)
      (call-interactively (key-binding (kbd "TAB")))
      (should (invisible-p detail))
      (should (looking-at-p "✓"))
      (let ((original (buffer-string)))
        (agent-dash-hub-compact-report)
        (should (equal original (buffer-string))))
      (search-forward "失败 · bad source")
      (should-not (invisible-p (1- (point)))))))

(ert-deftest agent-dash-convert-report-rejects-incomplete-legacy ()
  (with-temp-buffer
    (insert "转换到 Pi · 2 条\n\n✗ claude:s  error\n")
    (let ((old (buffer-string)))
      (should-error (agent-dash-hub-compact-report) :type 'user-error)
      (should (equal old (buffer-string))))))

(ert-deftest agent-dash-convert-report-warnings ()
  (dolist (pair '(("archived Claude message outside the final parentUuid chain (source contains compact_boundary) (3)"
                   . "当前上下文外3条记录仅归档（含压缩前历史或其他分支）")
                  ("Claude attachment file is available only in the original archive (1)" . "部分附件仅归档")
                  ("Source tool calls and results rendered as historical text" . "工具记录转为文本")))
    (should (equal (agent-dash-hub--report-warning (car pair)) (cdr pair)))))

(ert-deftest agent-dash-convert-hub-exports-dsh-package ()
  (let ((row '(:key "claude:a" :backend claude)) loaded report)
    (cl-letf (((symbol-function 'agent-dash-hub--row-at-point) (lambda () row))
              ((symbol-function 'agent-dash-hub--convert-one)
               (lambda (source done dsh-export)
                 (should (equal row source))
                 (should (eq dsh-export 'export))
                 (funcall done t "/exports/conversation.zip")))
              ((symbol-function 'agent-dash-hub--load) (lambda (backend) (push backend loaded)))
              ((symbol-function 'run-at-time) (lambda (_time _repeat callback) (funcall callback)))
              ((symbol-function 'display-buffer) #'ignore))
      (unwind-protect
          (progn
            (setq report (agent-dash-hub-export-dsh))
            (with-current-buffer report
              (dolist (text '("DeepSeek 网站" "工作区" "/exports/conversation.zip"))
                (should (string-search text (buffer-string)))))
            (should-not loaded))
        (when report (kill-buffer report))))))

(ert-deftest agent-dash-convert-dsh-passes-current-login-on-stdin ()
  (let* ((agent-dash-dsh--host '(:base "http://127.0.0.1:42/" :cookie "expired"))
         (deadline (+ (float-time) 10)) result)
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (method _args)
                 (should (equal method "deepseekChatImport/limits"))
                 (setq agent-dash-dsh--host (plist-put (copy-sequence agent-dash-dsh--host)
                                                       :cookie "test-cookie"))))
              ((symbol-function 'agent-dash-hub--convert-command)
               (lambda (_row mode)
                 (should (eq mode 'dsh))
                 (list "node" "-e"
                       (concat "const h=JSON.parse(require('node:fs').readFileSync(0,'utf8'));"
                               "if(h.base!=='http://127.0.0.1:42/' || "
                               "h.cookie!=='test-cookie') process.exit(1);"
                               "console.log(JSON.stringify({id:'native-id',"
                               "file:'/exports/zip-id.zip',archive:'/archive',"
                               "migration:'retained',migrationError:'source changed'}));")))))
      (agent-dash-hub--convert-one '(:backend claude) (lambda (&rest args) (setq result args)) 'dsh)
      (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.05))
      (should (equal (car result) "retained"))
      (should (equal (nth 2 result) "native-id"))
      (dolist (text '("DSH 会话 native-id" "导入包 /exports/zip-id.zip" "Claude 原件保留：source changed"))
        (should (string-search text (cadr result)))))))

(ert-deftest agent-dash-convert-hub-imports-native-claude ()
  (let* ((dir (file-truename (make-temp-file "agent-dash-import-" t)))
         (agent-dash-claude-config-directory dir)
         (agent-dash-pi-sessions-directory (expand-file-name "pi" dir))
         (agent-dash-directory (expand-file-name "state" dir))
         (id "00000000-0000-4000-8000-000000000001")
         (source (expand-file-name (format "projects/-tmp-demo/%s.jsonl" id) dir))
         (deadline (+ (float-time) 10))
         (original-env (getenv "CLAUDE_CONFIG_DIR")) done result)
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "{\"type\":\"user\",\"sessionId\":\"" id "\",\"cwd\":\"/tmp/demo\","
                    "\"timestamp\":\"2026-01-01T00:00:00Z\","
                    "\"message\":{\"content\":\"hello\"}}\n"))
          (agent-dash-hub--convert-one
           (agent-dash-hub--row 'claude (car (agent-dash-backend-sessions 'claude nil)))
           (lambda (ok details &optional id) (setq result (list ok details id) done t)))
          (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.05))
          (should (equal (getenv "CLAUDE_CONFIG_DIR") original-env))
          (should (equal (car result) "moved"))
          (should-not (file-exists-p source))
          (should-not (agent-dash-backend-sessions 'claude nil))
          (let ((session (car (agent-dash-backend-sessions 'pi "/tmp/demo"))))
            (should (equal "hello" (plist-get session :first)))
            (should (equal (plist-get session :id) (nth 2 result)))
            (should (string-search (plist-get session :file) (nth 1 result)))))
      (delete-directory dir t))))

(ert-deftest agent-dash-convert-hub-keeps-claude-for-retry ()
  (let* ((dir (make-temp-file "agent-dash-retry-" t))
         (agent-dash-directory dir) (agent-dash-backends '(claude codex pi))
         (agent-dash-hub--sources (make-hash-table))
         (source (expand-file-name "source.jsonl" dir))
         (file (expand-file-name "pi.jsonl" dir))
         (archive (expand-file-name "conversion-archives/codex-dest.jsonl" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory archive))
          (dolist (f (list source file archive)) (with-temp-file f (insert "synthetic")))
          (copy-file archive (expand-file-name "claude-dest.jsonl" (file-name-directory archive)))
          (dolist (backend '(claude codex))
            (let* ((native (agent-dash-hub--row backend (list :id "source" :file source)))
                   (pi-row (agent-dash-hub--row
                            'pi (list :id "dest" :file file :import-source
                                      (list :id "source" :backend (symbol-name backend)
                                            :sha256 (secure-hash 'sha256 "synthetic"))))))
              (puthash backend (list :rows (list native)) agent-dash-hub--sources)
              (puthash 'pi (list :rows (list pi-row)) agent-dash-hub--sources)
              (if (eq backend 'claude)
                  (should (member native (agent-dash-hub--all)))
                (should-not (member native (agent-dash-hub--all)))
                (write-region "continued" nil file t 'silent)
                (should-not (member native (agent-dash-hub--all)))
                (write-region "changed" nil source t 'silent)
                (should (member native (agent-dash-hub--all)))
                (copy-file archive source t)
                (with-temp-file archive (insert "modified!"))
                (should (member native (agent-dash-hub--all)))
                (copy-file source archive t)
                (should-not (member native (agent-dash-hub--all)))
                (delete-file file)
                (should (member native (agent-dash-hub--all)))))))
      (delete-directory dir t))))

(ert-deftest agent-dash-convert-claude-live-and-dsh ()
  (let* ((source (make-temp-file "agent-dash-claude-"))
         (row (list :backend 'claude :id "synthetic" :file source :root "/project"))
         open holder)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-hub--chat) (lambda (&rest _) open))
                  ((symbol-function 'agent-dash-holder-alive-p) (lambda (_) holder)))
          (should (equal (nthcdr 8 (agent-dash-hub--convert-command row)) '("--migrate-claude")))
          (dolist (state '(running open holder))
            (setq open (eq state 'open) holder (eq state 'holder)
                  row (plist-put row :running (eq state 'running)))
            (should-error (agent-dash-hub--convert-command row) :type 'user-error)
            (should-error (agent-dash-hub--convert-command row 'dsh) :type 'user-error)
            (should-not (nthcdr 8 (agent-dash-hub--convert-command row 'export)))))
      (delete-file source))))

(ert-deftest agent-dash-convert-pi-reads-only-second-record-for-provenance ()
  (let* ((file (make-temp-file "agent-dash-pi-record-" nil ".jsonl"))
         (digest (make-string 64 ?e))
         (header "{\"type\":\"session\",\"id\":\"target\"}\n")
         (record (json-serialize `(:type "custom" :customType "agent-dash-import"
                                         :data (:backend "codex" :sourceId "source"
                                                         :sha256 ,digest
                                                         :notes ,(make-string 270000 ?a))))))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-holder-alive-p) #'ignore))
          (with-temp-file file (insert header record "\n"))
          (should (equal (plist-get (agent-dash-pi--session-info file) :import-source)
                         (list :backend "codex" :id "source" :sha256 digest)))
          (with-temp-file file (insert header "{}\n" record "\n"))
          (should-not (plist-get (agent-dash-pi--session-info file) :import-source)))
      (delete-file file))))

(ert-deftest agent-dash-convert-hub-follows-selection-without-stealing-focus ()
  (dolist (case '(selected moved batch dsh retained))
    (with-temp-buffer
      (agent-dash-hub-mode)
      (let* ((a '(:key "claude:a" :id "a" :backend claude :first "first"))
             (b '(:key "claude:b" :id "b" :backend claude :first "second"))
             (dsh (memq case '(dsh retained)))
             (backend (if dsh 'dsh 'pi))
             (target-key (format "%s:p" backend))
             (p (list :key target-key :id "p" :backend backend :first "first"))
             (agent-dash-backends '(dsh pi claude))
             (agent-dash-hub--agent 'claude)
             (agent-dash-summary--loaded t)
             (agent-dash-summary--cache (make-hash-table :test #'equal))
             (agent-dash-history--jobs (make-hash-table :test #'equal))
             imported complete report loaded)
        (cl-letf (((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'agent-dash-hub--all)
                   (lambda (&optional _replacements)
                     (if imported
                         (if (eq case 'retained) (list a b p) (list b p))
                       (list a b))))
                  ((symbol-function 'agent-dash-hub--convert-one)
                   (lambda (_row callback &optional _dsh-export) (setq complete callback)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat callback) (funcall callback)))
                  ((symbol-function 'agent-dash-hub--load)
                   (lambda (backend &optional callback)
                     (push backend loaded)
                     (setq imported t)
                     (when callback (funcall callback '(:ok t)))
                     (agent-dash-hub--render))))
          (unwind-protect
              (progn
                (agent-dash-hub--render)
                (agent-dash-hub--goto "claude:a")
                (puthash "claude:a" t agent-dash-hub--marks)
                (when (or dsh (eq case 'selected)) (agent-dash-hub-toggle-selection))
                (setq report (cond (dsh (agent-dash-hub-import-dsh))
                                   ((eq case 'batch) (agent-dash-hub--convert-rows (list a b)))
                                   (t (agent-dash-hub-convert-session))))
                (when (eq case 'moved) (agent-dash-hub--goto "claude:b"))
                (funcall complete (if (eq case 'retained) "retained" "moved") "done" "p")
                (when (eq case 'batch) (funcall complete nil "failed"))
                (should (equal loaded (list 'claude backend)))
                (should (eq (gethash "claude:a" agent-dash-hub--marks) (eq case 'retained)))
                (if (or dsh (eq case 'selected))
                    (progn (should (eq agent-dash-hub--agent backend))
                           (should (gethash target-key agent-dash-hub--selected))
                           (should (equal (get-text-property (point) 'agent-dash-key) target-key)))
                  (should (eq agent-dash-hub--agent 'claude))
                  (should (equal (get-text-property (point) 'agent-dash-key) "claude:b"))))
            (when report (kill-buffer report))))))))

(provide 'agent-dash-convert-test)
;;; agent-dash-convert-test.el ends here
