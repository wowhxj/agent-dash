;;; agent-dash-hub-test.el --- Hub, summary and search tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: the fake backend provides saved sessions and transcripts,
;; and gptel requests are stubbed.  The summary cache is a temp file.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(ert-deftest agent-dash-hub-test-text-columns-anchor-fallback-glyphs ()
  "Fallback glyph widths must not accumulate into later column positions."
  (let* ((layout '(:id 8 :project 20 :summary 40 :last 30 :status 0))
         (prefix (agent-dash-hub--prefix layout " " "dsh" " " "2026-11-18 09:15"
                                         "session1" "~/.emacs.d.default"))
         (last-start (+ (string-width prefix) 40 3))
         (status-start (+ last-start 30 3)))
    (dolist (texts '(("normal summary" "normal prompt")
                     ("已在 Emacs 配置中添加 ⌘ 数字切换 tab" "还有一个小 bug")
                     ("normal summary" "使用 ⌘ 切换")))
      (let* ((summary (propertize (car texts) 'help-echo "Full summary"))
             (line (agent-dash-hub--text-columns
                    layout prefix summary (cadr texts) "已生成"))
             (gap (text-property-not-all 0 (length line) 'display nil line))
             (next-gap (and gap (text-property-not-all
                                (+ gap 3) (length line) 'display nil line))))
        (should gap)
        (should next-gap)
        (should (equal (get-text-property gap 'display line)
                       `(space :align-to ,last-start)))
        (should (equal (get-text-property next-gap 'display line)
                       `(space :align-to ,status-start)))
        (should (equal (get-text-property (length prefix) 'help-echo line)
                       "Full summary"))
        (should (= (string-width (substring-no-properties line 0 (+ gap 3)))
                   last-start))
        (should (= (string-width (substring-no-properties line 0 (+ next-gap 3)))
                   status-start))))))

(ert-deftest agent-dash-hub-project-navigation ()
  "Project jumps skip session rows and include folded headers."
  (with-temp-buffer
    (insert "Hub\n"
            (propertize "Alpha\n" 'agent-dash-group "Alpha")
            "session one\nsession two\n"
            (propertize "Beta (folded)\n" 'agent-dash-group "Beta")
            (propertize "Gamma\n" 'agent-dash-group "Gamma")
            "session three\n")
    (let ((agent-dash-hub--grouping 'project))
      (goto-char (point-min))
      (agent-dash-hub-next-project)
      (should (equal (get-text-property (point) 'agent-dash-group) "Alpha"))
      (forward-line 1)
      (agent-dash-hub-next-project)
      (should (equal (get-text-property (point) 'agent-dash-group) "Beta"))
      (agent-dash-hub-next-project)
      (should (equal (get-text-property (point) 'agent-dash-group) "Gamma"))
      (let ((origin (point)))
        (agent-dash-hub-next-project)
        (should (= (point) origin)))
      (agent-dash-hub-previous-project 2)
      (should (equal (get-text-property (point) 'agent-dash-group) "Alpha"))
      (let ((origin (point)))
        (agent-dash-hub-previous-project)
        (should (= (point) origin)))
      (agent-dash-hub-previous-project -1)
      (should (equal (get-text-property (point) 'agent-dash-group) "Beta")))
    (dolist (grouping '(nil agent))
      (let ((agent-dash-hub--grouping grouping))
        (should-error (agent-dash-hub-next-project) :type 'user-error)))
    (should (eq (lookup-key agent-dash-hub-mode-map (kbd "C-c C-n"))
                #'agent-dash-hub-next-project))
    (should (eq (lookup-key agent-dash-hub-mode-map (kbd "C-c C-p"))
                #'agent-dash-hub-previous-project))))

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
          (agent-dash-hub--lifecycle-pending (make-hash-table))
          (agent-dash-hub--lifecycle-timer nil)
          (agent-dash-summary-cache-file (make-temp-file "agent-dash-summaries"))
          (agent-dash-summary--cache (make-hash-table :test #'equal))
          (agent-dash-summary--sessions (make-hash-table :test #'equal))
          (agent-dash-summary--loaded t))
     (make-directory agent-dash-hub-test-alpha t)
     (make-directory agent-dash-hub-test-beta t)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 200))
                     ((symbol-function 'agent-dash-history-request) #'agent-dash-fake-history-request)
                     ((symbol-function 'agent-dash-hub--schedule-redisplay)
                      #'agent-dash-hub--redisplay))
             (agent-dash-hub)
             (agent-dash-test-wait
              (lambda () (not (seq-some (lambda (b) (eq (plist-get (gethash b agent-dash-hub--sources)
                                                                   :status)
                                                        'loading))
                                        agent-dash-backends))))
             (with-current-buffer "*agent-dash hub*" ,@body))
         (when (timerp agent-dash-hub--lifecycle-timer)
           (cancel-timer agent-dash-hub--lifecycle-timer))
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

(ert-deftest agent-dash-hub-test-exited-chat-is-not-live ()
  (let* ((session (agent-dash-session-create 'fake temporary-file-directory))
         (buffer (generate-new-buffer " *hub-dead-chat*"))
         (agent-dash--sessions (list session)))
    (unwind-protect
        (progn
          (agent-dash-set-data session :sid "closed")
          (setf (agent-dash-session-buffer session) buffer
                (agent-dash-session-state session) 'dead)
          (should-not (agent-dash-hub-live-p '(:backend fake :id "closed"))))
      (kill-buffer buffer))))

(ert-deftest agent-dash-hub-test-process-exit-refreshes-live-status ()
  (agent-dash-hub-test-with-hub
   (let* ((session (agent-dash-session-create 'fake agent-dash-hub-test-beta))
          (buffer (generate-new-buffer " *hub-exiting-chat*"))
          (agent-dash--sessions (list session)))
     (unwind-protect
         (progn
           (agent-dash-set-data session :sid "s2-bbbbbbbb")
           (setf (agent-dash-session-buffer session) buffer)
           (should (agent-dash-hub-live-p
                    (seq-find (lambda (row) (equal (plist-get row :id) "s2-bbbbbbbb"))
                              (agent-dash-hub--all))))
           ;; A source snapshot must stay separate from the cached hub rows.
           (setq agent-dash-fake-saved (copy-tree agent-dash-fake-saved))
           (plist-put (nth 1 agent-dash-fake-saved) :running nil)
           (agent-dash-emit session '(:type run :state dead))
           (sleep-for 0.15)
           (let ((row (seq-find (lambda (row) (equal (plist-get row :id) "s2-bbbbbbbb"))
                                (agent-dash-hub--all))))
             (should-not (agent-dash-hub-live-p row))))
       (kill-buffer buffer)))))

(ert-deftest agent-dash-hub-test-detach-refreshes-without-marking-process-dead ()
  (agent-dash-hub-test-with-hub
   (let* ((agent-dash--sessions nil)
          (session (agent-dash-session-create 'fake agent-dash-hub-test-beta))
          (buffer (agent-dash--setup-buffer session)))
     (agent-dash-set-data session :sid "s2-bbbbbbbb")
     (kill-buffer buffer)
     (sleep-for 0.1)
     (should (member '(detach) agent-dash-fake-calls))
     (should (agent-dash-hub-live-p
              (seq-find (lambda (row) (equal (plist-get row :id) "s2-bbbbbbbb"))
                        (agent-dash-hub--all)))))))

(ert-deftest agent-dash-hub-test-lifecycle-refresh-coalesces-and-skips-turn-churn ()
  (agent-dash-hub-test-with-hub
   (let ((session (agent-dash-session-create 'fake agent-dash-hub-test-alpha))
         (calls 0))
     (cl-letf (((symbol-function 'agent-dash-history-request)
                (lambda (backend operation &optional callback id)
                  (should (eq backend 'fake))
                  (cl-incf calls)
                  (agent-dash-fake-history-request backend operation callback id))))
       (run-hook-with-args 'agent-dash-session-change-functions session)
       (run-hook-with-args 'agent-dash-session-change-functions session)
       (agent-dash-emit session '(:type run :state running))
       (agent-dash-emit session '(:type run :state idle))
       (sleep-for 0.1)
       (should (= calls 1))
       (agent-dash-emit session '(:type run :state running))
       (agent-dash-emit session '(:type run :state idle))
       (sleep-for 0.1)
       (should (= calls 1))
       (agent-dash-emit session '(:type run :state dead))
       (sleep-for 0.1)
       (should (= calls 2))))))

(ert-deftest agent-dash-hub-test-inflight-snapshot-gets-one-fresh-followup ()
  (agent-dash-hub-test-with-hub
   (let ((agent-dash-history--jobs (make-hash-table :test #'equal))
         (session (agent-dash-session-create 'fake agent-dash-hub-test-beta))
         (calls 0) old-callback)
     (puthash '(fake sessions nil) 'existing-worker agent-dash-history--jobs)
     (cl-letf (((symbol-function 'agent-dash-history-request)
                (lambda (backend operation &optional callback id)
                  (cl-incf calls)
                  (if (= calls 1) (setq old-callback callback)
                    (agent-dash-fake-history-request backend operation callback id)))))
       (run-hook-with-args 'agent-dash-session-change-functions session)
       (sleep-for 0.1)
       (should (eq (gethash 'fake agent-dash-hub--lifecycle-pending) 'waiting))
       (run-hook-with-args 'agent-dash-session-change-functions session)
       (sleep-for 0.1)
       (should (= calls 1))
       (setq agent-dash-fake-saved (copy-tree agent-dash-fake-saved))
       (plist-put (nth 1 agent-dash-fake-saved) :running nil)
       (remhash '(fake sessions nil) agent-dash-history--jobs)
       ;; The shared pre-exit snapshot is stale; only the next scan is current.
       (funcall old-callback '(:ok t))
       (should (= calls 2))
       (should-not (gethash 'fake agent-dash-hub--lifecycle-pending))
       (should-not (plist-get (nth 1 (plist-get (gethash 'fake agent-dash-hub--sources)
                                                :rows)) :running))))))

(ert-deftest agent-dash-hub-test-quit-reduces-two-real-holders-to-one-live ()
  (agent-dash-test-with-holders
    (agent-dash-hub-test-with-hub
     (let* ((agent-dash--sessions nil)
            (first (agent-dash-session-create 'fake agent-dash-hub-test-alpha))
            (second (agent-dash-session-create 'fake agent-dash-hub-test-beta))
            (first-buffer (agent-dash--setup-buffer first))
            (second-buffer (agent-dash--setup-buffer second)))
       (unwind-protect
           (progn
             (cl-loop for session in (list first second)
                      for id in '("s1-aaaaaaaa" "s2-bbbbbbbb")
                      do (let ((dir (agent-dash-holder-dir 'fake id)))
                           (agent-dash-set-data session :sid id)
                           (agent-dash-holder-start dir temporary-file-directory '("cat"))
                           (agent-dash-holder-attach
                            session dir
                            (lambda (s record)
                              (when (equal (agent-dash-jget record "type") "agent_dash_exit")
                                (agent-dash-emit s '(:type run :state dead)))))))
             (cl-letf (((symbol-function 'agent-dash-history-request)
                        (lambda (backend operation &optional callback id)
                          (setq agent-dash-fake-saved
                                (mapcar
                                 (lambda (row)
                                   (plist-put (copy-sequence row) :running
                                              (and (agent-dash-holder-alive-p
                                                    (agent-dash-holder-dir 'fake (plist-get row :id)))
                                                   t)))
                                 agent-dash-fake-saved))
                          (agent-dash-fake-history-request backend operation callback id)))
                       ((symbol-function 'agent-dash-backend-quit)
                        (lambda (_backend s) (agent-dash-holder-stop s)))
                       ((symbol-function 'yes-or-no-p) (lambda (_) t)))
               (agent-dash-hub-refresh)
               (setq agent-dash-hub--live-only t)
               (agent-dash-hub--redisplay)
               (should (= 2 (length (agent-dash-hub-test-ids))))
               (agent-dash-hub--goto "fake:s1-aaaaaaaa")
               (with-current-buffer second-buffer (agent-dash-quit))
               (should-not (buffer-live-p second-buffer))
               (agent-dash-test-wait
                (lambda ()
                  (and (eq (agent-dash-session-state second) 'dead)
                       (not (plist-get
                             (seq-find (lambda (row) (equal (plist-get row :id) "s2-bbbbbbbb"))
                                       (agent-dash-hub--all)) :running)))))
               (should (equal (agent-dash-hub-test-ids) '("s1-aaaaaaaa")))
               (should (equal (get-text-property (point) 'agent-dash-key) "fake:s1-aaaaaaaa"))
               (should (agent-dash-holder-alive-p (agent-dash-data first :holder)))
               (should-not (process-live-p (agent-dash-data second :tail)))))
         (dolist (session (list first second)) (agent-dash-holder-detach session))
         (dolist (buffer (list first-buffer second-buffer))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((agent-dash--quitting t)) (kill-buffer buffer))))))))))

(ert-deftest agent-dash-hub-test-no-inventory-work-without-hub ()
  (let ((agent-dash-hub--lifecycle-pending (make-hash-table))
        (agent-dash-hub--lifecycle-timer nil)
        (session (agent-dash-session-create 'fake temporary-file-directory)))
    (cl-letf (((symbol-function 'agent-dash-hub--open-p) (lambda () nil))
              ((symbol-function 'agent-dash-history-request)
               (lambda (&rest _) (ert-fail "Unopened Hub launched a scan"))))
      (run-hook-with-args 'agent-dash-session-change-functions session)
      (agent-dash-emit session '(:type run :state dead))
      (should-not agent-dash-hub--lifecycle-timer)
      (should (= 0 (hash-table-count agent-dash-hub--lifecycle-pending))))))

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
   (agent-dash-test-wait
    (lambda () (eq (plist-get (gethash 'broken agent-dash-hub--sources) :status) 'error)))
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

(ert-deftest agent-dash-hub-test-live-toggle-refreshes-session-snapshot ()
  "Enabling live filtering discovers new instances and drops stopped ones."
  (agent-dash-hub-test-with-hub
   (let ((first (copy-sequence (car agent-dash-fake-saved)))
         (stopped (copy-sequence (cadr agent-dash-fake-saved))))
     (setq agent-dash-fake-saved
           (list (plist-put first :running t)
                 (plist-put stopped :running nil)
                 (list :id "new-live" :root agent-dash-hub-test-beta
                       :time (float-time) :first "new instance" :running t))))
   ;; The inventory still contains the original running s2 snapshot.
   (should (agent-dash-hub-live-p
            (seq-find (lambda (row) (equal (plist-get row :id) "s2-bbbbbbbb"))
                      (agent-dash-hub--all))))
   (call-interactively (key-binding "l"))
   (should agent-dash-hub--live-only)
   (agent-dash-test-wait
    (lambda ()
      (and (eq (plist-get (gethash 'broken agent-dash-hub--sources) :status) 'error)
           (equal (agent-dash-hub-test-ids) '("new-live" "s1-aaaaaaaa")))))
   (let ((generation agent-dash-hub--generation))
     (call-interactively (key-binding "l"))
     (should-not agent-dash-hub--live-only)
     (should (= generation agent-dash-hub--generation))
     (should (equal (agent-dash-hub-test-ids)
                    '("new-live" "s2-bbbbbbbb" "s1-aaaaaaaa"))))))

(ert-deftest agent-dash-hub-test-live-refresh-keeps-view-state ()
  "Refreshing live status preserves filters, folds and deletion marks."
  (agent-dash-hub-test-with-hub
   (setq agent-dash-hub--agent 'fake
         agent-dash-hub--project "ad-beta"
         agent-dash-hub--grouping 'agent)
   (puthash "folded-project" t agent-dash-hub--collapsed)
   (puthash "fake:s1-aaaaaaaa" t agent-dash-hub--marks)
   (let ((generation agent-dash-hub--generation))
     (call-interactively (key-binding "l"))
     (should (> agent-dash-hub--generation generation))
     (agent-dash-test-wait
      (lambda () (not (seq-some
                       (lambda (backend)
                         (eq (plist-get (gethash backend agent-dash-hub--sources) :status)
                             'loading))
                       agent-dash-backends)))))
   (should (eq agent-dash-hub--agent 'fake))
   (should (equal agent-dash-hub--project "ad-beta"))
   (should (eq agent-dash-hub--grouping 'agent))
   (should (gethash "folded-project" agent-dash-hub--collapsed))
   (should (gethash "fake:s1-aaaaaaaa" agent-dash-hub--marks))
   (should (equal (agent-dash-hub-test-ids) '("s2-bbbbbbbb")))
   (should (string-match-p "来源失败：broken" agent-dash-hub--status))))

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
