;;; agent-dash-hub.el --- Cross-agent session hub -*- lexical-binding: t; -*-

;;; Commentary:

;; One table of the saved sessions of every backend, built only from the
;; backend interface: grouped by project (or agent, or newest first),
;; with summary, latest prompt and summary status columns, transient
;; menus for new sessions, filters and commands, details, deletion,
;; project relocation and @session references.
;;
;; A row is a session plist from `agent-dash-backend-sessions' plus
;; :backend and :key.

;;; Code:

(require 'agent-dash-ui)
(require 'agent-dash-summary)
(require 'transient)
(require 'text-property-search)


(defgroup agent-dash-hub nil "Session hub of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-hub-group-by 'project
  "Default grouping: `project', `agent', or nil for newest first."
  :type '(choice (const project) (const agent) (const :tag "None" nil)))

(defcustom agent-dash-hub-project-relocations nil
  "Alist (OLD . NEW) of moved project directories.
Sessions recorded under OLD are shown and opened from NEW.  Set with
`agent-dash-hub-relocate-project' (D)."
  :type '(alist :key-type directory :value-type directory))

(defcustom agent-dash-reference-max-chars 20000
  "Characters of conversation appended for all @session references of a prompt."
  :type 'integer)

(defconst agent-dash-hub--agents
  '((claude "Claude Code" "C") (codex "Codex" "x") (pi "pi" "p")
    (dsh "dsh" "d") (hermes "Hermes" "m"))
  "Backend, menu label and shortcut key, in menu order.")

(defconst agent-dash-hub--convert-file
  (expand-file-name "agent-dash-convert.mjs"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defconst agent-dash-hub--backup-file
  (expand-file-name "agent-dash-session-backup.py"
                    (file-name-directory agent-dash-hub--convert-file)))

(defvar agent-dash-codex-directory)
(defvar agent-dash-hermes-directory)

(defconst agent-dash-hub--dsh-export-file
  (expand-file-name "agent-dash-dsh-export.mjs" (file-name-directory agent-dash-hub--convert-file)))

(defconst agent-dash-hub--dsh-migrate-file
  (expand-file-name "agent-dash-dsh-migrate.mjs"
                    (file-name-directory agent-dash-hub--convert-file)))

(defvar agent-dash-dsh--host)
(declare-function agent-dash-dsh--login "agent-dash-dsh")
(declare-function agent-dash-dsh--call "agent-dash-dsh" (method args &optional retried))
(defconst agent-dash-hub--convert-sources '(claude codex))
(defvar agent-dash-pi-sessions-directory)
(defvar agent-dash-claude-config-directory)
(declare-function agent-dash-holder-dir "agent-dash-holder")
(declare-function agent-dash-holder-alive-p "agent-dash-holder")

(defconst agent-dash--reference-regexp
  "@\\[[^]\n]*\\](agent-dash:\\([a-z]+\\):\\([^)\n]+\\))"
  "An @session reference; group 1 is the backend, group 2 the session id.")

(defface agent-dash-hub-current-row-face
  '((((class color) (background light)) :background "#e5edf7")
    (((class color) (background dark)) :background "#303b4a")
    (t :inherit highlight))
  "Face of the session row under point.")
(defface agent-dash-hub-delete-face
  '((((class color) (background light)) :background "#ffe2dc" :foreground "#8f2415")
    (((class color) (background dark)) :background "#542b2b" :foreground "#ffd7cc")
    (t :inherit warning))
  "Face of rows marked for deletion.")
(defface agent-dash-hub-user-face
  '((((class color) (background light)) :background "#e7f0ff" :extend nil)
    (((class color) (background dark)) :background "#29384b" :extend nil)
    (t :inherit shadow))
  "Bubble of user messages in the details buffer.")
(defface agent-dash-hub-assistant-face
  '((((class color) (background light)) :background "#f4f0df" :extend nil)
    (((class color) (background dark)) :background "#403b2a" :extend nil)
    (t :inherit default))
  "Bubble of agent messages in the details buffer.")

;; Every hub shares one inventory, so @references and the summary
;; scheduler see the same rows as the table.
(defvar agent-dash-hub--sources (make-hash-table)
  "Backend -> plist (:status loading|ok|error :rows ROWS :error STRING).")
(defvar agent-dash-hub--generation 0 "Number of requested hub refreshes.")

(defvar-local agent-dash-hub--agent nil "Backend filter, or nil for all.")
(defvar-local agent-dash-hub--project nil "Project substring filter, or nil.")
(defvar-local agent-dash-hub--live-only nil)
(defvar-local agent-dash-hub--show-hidden nil "Show sessions that are never summarized.")
(defvar-local agent-dash-hub--grouping nil)
(defvar-local agent-dash-hub--collapsed nil "Group name -> t when folded.")
(defvar-local agent-dash-hub--selected nil "Set of selected session keys in this view.")
(defvar-local agent-dash-hub--marks nil "Row key -> t when marked for deletion.")
(defvar-local agent-dash-hub--status "" "Header-line text.")
(defvar-local agent-dash-hub--width nil "Body width used for the last table render.")

;;;; Rows

(defun agent-dash-hub--chat (backend id)
  "Return the live chat session of BACKEND session ID, or nil."
  (seq-find (lambda (s) (and (eq (agent-dash-session-backend s) backend)
                             (equal (agent-dash-data s :sid) id)
                             (buffer-live-p (agent-dash-session-buffer s))
                             (not (eq (agent-dash-session-state s) 'dead))))
            agent-dash--sessions))

(defun agent-dash-hub-live-p (row)
  "Whether ROW has a live instance or an open chat."
  (or (plist-get row :running)
      (and (agent-dash-hub--chat (plist-get row :backend) (plist-get row :id)) t)))

(setq agent-dash-summary-live-function #'agent-dash-hub-live-p)

(defun agent-dash-hub--relocate (root)
  "Return ROOT after `agent-dash-hub-project-relocations'."
  (when root
    (let ((root (directory-file-name (expand-file-name root))))
      (or (seq-some (lambda (pair)
                      (let ((old (directory-file-name (expand-file-name (car pair)))))
                        (cond ((equal root old) (directory-file-name (cdr pair)))
                              ((string-prefix-p (file-name-as-directory old) root)
                               (concat (file-name-as-directory (cdr pair))
                                       (substring root (length (file-name-as-directory old))))))))
                    agent-dash-hub-project-relocations)
          root))))

(defun agent-dash-hub--row (backend session)
  "Return the hub row of BACKEND's SESSION plist."
  (let ((root (agent-dash-hub--relocate (plist-get session :root))))
    (append (list :backend backend
                  :key (format "%s:%s" backend (plist-get session :id))
                  :root root
                  :missing (and root (not (file-remote-p root)) (not (file-directory-p root))))
            session)))

(defvar agent-dash-hub--import-hashes (make-hash-table :test #'equal)
  "Local file name -> (stat signature . SHA-256) for import comparisons.")

(defun agent-dash-hub--file-hash (file attrs)
  "Return FILE's literal SHA-256, reusing a digest only for unchanged ATTRS."
  (let ((stamp (list (file-attribute-size attrs) (file-attribute-modification-time attrs)
                     (file-attribute-status-change-time attrs) (file-attribute-inode-number attrs)
                     (file-attribute-device-number attrs)))
        (cached (gethash file agent-dash-hub--import-hashes)))
    (if (equal stamp (car cached)) (cdr cached)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (cdr (puthash file (cons stamp (secure-hash 'sha256 (current-buffer)))
                      agent-dash-hub--import-hashes))))))

(defun agent-dash-hub--import-matches-p (source target)
  "Whether TARGET exists and its archived bytes still match SOURCE."
  (let ((file (plist-get source :file)) (id (plist-get target :id)))
    (when (and (eq (plist-get source :backend) 'codex)
               (stringp file) (not (file-remote-p file)) (stringp id)
               (stringp (plist-get target :file))
               (string-match-p "\\`[[:alnum:]_.-]+\\'" id)
               (file-regular-p (plist-get target :file)))
      (let* ((archive (expand-file-name
                       (format "conversion-archives/%s-%s.jsonl%s" (plist-get source :backend)
                               id (if (string-suffix-p ".zst" file) ".zst" ""))
                       agent-dash-directory))
             (digest (plist-get (plist-get target :import-source) :sha256))
             (src (file-attributes file)) (copy (file-attributes archive)))
        (and src copy (null (file-attribute-type src)) (null (file-attribute-type copy))
             (= (file-attribute-size src) (file-attribute-size copy))
             (condition-case nil
                 (and (equal digest (agent-dash-hub--file-hash file src))
                      (equal digest (agent-dash-hub--file-hash archive copy)))
               (file-error nil)))))))

(defun agent-dash-hub--all (&optional replacements)
  "Return every loaded row, recording verified source -> Pi rows in REPLACEMENTS."
  (let ((imports (make-hash-table :test #'equal)) rows)
    (dolist (backend agent-dash-backends)
      (setq rows (append rows (plist-get (gethash backend agent-dash-hub--sources) :rows))))
    (when (memq 'pi agent-dash-backends)
      (dolist (target (plist-get (gethash 'pi agent-dash-hub--sources) :rows))
        (when-let* ((source (plist-get target :import-source)))
          (push target (gethash (format "%s:%s" (plist-get source :backend) (plist-get source :id))
                                imports)))))
    (seq-remove
     (lambda (row)
       (when-let* ((key (plist-get row :key))
                   (target (seq-find (lambda (pi-row) (agent-dash-hub--import-matches-p row pi-row))
                                     (gethash key imports))))
         (when replacements (puthash key target replacements))
         t))
     rows)))

(defun agent-dash-hub--history-updated (backend result)
  "Publish BACKEND's shared reader RESULT, preserving old rows on failure."
  (let ((old (gethash backend agent-dash-hub--sources)))
    (puthash backend
             (if (plist-get result :ok)
                 (list :status 'ok
                       :rows (mapcar (lambda (row) (agent-dash-hub--row backend row))
                                     (plist-get result :value))
                       :warnings (plist-get result :warnings)
                       :seconds (plist-get result :seconds))
               (list :status 'error :rows (plist-get old :rows)
                     :error (plist-get result :error) :seconds (plist-get result :seconds)))
             agent-dash-hub--sources))
  (agent-dash-hub--schedule-redisplay))

(add-hook 'agent-dash-history-update-hook #'agent-dash-hub--history-updated)

(defun agent-dash-hub--load (backend &optional callback)
  "Request BACKEND's inventory without blocking; optionally call CALLBACK."
  (puthash backend (plist-put (copy-sequence (gethash backend agent-dash-hub--sources))
                              :status 'loading)
           agent-dash-hub--sources)
  (agent-dash-history-request backend 'sessions callback))

(defvar agent-dash-hub--lifecycle-pending (make-hash-table)
  "Backends awaiting a lifecycle refresh: `queued' or `waiting' on an old worker.")
(defvar agent-dash-hub--lifecycle-timer nil
  "One-shot timer merging chat and process lifecycle changes.")

(defun agent-dash-hub--open-p ()
  "Whether any Hub buffer exists, including a currently hidden one."
  (seq-some (lambda (buffer)
              (with-current-buffer buffer (derived-mode-p 'agent-dash-hub-mode)))
            (buffer-list)))

(defun agent-dash-hub--refresh-changed ()
  "Refresh affected sources, after any pre-change worker has finished."
  (setq agent-dash-hub--lifecycle-timer nil)
  (let (backends)
    (maphash (lambda (backend state) (when (eq state 'queued) (push backend backends)))
             agent-dash-hub--lifecycle-pending)
    (dolist (backend backends)
      (cond
       ((not (agent-dash-hub--open-p))
        (remhash backend agent-dash-hub--lifecycle-pending))
       ((gethash (list backend 'sessions nil) agent-dash-history--jobs)
        ;; Sharing the current reader alone could republish its pre-exit live
        ;; flags.  Coalesce all intervening changes into one fresh follow-up.
        (puthash backend 'waiting agent-dash-hub--lifecycle-pending)
        (agent-dash-history-request
         backend 'sessions
         (lambda (_result)
           (remhash backend agent-dash-hub--lifecycle-pending)
           (when (agent-dash-hub--open-p) (agent-dash-hub--load backend)))))
       (t
        (remhash backend agent-dash-hub--lifecycle-pending)
        (agent-dash-hub--load backend))))))

(defun agent-dash-hub--session-changed (session)
  "Debounce a source refresh after SESSION opens, closes or gets its native ID."
  (when (agent-dash-hub--open-p)
    (let ((backend (agent-dash-session-backend session)))
      (unless (gethash backend agent-dash-hub--lifecycle-pending)
        (puthash backend 'queued agent-dash-hub--lifecycle-pending)
        (unless (timerp agent-dash-hub--lifecycle-timer)
          (setq agent-dash-hub--lifecycle-timer
                (run-at-time 0.05 nil #'agent-dash-hub--refresh-changed)))))))

(defun agent-dash-hub--session-event (session event)
  "Refresh on SESSION's live/dead EVENT transitions, not each streamed event."
  (when (and (eq (plist-get event :type) 'run)
             (memq (plist-get event :state) '(idle running dead)))
    (let ((state (if (eq (plist-get event :state) 'dead) 'down 'up)))
      (unless (eq state (agent-dash-data session :hub-live-state))
        (agent-dash-set-data session :hub-live-state state)
        (agent-dash-hub--session-changed session)))))

(add-hook 'agent-dash-session-change-functions #'agent-dash-hub--session-changed)
(add-hook 'agent-dash-event-functions #'agent-dash-hub--session-event)

(defun agent-dash-hub--first-text (row)
  "Return ROW's first prompt, labelled title, or a placeholder."
  (cond ((plist-get row :first))
        ((plist-get row :title) (concat "[标题] " (plist-get row :title)))
        (t "[首条用户消息未知]")))

(defun agent-dash-hub--summary-text (row)
  "Return ROW's AI summary, falling back to its first prompt."
  (or (agent-dash-summary-text row) (agent-dash-hub--first-text row)))

(defun agent-dash-hub--last-text (row)
  "Return ROW's latest prompt or a placeholder."
  (let ((last (plist-get row :last)))
    (if (and (stringp last) (not (string-blank-p last))) last "[末句未知]")))

(defun agent-dash-hub--stale-p (row)
  "Whether ROW is kept from a failed listing."
  (eq (plist-get (gethash (plist-get row :backend) agent-dash-hub--sources) :status) 'error))

(defun agent-dash-hub--row-status (row)
  "Return ROW's session status suffix."
  (concat (when (agent-dash-hub--stale-p row) " [旧]")
          (when (plist-get row :missing) " [目录缺失]")
          (when-let* ((reason (agent-dash-summary-skip-reason row))) (format " [%s]" reason))))

(defun agent-dash-hub-time (row &optional seconds)
  "Return ROW's time as text, with SECONDS if non-nil; `*' marks a source time."
  (let ((time (plist-get row :time)))
    (if (numberp time)
        (concat (format-time-string (if seconds "%Y-%m-%d %H:%M:%S" "%Y-%m-%d %H:%M") time)
                (if (plist-get row :exact) "" "*"))
      "时间未知")))

(defun agent-dash-hub--newest-first (rows)
  "Return ROWS sorted by time, newest first."
  (sort (copy-sequence rows)
        (lambda (a b) (> (or (plist-get a :time) 0) (or (plist-get b :time) 0)))))

(cl-defun agent-dash-hub--visible (&optional (all (agent-dash-hub--all)))
  "Return the rows of ALL passing the filters, newest first."
  (agent-dash-hub--newest-first
   (seq-filter
    (lambda (row)
      (and (or (not agent-dash-hub--agent) (eq agent-dash-hub--agent (plist-get row :backend)))
           (or (not agent-dash-hub--project)
               (string-search agent-dash-hub--project (or (plist-get row :root) "")))
           (or agent-dash-hub--show-hidden (not (agent-dash-summary-skip-reason row)))
           (or (not agent-dash-hub--live-only) (agent-dash-hub-live-p row))))
    all)))

(defun agent-dash-hub--group-name (row)
  "Return ROW's group in the current grouping."
  (pcase agent-dash-hub--grouping
    ('project (if (plist-get row :root) (abbreviate-file-name (plist-get row :root)) "（未知项目）"))
    ('agent (symbol-name (plist-get row :backend)))))

;;;; Layout

(defun agent-dash-hub--middle (text width)
  "Shorten TEXT to WIDTH, keeping its beginning and end."
  (let ((text (agent-dash--one-line text 10000)))
    (if (<= (string-width text) width)
        text
      (let* ((head (/ (1- width) 2)) (tail (- width head 1)))
        (concat (truncate-string-to-width text head) "…"
                (substring text (- (length text) tail)))))))

(defun agent-dash-hub--column (text width)
  "Return TEXT as a one-line column of display WIDTH."
  (truncate-string-to-width (agent-dash--one-line text 10000) width nil ?\s "…"))

(defun agent-dash-hub--short-ids (rows)
  "Map each id of ROWS to its shortest unique prefix of 8 to 10 chars.
Neighbours in sorted order share the longest prefixes, so comparing each
id with them is enough.  Return a hash table."
  (let* ((ids (vconcat (sort (delete-dups (mapcar (lambda (r) (plist-get r :id)) rows))
                             #'string<)))
         (table (make-hash-table :test #'equal)))
    (cl-flet ((unique (a b)             ; 1 + common prefix length; ids are distinct
                (if b (abs (compare-strings a nil nil b nil nil)) 0)))
      (dotimes (i (length ids))
        (let* ((id (aref ids i))
               (need (max (unique id (and (> i 0) (aref ids (1- i))))
                          (unique id (and (< (1+ i) (length ids)) (aref ids (1+ i)))))))
          (puthash id (substring id 0 (min (length id) 10 (max 8 need))) table))))
    table))

(defun agent-dash-hub--window-width ()
  "Return the narrowest visible hub window's body width.
A shared buffer needs one column layout even when shown in several windows."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows (apply #'min (mapcar #'window-body-width windows))
      (window-body-width))))

(defun agent-dash-hub--layout (rows &optional show-project)
  "Compute column widths for ROWS in the visible hub windows.
With SHOW-PROJECT, reserve a project column even in narrow windows."
  (let* ((width (agent-dash-hub--window-width))
         (short (agent-dash-hub--short-ids rows))
         (id (apply #'max 8 (mapcar #'string-width (hash-table-values short))))
         (project (if (or show-project (>= width 120))
                      (min 20 (max 4 (- width id 64))
                           (apply #'max 4
                                  (mapcar (lambda (row)
                                            (string-width (abbreviate-file-name
                                                           (or (plist-get row :root) ""))))
                                          rows)))
                    0))
         (message (max 28 (- width (+ 32 id (if (> project 0) (1+ project) 0)) 4)))
         (status (min (max 0 (- message 27))
                      (apply #'max 0 (mapcar (lambda (r)
                                               (string-width (agent-dash-hub--row-status r)))
                                             rows))))
         (text (- message status 8 6))
         (summary (max 4 (min (- text 10) (floor (* text 0.6))))))
    (list :width width :id id :short short :project project
          :summary summary :last (- text summary) :status status)))

(defun agent-dash-hub--prefix (layout mark agent live date id project)
  "Format the leading columns with LAYOUT.
MARK, AGENT, LIVE, DATE, ID and PROJECT are the column texts."
  (concat (format " %s %s%s %s %s " mark (agent-dash-hub--column agent 7) live
                  (agent-dash-hub--column date 17)
                  (agent-dash-hub--column id (plist-get layout :id)))
          (when (> (plist-get layout :project) 0)
            (concat (agent-dash-hub--column project (plist-get layout :project)) " "))))

(defun agent-dash-hub--text-columns (layout prefix summary last status)
  "Format PREFIX, SUMMARY, LAST and STATUS using LAYOUT's display stops.
Anchor the gaps rather than padding alone: fallback glyphs such as ⌘ can
occupy more pixels than `string-width' predicts in graphical Emacs."
  (let* ((last-start (+ (string-width prefix) (plist-get layout :summary) 3))
         (status-start (+ last-start (plist-get layout :last) 3)))
    (concat prefix
            (agent-dash-hub--column summary (plist-get layout :summary))
            (propertize "   " 'display `(space :align-to ,last-start))
            (agent-dash-hub--column last (plist-get layout :last))
            (propertize "   " 'display `(space :align-to ,status-start))
            (agent-dash-hub--column status 8))))

(defun agent-dash-hub--header (layout)
  "Return the column header line for LAYOUT."
  (propertize
   (concat (agent-dash-hub--text-columns
            layout
            (propertize (agent-dash-hub--prefix layout "  " "Agent" " " "日期*" "ID" "项目")
                        'help-echo "日期 *：来源更新/创建时间，不是已验证的消息时间；*=已选，D=待删除，●=后台实例或已打开")
            "摘要" "用户末句" "摘要状态")
           (make-string (plist-get layout :status) ?\s) "\n")
   'face 'bold))

(defun agent-dash-hub--label (row layout)
  "Return the table line of ROW with LAYOUT."
  (let* ((summary (agent-dash-hub--summary-text row))
         (last (agent-dash-hub--last-text row))
         (status (agent-dash-summary-status row))
         (id (plist-get row :id))
         (root (plist-get row :root)))
    (concat
     (agent-dash-hub--text-columns
      layout
      (agent-dash-hub--prefix
       layout (concat (if (gethash (plist-get row :key) (agent-dash-hub--selection)) "*" " ")
                      (if (gethash (plist-get row :key) agent-dash-hub--marks) "D" " "))
       (symbol-name (plist-get row :backend))
       (if (agent-dash-hub-live-p row)
           (propertize "●" 'face 'success 'help-echo "后台实例运行中或聊天已打开")
         " ")
       (agent-dash-hub-time row)
       (propertize (gethash id (plist-get layout :short) id) 'help-echo id)
       (propertize (agent-dash-hub--middle (abbreviate-file-name (or root ""))
                                           (max 1 (plist-get layout :project)))
                   'help-echo root))
      (propertize summary 'help-echo summary)
      (propertize last 'help-echo last)
      status)
     (agent-dash-hub--column (agent-dash-hub--row-status row) (plist-get layout :status)))))

;;;; Rendering

(cl-defun agent-dash-hub--status-line (rows &optional (total (length (agent-dash-hub--all))))
  "Return the header-line status for visible ROWS out of TOTAL."
  (let (loading failed warnings)
    (dolist (backend agent-dash-backends)
      (when-let* ((notes (plist-get (gethash backend agent-dash-hub--sources) :warnings)))
        (push (format "%s (%d)" backend (length notes)) warnings))
      (pcase (plist-get (gethash backend agent-dash-hub--sources) :status)
        ('loading (push (symbol-name backend) loading))
        ('error (push (symbol-name backend) failed))))
    (concat "agent-dash"
            (format "  显示 %d/已载入 %d（过滤/隐藏 %d）" (length rows) total (- total (length rows)))
            (format "  已选 %d" (if agent-dash-hub--selected
                                    (hash-table-count agent-dash-hub--selected) 0))
            (if loading (format "  扫描中：%s" (string-join (nreverse loading) ", ")) "")
            (if failed (format "  来源失败：%s  [! 诊断]" (string-join (nreverse failed) ", ")) "")
            (if warnings (format "  读取警告：%s  [! 诊断]"
                                 (string-join (nreverse warnings) ", ")) ""))))

(defvar-local agent-dash-hub--follow-import nil
  "Single-source conversion and originating view awaiting the destination inventory.")

(defun agent-dash-hub--focus ()
  "Identify the current row, selection and filters during an asynchronous import."
  (list (get-text-property (point) 'agent-dash-key)
        (sort (hash-table-keys (agent-dash-hub--selection)) #'string<)
        agent-dash-hub--agent agent-dash-hub--project agent-dash-hub--live-only
        agent-dash-hub--show-hidden agent-dash-hub--grouping))

(defun agent-dash-hub--render ()
  "Redraw the hub, keeping point on the same row or its imported session."
  (let* ((replacements (make-hash-table :test #'equal))
         (all (agent-dash-hub--all replacements))
         (key (get-text-property (point) 'agent-dash-key))
         (follow-source (plist-get agent-dash-hub--follow-import :source))
         (dest (plist-get agent-dash-hub--follow-import :target))
         (follow-target (if dest (seq-find (lambda (r) (equal dest (plist-get r :key))) all)
                          (gethash follow-source replacements)))
         (target (gethash key replacements))
         (column (current-column))
         (rows (progn
                 (when agent-dash-hub--follow-import
                   (cond
                    ((not (equal (plist-get agent-dash-hub--follow-import :focus)
                                 (agent-dash-hub--focus)))
                     (setq agent-dash-hub--follow-import nil))
                    (follow-target
                     (setq target follow-target agent-dash-hub--follow-import nil)
                     (when (gethash follow-source (agent-dash-hub--selection))
                       (remhash follow-source agent-dash-hub--selected)
                       (puthash (plist-get target :key) t agent-dash-hub--selected))
                     (when agent-dash-hub--agent
                       (setq agent-dash-hub--agent (plist-get target :backend)))
                     (remhash (agent-dash-hub--group-name target) agent-dash-hub--collapsed))))
                 (agent-dash-hub--visible all)))
         (layout (agent-dash-hub--layout rows))
         (groups (make-hash-table :test #'equal)) order
         (selected (make-hash-table :test #'equal))
         (inhibit-read-only t))
    (when target (setq key (plist-get target :key)))
    (maphash (lambda (source pi-row)
               (remhash source agent-dash-hub--marks)
               (when (gethash source (agent-dash-hub--selection))
                 (puthash (plist-get pi-row :key) t agent-dash-hub--selected)))
             replacements)
    (dolist (row rows)
      (let ((name (agent-dash-hub--group-name row)))
        (unless (gethash name groups) (push name order))
        (when (and agent-dash-hub--selected
                   (gethash (plist-get row :key) agent-dash-hub--selected))
          (puthash (plist-get row :key) t selected))
        (puthash name (cons row (gethash name groups)) groups)))
    (setq agent-dash-hub--selected selected
          agent-dash-hub--width (plist-get layout :width)
          agent-dash-hub--status (agent-dash-hub--status-line rows (length all)))
    (erase-buffer)
    (insert (propertize "Agent Session Hub\n" 'face 'bold))
    (insert (format "分组:%s  agent:%s  项目:%s  摘要范围:%s  仅存活:%s\n\n"
                    (pcase agent-dash-hub--grouping ('project "项目") ('agent "Agent") (_ "无（时间倒序）"))
                    (or agent-dash-hub--agent "全部")
                    (agent-dash--one-line (or agent-dash-hub--project "全部") 40)
                    (if agent-dash-hub--show-hidden "全部状态" "隐藏不摘要")
                    (if agent-dash-hub--live-only "开" "关")))
    (insert (agent-dash-hub--header layout))
    (dolist (backend agent-dash-backends)
      (let ((source (gethash backend agent-dash-hub--sources)))
        (when (and (eq (plist-get source :status) 'error) (null (plist-get source :rows)))
          (insert (propertize (format "%s 无法加载：%s  [! 完整诊断]\n" backend
                                      (agent-dash--one-line (plist-get source :error) 140))
                              'face 'warning)))))
    (if (null rows)
        (insert "没有符合当前过滤条件的会话；f c 恢复默认，! 查看诊断。\n")
      (dolist (name (nreverse order))
        (let ((group (nreverse (gethash name groups)))
              (folded (gethash name agent-dash-hub--collapsed)))
          (when agent-dash-hub--grouping
            (let ((start (point)))
              (insert (propertize (format "%s %s (%d)%s\n" (if folded "+" "−") name (length group)
                                          (if (and (eq agent-dash-hub--grouping 'project)
                                                   (plist-get (car group) :missing))
                                              "  [目录缺失：D 重定向]" ""))
                                  'face 'bold))
              (add-text-properties start (point) (list 'agent-dash-group name
                                                       'agent-dash-project-root
                                                       (and (eq agent-dash-hub--grouping 'project)
                                                            (plist-get (car group) :root))
                                                       'agent-dash-key (list 'group name)))))
          (unless folded
            (dolist (row group)
              (let ((start (point)))
                (insert (agent-dash-hub--label row layout) "\n")
                (add-text-properties start (point) (list 'agent-dash-row row
                                                         'agent-dash-key (plist-get row :key)
                                                         'mouse-face 'highlight))
                (when (gethash (plist-get row :key) agent-dash-hub--marks)
                  (overlay-put (make-overlay start (1- (point))) 'face
                               'agent-dash-hub-delete-face))))))))
    (goto-char (point-min))
    (let ((match (and key (text-property-search-forward 'agent-dash-key key #'equal))))
      (if match
          (progn (goto-char (prop-match-beginning match)) (move-to-column column))
        (agent-dash-hub--first-row)))
    (agent-dash-hub--highlight)))

(defun agent-dash-hub--first-row ()
  "Move to the first session row, if any."
  (goto-char (point-min))
  (when-let* ((match (text-property-search-forward 'agent-dash-row nil
                                                   (lambda (_ v) v))))
    (goto-char (prop-match-beginning match))))

(defun agent-dash-hub--highlight ()
  "Highlight the row under point."
  (when (derived-mode-p 'agent-dash-hub-mode)
    (remove-overlays (point-min) (point-max) 'agent-dash-current t)
    (when (get-text-property (point) 'agent-dash-row)
      (let ((overlay (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put overlay 'agent-dash-current t)
        (overlay-put overlay 'face 'agent-dash-hub-current-row-face)
        (overlay-put overlay 'priority -1)))))

(defun agent-dash-hub--redisplay ()
  "Re-render every hub buffer, for example after a summary changed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-dash-hub-mode)
        (agent-dash-hub--render)))))

(remove-hook 'agent-dash-summary-update-hook #'agent-dash-hub--redisplay)
(add-hook 'agent-dash-summary-update-hook #'agent-dash-hub--schedule-redisplay)

(defvar agent-dash-hub--render-timer nil
  "Timer merging data and layout changes into a single hub redraw.")

(defun agent-dash-hub--resize (_window)
  "Schedule a cached redraw when the visible hub's effective width changes."
  (unless (eql agent-dash-hub--width (agent-dash-hub--window-width))
    (agent-dash-hub--schedule-redisplay)))

(defun agent-dash-hub--schedule-redisplay ()
  "Merge bursts of worker, summary and layout updates into one redraw."
  (unless (timerp agent-dash-hub--render-timer)
    (setq agent-dash-hub--render-timer
          (run-at-time 0.05 nil
                       (lambda ()
                         (setq agent-dash-hub--render-timer nil)
                         (agent-dash-hub--redisplay))))))

(defun agent-dash-hub-refresh (&optional done)
  "Reread sessions in isolated workers; call DONE after all sources finish.
Keep old rows usable while loading.  Repeated requests share active workers."
  (interactive)
  (cl-incf agent-dash-hub--generation)
  (let ((pending (length agent-dash-backends)))
    (if (zerop pending)
        (when done (funcall done))
      (dolist (backend agent-dash-backends)
        (agent-dash-hub--load
         backend (when done (lambda (_result)
                              (when (zerop (cl-decf pending)) (funcall done))))))))
  (agent-dash-hub--redisplay))

;;;; Navigation and filters

(defun agent-dash-hub--row-at-point ()
  "Return the row at point, or signal."
  (or (get-text-property (point) 'agent-dash-row) (user-error "请先选择一条会话")))

(defun agent-dash-hub--selection ()
  "Return the selection table, including in Hub buffers opened before reload."
  (or agent-dash-hub--selected
      (setq agent-dash-hub--selected (make-hash-table :test #'equal))))

(defun agent-dash-hub-toggle-selection ()
  "Toggle selection of the current row and advance to the next session."
  (interactive)
  (let ((key (plist-get (agent-dash-hub--row-at-point) :key))
        (selected (agent-dash-hub--selection)))
    (if (gethash key selected)
        (remhash key selected)
      (puthash key t selected))
    (when-let* ((next (save-excursion
                        (forward-line 1)
                        (text-property-not-all (point) (point-max) 'agent-dash-row nil))))
      (goto-char next))
    (agent-dash-hub--render)))

(defun agent-dash-hub-select-all ()
  "Select every loaded session passing the filters, including folded rows."
  (interactive)
  (let ((selected (agent-dash-hub--selection)))
    (dolist (row (agent-dash-hub--visible))
      (puthash (plist-get row :key) t selected)))
  (agent-dash-hub--render))

(defun agent-dash-hub-clear-selection ()
  "Clear this Hub's selection."
  (interactive)
  (clrhash (agent-dash-hub--selection))
  (agent-dash-hub--render))

(defun agent-dash-hub--action-rows ()
  "Return selected sessions in this view, or the session at point."
  (if (and agent-dash-hub--selected (> (hash-table-count agent-dash-hub--selected) 0))
      (seq-filter (lambda (row) (gethash (plist-get row :key) agent-dash-hub--selected))
                  (agent-dash-hub--visible))
    (list (agent-dash-hub--row-at-point))))

(defun agent-dash-hub--goto (key)
  "Move to the row or group KEY."
  (goto-char (point-min))
  (when-let* ((match (text-property-search-forward 'agent-dash-key key #'equal)))
    (goto-char (prop-match-beginning match))))

(defun agent-dash-hub-next-entry (&optional count)
  "Move COUNT rows or group headers forward."
  (interactive "p")
  (let ((step (if (< (or count 1) 0) -1 1)))
    (dotimes (_ (abs (or count 1)))
      (let ((origin (point)) (key (get-text-property (point) 'agent-dash-key)) found)
        (while (and (not found) (zerop (forward-line step)))
          (let ((next (get-text-property (point) 'agent-dash-key)))
            (when (and next (not (equal next key))) (setq found t))))
        (unless found (goto-char origin))))))

(defun agent-dash-hub-previous-entry (&optional count)
  "Move COUNT rows or group headers backward."
  (interactive "p")
  (agent-dash-hub-next-entry (- (or count 1))))

(defun agent-dash-hub-next-project (&optional count)
  "Move COUNT project headers forward, including folded projects.
With a negative COUNT, move backward.  Stop at the list boundaries."
  (interactive "p")
  (unless (eq agent-dash-hub--grouping 'project)
    (user-error "请先按 t 切换到项目分组视图"))
  (let ((step (if (< (or count 1) 0) -1 1)))
    (dotimes (_ (abs (or count 1)))
      (let ((origin (point)) found)
        (while (and (not found) (zerop (forward-line step)))
          (when (get-text-property (point) 'agent-dash-group)
            (setq found t)))
        (unless found (goto-char origin))))))

(defun agent-dash-hub-previous-project (&optional count)
  "Move COUNT project headers backward, including folded projects."
  (interactive "p")
  (agent-dash-hub-next-project (- (or count 1))))

(defun agent-dash-hub-jump-project ()
  "Choose a filtered project and jump to its header, even when folded.
Switch to project grouping if necessary, without changing filters or folds."
  (interactive)
  (let* ((projects (let ((agent-dash-hub--grouping 'project))
                     (delete-dups (mapcar #'agent-dash-hub--group-name
                                          (agent-dash-hub--visible)))))
         (project (progn
                    (unless projects (user-error "当前视图没有项目"))
                    (completing-read "跳转到项目: " projects nil t))))
    (unless (eq agent-dash-hub--grouping 'project)
      (setq agent-dash-hub--grouping 'project)
      (agent-dash-hub--render))
    (agent-dash-hub--goto (list 'group project))))

(defun agent-dash-hub-toggle-group ()
  "Fold or unfold the group at point."
  (interactive)
  (unless agent-dash-hub--grouping (user-error "时间排序模式没有可折叠的分组"))
  (let ((name (or (get-text-property (point) 'agent-dash-group)
                  (agent-dash-hub--group-name (agent-dash-hub--row-at-point)))))
    (puthash name (not (gethash name agent-dash-hub--collapsed)) agent-dash-hub--collapsed)
    (agent-dash-hub--render)
    (agent-dash-hub--goto (list 'group name))))

(defun agent-dash-hub-toggle-all-groups ()
  "Fold all groups in the current view, or unfold them if all are folded."
  (interactive)
  (unless agent-dash-hub--grouping (user-error "时间排序模式没有可折叠的分组"))
  (when-let* ((rows (agent-dash-hub--visible)))
    (let* ((names (delete-dups (mapcar #'agent-dash-hub--group-name rows)))
           (fold (seq-some (lambda (name) (not (gethash name agent-dash-hub--collapsed)))
                           names))
           (row (get-text-property (point) 'agent-dash-row)))
      (dolist (name names)
        (if fold
            (puthash name t agent-dash-hub--collapsed)
          (remhash name agent-dash-hub--collapsed)))
      (agent-dash-hub--render)
      (when (and fold row)
        (agent-dash-hub--goto (list 'group (agent-dash-hub--group-name row)))))))

(defun agent-dash-hub-filter-agent-to (backend)
  "Show only BACKEND (nil for all) and jump to its newest session."
  (setq agent-dash-hub--agent backend)
  (let ((first (car (agent-dash-hub--visible))))
    (when first (remhash (agent-dash-hub--group-name first) agent-dash-hub--collapsed))
    (agent-dash-hub--render)
    (if first
        (agent-dash-hub--goto (plist-get first :key))
      (message "没有符合当前条件的 %s 会话；f c 恢复默认" (or backend "")))))

(defun agent-dash-hub-filter-all-agents ()
  "Show every agent."
  (interactive)
  (agent-dash-hub-filter-agent-to nil))

(defun agent-dash-hub-filter-project ()
  "Filter by a project path or path fragment."
  (interactive)
  (let ((choice (completing-read
                 "项目路径（可输入片段）："
                 (cons "全部" (delete-dups (delq nil (mapcar (lambda (r) (plist-get r :root))
                                                             (agent-dash-hub--all)))))
                 nil nil nil nil agent-dash-hub--project)))
    (setq agent-dash-hub--project (unless (or (equal choice "全部") (string-empty-p choice)) choice))
    (agent-dash-hub--render)))

(defun agent-dash-hub-toggle-live ()
  "Toggle showing only live sessions, refreshing the inventory when enabled."
  (interactive)
  (setq agent-dash-hub--live-only (not agent-dash-hub--live-only))
  (if agent-dash-hub--live-only
      (agent-dash-hub-refresh)
    (agent-dash-hub--render)))

(defun agent-dash-hub-toggle-hidden ()
  "Toggle showing sessions that are never summarized."
  (interactive)
  (setq agent-dash-hub--show-hidden (not agent-dash-hub--show-hidden))
  (agent-dash-hub--render))

(defun agent-dash-hub-group-by-agent ()
  "Group sessions by agent."
  (interactive)
  (setq agent-dash-hub--grouping 'agent)
  (clrhash agent-dash-hub--collapsed)
  (agent-dash-hub--render))

(defun agent-dash-hub-sort-by-time ()
  "Toggle between newest-first order and project groups."
  (interactive)
  (setq agent-dash-hub--grouping (if agent-dash-hub--grouping nil 'project))
  (clrhash agent-dash-hub--collapsed)
  (agent-dash-hub--render))

(defun agent-dash-hub-clear-filters ()
  "Restore the default view."
  (interactive)
  (setq agent-dash-hub--agent nil agent-dash-hub--project nil agent-dash-hub--live-only nil
        agent-dash-hub--show-hidden nil agent-dash-hub--grouping agent-dash-hub-group-by)
  (clrhash agent-dash-hub--collapsed)
  (agent-dash-hub--render))

(defvar vertico-group-format)

(defun agent-dash-hub-search-all ()
  "Pick one of the visible sessions by any of its text and jump to it.
Candidates keep the list order and show the table header as their group."
  (interactive)
  (let* ((visible (agent-dash-hub--visible))
         (groups (make-hash-table :test #'equal)) order
         (layout (agent-dash-hub--layout visible t))
         (header (string-trim-right (agent-dash-hub--header layout) "\n"))
         rows choices)
    (dolist (row visible)
      (let ((name (agent-dash-hub--group-name row)))
        (unless (gethash name groups) (push name order))
        (push row (gethash name groups))))
    (setq rows (mapcan (lambda (name) (reverse (gethash name groups))) (nreverse order)))
    (setq choices (mapcar (lambda (row)
                            (cons (propertize
                                   (string-join (list (symbol-name (plist-get row :backend))
                                                      (plist-get row :id)
                                                      (or (plist-get row :root) "")
                                                      (agent-dash-hub--summary-text row)
                                                      (agent-dash-hub--first-text row)
                                                      (agent-dash-hub--last-text row))
                                                " ")
                                   'display (agent-dash-hub--label row layout))
                                  row))
                          rows))
    (unless choices (user-error "没有可搜索的会话"))
    (let* ((vertico-group-format "%s")
           (table (lambda (string predicate action)
                    (if (eq action 'metadata)
                        `(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity)
                                   (group-function . ,(lambda (candidate transform)
                                                        (if transform candidate header))))
                      (complete-with-action action choices string predicate))))
           (row (cdr (assoc (completing-read "搜索当前会话：" table nil t) choices))))
      (remhash (agent-dash-hub--group-name row) agent-dash-hub--collapsed)
      (agent-dash-hub--render)
      (agent-dash-hub--goto (plist-get row :key)))))

;;;; Session commands

(defun agent-dash-hub--show (buffer)
  "Show BUFFER in the agent workspace without hiding other windows."
  (agent-dash-pop-to-buffer buffer))

(defun agent-dash-hub-open-row (row)
  "Open ROW: switch to its live chat, or resume it."
  (let ((chat (agent-dash-hub--chat (plist-get row :backend) (plist-get row :id))))
    (if chat
        (agent-dash-hub--show (agent-dash-session-buffer chat))
      (when (plist-get row :missing)
        (user-error "项目目录不存在：%s；按 D 重定向" (plist-get row :root)))
      (agent-dash-open (plist-get row :backend) (or (plist-get row :root) default-directory)
                       (plist-get row :id)))))

(defun agent-dash-hub-open ()
  "Open the session at point, or switch to its live chat."
  (interactive)
  (agent-dash-hub-open-row (agent-dash-hub--row-at-point)))

(defun agent-dash-hub--new (backend)
  "Choose a project directory and start a BACKEND session there."
  (let* ((row (get-text-property (point) 'agent-dash-row))
         (group-root (get-text-property (point) 'agent-dash-project-root))
         (initial (file-name-as-directory
                   (or (and row (plist-get row :root) (not (plist-get row :missing))
                            (plist-get row :root))
                       (and group-root (file-directory-p group-root) group-root)
                       default-directory)))
         (directory (read-directory-name
                     (format "%s 项目目录：" (cadr (assq backend agent-dash-hub--agents)))
                     initial nil nil)))
    (when (string-empty-p directory) (user-error "项目目录不能为空"))
    (setq directory (file-name-as-directory (expand-file-name directory)))
    (when (file-remote-p directory) (user-error "请选择本地项目目录"))
    (unless (file-directory-p directory) (make-directory directory t))
    (agent-dash-open backend directory)))

(defun agent-dash-hub-copy-id ()
  "Copy the full session id at point."
  (interactive)
  (let ((id (plist-get (agent-dash-hub--row-at-point) :id)))
    (kill-new id)
    (message "已复制完整 session ID: %s" id)))

(defun agent-dash-hub-copy-project ()
  "Copy the project directory of the session at point."
  (interactive)
  (let ((root (or (plist-get (agent-dash-hub--row-at-point) :root)
                  (user-error "该会话未记录项目目录"))))
    (kill-new root)
    (message "已复制项目路径：%s" root)))

(defun agent-dash-hub--convert-command (row &optional destination)
  "Build the command for ROW and DESTINATION (nil for Pi, `dsh' or `export')."
  (let ((source (plist-get row :file)) (root (plist-get row :root))
        (backend (plist-get row :backend)))
    (unless (memq backend agent-dash-hub--convert-sources)
      (user-error "不支持从 %s 转换" backend))
    (unless (and source (file-name-absolute-p source) (not (file-remote-p source))
                 (file-regular-p source) (file-readable-p source))
      (user-error "找不到可读的本地会话文件：%s" source))
    (unless (and root (file-name-absolute-p root) (not (file-remote-p root)))
      (user-error "缺少本地项目路径：%s" root))
    (let ((migrate (and (eq backend 'claude) (not (eq destination 'export)))))
      (when (and migrate
                 (or (agent-dash-hub-live-p row)
                     (agent-dash-holder-alive-p
                      (agent-dash-holder-dir backend (plist-get row :id)))))
        (user-error "%s 正在运行或已打开，请关闭后再迁移" (plist-get row :key)))
      (append (list "node" (pcase destination
                             ('dsh agent-dash-hub--dsh-migrate-file)
                             ('export agent-dash-hub--dsh-export-file)
                             (_ agent-dash-hub--convert-file))
                    (symbol-name backend) (expand-file-name source) (plist-get row :id)
                    (expand-file-name root) (expand-file-name agent-dash-pi-sessions-directory)
                    (expand-file-name "conversion-archives" agent-dash-directory))
              (when (and migrate (null destination)) '("--migrate-claude"))))))

(defun agent-dash-hub--convert-result (text destination)
  "Decode converter output TEXT for DESTINATION into callback arguments."
  (let* ((reply (agent-dash-json-read text))
         (file (agent-dash-jget reply "file"))
         (id (agent-dash-jget reply "id"))
         (archive (agent-dash-jget reply "archive"))
         (warnings (agent-dash-jget reply "warnings"))
         (notes (agent-dash-jget reply "notes"))
         (migration (agent-dash-jget reply "migration")))
    (unless (and (stringp file) (stringp id) (stringp archive))
      (error "转换器返回的会话信息不完整"))
    (list (or migration t)
          (propertize
           (concat (pcase destination
                     ('dsh (format "DSH 会话 %s\n  导入包 %s" id file))
                     ('export (format "导入包 %s" file))
                     (_ (format "%s  %s" id file)))
                   (format "\n  归档 %s" archive)
                   (when-let* ((workspace (agent-dash-jget reply "workspaceId")))
                     (format "\n  工作区 %s" workspace))
                   (pcase migration
                     ("moved" "\n  Claude 原件已迁出")
                     ("retained"
                      (format "\n  ⚠ %s，Claude 原件保留：%s"
                              (if (eq destination 'dsh) "DSH 会话已验证" "Pi 已生成")
                              (agent-dash-jget reply "migrationError"))))
                   (mapconcat (lambda (w) (format "\n  ⚠ %s" w)) warnings "")
                   (when notes
                     (format "\n  仅归档：%d 类记录\n    %s" (length notes)
                             (string-join notes "\n    "))))
           'agent-dash-warnings warnings)
          id)))

(defun agent-dash-hub--convert-one (row done &optional destination)
  "Convert ROW to DESTINATION, then call DONE with status, details and id."
  (let* ((command (agent-dash-hub--convert-command row destination))
         (credentials
          (when (eq destination 'dsh)
            (require 'agent-dash-dsh)
            (if agent-dash-dsh--host
                (agent-dash-dsh--call "deepseekChatImport/limits" (make-hash-table))
              (agent-dash-dsh--login))
            (json-serialize agent-dash-dsh--host)))
         (process-environment
          (if (and (eq (plist-get row :backend) 'claude) (not (eq destination 'export)))
              (cons (concat "CLAUDE_CONFIG_DIR="
                            (expand-file-name agent-dash-claude-config-directory))
                    process-environment)
            process-environment))
         (output (generate-new-buffer " *agent-dash-converter*"))
         (errors (generate-new-buffer " *agent-dash-converter-errors*"))
         (default-directory (file-name-directory agent-dash-hub--convert-file))
         process)
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "agent-dash-converter" :command command :buffer output :stderr errors
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :sentinel
                 (lambda (proc event)
                   (when (memq (process-status proc) '(exit signal))
                     (let ((result
                            (condition-case failure
                                (if (zerop (process-exit-status proc))
                                    (with-current-buffer output
                                      (agent-dash-hub--convert-result (buffer-string) destination))
                                  (list nil (format "%s %s" (string-trim event)
                                                    (with-current-buffer errors
                                                      (string-trim (buffer-string))))))
                              (error (list nil (error-message-string failure))))))
                       (kill-buffer output)
                       (kill-buffer errors)
                       (apply done result))))))
          (when credentials
            (process-send-string process credentials)
            (process-send-eof process))
          process)
      (error
       (when process (set-process-sentinel process #'ignore) (delete-process process))
       (kill-buffer output) (kill-buffer errors) (signal (car err) (cdr err))))))

(defun agent-dash-hub--reload-after-conversion (backend &optional callback)
  "Load BACKEND after any pre-conversion reader, then call CALLBACK."
  (if (gethash (list backend 'sessions nil) agent-dash-history--jobs)
      (agent-dash-history-request backend 'sessions
                                  (lambda (_) (agent-dash-hub--load backend callback)))
    (agent-dash-hub--load backend callback)))

(defvar-local agent-dash-hub--report-total 0)
(defvar-local agent-dash-hub--report-success 0)
(defvar-local agent-dash-hub--report-failed 0)
(defvar-local agent-dash-hub--report-kept 0)
(defvar-local agent-dash-hub--report-warned 0)

(define-derived-mode agent-dash-hub-report-mode special-mode "转换报告"
  "View the results of a Hub conversion batch.")

(defun agent-dash-hub-report-toggle ()
  "Expand or collapse the conversion under point."
  (interactive)
  (let ((detail (or (get-text-property (line-beginning-position) 'agent-dash-detail)
                    (seq-find (lambda (o) (overlay-get o 'agent-dash-detail))
                              (overlays-at (point))))))
    (when detail
      (goto-char (overlay-start detail))
      (forward-line -1)
      (overlay-put detail 'invisible (not (overlay-get detail 'invisible))))))

(dolist (key '("RET" "TAB" "<tab>"))
  (define-key agent-dash-hub-report-mode-map (kbd key) #'agent-dash-hub-report-toggle))

(defun agent-dash-hub--report-warning (warning)
  "Summarize one converter WARNING for a collapsed row."
  (cond
   ;; Older reports mixed administrative records with conversion warnings.
   ((string-match-p
     (rx (or (seq "Claude " (or "last-prompt" "mode" "permission-mode" "metadata user"
                                "file-history-snapshot" "atis-latch" "api-request" "cost-state"
                                "session-owner" "ai-title" "tools-used" "file-history-delta"
                                "worktree-state" "relocated") " record")
             (seq "attachment " (or "hook_success" "environment" "model" "output_style_instructions"
                                    "deferred_tools_delta" "agent_listing_delta"
                                    "mcp_instructions_delta"
                                    "skill_listing" "total_tokens_reminder" "output_style"
                                    "hook_additional_context"
                                    "instructions" "session_context" "date" "credential_org"
                                    "remote_session_change" "prompt_snapshot" "auto_mode"
                                    "silent_turn_reminder"
                                    "deferred_tools_record" "command_permissions") word-end)))
     warning) nil)
   ((string-match-p "inactive Claude branch\\|outside the final parentUuid chain" warning)
    (format "当前上下文外%s条记录仅归档%s"
            (if (string-match "(\\([0-9]+\\))\\'" warning) (match-string 1 warning) "部分")
            (if (string-match-p "compact_boundary" warning) "（含压缩前历史或其他分支）" "")))
   ((string-match-p "sidechain" warning) "旁支记录仅归档")
   ((string-match-p "tool calls and results rendered" warning) "工具记录转为文本")
   ((string-match-p "archived .*tool" warning) "部分工具记录仅归档")
   ((string-match-p "attachment\\|Source image\\|archived content block .*image" warning)
    "部分附件仅归档")
   ((string-match-p "replacement_history" warning) "早期历史仅归档，已恢复压缩后的上下文")
   ((string-match-p "encrypted" warning) "加密内容仅归档")
   ((string-match-p "archived Claude system" warning) "系统记录仅归档")
   ((string-match-p "archived\\|only in original archive" warning) "部分记录仅归档")
   ((string-match-p "missing assistant\\|attributes imported replies" warning) "模型或用量信息不完整")
   ((string-match-p "reasoning rendered" warning) "推理记录转为文本")
   (t "其他警示见详情")))

(defun agent-dash-hub--report-start (action total)
  "Initialize the current report for ACTION on TOTAL sessions."
  (agent-dash-hub-report-mode)
  (setq agent-dash-hub--report-total total)
  (let ((inhibit-read-only t))
    (insert (format "%s · %d 条 · 进行中\nRET / TAB 展开或收起当前条目\n" action total))
    (when (equal action "导出 DSH 导入包")
      (insert "在 DSH 中打开「DeepSeek 网站」导入器，展开条目查看 ZIP，选择目标工作区。\n"))
    (goto-char (point-min))))

(defun agent-dash-hub--report-add (row target ok text id warnings)
  "Append ROW's result for TARGET, with status OK, TEXT, ID and WARNINGS."
  (let* ((inhibit-read-only t)
         (source (plist-get row :id)) (backend (plist-get row :backend))
         (kept (and ok (not (equal ok "moved"))))
         (labels (delq nil (delete-dups (mapcar #'agent-dash-hub--report-warning warnings))))
         (priorities '("当前上下文外" "旁支" "部分工具" "工具记录" "部分附件"))
         (rank (lambda (label)
                 (or (cl-position-if (lambda (p) (string-prefix-p p label)) priorities)
                     (length priorities))))
         (warned (or labels (equal ok "retained"))))
    (setq labels (cl-stable-sort labels #'< :key rank))
    (when (string-match-p "Claude 源记录包含本地命令，未发现普通问答" text)
      (push "仅本地命令，未发现普通问答" labels))
    (if ok (cl-incf agent-dash-hub--report-success) (cl-incf agent-dash-hub--report-failed))
    (when kept (cl-incf agent-dash-hub--report-kept))
    (when warned (cl-incf agent-dash-hub--report-warned))
    (save-excursion
      (goto-char (point-min))
      (search-forward " 条 · ")
      (delete-region (point) (line-end-position))
      (insert (format "%s · 成功 %d，失败 %d，成功项中源保留 %d，有警示 %d 条"
                      (if (= agent-dash-hub--report-total
                             (+ agent-dash-hub--report-success agent-dash-hub--report-failed))
                          "完成" "进行中")
                      agent-dash-hub--report-success agent-dash-hub--report-failed
                      agent-dash-hub--report-kept agent-dash-hub--report-warned))
      (goto-char (point-max))
      (let ((start (point)))
        (insert (format "%s %s → %s:%s  %s"
                        (cond ((null ok) "✗") ((equal ok "retained") "⚠") (t "✓"))
                        (if (and backend source)
                            (format "%s:%s" backend (agent-dash--one-line source 9))
                          (plist-get row :key))
                        target (if id (agent-dash--one-line id 9) "—")
                        (cond ((not ok)
                               (concat "失败 · " (agent-dash--one-line
                                                  (car (split-string text "Original archived at "))
                                                  100)))
                              ((equal ok "retained") "迁出未完成，源保留")
                              (kept "源保留") (t "已迁出"))))
        (when labels (insert " · " (string-join (seq-take labels 2) "、")))
        (insert "\n")
        (let ((body (point)))
          (when source (insert (format "  来源 %s:%s\n" backend source)))
          (when-let* ((file (plist-get row :file))) (insert "  源文件 " file "\n"))
          (when id (insert (format "  目标 %s:%s\n" target id)))
          (insert "  " text "\n")
          (let ((detail (make-overlay body (point))))
            (overlay-put detail 'invisible t)
            (overlay-put detail 'agent-dash-detail t)
            (put-text-property start body 'agent-dash-detail detail)))))))

(defun agent-dash-hub-compact-report ()
  "Fold a completed legacy conversion report in the current buffer."
  (interactive)
  (unless (derived-mode-p 'agent-dash-hub-report-mode)
    (let (action total entries)
      (save-excursion
        (goto-char (point-min))
        (unless (looking-at "^\\(转换到 Pi\\|导入 DSH\\|导出 DSH 导入包\\) · \\([0-9]+\\) 条$")
          (user-error "当前缓冲区不是旧版转换报告"))
        (setq action (match-string 1) total (string-to-number (match-string 2)))
        (let ((header "^\\([✓⚠✗]\\) \\(claude\\|codex\\):\\([^ \n]+\\)  "))
          (while (re-search-forward header nil t)
            (let* ((status (match-string 1)) (backend (match-string 2)) (source (match-string 3))
                   (text (buffer-substring
                          (point) (save-excursion
                                    (if (re-search-forward header nil t)
                                        (max (point-min) (1- (line-beginning-position)))
                                      (point-max)))))
                   (ok (cond ((equal status "✗") nil) ((equal status "⚠") "retained")
                             ((string-match-p "\n  Claude 原件已迁出" text) "moved") (t t)))
                   (target (pcase action ("转换到 Pi" "pi") ("导入 DSH" "dsh") (_ "ZIP")))
                   (id (and ok (pcase target
                                 ("pi" (and (string-match "\\`\\([^ \n]+\\)  " text)
                                            (match-string 1 text)))
                                 ("dsh" (and (string-match "\\`DSH 会话 \\([^ \n]+\\)" text)
                                             (match-string 1 text))))))
                   warnings)
              (dolist (line (split-string text "\n"))
                (when (and (string-prefix-p "  ⚠ " line)
                           (not (string-match-p "Claude 原件保留：" line)))
                  (push (substring line 4) warnings)))
              (push (list (list :backend backend :id source) target ok
                          (string-trim-right text) id (nreverse warnings)) entries)))))
      (unless (= (length entries) total) (user-error "报告未写完或格式不匹配"))
      (let ((inhibit-read-only t))
        (atomic-change-group
          (erase-buffer)
          (agent-dash-hub--report-start action total)
          (dolist (entry (nreverse entries)) (apply #'agent-dash-hub--report-add entry)))))))

(defun agent-dash-hub--convert-rows (rows &optional destination)
  "Convert ROWS serially to DESTINATION (nil for Pi, `dsh' or `export')."
  (unless rows (user-error "没有可转换的会话"))
  (let* ((action (pcase destination ('dsh "导入 DSH") ('export "导出 DSH 导入包") (_ "转换到 Pi")))
         (backend (or destination 'pi))
         (report (generate-new-buffer (format "*Agent Dash · %s*" action)))
         (success 0) (retained 0) moved (total (length rows))
         (hub (current-buffer))
         (source (plist-get (car rows) :key))
         (follow (and (not (eq destination 'export)) (= total 1)
                      (derived-mode-p 'agent-dash-hub-mode)
                      (or (equal source (get-text-property (point) 'agent-dash-key))
                          (gethash source (agent-dash-hub--selection)))
                      (list :source source :focus (agent-dash-hub--focus)))))
    (with-current-buffer report
      (agent-dash-hub--report-start action total))
    (display-buffer report)
    (cl-labels
        ((next ()
           (if-let* ((row (pop rows)))
               (let ((done (lambda (ok text &optional id)
                             (when ok
                               (cl-incf success)
                               (when (and follow id)
                                 (setq follow (plist-put follow :target
                                                         (format "%s:%s" backend id)))))
                             (pcase ok
                               ("retained" (cl-incf retained)
                                (unless (eq destination 'dsh) (setq follow nil)))
                               ("moved" (push (plist-get row :key) moved)))
                             (when (buffer-live-p report)
                               (with-current-buffer report
                                 (agent-dash-hub--report-add
                                  row (if (eq backend 'export) "ZIP" backend) ok text id
                                  (and (> (length text) 0)
                                       (get-text-property 0 'agent-dash-warnings text)))))
                             (run-at-time 0 nil #'next))))
                 (condition-case err (agent-dash-hub--convert-one row done destination)
                   (error (funcall done nil (error-message-string err)))))
             (when (and (> success 0) (not (eq destination 'export)))
               (when (and follow (buffer-live-p hub))
                 (with-current-buffer hub (setq agent-dash-hub--follow-import follow)))
               (agent-dash-hub--reload-after-conversion
                backend
                (lambda (_result)
                  (when (and follow (buffer-live-p hub))
                    (with-current-buffer hub
                      (when (eq follow agent-dash-hub--follow-import)
                        (agent-dash-hub--render)
                        (setq agent-dash-hub--follow-import nil))))
                  (when (or moved (and (eq destination 'dsh) (> retained 0)))
                    (when (buffer-live-p hub)
                      (with-current-buffer hub
                        (when agent-dash-hub--marks
                          (dolist (key moved) (remhash key agent-dash-hub--marks)))))
                    (agent-dash-hub--reload-after-conversion 'claude)))))
             (message "%s完成：成功 %d，失败 %d%s" action success (- total success)
                      (if (or moved (> retained 0))
                          (format "，Claude 原件已迁出 %d、已保留 %d" (length moved) retained)
                        "")))))
      (next))
    report))

(defun agent-dash-hub-convert-session ()
  "Convert selected sessions, or the session at point, to Pi."
  (interactive)
  (agent-dash-hub--convert-rows (agent-dash-hub--action-rows)))

(defun agent-dash-hub-import-dsh ()
  "Import selected sessions, or the session at point, into the configured DSH Host."
  (interactive)
  (agent-dash-hub--convert-rows (agent-dash-hub--action-rows) 'dsh))

(defun agent-dash-hub-export-dsh ()
  "Export selected sessions, or the session at point, for DSH import."
  (interactive)
  (agent-dash-hub--convert-rows (agent-dash-hub--action-rows) 'export))

;;;; Native backups

(defcustom agent-dash-hub-dsh-backup-directory (or (getenv "DSH_HOME") "~/.dsh")
  "DSH data root containing sessions and storages."
  :type 'directory)

(defun agent-dash-hub--backup-local (path)
  "Return expanded local PATH, rejecting remote paths."
  (when (file-remote-p path) (user-error "备份只支持本地路径"))
  (expand-file-name path))

(defun agent-dash-hub--backup-run (args done)
  "Run backup ARGS asynchronously and call DONE with result or error."
  (let ((out (generate-new-buffer " *agent-dash-backup*"))
        (err (generate-new-buffer " *agent-dash-backup-errors*"))
        (default-directory (file-name-directory agent-dash-hub--backup-file)))
    (condition-case failure
        (make-process
         :name "agent-dash-backup"
         :command (append (list "python3" agent-dash-hub--backup-file) args)
         :buffer out :stderr err :connection-type 'pipe :coding 'utf-8-unix :noquery t
         :sentinel (lambda (process event)
                     (when (memq (process-status process) '(exit signal))
                       (let* ((diagnostic (with-current-buffer err (string-trim (buffer-string))))
                              (result (condition-case problem
                                          (cons (with-current-buffer out
                                                  (unless (zerop (buffer-size))
                                                    (agent-dash-json-read (buffer-string)))) nil)
                                        (error (cons nil (error-message-string problem))))))
                         (unless (zerop (process-exit-status process))
                           (let ((errors (agent-dash-jget (car result) "errors")))
                             (setcdr result
                                     (cond ((and (hash-table-p errors)
                                                 (> (hash-table-count errors) 0))
                                            (mapconcat (lambda (key)
                                                         (format "%s: %s" key (gethash key errors)))
                                                       (hash-table-keys errors) "；"))
                                           ((not (string-empty-p diagnostic)) diagnostic)
                                           (t (string-trim event))))))
                         (kill-buffer out) (kill-buffer err)
                         (funcall done (car result) (cdr result))))))
      (error (kill-buffer out) (kill-buffer err) (signal (car failure) (cdr failure))))))

(defun agent-dash-hub--backup-notices (result failure)
  "Return backend warnings and errors from RESULT, falling back to FAILURE."
  (let ((errors (agent-dash-jget result "errors")) lines)
    (dolist (backend '("codex" "pi" "dsh" "hermes"))
      (dolist (warning (agent-dash-jget result "backends" backend "warnings"))
        (push (format "%s 提示：%s" backend warning) lines)))
    (if (and (hash-table-p errors) (> (hash-table-count errors) 0))
        (maphash (lambda (backend detail)
                   (push (format "%s 错误：%s" backend detail) lines)) errors)
      (when failure (push failure lines)))
    (string-join (delete-dups (nreverse lines)) "\n")))

(defun agent-dash-hub--backup-show-report (title file notices)
  "Show a backup report with TITLE, FILE and NOTICES."
  (let ((buffer (get-buffer-create "*Agent Dash · 备份报告*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert title "\n" file "\n\n" notices "\n")
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)))

(defun agent-dash-hub--backup-rows (selected)
  "Return SELECTED rows, or all loaded rows, without silently dropping backends."
  (let* ((rows (agent-dash-hub--all)) (selection (agent-dash-hub--selection)))
    (when selected
      (when (zerop (hash-table-count selection)) (user-error "请先选择会话"))
      (setq rows (seq-filter (lambda (row) (gethash (plist-get row :key) selection)) rows))
      (unless (= (length rows) (hash-table-count selection))
        (user-error "选集含未加载的会话，请刷新后重选")))
    (unless rows (user-error "没有已加载的会话"))
    rows))

(defun agent-dash-hub--backup-homes (backends)
  "Return CLI home arguments for BACKENDS."
  (cl-mapcan
   (lambda (backend)
     (list "--home" (symbol-name backend)
           (agent-dash-hub--backup-local
            (pcase backend
              ('codex agent-dash-codex-directory)
              ('pi agent-dash-pi-sessions-directory)
              ('dsh agent-dash-hub-dsh-backup-directory)
              ('hermes agent-dash-hermes-directory)))))
   backends))

(defun agent-dash-hub--backup-export (selected)
  "Export SELECTED rows, or all loaded rows."
  (let* ((rows (agent-dash-hub--backup-rows selected))
         (unsupported (seq-remove
                       (lambda (row) (memq (plist-get row :backend) '(codex pi dsh hermes))) rows)))
    (when unsupported
      (let ((counts (mapconcat (lambda (backend)
                                 (format "%s %d" backend
                                         (seq-count (lambda (row)
                                                      (eq (plist-get row :backend) backend))
                                                    unsupported)))
                               (delete-dups (mapcar (lambda (row) (plist-get row :backend))
                                                    unsupported)) "、")))
        (unless (yes-or-no-p (format "不支持导出 %s；跳过这些会话并继续? " counts))
          (user-error "已取消备份")))
      (setq rows (seq-difference rows unsupported)))
    (unless rows (user-error "没有支持导出的会话"))
    (let* ((dir (agent-dash-hub--backup-local (read-directory-name "备份保存到文件夹：" nil nil t)))
           (base (expand-file-name (format-time-string "agent-dash-backup-%Y%m%d%H%M%S%1N") dir))
           (file (concat base ".zip"))
           (suffix 0)
           (backends (delete-dups (mapcar (lambda (row) (plist-get row :backend)) rows)))
           (homes (agent-dash-hub--backup-homes backends)))
      (while (or (file-exists-p file) (file-symlink-p file))
        (setq file (format "%s-%d.zip" base (cl-incf suffix))))
      (agent-dash-hub--backup-run
       (append (list "export" "--output" file) homes
               (cl-mapcan (lambda (row) (list "--session" (plist-get row :key))) rows))
       (lambda (result error)
         (let ((notices (agent-dash-hub--backup-notices result error))
               (title (if error "备份导出失败" (format "已导出所选 %d 个会话" (length rows)))))
           (if (string-empty-p notices) (message "%s：%s" title file)
             (agent-dash-hub--backup-show-report title file notices)
             (message "%s，详见备份报告" title)))))
      (message "正在后台导出 %d 个会话…" (length rows)))))

(defun agent-dash-hub-backup-export-selected ()
  "Export selected sessions."
  (interactive) (agent-dash-hub--backup-export t))

(defun agent-dash-hub-backup-export-all ()
  "Export all loaded sessions."
  (interactive) (agent-dash-hub--backup-export nil))

(defun agent-dash-hub--backup-active-ids ()
  "Return backend-qualified IDs known to be active."
  (let (ids)
    (dolist (backend '(codex pi dsh hermes))
      (dolist (row (plist-get (gethash backend agent-dash-hub--sources) :rows))
        (when (or (agent-dash-hub-live-p row)
                  (agent-dash-holder-alive-p (agent-dash-holder-dir backend (plist-get row :id))))
          (push (format "%s:%s" backend (plist-get row :id)) ids))))
    (dolist (session agent-dash--sessions)
      (when (and (memq (agent-dash-session-backend session) '(codex pi dsh hermes))
                 (buffer-live-p (agent-dash-session-buffer session))
                 (not (eq (agent-dash-session-state session) 'dead))
                 (agent-dash-data session :sid))
        (push (format "%s:%s" (agent-dash-session-backend session)
                      (agent-dash-data session :sid)) ids)))
    (sort (delete-dups ids) #'string<)))

(defun agent-dash-hub--backup-maps (project-dirs)
  "Resolve missing PROJECT-DIRS and return the backup CLI mapping arguments."
  (let ((dirs (sort (delete-dups (mapcar #'directory-file-name project-dirs)) #'string<))
        mappings args)
    (dolist (old dirs)
      (let ((local (and (file-name-absolute-p old) (not (file-remote-p old)))))
        (unless (and local (file-directory-p old))
          (if (and local (not (file-exists-p old))
                   (= ?c (read-char-choice
                          (format "项目目录 %s 缺失：[c] 按原路径新建，[m] 映射到本机目录 " old)
                          '(?c ?m))))
              (make-directory old t)
            (let ((new (agent-dash-hub--backup-local
                        (read-directory-name (format "%s 映射到：" old) nil nil t))))
              (unless (file-directory-p new) (user-error "目标目录不存在：%s" new))
              (push (cons old (directory-file-name new)) mappings))))))
    ;; A more specific project can retain its path under a remapped parent.
    (dolist (dir (reverse dirs))
      (let ((mapping (assoc dir mappings)))
        (when (or mapping (seq-some (lambda (pair)
                                      (string-prefix-p (file-name-as-directory (car pair)) dir))
                                    mappings))
          (setq args (append args (list "--map" dir (or (cdr mapping) dir)))))))
    args))

(defun agent-dash-hub-backup-import ()
  "Inspect a native backup before previewing it."
  (interactive)
  (let ((file (agent-dash-hub--backup-local (read-file-name "选择备份 ZIP：" nil nil t)))
        (hub (current-buffer)))
    (agent-dash-hub--backup-run
     (list "inspect" "--input" file)
     (lambda (result error)
       (if error (message "读取备份失败：%s" error)
         (let ((backends (agent-dash-jget result "backends")))
           (if (and (listp backends) backends
                    (seq-every-p (lambda (b) (member b '("codex" "pi" "dsh" "hermes"))) backends))
               (when (buffer-live-p hub)
                 (with-current-buffer hub
                   (agent-dash-hub--backup-preview file (mapcar #'intern backends)
                                                    (agent-dash-jget result "project_dirs"))))
             (message "读取备份失败：后端列表无效"))))))))

(defun agent-dash-hub--backup-preview (file backends project-dirs)
  "Resolve PROJECT-DIRS and preview FILE for BACKENDS before importing."
  (when (and (memq 'dsh backends)
             (not (yes-or-no-p "DSH 恢复期间必须停止目标 Host，确认已停止且不会重启? ")))
    (user-error "已取消 DSH 备份导入"))
  (let* ((homes (agent-dash-hub--backup-homes backends))
         (maps (agent-dash-hub--backup-maps project-dirs))
         (active (agent-dash-hub--backup-active-ids))
         (active-args (cl-mapcan (lambda (id) (list "--active-session" id)) active))
         (hub (current-buffer)))
    (agent-dash-hub--backup-run
     (append (list "preview" "--input" file) homes maps active-args)
     (lambda (result error)
       (if error
           (progn (agent-dash-hub--backup-show-report
                   "备份预览失败" file (agent-dash-hub--backup-notices result error))
                  (message "备份预览失败，详见备份报告"))
         (condition-case problem
             (let ((token (agent-dash-jget result "preview_token"))
                   (sessions (agent-dash-jget result "sessions"))
                   (report (get-buffer-create "*Agent Dash · 备份预览*")))
               (unless (and (stringp token) (listp sessions)) (error "备份预览结果不完整"))
               (with-current-buffer report
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (format "原生备份：%s\n" file))
                   (let ((count (lambda (action)
                                  (seq-count (lambda (session)
                                               (equal action (agent-dash-jget session "action")))
                                             sessions))))
                     (insert (format "新增 %d · 覆盖 %d · 相同跳过 %d · 使用中跳过 %d\n\n"
                                     (funcall count "create") (funcall count "overwrite")
                                     (funcall count "skip") (funcall count "busy"))))
                   (let ((notices (agent-dash-hub--backup-notices result nil)))
                     (unless (string-empty-p notices) (insert notices "\n\n")))
                   (dolist (session sessions)
                     (let ((backend (agent-dash-jget session "backend"))
                           (id (agent-dash-jget session "id"))
                           (action (agent-dash-jget session "action"))
                           (path (agent-dash-jget session "path")))
                       (unless (and (member backend '("codex" "pi" "dsh" "hermes"))
                                    (stringp id) (stringp path)
                                    (member action '("create" "overwrite" "skip" "busy")))
                         (error "备份预览条目不完整"))
                       (insert (format "%s  %s:%s  %s\n"
                                       (pcase action ("create" "新增") ("overwrite" "覆盖")
                                              ("busy" "使用中跳过") (_ "相同跳过")) backend id path))))
                   (special-mode)))
               (display-buffer report)
               (when (or (not (seq-some (lambda (session)
                                           (equal (agent-dash-jget session "action") "overwrite"))
                                         sessions))
                          (yes-or-no-p "覆盖前将保存回滚快照；确认按预览导入? "))
                 (unless (equal active (agent-dash-hub--backup-active-ids))
                   (error "活动会话已改变，请重新预览"))
                 (dolist (session sessions)
                   (when (and (member (agent-dash-jget session "action") '("create" "overwrite"))
                              (agent-dash-holder-alive-p
                               (agent-dash-holder-dir (intern (agent-dash-jget session "backend"))
                                                      (agent-dash-jget session "id"))))
                     (error "目标会话正在运行，请关闭后重新预览：%s" (agent-dash-jget session "id"))))
                 (agent-dash-hub--backup-run
                  (append (list "import" "--input" file "--preview-token" token)
                          homes maps active-args)
                  (lambda (reply failure)
                    (when (buffer-live-p report)
                      (with-current-buffer report
                        (let ((inhibit-read-only t))
                          (goto-char (point-max))
                          (insert (format "\n导入结果：%s\n" (if failure "有后端失败" "完成")))
                          (let ((notices (agent-dash-hub--backup-notices reply failure)))
                            (unless (string-empty-p notices) (insert notices "\n")))
                          (when (member "dsh" (agent-dash-jget reply "affected_backends"))
                            (insert "DSH 维护完成后，请自行重新启动 Host，再回到 Hub 按 g 刷新。\n"))
                          (dolist (backend '(codex pi dsh hermes))
                            (let* ((entry (agent-dash-jget reply "backends" (symbol-name backend)))
                                   (rollback (agent-dash-jget entry "rollback_path"))
                                   (archive (agent-dash-jget entry "rollback_archive_path")))
                              (dolist (item (list (cons (format "%s 回滚快照：" backend) rollback)
                                                  (cons "通过 B i 导入回滚包：" archive)))
                                (when (stringp (cdr item))
                                  (insert (car item))
                                  (insert-text-button (cdr item) 'follow-link t
                                                      'action (lambda (button)
                                                                (find-file (button-label button))))
                                  (insert "\n")))))))
                      (display-buffer report))
                    (when (buffer-live-p hub)
                      (dolist (backend (agent-dash-jget reply "affected_backends"))
                        (when (member backend '("codex" "pi" "hermes"))
                          (agent-dash-hub--reload-after-conversion (intern backend)))))
                    (message "备份导入%s" (if failure "有后端失败，详见备份预览" "完成"))))))
           (error (message "备份导入已停止：%s" (error-message-string problem)))))))
    (message "正在后台预览备份…")))

(defun agent-dash-hub-convert-project ()
  "Convert all loaded Claude and Codex sessions in the project at point."
  (interactive)
  (let ((root (or (get-text-property (point) 'agent-dash-project-root)
                  (plist-get (agent-dash-hub--row-at-point) :root)
                  (user-error "该会话未记录项目目录"))))
    (agent-dash-hub--convert-rows
     (seq-filter (lambda (row)
                   (and (equal root (plist-get row :root))
                        (memq (plist-get row :backend) agent-dash-hub--convert-sources)))
                 (agent-dash-hub--all)))))

(defun agent-dash-hub-convert-backend (backend)
  "Convert all loaded sessions from BACKEND to Pi."
  (interactive (list (intern (completing-read "转换哪个后端到 Pi？ "
                                              agent-dash-hub--convert-sources nil t))))
  (agent-dash-hub--convert-rows
   (seq-filter (lambda (row) (eq (plist-get row :backend) backend)) (agent-dash-hub--all))))

(defun agent-dash-hub--check-deletable (row)
  "Signal if ROW is live or its backend does not support deletion."
  (unless (plist-get (agent-dash-backend-capabilities (plist-get row :backend)) :delete)
    (user-error "%s 会话不支持删除" (plist-get row :backend)))
  (when (agent-dash-hub-live-p row)
    (user-error "%s 正在运行或已打开，不能删除" (plist-get row :key))))

(defun agent-dash-hub-mark-delete ()
  "Mark selected sessions, or the session at point, after checking every row."
  (interactive)
  (let ((rows (agent-dash-hub--action-rows)))
    (unless rows (user-error "选中的会话已不在当前筛选中"))
    (mapc #'agent-dash-hub--check-deletable rows)
    (dolist (row rows) (puthash (plist-get row :key) t agent-dash-hub--marks))
    (when (zerop (hash-table-count (agent-dash-hub--selection))) (agent-dash-hub-next-entry))
    (agent-dash-hub--render)
    (message "已标记 %d 条待删除；u 取消当前行标记，x 确认执行" (length rows))))

(defun agent-dash-hub-unmark-delete ()
  "Clear selection and any pending deletion mark on the session at point."
  (interactive)
  (let ((key (plist-get (agent-dash-hub--row-at-point) :key)))
    (remhash key (agent-dash-hub--selection))
    (remhash key agent-dash-hub--marks))
  (agent-dash-hub--render))

(defun agent-dash-hub-execute-deletions ()
  "Permanently delete the marked sessions after confirmation."
  (interactive)
  (let* ((confirmed (make-hash-table :test #'equal))
         (marked-p (lambda (row) (gethash (plist-get row :key) confirmed))))
    (dolist (row (agent-dash-hub--all))
      (let ((key (plist-get row :key)))
        (when (gethash key agent-dash-hub--marks) (puthash key t confirmed))))
    (let* ((count (hash-table-count confirmed))
           (outside (- count (seq-count marked-p (agent-dash-hub--visible)))))
      (when (zerop count) (user-error "没有标记待删除的会话"))
      (unless (yes-or-no-p (format "永久删除 %d 个标记会话（筛选外 %d 个，不可撤销）? " count outside))
        (user-error "已取消删除"))
      ;; A reader can publish new rows while the confirmation prompt is open.
      (let ((marked (seq-filter marked-p (agent-dash-hub--all))))
        (unless (= count (length marked)) (user-error "会话列表已变更，请重新确认"))
        (mapc #'agent-dash-hub--check-deletable marked)
        (unwind-protect
            (dolist (row marked)
              (agent-dash-backend-delete (plist-get row :backend) row)
              (remhash (plist-get row :key) agent-dash-hub--marks)
              (let ((source (gethash (plist-get row :backend) agent-dash-hub--sources)))
                (puthash (plist-get row :backend)
                         (plist-put source :rows (delq row (plist-get source :rows)))
                         agent-dash-hub--sources))
              (agent-dash-summary-forget row))
          (agent-dash-hub--render)))
      (message "已永久删除 %d 个会话" count))))

(defun agent-dash-hub-relocate-project (old new)
  "Show and open sessions recorded under directory OLD from NEW."
  (interactive
   (let* ((row (get-text-property (point) 'agent-dash-row))
          (old (read-directory-name "原项目目录（已改名/移动）：" (plist-get row :root)
                                    (plist-get row :root))))
     (list old (read-directory-name (format "%s 的新位置：" (abbreviate-file-name old)) nil nil t))))
  (let ((old (directory-file-name (expand-file-name old)))
        (new (directory-file-name (expand-file-name new))))
    (unless (file-directory-p new) (user-error "新位置必须是现有的本地目录"))
    (when (equal old new) (user-error "新旧目录相同"))
    (customize-save-variable 'agent-dash-hub-project-relocations
                             (cons (cons old new)
                                   (assoc-delete-all
                                    old (copy-alist agent-dash-hub-project-relocations))))
    (message "已保存：%s → %s" old new)
    (agent-dash-hub-refresh)))

(defun agent-dash-hub-summary-retry ()
  "Queue a new summary of the session at point."
  (interactive)
  (agent-dash-summary-requeue (list (agent-dash-hub--row-at-point)))
  (message "已重新排队；按后台规则生成"))

(defun agent-dash-hub-diagnostics ()
  "Show source failures and the summary scheduler state."
  (interactive)
  (let ((visible (length (agent-dash-hub--visible))) (total (length (agent-dash-hub--all))))
    (agent-dash-select-tab)
    (with-help-window "*agent-dash diagnostics*"
      (princ (format "显示 %d/已载入 %d；过滤/隐藏 %d。\n\n" visible total (- total visible)))
      (dolist (backend agent-dash-backends)
        (let ((source (gethash backend agent-dash-hub--sources)))
          (princ (format "%-7s %s；%d 条%s%s\n" backend (or (plist-get source :status) "未载入")
                         (length (plist-get source :rows))
                         (if (numberp (plist-get source :seconds))
                             (format "；后台读取 %.3fs" (plist-get source :seconds)) "")
                         (if (plist-get source :error)
                             (concat "\n  " (plist-get source :error))
                           "")))
          (dolist (warning (plist-get source :warnings))
            (princ (format "  %s\n" warning)))))
      (princ "\n")
      (princ (agent-dash-summary-describe))
      (dolist (row (agent-dash-hub--all))
        (when-let* ((error (plist-get (agent-dash-summary-entry row) :error)))
          (princ (format "  [%s] %s（失败 %s 次；r 重新排队）\n" (plist-get row :key) error
                         (plist-get (agent-dash-summary-entry row) :failures))))))))

(defun agent-dash-hub-quit ()
  "Leave the `agent-dash' tab without closing its buffers."
  (interactive)
  (if (and (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash")
           (cdr (tab-bar-tabs)))
      (tab-bar-switch-to-recent-tab)
    (quit-window)))

;;;; Details

(defcustom agent-dash-hub-message-width 100
  "Widest chat bubble in the details buffer, in columns."
  :type 'integer)

(defcustom agent-dash-hub-message-width-ratio 0.76
  "Largest share of the window one bubble may take."
  :type 'number)

(defvar-local agent-dash-hub--details-row nil)
(defvar-local agent-dash-hub--details-turns nil "Cached (ROLE . TEXT) list, or an error string.")
(defvar-local agent-dash-hub--details-width nil)
(defvar-local agent-dash-hub--details-expanded nil "Whether the metadata is shown.")

(defun agent-dash-hub--wrap (text width)
  "Return the display rows of TEXT wrapped at WIDTH columns, losing nothing."
  (mapcan (lambda (line)
            (let ((line (replace-regexp-in-string "\t" (make-string tab-width ?\s) line t t))
                  rows)
              (while (> (string-width line) width)
                (let* ((cut (length (truncate-string-to-width line width)))
                       (space (string-search " " (reverse (substring line 0 cut)))))
                  ;; Prefer breaking at a space in the second half of the row.
                  (when (and space (< space (/ cut 2))) (setq cut (- cut space)))
                  (push (substring line 0 (max 1 cut)) rows)
                  (setq line (substring line (max 1 cut)))))
              (nreverse (cons line rows))))
          (split-string text "\n")))

(defun agent-dash-hub--bubble (role text width)
  "Insert TEXT of ROLE as a chat bubble in a window WIDTH wide."
  (let* ((user (eq role 'user))
         (max-width (max 8 (min agent-dash-hub-message-width
                                (floor (* (max 12 (- width 4))
                                          agent-dash-hub-message-width-ratio)))))
         (rows (agent-dash-hub--wrap text (- max-width 4)))
         (label (if user "用户"
                  (upcase (symbol-name (plist-get agent-dash-hub--details-row :backend)))))
         (bubble (min max-width (max 18 (+ 4 (apply #'max 0 (mapcar #'string-width rows))))))
         (indent (make-string (if user (max 1 (- width bubble 2)) 2) ?\s))
         (face (if user 'agent-dash-hub-user-face 'agent-dash-hub-assistant-face))
         (heading (concat "  " label "  ")))
    (insert indent (propertize heading 'face (list :weight 'bold :inherit face)))
    (insert-text-button "复制" 'follow-link t 'face (list :underline t :inherit face)
                        'help-echo "复制原文，不含聊天排版"
                        'action (lambda (_) (kill-new text) (message "已复制原始消息")))
    (insert (propertize (make-string (max 0 (- bubble (string-width heading) 4)) ?\s) 'face face)
            "\n")
    (dolist (row rows)
      (insert indent
              (propertize (concat "  " row
                                  (make-string (max 0 (- bubble 2 (string-width row))) ?\s))
                          'face face)
              "\n"))
    (insert "\n")))

(defun agent-dash-hub--details-metadata ()
  "Return the full metadata text of the details row."
  (let* ((row agent-dash-hub--details-row) (entry (agent-dash-summary-entry row)))
    (concat (format "Agent: %s\nSession ID: %s\nProject: %s\nStorage path: %s\n"
                    (plist-get row :backend) (plist-get row :id)
                    (or (plist-get row :root) "unknown")
                    (or (plist-get row :file) "unknown"))
            (format "Time: %s（%s）\nRunning: %s\n" (agent-dash-hub-time row t)
                    (if (plist-get row :exact) "最后一条用户消息" "来源时间")
                    (if (agent-dash-hub-live-p row) "yes" "no"))
            (when (plist-get row :title) (format "Title: %s\n" (plist-get row :title)))
            (format "Summary model: %s; generated: %s\n" (or (plist-get entry :model) "unknown")
                    (if (plist-get entry :generated-at)
                        (format-time-string "%Y-%m-%d %H:%M:%S" (plist-get entry :generated-at))
                      "unknown"))
            (when (plist-get entry :error) (format "Summary error: %s\n" (plist-get entry :error)))
            (format "\nFirst user message:\n%s\n\nLast user message:\n%s\n\n"
                    (agent-dash-hub--first-text row) (agent-dash-hub--last-text row)))))

(defun agent-dash-hub--details-render (&optional width)
  "Draw the details buffer at WIDTH from cached data, without rereading."
  (let* ((inhibit-read-only t)
         (row agent-dash-hub--details-row)
         (width (max 24 (or width (window-body-width (get-buffer-window (current-buffer)))
                            (frame-width))))
         (turns agent-dash-hub--details-turns)
         (id (plist-get row :id))
         (identity (format "%s · %s" (upcase (symbol-name (plist-get row :backend)))
                           (substring id 0 (min 8 (length id)))))
         (project (abbreviate-file-name (or (plist-get row :root) "未知项目")))
         (position (point)))
    (setq agent-dash-hub--details-width width)
    (erase-buffer)
    (insert (propertize identity 'face 'bold 'help-echo id) "  ·  "
            (propertize (truncate-string-to-width project
                                                  (max 1 (- width (string-width identity) 5))
                                                  nil nil "…")
                        'face 'shadow)
            "\n")
    (insert (propertize (format "%s  ·  摘要：%s  ·  %s%s\n" (agent-dash-hub-time row)
                                (agent-dash-summary-status row)
                                (if (stringp turns) "对话读取失败"
                                  (format "%d 条消息" (length turns)))
                                (if (plist-get row :missing) "  [目录缺失]" ""))
                        'face 'shadow))
    (when-let* ((summary (agent-dash-summary-text row)))
      (dolist (line (agent-dash-hub--wrap (concat "摘要  " summary) (max 12 (- width 2))))
        (insert line "\n")))
    (insert-text-button (if agent-dash-hub--details-expanded "▾ 详细信息（m 收起）" "▸ 详细信息（m 展开）")
                        'follow-link t
                        'action (lambda (_) (agent-dash-hub-details-toggle-metadata)))
    (insert "\n")
    (when agent-dash-hub--details-expanded (insert (agent-dash-hub--details-metadata)))
    (insert (propertize "\n对话" 'face 'bold)
            (propertize "  ·  agent 左 / 用户右  ·  思考与工具调用不在此展示\n\n" 'face 'shadow))
    (if (stringp turns)
        (insert (format "[读取对话失败：%s]\n" turns))
      (unless turns (insert "[没有可显示的用户/助手对话文本]\n"))
      (dolist (turn turns) (agent-dash-hub--bubble (car turn) (cdr turn) width)))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun agent-dash-hub--details-resize (frame)
  "Reflow details windows of FRAME whose width changed."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'agent-dash-hub-details-mode)
                 (not (eql (window-body-width window) agent-dash-hub--details-width)))
        (agent-dash-hub--details-render (window-body-width window))))))

(add-hook 'window-size-change-functions #'agent-dash-hub--details-resize)

(defun agent-dash-hub-show-details (row)
  "Show session ROW: summary, metadata and the whole conversation."
  (let ((buffer (get-buffer-create "*agent-dash details*")))
    (with-current-buffer buffer
      (agent-dash-hub-details-mode)
      (setq agent-dash-hub--details-row row
            agent-dash-hub--details-turns
            (condition-case err
                (agent-dash-backend-transcript (plist-get row :backend) (plist-get row :id))
              (error (error-message-string err)))))
    (agent-dash-hub--show buffer)
    (with-current-buffer buffer (agent-dash-hub--details-render))))

(defun agent-dash-hub-details ()
  "Show the session at point: summary, metadata and the whole conversation."
  (interactive)
  (agent-dash-hub-show-details (agent-dash-hub--row-at-point)))

(defun agent-dash-hub-details-toggle-metadata ()
  "Show or hide the full metadata."
  (interactive)
  (setq agent-dash-hub--details-expanded (not agent-dash-hub--details-expanded))
  (agent-dash-hub--details-render))

(defun agent-dash-hub-details-refresh ()
  "Reflow the cached conversation; nothing is read again."
  (interactive)
  (agent-dash-hub--details-render))

(defun agent-dash-hub-details-open ()
  "Press the button at point, or open the session shown here."
  (interactive)
  (if (button-at (point))
      (push-button)
    (agent-dash-hub-open-row agent-dash-hub--details-row)))

(defun agent-dash-hub-details-copy ()
  "Copy the original conversation, without display wrapping."
  (interactive)
  (if (stringp agent-dash-hub--details-turns)
      (user-error "没有可复制的对话")
    (kill-new (mapconcat (lambda (turn)
                           (format "%s: %s" (if (eq (car turn) 'user) "User" "Assistant")
                                   (cdr turn)))
                         agent-dash-hub--details-turns "\n\n"))
    (message "已复制原始对话")))

(defvar agent-dash-hub-details-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'agent-dash-hub-details-open)
    (define-key map (kbd "m") #'agent-dash-hub-details-toggle-metadata)
    (define-key map (kbd "g") #'agent-dash-hub-details-refresh)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "C-c C-w") #'agent-dash-hub-details-copy)
    map)
  "Keymap for `agent-dash-hub-details-mode'.")

(define-derived-mode agent-dash-hub-details-mode special-mode "Agent-Details"
  "A saved conversation: agent on the left, user on the right.
\\<agent-dash-hub-details-mode-map>\\[agent-dash-hub-details-toggle-metadata] toggles the metadata.
Every message has a copy button; \\[agent-dash-hub-details-copy] copies the
whole original conversation."
  (setq-local truncate-lines t)
  (setq-local header-line-format
              "  RET 恢复会话（按钮上为操作按钮）   q 返回   m 详细信息   TAB 切换按钮   C-c C-w 复制原始对话"))

;;;; Menus

(defun agent-dash-hub--agent-label (label key)
  "Return LABEL with its shortcut KEY in bold."
  (let ((start (string-match (regexp-quote key) label)))
    (concat (substring label 0 start) (propertize key 'face 'bold) (substring label (1+ start)))))

(defun agent-dash-hub--describe (field)
  "Return the menu description of view FIELD."
  (with-current-buffer transient--original-buffer
    (pcase field
      ('convert (let ((count (hash-table-count (agent-dash-hub--selection))))
                  (if (> count 0) (format "转换已选的 %d 条会话" count) "转换光标所在会话")))
      ('agent (format "筛选（Agent：%s）" (or agent-dash-hub--agent "全部")))
      ('project (format "项目：%s" (agent-dash--one-line (or agent-dash-hub--project "全部") 32)))
      ('live (format "仅 live：%s" (if agent-dash-hub--live-only "开" "关")))
      ('hidden (format "显示隐藏：%s" (if agent-dash-hub--show-hidden "开" "关")))
      ('ordering (format "排列（当前：%s）"
                         (pcase agent-dash-hub--grouping
                           ('agent "Agent 分组") ('project "项目分组") (_ "时间倒序")))))))

(defconst agent-dash-hub--display
  '(display-buffer-in-side-window (side . bottom) (slot . 0)
                                  (window-parameters . ((no-other-window . t))))
  "Where hub menus appear.")

(transient-define-prefix agent-dash-hub-new-session ()
  "Choose an agent, then its project directory."
  :variable-pitch t
  :display-action agent-dash-hub--display
  ["新建会话（选择 Agent 后选择项目目录）"
   ["Agent"
    ("C" (lambda () (agent-dash-hub--agent-label "Claude Code" "C"))
     (lambda () (interactive) (agent-dash-hub--new 'claude)))
    ("x" (lambda () (agent-dash-hub--agent-label "Codex" "x"))
     (lambda () (interactive) (agent-dash-hub--new 'codex)))
    ("p" (lambda () (agent-dash-hub--agent-label "pi" "p"))
     (lambda () (interactive) (agent-dash-hub--new 'pi)))
    ("d" (lambda () (agent-dash-hub--agent-label "dsh" "d"))
     (lambda () (interactive) (agent-dash-hub--new 'dsh)))
    ("m" (lambda () (agent-dash-hub--agent-label "Hermes" "m"))
     (lambda () (interactive) (agent-dash-hub--new 'hermes)))]
   ["其他"
    ("q" "关闭 / 返回" transient-quit-one :transient nil)]])

(transient-define-group agent-dash-hub--agent-group
  [:description (lambda () (agent-dash-hub--describe 'agent))
                ("a" (lambda () (agent-dash-hub--agent-label "全部 agent" "a"))
                 agent-dash-hub-filter-all-agents)
                ("C" (lambda () (agent-dash-hub--agent-label "Claude Code" "C"))
                 (lambda () (interactive) (agent-dash-hub-filter-agent-to 'claude)))
                ("x" (lambda () (agent-dash-hub--agent-label "Codex" "x"))
                 (lambda () (interactive) (agent-dash-hub-filter-agent-to 'codex)))
                ("p" (lambda () (agent-dash-hub--agent-label "pi" "p"))
                 (lambda () (interactive) (agent-dash-hub-filter-agent-to 'pi)))
                ("d" (lambda () (agent-dash-hub--agent-label "dsh" "d"))
                 (lambda () (interactive) (agent-dash-hub-filter-agent-to 'dsh)))
                ("m" (lambda () (agent-dash-hub--agent-label "Hermes" "m"))
                 (lambda () (interactive) (agent-dash-hub-filter-agent-to 'hermes)))])

(transient-define-prefix agent-dash-hub-filter-agent ()
  "Filter agents; changes apply immediately."
  :transient-suffix 'transient--do-call
  :variable-pitch t
  :display-action agent-dash-hub--display
  ["Agent 筛选（立即生效）"
   agent-dash-hub--agent-group
   ["其他"
    ("q" "关闭 / 返回" transient-quit-one :transient nil)]])

(transient-define-prefix agent-dash-hub-filter-menu ()
  "Adjust the view repeatedly; closing keeps the changes."
  :transient-suffix 'transient--do-call
  :variable-pitch t
  :display-action agent-dash-hub--display
  ["会话视图（立即生效）"
   ["项目"
    ("P" (lambda () (agent-dash-hub--describe 'project)) agent-dash-hub-filter-project)]
   agent-dash-hub--agent-group
   ["开关"
    ("l" (lambda () (agent-dash-hub--describe 'live)) agent-dash-hub-toggle-live)
    ("h" (lambda () (agent-dash-hub--describe 'hidden)) agent-dash-hub-toggle-hidden)]
   [:description (lambda () (agent-dash-hub--describe 'ordering))
                 ("g" "按 Agent 分组" agent-dash-hub-group-by-agent)
                 ("t" "时间倒序 / 项目分组" agent-dash-hub-sort-by-time)]
   ["其他"
    ("c" "恢复默认" agent-dash-hub-clear-filters)
    ("q" "关闭 / 返回" transient-quit-one :transient nil)]])

(transient-define-prefix agent-dash-hub-convert-menu ()
  "Choose the scope of a native session conversion."
  :display-action agent-dash-hub--display
  [[:description (lambda () (agent-dash-hub--describe 'convert))
                 ("s" "转到 Pi（Claude 原件迁出并归档）" agent-dash-hub-convert-session)
                 ("d" "导入 DSH（Claude 原件验证后迁出）" agent-dash-hub-import-dsh)
                 ("e" "仅导出 DSH 包" agent-dash-hub-export-dsh)]
   ["批量转到 Pi（Claude 原件迁出并归档）"
    ("p" "当前项目的全部已加载会话" agent-dash-hub-convert-project)
    ("b" "指定后端的全部已加载会话" agent-dash-hub-convert-backend)]
   ["返回"
    ("q" "关闭菜单" transient-quit-one :transient nil)]])

(transient-define-prefix agent-dash-hub-backup-menu ()
  "Export or import native backups."
  :display-action agent-dash-hub--display
  ["原生备份"
   ("s" "导出已选会话" agent-dash-hub-backup-export-selected)
   ("a" "导出全部已加载会话" agent-dash-hub-backup-export-all)
   ("i" "预览并导入备份" agent-dash-hub-backup-import)
   ("q" "关闭菜单" transient-quit-one :transient nil)])

(transient-define-prefix agent-dash-hub-help-menu ()
  "Hub commands; the same keys work directly in the list."
  :variable-pitch t
  :display-action agent-dash-hub--display
  ["agent-dash 命令（C-h m 查看完整说明）"
   ["会话"
    ("N" "新建" agent-dash-hub-new-session)
    ("RET" "打开 / 恢复" agent-dash-hub-open)
    ("i" "详情 / 对话" agent-dash-hub-details)
    ("r" "生成摘要" agent-dash-hub-summary-retry)
    ("R" "重试失败摘要" agent-dash-summary-retry-failed)]
   ["浏览"
    ("n" "下一条" agent-dash-hub-next-entry :transient t)
    ("p" "上一条" agent-dash-hub-previous-entry :transient t)
    ("C-c C-n" "下一项目" agent-dash-hub-next-project :transient t)
    ("C-c C-p" "上一项目" agent-dash-hub-previous-project :transient t)
    ("C-c C-j" "跳转项目" agent-dash-hub-jump-project :transient t)
    ("j" "定位会话" agent-dash-hub-search-all)
    ("s" "语义搜索 / 问答" agent-dash-search-menu)
    ("TAB" "折叠 / 展开" agent-dash-hub-toggle-group :transient t)
    ("<backtab>" "全部折叠 / 展开" agent-dash-hub-toggle-all-groups :transient t)
    ("g" "刷新" agent-dash-hub-refresh)]
   ["视图"
    ("f" "会话视图" agent-dash-hub-filter-menu)
    ("a" "Agent 筛选" agent-dash-hub-filter-agent)
    ("P" "项目筛选" agent-dash-hub-filter-project)
    ("l" "切换仅 live" agent-dash-hub-toggle-live)
    ("t" "时间 / 项目" agent-dash-hub-sort-by-time)
    ("c" "恢复默认" agent-dash-hub-clear-filters)]
   ["管理"
    ("m" "切换选中并前进" agent-dash-hub-toggle-selection :transient t)
    ("M" "全选当前筛选（含折叠）" agent-dash-hub-select-all :transient t)
    ("U" "清空选择" agent-dash-hub-clear-selection :transient t)
    ("d" "标记已选 / 当前行待删除" agent-dash-hub-mark-delete)
    ("u" "清除当前行的选择和待删标记" agent-dash-hub-unmark-delete)
    ("x" "确认删除" agent-dash-hub-execute-deletions)
    ("v" "转换会话" agent-dash-hub-convert-menu)
    ("B" "原生备份" agent-dash-hub-backup-menu)
    ("D" "项目重定向" agent-dash-hub-relocate-project)
    ("!" "诊断" agent-dash-hub-diagnostics)]
   ["其他"
    ("w" "复制 ID" agent-dash-hub-copy-id)
    ("W" "复制项目" agent-dash-hub-copy-project)
    ("q" "关闭 / 返回" transient-quit-one :transient nil)]])

;;;; Mode

(defvar agent-dash-hub-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (entry '(("N" . agent-dash-hub-new-session) ("RET" . agent-dash-hub-open)
                     ("j" . agent-dash-hub-search-all) ("s" . agent-dash-search-menu)
                     ("f" . agent-dash-hub-filter-menu) ("P" . agent-dash-hub-filter-project)
                     ("a" . agent-dash-hub-filter-agent) ("l" . agent-dash-hub-toggle-live)
                     ("t" . agent-dash-hub-sort-by-time) ("c" . agent-dash-hub-clear-filters)
                     ("n" . agent-dash-hub-next-entry) ("p" . agent-dash-hub-previous-entry)
                     ("C-c C-n" . agent-dash-hub-next-project)
                     ("C-c C-p" . agent-dash-hub-previous-project)
                     ("C-c C-j" . agent-dash-hub-jump-project)
                     ("TAB" . agent-dash-hub-toggle-group)
                     ("<backtab>" . agent-dash-hub-toggle-all-groups)
                     ("S-<tab>" . agent-dash-hub-toggle-all-groups)
                     ("g" . agent-dash-hub-refresh)
                     ("i" . agent-dash-hub-details)
                     ("d" . agent-dash-hub-mark-delete) ("u" . agent-dash-hub-unmark-delete)
                     ("x" . agent-dash-hub-execute-deletions)
                     ("w" . agent-dash-hub-copy-id) ("W" . agent-dash-hub-copy-project)
                     ("D" . agent-dash-hub-relocate-project) ("r" . agent-dash-hub-summary-retry)
                     ("R" . agent-dash-summary-retry-failed)
                     ("!" . agent-dash-hub-diagnostics) ("?" . agent-dash-hub-help-menu)
                     ("q" . agent-dash-hub-quit)))
      (define-key map (kbd (car entry)) (cdr entry)))
    map)
  "Keymap for `agent-dash-hub-mode'.")

(define-key agent-dash-hub-mode-map (kbd "v") #'agent-dash-hub-convert-menu)
(define-key agent-dash-hub-mode-map (kbd "B") #'agent-dash-hub-backup-menu)
(define-key agent-dash-hub-mode-map (kbd "m") #'agent-dash-hub-toggle-selection)
(define-key agent-dash-hub-mode-map (kbd "M") #'agent-dash-hub-select-all)
(define-key agent-dash-hub-mode-map (kbd "U") #'agent-dash-hub-clear-selection)

(define-derived-mode agent-dash-hub-mode special-mode "Agent-Hub"
  "Saved sessions of every agent.

N 新建（C/x/p/d/m 选择 Agent，再选目录）；RET 打开/恢复；n/p 移动；j 定位会话。
f 会话视图菜单；a Agent 筛选；P 项目筛选；l 仅存活；f h 显示不摘要会话；
t 时间倒序/项目分组；f g 按 Agent 分组；c 恢复默认；g 刷新。
TAB 折叠/展开当前分组；Shift-TAB 全部折叠/展开。
i 详情/对话；s 语义搜索/问答；r 生成摘要；R 重试失败摘要（需 `agent-dash-summary-mode'）。
m 切换选中并移到下一会话；M 全选当前筛选的已加载会话（含折叠）；U 清空选择。
v s 转换到 Pi；v d 导出 DSH 包；均优先处理选集，空选集处理当前行。
v p 转换当前项目；v b 转换指定后端；B Codex 备份菜单。
d 标记已选会话或当前行待删除；u 清除当前行选择和删除标记；x 确认执行全部删除标记。
D 项目目录重定向；! 诊断。
w 复制 ID；W 复制项目；q 返回之前的 tab；? 命令菜单。
列：*=已选，D=待删除，●=后台实例或已打开；日期 * 表示来源时间，不是消息时间。

\\{agent-dash-hub-mode-map}"
  (setq-local truncate-lines t)
  (setq-local header-line-format
              '(:eval (propertize agent-dash-hub--status 'face
                                  (if (string-search "来源失败" agent-dash-hub--status)
                                      'warning 'mode-line))))
  (setq agent-dash-hub--collapsed (make-hash-table :test #'equal)
        agent-dash-hub--selected (make-hash-table :test #'equal)
        agent-dash-hub--marks (make-hash-table :test #'equal)
        agent-dash-hub--grouping agent-dash-hub-group-by)
  (add-hook 'post-command-hook #'agent-dash-hub--highlight nil t)
  (add-hook 'window-size-change-functions #'agent-dash-hub--resize nil t))

;; Autoload the main file, which loads every backend, not just this one.
;;;###autoload (autoload 'agent-dash-hub "agent-dash" "List the saved sessions of every agent." t)
(defun agent-dash-hub ()
  "List saved sessions in the `agent-dash' tab alongside agent chats.
Reuse the existing tab, hub buffer and window.  q returns to the previous tab."
  (interactive)
  (let ((buffer (get-buffer-create "*agent-dash hub*")))
    (agent-dash-hub--show buffer)
    (unless (derived-mode-p 'agent-dash-hub-mode) (agent-dash-hub-mode))
    (agent-dash-hub-refresh)))

;;;; @session references

(defun agent-dash-hub--transcript-text (backend id max)
  "Return saved session ID of BACKEND as text of at most MAX chars."
  (let ((text (mapconcat (lambda (turn) (format "%s: %s" (if (eq (car turn) 'user) "User" "Agent")
                                                (cdr turn)))
                         (agent-dash-backend-transcript backend id) "\n\n")))
    (if (> (length text) max)
        (concat "…" (substring text (- (length text) max)))
      text)))

(defun agent-dash-hub--reference-choices (rows)
  "Return aligned completion choices for ROWS within the minibuffer window.
Keep full metadata searchable without displaying it after the table columns."
  (let* ((width (max 1 (- (window-body-width (minibuffer-window)) 4)))
         (agent-width (if (< width 40) 3 7))
         (id-width (min 12 (max 4 (/ width 10))))
         (date-width (if (< width 56) 10 17))
         (project-width (min 20 (max 4 (/ width 6))))
         (text-width (max 2 (- width agent-width id-width date-width project-width 10)))
         (summary-width (max 1 (floor (* text-width 0.6)))))
    (mapcar
     (lambda (row)
       (let* ((id (plist-get row :id))
              (root (or (plist-get row :root) ""))
              (agent (symbol-name (plist-get row :backend)))
              (date (agent-dash-hub-time row))
              (summary (agent-dash-hub--summary-text row))
              (last (agent-dash-hub--last-text row))
              (metadata (mapconcat (lambda (text) (agent-dash--one-line text 10000))
                                   (list agent date root id summary last) " | "))
              (label
               (concat
                (agent-dash-hub--column agent agent-width)
                (if (agent-dash-hub-live-p row)
                    (concat (propertize "●" 'face 'success) " ")
                  "  ")
                (agent-dash-hub--column id id-width) " "
                (agent-dash-hub--column date date-width) " "
                (agent-dash-hub--column
                 (file-name-nondirectory (directory-file-name (if (equal root "") "—" root)))
                 project-width)
                " │ " (agent-dash-hub--column summary summary-width)
                " │ " (agent-dash-hub--column last (- text-width summary-width)))))
         (cons (concat (propertize (truncate-string-to-width label width nil nil "…")
                                   'help-echo metadata)
                       (propertize (concat " | " metadata) 'display ""))
               row)))
     rows)))

(defun agent-dash-hub-read-reference (&optional backend query)
  "Read a reference, limited to BACKEND when non-nil, with initial QUERY.
Use the shared inventory without generating summaries.  Full ids keep
otherwise identical labels distinct; all visible metadata is searchable."
  (dolist (source (if backend (list backend) agent-dash-backends))
    (unless (memq (plist-get (gethash source agent-dash-hub--sources) :status)
                  '(ok error))
      (agent-dash-hub--load source)))
  (let* ((agent-dash-hub--agent backend)
         (agent-dash-hub--project nil)
         (agent-dash-hub--live-only nil)
         (agent-dash-hub--show-hidden nil)
         (rows (agent-dash-hub--visible)))
    (when (and (not rows)
               (seq-some (lambda (source)
                           (eq (plist-get (gethash source agent-dash-hub--sources) :status)
                               'loading))
                         (if backend (list backend) agent-dash-backends)))
      (user-error "会话列表正在后台读取，请稍后重试引用"))
    (let* ((choices (agent-dash-hub--reference-choices rows))
           (row (agent-dash-input-read "引用会话：" choices query)))
      (format "@[%s](agent-dash:%s:%s)"
              (replace-regexp-in-string
               "[][\n]" " " (agent-dash--one-line (agent-dash-hub--summary-text row) 40))
              (plist-get row :backend) (plist-get row :id)))))

(defun agent-dash-insert-reference ()
  "Insert a cross-agent session reference at point."
  (interactive)
  (insert (agent-dash-hub-read-reference)))

(defun agent-dash-expand-references (text)
  "Return TEXT with the conversations of its @session references appended."
  (let ((start 0) refs)
    (while (string-match agent-dash--reference-regexp text start)
      (push (cons (intern (match-string 1 text)) (match-string 2 text)) refs)
      (setq start (match-end 0)))
    (if (not refs)
        text
      (let ((each (/ agent-dash-reference-max-chars (length refs))))
        (concat text agent-dash-reference-boundary
                (mapconcat (lambda (ref)
                             (format "## Session %s:%s\n%s" (car ref) (cdr ref)
                                     (agent-dash-hub--transcript-text (car ref) (cdr ref) each)))
                           (nreverse refs) "\n\n")
                "\n</agent-dash-session-references>")))))

(add-hook 'agent-dash-prompt-filter-functions #'agent-dash-expand-references)

(provide 'agent-dash-hub)
;;; agent-dash-hub.el ends here
