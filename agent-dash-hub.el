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
(defvar agent-dash-hub--generation 0 "Refresh generation; late scans are dropped.")

(defvar-local agent-dash-hub--agent nil "Backend filter, or nil for all.")
(defvar-local agent-dash-hub--project nil "Project substring filter, or nil.")
(defvar-local agent-dash-hub--live-only nil)
(defvar-local agent-dash-hub--show-hidden nil "Show sessions that are never summarized.")
(defvar-local agent-dash-hub--grouping nil)
(defvar-local agent-dash-hub--collapsed nil "Group name -> t when folded.")
(defvar-local agent-dash-hub--marks nil "Row key -> t when marked for deletion.")
(defvar-local agent-dash-hub--status "" "Header-line text.")

;;;; Rows

(defun agent-dash-hub--chat (backend id)
  "Return the live chat session of BACKEND session ID, or nil."
  (seq-find (lambda (s) (and (eq (agent-dash-session-backend s) backend)
                             (equal (agent-dash-data s :sid) id)
                             (buffer-live-p (agent-dash-session-buffer s))))
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

(defun agent-dash-hub--all ()
  "Return every loaded row."
  (let (rows)
    (dolist (backend agent-dash-backends)
      (setq rows (append rows (plist-get (gethash backend agent-dash-hub--sources) :rows))))
    rows))

(defun agent-dash-hub--load (backend)
  "List BACKEND's sessions into the shared inventory."
  (let ((old (gethash backend agent-dash-hub--sources))
        (agent-dash-history-warnings nil))
    (condition-case err
        (let ((rows (mapcar (lambda (s) (agent-dash-hub--row backend s))
                            (agent-dash-backend-sessions backend nil))))
          (agent-dash-summary-register rows)
          (puthash backend (list :status 'ok :rows rows
                                 :warnings (nreverse agent-dash-history-warnings))
                   agent-dash-hub--sources))
      ;; A broken source keeps its previous rows, marked stale.
      (error (puthash backend (list :status 'error :rows (plist-get old :rows)
                                    :error (error-message-string err))
                      agent-dash-hub--sources)))))

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

(defun agent-dash-hub--visible ()
  "Return the rows passing the filters, newest first."
  (agent-dash-hub--newest-first
   (seq-filter
    (lambda (row)
      (and (or (not agent-dash-hub--agent) (eq agent-dash-hub--agent (plist-get row :backend)))
           (or (not agent-dash-hub--project)
               (string-search agent-dash-hub--project (or (plist-get row :root) "")))
           (or agent-dash-hub--show-hidden (not (agent-dash-summary-skip-reason row)))
           (or (not agent-dash-hub--live-only) (agent-dash-hub-live-p row))))
    (agent-dash-hub--all))))

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

(defun agent-dash-hub--layout (rows)
  "Compute column widths for ROWS in the current window."
  (let* ((width (window-body-width (get-buffer-window (current-buffer))))
         (short (agent-dash-hub--short-ids rows))
         (id (apply #'max 8 (mapcar #'string-width (hash-table-values short))))
         (project (if (>= width 120)
                      (min 20 (apply #'max 4 (mapcar (lambda (r) (string-width
                                                                  (abbreviate-file-name
                                                                   (or (plist-get r :root) ""))))
                                                     rows)))
                    0))
         (message (max 28 (- width (+ 32 id (if (> project 0) (1+ project) 0)) 4)))
         (status (min (max 0 (- message 27))
                      (apply #'max 0 (mapcar (lambda (r)
                                               (string-width (agent-dash-hub--row-status r)))
                                             rows))))
         (text (- message status 8 6))
         (summary (max 4 (min (- text 10) (floor (* text 0.6))))))
    (list :id id :short short :project project
          :summary summary :last (- text summary) :status status)))

(defun agent-dash-hub--prefix (layout mark agent live date id project)
  "Format the leading columns with LAYOUT.
MARK, AGENT, LIVE, DATE, ID and PROJECT are the column texts."
  (concat (format "  %s %s%s %s %s " mark (agent-dash-hub--column agent 7) live
                  (agent-dash-hub--column date 17)
                  (agent-dash-hub--column id (plist-get layout :id)))
          (when (> (plist-get layout :project) 0)
            (concat (agent-dash-hub--column project (plist-get layout :project)) " "))))

(defun agent-dash-hub--header (layout)
  "Return the column header line for LAYOUT."
  (propertize
   (concat (propertize (agent-dash-hub--prefix layout " " "Agent" " " "日期*" "ID" "项目")
                       'help-echo "日期 *：来源更新/创建时间，不是已验证的消息时间；D=待删除，●=后台实例或已打开")
           (agent-dash-hub--column "摘要" (plist-get layout :summary)) "   "
           (agent-dash-hub--column "用户末句" (plist-get layout :last)) "   "
           (agent-dash-hub--column "摘要状态" 8)
           (make-string (plist-get layout :status) ?\s) "\n")
   'face 'bold))

(defun agent-dash-hub--label (row layout)
  "Return the table line of ROW with LAYOUT."
  (let* ((summary (agent-dash-hub--summary-text row))
         (last (agent-dash-hub--last-text row))
         (status (agent-dash-summary-status row))
         (id (plist-get row :id)))
    (concat
     (agent-dash-hub--prefix
      layout (if (gethash (plist-get row :key) agent-dash-hub--marks) "D" " ")
      (symbol-name (plist-get row :backend))
      (if (agent-dash-hub-live-p row)
          (propertize "●" 'face 'success 'help-echo "后台实例运行中或聊天已打开")
        " ")
      (agent-dash-hub-time row)
      (propertize (gethash id (plist-get layout :short) id) 'help-echo id)
      (agent-dash-hub--middle (abbreviate-file-name (or (plist-get row :root) ""))
                              (max 1 (plist-get layout :project))))
     (propertize (agent-dash-hub--column summary (plist-get layout :summary)) 'help-echo summary)
     "   "
     (propertize (agent-dash-hub--column last (plist-get layout :last)) 'help-echo last)
     "   "
     (agent-dash-hub--column status 8)
     (agent-dash-hub--column (agent-dash-hub--row-status row) (plist-get layout :status)))))

;;;; Rendering

(defun agent-dash-hub--status-line (rows)
  "Return the header-line status for the visible ROWS."
  (let ((total (length (agent-dash-hub--all))) loading failed warnings)
    (dolist (backend agent-dash-backends)
      (when-let* ((notes (plist-get (gethash backend agent-dash-hub--sources) :warnings)))
        (push (format "%s (%d)" backend (length notes)) warnings))
      (pcase (plist-get (gethash backend agent-dash-hub--sources) :status)
        ('loading (push (symbol-name backend) loading))
        ('error (push (symbol-name backend) failed))))
    (concat "agent-dash"
            (format "  显示 %d/已载入 %d（过滤/隐藏 %d）" (length rows) total (- total (length rows)))
            (if loading (format "  扫描中：%s" (string-join (nreverse loading) ", ")) "")
            (if failed (format "  来源失败：%s  [! 诊断]" (string-join (nreverse failed) ", ")) "")
            (if warnings (format "  读取警告：%s  [! 诊断]"
                                 (string-join (nreverse warnings) ", ")) ""))))

(defun agent-dash-hub--render ()
  "Redraw the hub, keeping point on the same row."
  (let* ((key (get-text-property (point) 'agent-dash-key))
         (column (current-column))
         (rows (agent-dash-hub--visible))
         (layout (agent-dash-hub--layout rows))
         (groups (make-hash-table :test #'equal)) order
         (inhibit-read-only t))
    (dolist (row rows)
      (let ((name (agent-dash-hub--group-name row)))
        (unless (gethash name groups) (push name order))
        (puthash name (cons row (gethash name groups)) groups)))
    (setq agent-dash-hub--status (agent-dash-hub--status-line rows))
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

(add-hook 'agent-dash-summary-update-hook #'agent-dash-hub--redisplay)

(defun agent-dash-hub-refresh ()
  "Reread every backend's sessions, one source at a time."
  (interactive)
  (let ((generation (cl-incf agent-dash-hub--generation)))
    (dolist (backend agent-dash-backends)
      (puthash backend (plist-put (copy-sequence (gethash backend agent-dash-hub--sources))
                                  :status 'loading)
               agent-dash-hub--sources))
    (agent-dash-hub--redisplay)
    ;; One backend per timer turn keeps Emacs responsive and the header
    ;; showing which sources are still being read.
    (cl-labels ((next (backends)
                  (when (and backends (= generation agent-dash-hub--generation))
                    (agent-dash-hub--load (car backends))
                    (agent-dash-hub--redisplay)
                    (run-at-time 0 nil #'next (cdr backends)))))
      (run-at-time 0 nil #'next agent-dash-backends))))

;;;; Navigation and filters

(defun agent-dash-hub--row-at-point ()
  "Return the row at point, or signal."
  (or (get-text-property (point) 'agent-dash-row) (user-error "请先选择一条会话")))

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

(defun agent-dash-hub-toggle-group ()
  "Fold or unfold the group at point."
  (interactive)
  (unless agent-dash-hub--grouping (user-error "时间排序模式没有可折叠的分组"))
  (let ((name (or (get-text-property (point) 'agent-dash-group)
                  (agent-dash-hub--group-name (agent-dash-hub--row-at-point)))))
    (puthash name (not (gethash name agent-dash-hub--collapsed)) agent-dash-hub--collapsed)
    (agent-dash-hub--render)
    (agent-dash-hub--goto (list 'group name))))

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
  "Toggle showing only live sessions."
  (interactive)
  (setq agent-dash-hub--live-only (not agent-dash-hub--live-only))
  (agent-dash-hub--render))

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
         (layout (agent-dash-hub--layout visible))
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
  "Show BUFFER filling the frame."
  (pop-to-buffer buffer)
  (delete-other-windows))

(defun agent-dash-hub-open-row (row)
  "Open ROW: switch to its live chat, or resume it."
  (let ((chat (agent-dash-hub--chat (plist-get row :backend) (plist-get row :id))))
    (if chat
        (agent-dash-hub--show (agent-dash-session-buffer chat))
      (when (plist-get row :missing)
        (user-error "项目目录不存在：%s；按 D 重定向" (plist-get row :root)))
      (agent-dash-open (plist-get row :backend) (or (plist-get row :root) default-directory)
                       (plist-get row :id))
      (delete-other-windows))))

(defun agent-dash-hub-open ()
  "Open the session at point, or switch to its live chat."
  (interactive)
  (agent-dash-hub-open-row (agent-dash-hub--row-at-point)))

(defun agent-dash-hub--new (backend)
  "Choose a project directory and start a BACKEND session there."
  (let* ((row (get-text-property (point) 'agent-dash-row))
         (initial (file-name-as-directory
                   (or (and row (plist-get row :root) (not (plist-get row :missing))
                            (plist-get row :root))
                       default-directory)))
         (directory (read-directory-name
                     (format "%s 项目目录：" (cadr (assq backend agent-dash-hub--agents)))
                     initial nil nil)))
    (when (string-empty-p directory) (user-error "项目目录不能为空"))
    (setq directory (file-name-as-directory (expand-file-name directory)))
    (when (file-remote-p directory) (user-error "请选择本地项目目录"))
    (unless (file-directory-p directory) (make-directory directory t))
    (agent-dash-open backend directory)
    (delete-other-windows)))

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

(defun agent-dash-hub-mark-delete ()
  "Mark the session at point for deletion and move on."
  (interactive)
  (let ((row (agent-dash-hub--row-at-point)))
    (unless (plist-get (agent-dash-backend-capabilities (plist-get row :backend)) :delete)
      (user-error "%s 会话不支持删除" (plist-get row :backend)))
    (when (agent-dash-hub-live-p row) (user-error "会话正在运行或已打开，不能删除"))
    (puthash (plist-get row :key) t agent-dash-hub--marks)
    (agent-dash-hub-next-entry)
    (let ((key (get-text-property (point) 'agent-dash-key)))
      (agent-dash-hub--render)
      (agent-dash-hub--goto key))
    (message "已标记删除；u 取消标记，x 确认执行")))

(defun agent-dash-hub-unmark-delete ()
  "Remove the deletion mark of the session at point."
  (interactive)
  (remhash (plist-get (agent-dash-hub--row-at-point) :key) agent-dash-hub--marks)
  (agent-dash-hub--render))

(defun agent-dash-hub-execute-deletions ()
  "Permanently delete the marked sessions after confirmation."
  (interactive)
  (let ((marked (seq-filter (lambda (row) (gethash (plist-get row :key) agent-dash-hub--marks))
                            (agent-dash-hub--all))))
    (unless marked (user-error "没有标记待删除的会话"))
    (unless (yes-or-no-p (format "永久删除 %d 个会话（不可撤销）? " (length marked)))
      (user-error "已取消删除"))
    (dolist (row marked)
      (agent-dash-backend-delete (plist-get row :backend) row)
      (agent-dash-summary-forget row)
      (remhash (plist-get row :key) agent-dash-hub--marks)
      (let ((source (gethash (plist-get row :backend) agent-dash-hub--sources)))
        (puthash (plist-get row :backend)
                 (plist-put source :rows (delq row (plist-get source :rows)))
                 agent-dash-hub--sources)))
    (agent-dash-hub--render)
    (message "已永久删除 %d 个会话" (length marked))))

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
    (with-help-window "*agent-dash diagnostics*"
      (princ (format "显示 %d/已载入 %d；过滤/隐藏 %d。\n\n" visible total (- total visible)))
      (dolist (backend agent-dash-backends)
        (let ((source (gethash backend agent-dash-hub--sources)))
          (princ (format "%-7s %s；%d 条%s\n" backend (or (plist-get source :status) "未载入")
                         (length (plist-get source :rows))
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
  "Restore the window layout from before the hub."
  (interactive)
  (let ((configuration (frame-parameter nil 'agent-dash-hub-windows)))
    (set-frame-parameter nil 'agent-dash-hub-windows nil)
    (if (window-configuration-p configuration)
        (set-window-configuration configuration)
      (quit-window))))

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
            (format "Summary model: %s; generated: %s%s\n" (or (plist-get entry :model) "unknown")
                    (if (plist-get entry :generated-at)
                        (format-time-string "%Y-%m-%d %H:%M:%S" (plist-get entry :generated-at))
                      "unknown")
                    (if (plist-get entry :imported) "（导入自 ashub）" ""))
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
    ("j" "定位会话" agent-dash-hub-search-all)
    ("s" "语义搜索 / 问答" agent-dash-search-menu)
    ("TAB" "折叠 / 展开" agent-dash-hub-toggle-group :transient t)
    ("g" "刷新" agent-dash-hub-refresh)]
   ["视图"
    ("f" "会话视图" agent-dash-hub-filter-menu)
    ("a" "Agent 筛选" agent-dash-hub-filter-agent)
    ("P" "项目筛选" agent-dash-hub-filter-project)
    ("l" "切换仅 live" agent-dash-hub-toggle-live)
    ("t" "时间 / 项目" agent-dash-hub-sort-by-time)
    ("c" "恢复默认" agent-dash-hub-clear-filters)]
   ["管理"
    ("d" "标记删除" agent-dash-hub-mark-delete)
    ("u" "取消标记" agent-dash-hub-unmark-delete)
    ("x" "确认删除" agent-dash-hub-execute-deletions)
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
                     ("TAB" . agent-dash-hub-toggle-group) ("g" . agent-dash-hub-refresh)
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

(define-derived-mode agent-dash-hub-mode special-mode "Agent-Hub"
  "Saved sessions of every agent.

N 新建（C/x/p/d/m 选择 Agent，再选目录）；RET 打开/恢复；n/p 移动；j 定位会话。
f 会话视图菜单；a Agent 筛选；P 项目筛选；l 仅存活；f h 显示不摘要会话；
t 时间倒序/项目分组；f g 按 Agent 分组；c 恢复默认；TAB 折叠/展开；g 刷新。
i 详情/对话；s 语义搜索/问答；r 生成摘要；R 重试失败摘要（需 `agent-dash-summary-mode'）。
d 标记删除；u 取消；x 执行删除（Claude/Pi）；D 项目目录重定向；! 诊断。
w 复制 ID；W 复制项目；q 恢复窗口布局；? 命令菜单。
列：D=待删除，●=后台实例或已打开；日期 * 表示来源时间，不是消息时间。

\\{agent-dash-hub-mode-map}"
  (setq-local truncate-lines t)
  (setq-local header-line-format
              '(:eval (propertize agent-dash-hub--status 'face
                                  (if (string-search "来源失败" agent-dash-hub--status)
                                      'warning 'mode-line))))
  (setq agent-dash-hub--collapsed (make-hash-table :test #'equal)
        agent-dash-hub--marks (make-hash-table :test #'equal)
        agent-dash-hub--grouping agent-dash-hub-group-by)
  (add-hook 'post-command-hook #'agent-dash-hub--highlight nil t))

;; Autoload the main file, which loads every backend, not just this one.
;;;###autoload (autoload 'agent-dash-hub "agent-dash" "List the saved sessions of every agent." t)
(defun agent-dash-hub ()
  "List the saved sessions of every agent, filling the frame.
q restores the previous window layout."
  (interactive)
  (let ((buffer (get-buffer-create "*agent-dash hub*")))
    (unless (and (get-buffer-window buffer) (frame-parameter nil 'agent-dash-hub-windows))
      (set-frame-parameter nil 'agent-dash-hub-windows (current-window-configuration)))
    (switch-to-buffer buffer)
    (delete-other-windows)
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

(defun agent-dash-hub-read-reference (&optional backend query)
  "Read a reference, limited to BACKEND when non-nil, with initial QUERY.
Use the shared inventory without generating summaries.  Full ids keep
otherwise identical labels distinct; all visible metadata is searchable."
  (dolist (source (if backend (list backend) agent-dash-backends))
    (unless (memq (plist-get (gethash source agent-dash-hub--sources) :status)
                  '(ok error))
      (agent-dash-hub--load source)))
  (let* ((rows (agent-dash-hub--newest-first
                (seq-filter (lambda (row)
                              (or (not backend) (eq backend (plist-get row :backend))))
                            (agent-dash-hub--all))))
         (choices
          (mapcar (lambda (row)
                    (cons (format "%s  %.12s  %s  %s | %s | %s | %s | %s"
                                  (plist-get row :backend) (plist-get row :id)
                                  (agent-dash-hub-time row)
                                  (file-name-nondirectory
                                   (directory-file-name (or (plist-get row :root) "—")))
                                  (agent-dash--one-line (agent-dash-hub--summary-text row) 70)
                                  (agent-dash--one-line (plist-get row :last) 70)
                                  (or (plist-get row :root) "") (plist-get row :id))
                          row)) rows))
         (row (agent-dash-input-read "引用会话：" choices query)))
    (format "@[%s](agent-dash:%s:%s)"
            (replace-regexp-in-string
             "[][\n]" " " (agent-dash--one-line (agent-dash-hub--summary-text row) 40))
            (plist-get row :backend) (plist-get row :id))))

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
