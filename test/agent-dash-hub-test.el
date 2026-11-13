;;; agent-dash-hub-test.el --- Hub, summary and search tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: the fake backend provides saved sessions and transcripts,
;; and gptel requests are stubbed.  The summary cache is a temp file.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defvar gptel-model 'test-model "Stand-in until gptel is loaded.")
(defvar gptel-backend nil "Stand-in until gptel is loaded.")

(defconst agent-dash-hub-test-alpha (expand-file-name "ad-alpha" temporary-file-directory))
(defconst agent-dash-hub-test-beta (expand-file-name "ad-beta" temporary-file-directory))

(cl-defmethod agent-dash-backend-sessions ((_ (eql broken)) _root)
  "A source whose listing always fails."
  (error "Source unavailable"))

(defun agent-dash-hub-test-saved ()
  "Return the fake saved sessions: two projects, one empty, one running."
  (let ((now (float-time)))
    (list (list :id "s1-aaaaaaaa" :root agent-dash-hub-test-alpha :time (- now 7200) :exact t
                :first "fix the parser" :last "commit and push")
          (list :id "s2-bbbbbbbb" :root agent-dash-hub-test-beta :time (- now 3600)
                :first "write docs" :running t)
          (list :id "s3-cccccccc" :root agent-dash-hub-test-alpha :time (- now 60) :empty t)
          (list :id "s4-dddddddd" :root agent-dash-hub-test-alpha :time (- now 7300)
                :first "child task" :subagent t))))

(defmacro agent-dash-hub-test-with-hub (&rest body)
  "Run BODY in a fresh hub over the fake backend and a broken source."
  (declare (indent 0))
  `(let* ((agent-dash-backends '(fake broken))
          (agent-dash-fake-calls nil)
          (agent-dash-fake-saved (agent-dash-hub-test-saved))
          (agent-dash-hub--sources (make-hash-table))
          (agent-dash-summary-cache-file (make-temp-file "agent-dash-summaries"))
          (agent-dash-summary--cache (make-hash-table :test #'equal))
          (agent-dash-summary--sessions (make-hash-table :test #'equal))
          (agent-dash-summary--loaded t))
     (make-directory agent-dash-hub-test-alpha t)
     (make-directory agent-dash-hub-test-beta t)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 200)))
             (agent-dash-hub)
             (agent-dash-test-wait
              (lambda () (not (seq-some (lambda (b) (eq (plist-get (gethash b agent-dash-hub--sources)
                                                                   :status)
                                                        'loading))
                                        agent-dash-backends))))
             (with-current-buffer "*agent-dash hub*" ,@body))
         (kill-buffer "*agent-dash hub*")
         (delete-directory agent-dash-hub-test-alpha)
         (delete-directory agent-dash-hub-test-beta)
         (delete-file agent-dash-summary-cache-file)))))

(defun agent-dash-hub-test-lines ()
  "Return the hub lines after the column header, trimmed."
  (save-excursion
    (goto-char (point-min))
    (forward-line 4)
    (mapcar #'string-trim-right
            (split-string (buffer-substring-no-properties (point) (point-max)) "\n" t))))

(defun agent-dash-hub-test-ids ()
  "Return the ids of the listed rows, top to bottom."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((row (get-text-property (point) 'agent-dash-row)))
          (push (plist-get row :id) ids))
        (forward-line 1)))
    (nreverse ids)))

(ert-deftest agent-dash-hub-test-groups-columns-and-errors ()
  (agent-dash-hub-test-with-hub
   ;; Newest group first; the empty session is hidden by default.
   (should (equal (agent-dash-hub-test-ids) '("s2-bbbbbbbb" "s1-aaaaaaaa")))
   (let ((lines (agent-dash-hub-test-lines)))
     (should (string-match-p "\\`broken 无法加载：Source unavailable" (nth 0 lines)))
     (should (string-prefix-p (format "− %s (1)" (abbreviate-file-name agent-dash-hub-test-beta))
                              (nth 1 lines)))
     (should (string-match-p "fake +●.*s2-bbbbb.*write docs.*\\[末句未知\\].*未启用" (nth 2 lines)))
     (should (string-prefix-p (format "− %s (1)" (abbreviate-file-name agent-dash-hub-test-alpha))
                              (nth 3 lines)))
     ;; An exact message time has no `*'; the summary column falls back to
     ;; the first prompt.
     (should (string-match-p "fake +[0-9-]+ [0-9:]+ +s1-aaaaa.*fix the parser.*commit and push" (nth 4 lines))))
   (should (string-match-p "来源失败：broken" agent-dash-hub--status))
   (agent-dash-hub-toggle-hidden)
   ;; The alpha group now holds the newest session, so it comes first.
   (should (equal (agent-dash-hub-test-ids)
                  '("s3-cccccccc" "s1-aaaaaaaa" "s4-dddddddd" "s2-bbbbbbbb")))
   (should (string-match-p "\\[空会话\\]" (buffer-string)))
   (should (string-match-p "\\[子代理\\]" (buffer-string)))))

(ert-deftest agent-dash-hub-test-filters-and-ordering ()
  (agent-dash-hub-test-with-hub
   (agent-dash-hub-toggle-live)
   (should (equal (agent-dash-hub-test-ids) '("s2-bbbbbbbb")))
   (agent-dash-hub-toggle-live)
   (setq agent-dash-hub--project "ad-alpha")
   (agent-dash-hub--render)
   (should (equal (agent-dash-hub-test-ids) '("s1-aaaaaaaa")))
   (agent-dash-hub-clear-filters)
   (agent-dash-hub-filter-agent-to 'broken)
   (should-not (agent-dash-hub-test-ids))
   (agent-dash-hub-filter-all-agents)
   (agent-dash-hub-sort-by-time)
   (should-not (string-match-p "^− " (buffer-string)))
   (agent-dash-hub-sort-by-time)
   (agent-dash-hub--goto (list 'group (abbreviate-file-name agent-dash-hub-test-beta)))
   (agent-dash-hub-toggle-group)
   (should (equal (agent-dash-hub-test-ids) '("s1-aaaaaaaa")))
   (should (string-search (format "+ %s (1)" (abbreviate-file-name agent-dash-hub-test-beta))
                          (buffer-string)))))

(ert-deftest agent-dash-hub-test-open-resumes-then-switches ()
  (agent-dash-hub-test-with-hub
   (agent-dash-hub--goto "fake:s2-bbbbbbbb")
   (agent-dash-hub-open)
   (let ((session (car agent-dash--sessions)))
     (should (equal (car agent-dash-fake-calls)
                    (list 'start (agent-dash-session-id session) "s2-bbbbbbbb")))
     (agent-dash-set-data session :sid "s2-bbbbbbbb")
     (with-current-buffer "*agent-dash hub*"
       (agent-dash-hub--goto "fake:s2-bbbbbbbb")
       (agent-dash-hub-open))
     (should (= 1 (seq-count (lambda (c) (eq (car c) 'start)) agent-dash-fake-calls)))
     (should (eq (current-buffer) (agent-dash-session-buffer session)))
     (let ((agent-dash--quitting t)) (kill-buffer (agent-dash-session-buffer session))))))

(ert-deftest agent-dash-hub-test-delete-marks-and-confirms ()
  (agent-dash-hub-test-with-hub
   (agent-dash-hub--goto "fake:s2-bbbbbbbb")
   (should-error (agent-dash-hub-mark-delete) :type 'user-error)
   (agent-dash-hub--goto "fake:s1-aaaaaaaa")
   (agent-dash-hub-mark-delete)
   (should (string-match-p "^  D fake" (buffer-string)))
   (cl-letf (((symbol-function 'yes-or-no-p) #'always))
     (agent-dash-hub-execute-deletions))
   (should (equal (car agent-dash-fake-calls) '(delete "s1-aaaaaaaa")))
   (should (equal (agent-dash-hub-test-ids) '("s2-bbbbbbbb")))))

(ert-deftest agent-dash-hub-test-short-ids ()
  (let ((short (agent-dash-hub--short-ids
                (mapcar (lambda (id) (list :id id))
                        '("a42bb220-1111" "a42bb229-2222" "7389aaaa-3333"
                          "session-a3f0aa" "session-b100aa" "x1")))))
    (should (equal (gethash "a42bb220-1111" short) "a42bb220"))
    (should (equal (gethash "7389aaaa-3333" short) "7389aaaa"))
    (should (equal (gethash "session-a3f0aa" short) "session-a"))
    (should (equal (gethash "x1" short) "x1"))))

(ert-deftest agent-dash-hub-test-relocation ()
  (let ((agent-dash-hub-project-relocations '(("/old/proj" . "/new/proj"))))
    (should (equal (agent-dash-hub--relocate "/old/proj") "/new/proj"))
    (should (equal (agent-dash-hub--relocate "/old/proj/sub/") "/new/proj/sub"))
    (should (equal (agent-dash-hub--relocate "/old/project") "/old/project"))
    (should (plist-get (agent-dash-hub--row 'fake '(:id "x" :root "/old/proj")) :missing))))

(ert-deftest agent-dash-hub-test-new-session-and-details ()
  (agent-dash-hub-test-with-hub
   (agent-dash-hub--goto "fake:s1-aaaaaaaa")
   (agent-dash-hub-details)
   (with-current-buffer "*agent-dash details*"
     (let ((text (buffer-string)))
       (should (string-prefix-p "FAKE · s1-aaaaa" text))
       (should (string-match-p "▸ 详细信息（m 展开）" text))
       (should-not (string-match-p "First user message" text))
       ;; User bubble on the right, agent bubble on the left; each has a copy button.
       (should (string-match-p "^ \\{20,\\}  用户  复制" text))
       (should (string-match-p "^ \\{20,\\}  question of s1-aaaaaaaa" text))
       (should (string-match-p "^    FAKE  复制" text))
       (should (string-match-p "^    answer" text)))
     (agent-dash-hub-details-toggle-metadata)
     (should (string-match-p "First user message:\nfix the parser" (buffer-string)))
     (agent-dash-hub-details-copy)
     (should (equal (current-kill 0) "User: question of s1-aaaaaaaa\n\nAssistant: answer"))
     (kill-buffer))
   (with-current-buffer "*agent-dash hub*"
     (cl-letf (((symbol-function 'read-directory-name)
                (lambda (&rest _) temporary-file-directory)))
       (agent-dash-hub--new 'fake)))
   (should (eq (car (car agent-dash-fake-calls)) 'start))
   (let ((agent-dash--quitting t)) (kill-buffer (agent-dash-session-buffer (car agent-dash--sessions))))))

(ert-deftest agent-dash-hub-test-summary-job-and-status ()
  (agent-dash-hub-test-with-hub
   (let* ((row (seq-find (lambda (r) (equal (plist-get r :id) "s1-aaaaaaaa")) (agent-dash-hub--all)))
          (sent nil)
          (agent-dash-summary-mode t))
     (should (equal (agent-dash-summary-status row) "待生成"))
     (should (equal (plist-get (agent-dash-summary--candidate) :id) "s1-aaaaaaaa"))
     (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
               ((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (setq sent prompt)
                  (funcall (plist-get args :callback) "修复解析器并已推送。" nil))))
       (agent-dash-summary--start row))
     (should (string-match-p "User: question of s1-aaaaaaaa\n\nAssistant: answer" sent))
     (should (equal (agent-dash-summary-text row) "修复解析器并已推送。"))
     (should (equal (agent-dash-summary-status row) "已生成"))
     (should (string-match-p "修复解析器并已推送。.*commit and push.*已生成" (buffer-string)))
     (should-not (agent-dash-summary--candidate))
     ;; New activity makes the summary stale.
     (should (equal (agent-dash-summary-status (plist-put (copy-sequence row) :time 1)) "待更新"))
     ;; A failure is recorded and retried later, not lost.
     (agent-dash-summary-requeue (list row))
     (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
               ((symbol-function 'gptel-request)
                (lambda (_prompt &rest args)
                  (funcall (plist-get args :callback) nil '(:status "HTTP 500")))))
       (agent-dash-summary--start row))
     (should (equal (agent-dash-summary-status row) "摘要失败"))
     (should (equal (agent-dash-summary-text row) "修复解析器并已推送。"))
     (should (file-exists-p agent-dash-summary-cache-file)))))

(ert-deftest agent-dash-hub-test-import-ashub-summaries ()
  (agent-dash-hub-test-with-hub
   (let ((hub (get-buffer-create "*ashub*"))
         (orig-featurep (symbol-function 'featurep)))
     (unwind-protect
         (cl-letf (((symbol-function 'featurep)
                    (lambda (f &rest r) (or (eq f 'ashub-summary) (apply orig-featurep f r))))
                   ((symbol-function 'ashub--all-sessions)
                    (lambda () '((fake "s1-aaaaaaaa" current) (fake "s2-bbbbbbbb" stale)
                                 (fake "gone" current))))
                   ((symbol-function 'ashub-session-agent) #'car)
                   ((symbol-function 'ashub-session-id) #'cadr)
                   ((symbol-function 'ashub-summary--stamp) (lambda (_) "now"))
                   ((symbol-function 'ashub-summary-entry)
                    (lambda (s) (list :summary (format "摘要 %s" (cadr s))
                                      :checked-stamp (if (eq (nth 2 s) 'current) "now" "old")))))
           (should (= 3 (agent-dash-summary-import-ashub)))
           (let ((rows (agent-dash-hub--all)))
             (cl-flet ((row (id) (seq-find (lambda (r) (equal (plist-get r :id) id)) rows)))
               ;; Current in ashub: generated, nothing to request.
               (should (equal (agent-dash-summary-status (row "s1-aaaaaaaa")) "已生成"))
               ;; Stale in ashub: shown, but refreshed later.
               (should (equal (agent-dash-summary-status (row "s2-bbbbbbbb")) "待更新"))
               (should (equal (agent-dash-summary-text (row "s2-bbbbbbbb")) "摘要 s2-bbbbbbbb"))))
           ;; A second import keeps what is already here.
           (should (= 0 (agent-dash-summary-import-ashub))))
       (kill-buffer hub)))))

(ert-deftest agent-dash-hub-test-semantic-search ()
  (agent-dash-hub-test-with-hub
   (let ((row (seq-find (lambda (r) (equal (plist-get r :id) "s1-aaaaaaaa")) (agent-dash-hub--all)))
         (replies (list "{\"evidence\":[{\"source\":1,\"quote\":\"解析器\",\"reason\":\"相关\"},{\"source\":1,\"quote\":\"编造\",\"reason\":\"x\"}]}"
                        "{\"claims\":[{\"text\":\"之前修过解析器。\",\"sources\":[1]}]}")))
     (agent-dash-summary--put row :summary "修复解析器并已推送。")
     (save-window-excursion
       (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                 ((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (funcall (plist-get args :callback) (pop replies) nil))))
         (agent-dash-search-start 'summary "解析器修过吗")
         (with-current-buffer "*agent-dash search*"
           (agent-dash-test-wait (lambda () (agent-dash-search--run-done agent-dash-search--current)))
           (should (string-match-p "完成" (agent-dash-search--run-status agent-dash-search--current)))
           (should (string-match-p "之前修过解析器。 \\[1\\]" (buffer-string)))
           (should (string-match-p "依据：解析器" (buffer-string)))
           (should (string-match-p "拒绝 1 条" (buffer-string)))
           (kill-buffer)))))))

(ert-deftest agent-dash-hub-test-reference-expands-and-displays-short ()
  (agent-dash-hub-test-with-hub
   (let ((session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect
           (progn
             (goto-char (point-max))
             (insert "see ")
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (_prompt choices &rest _)
                          (seq-find (lambda (c) (string-match-p "parser" c))
                                    (all-completions "" choices)))))
               (agent-dash-insert-reference))
             (should (equal (agent-dash--input) "see @[fix the parser](agent-dash:fake:s1-aaaaaaaa)"))
             (agent-dash-send)
             (let ((sent (nth 1 (car agent-dash-fake-calls))))
               (should (string-prefix-p (concat "see @[fix the parser](agent-dash:fake:s1-aaaaaaaa)"
                                                agent-dash-reference-boundary)
                                        sent))
               (should (string-match-p "User: question of s1-aaaaaaaa\n\nAgent: answer" sent))
               (agent-dash-emit session (list :type 'user :id "u" :text sent))
               (should (equal (buffer-substring-no-properties (point-min) agent-dash--transcript-end)
                              "\nYou: see @[fix the parser](agent-dash:fake:s1-aaaaaaaa)\n\n"))))
         (let ((agent-dash--quitting t)) (kill-buffer)))))))

(ert-deftest agent-dash-hub-test-file-completion-bounds ()
  (let ((agent-dash-fake-calls nil))
    (with-current-buffer (agent-dash-session-buffer (agent-dash-open 'fake temporary-file-directory))
      (unwind-protect
          (progn
            (goto-char (point-max))
            (insert "read @src/ma")
            (let ((capf (agent-dash--file-capf)))
              (should (equal (buffer-substring (nth 0 capf) (nth 1 capf)) "src/ma"))
              (should (eq (nth 2 capf) #'read-file-name-internal)))
            (insert " now")
            (should-not (agent-dash--file-capf)))
        (let ((agent-dash--quitting t)) (kill-buffer))))))

(provide 'agent-dash-hub-test)
;;; agent-dash-hub-test.el ends here
