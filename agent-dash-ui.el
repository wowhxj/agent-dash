;;; agent-dash-ui.el --- Chat buffer for agent-dash sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; One chat buffer per session: a read-only transcript of timeline
;; items, a separator, and an editable composer at the bottom.  Each
;; item owns the region START..END (its trailing newline excluded), so
;; an update re-renders only that item and never touches the draft.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-input)
(require 'agent-dash-images)
(require 'agent-dash-queue)
(require 'markdown-mode)

(defgroup agent-dash-ui nil "Chat buffer of `agent-dash'." :group (quote agent-dash))

(defcustom agent-dash-tool-output-lines 40
  "Lines of tool output shown when a tool item is expanded."
  :type 'integer)

(defface agent-dash-user-face '((t :inherit highlight :weight bold :extend t))
  "Face for a user turn, extended across the window.")
(defface agent-dash-input-face
  '((t :inherit widget-field :underline nil :extend t))
  "Face for the editable composer.")
(defface agent-dash-assistant-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant label.")
(defface agent-dash-status-face '((t :inherit mode-line))
  "Face for the compact agent activity indicator.")
(defface agent-dash-process-face '((t :inherit shadow))
  "Face for tool and thinking lines.")
(defface agent-dash-separator-face '((t :inherit shadow))
  "Face for the line above the composer.")

(defcustom agent-dash-auto-answer t
  "Open pending agent dialogs in the minibuffer for the selected chat.
Other chats keep their requests visible until selected or answered with
`agent-dash-answer'.  Never interrupt an existing minibuffer interaction."
  :type 'boolean
  :group 'agent-dash)

(defvar agent-dash--answering nil
  "Non-nil while an agent dialog owns the minibuffer.")

(defvar-local agent-dash--answer-timer nil
  "Deferred minibuffer dialog timer for this chat.")

(defvar-local agent-dash--session nil "Session shown in this chat buffer.")
(defvar-local agent-dash--transcript-end nil
  "Marker where the next timeline item goes; advances on insertion.")
(defvar-local agent-dash--input-start nil "Marker at the composer start.")
(defvar-local agent-dash--input-overlay nil "Overlay decorating the composer.")
(defvar-local agent-dash--spinner-index 0 "Current activity animation frame.")
(defvar-local agent-dash--spinner-timer nil "Timer while this chat is running.")
(defvar-local agent-dash--history nil "Sent prompts, newest first.")
(defvar-local agent-dash--history-index -1)
(defvar-local agent-dash--history-draft nil)
(defvar-local agent-dash--quitting nil
  "Non-nil while `agent-dash-quit' kills the buffer, so it skips detach.")

(defvar agent-dash--sessions nil "Live sessions, newest first.")

(defvar agent-dash-prompt-filter-functions nil
  "Functions of one argument, the prompt text, returning the text to send.
The prompt history keeps the text as typed.")

(defconst agent-dash-reference-boundary "\n\n<agent-dash-session-references>\n"
  "Marker before context appended to a prompt; the chat shows only what precedes it.")

;;;; Rendering

(defun agent-dash--one-line (text width)
  "Return TEXT flattened to one line of at most WIDTH chars."
  (truncate-string-to-width
   (replace-regexp-in-string "[ \t\n]+" " " (string-trim (format "%s" (or text ""))))
   width nil nil "…"))

(defun agent-dash--markdown (text)
  "Return TEXT with markdown faces, keeping every original character."
  (with-temp-buffer
    (insert text)
    (delay-mode-hooks (gfm-mode))
    (font-lock-ensure)
    (buffer-string)))

(defun agent-dash--backend-name (backend)
  "Return the display name of BACKEND."
  (if (eq backend 'dsh) "DSH" (capitalize (symbol-name backend))))

(defun agent-dash--label (session)
  "Return the assistant label of SESSION."
  (propertize (format "%s: " (agent-dash--backend-name
                              (agent-dash-session-backend session)))
              'face 'agent-dash-assistant-face))

(defun agent-dash--item-folded-p (item)
  "Whether ITEM's details are folded, independently of its Process group.
Details stay folded until explicitly opened by the user."
  (not (eq (plist-get item :folded) 'open)))

(defun agent-dash--item-body (session item)
  "Return the display body of timeline ITEM of SESSION."
  (let ((folded (agent-dash--item-folded-p item)))
    (pcase (plist-get item :type)
      ('user
       (concat "\n"
               (propertize
                (concat "You: "
                        (let* ((text (plist-get item :text))
                               (cut (string-search agent-dash-reference-boundary text)))
                          (if cut (substring text 0 cut) text))
                        (if (plist-get item :images)
                            (format " [%d image(s)]" (length (plist-get item :images)))
                          "") "\n"
                        (agent-dash-images-string (plist-get item :images)))
                'face 'agent-dash-user-face)))
      ('assistant
       (let ((thinking (plist-get item :thinking))
             (text (or (plist-get item :text) "")))
         (concat
          (when (and thinking (not (string-blank-p thinking)))
            (propertize (if folded
                            (concat "▸ Thinking  " (agent-dash--one-line thinking 60) "\n")
                          (concat "▾ Thinking\n" thinking "\n"))
                        'face 'agent-dash-process-face))
          ;; A message of thinking alone shows no empty label.
          (unless (and (string-empty-p text) thinking (not (string-blank-p thinking)))
            (concat (agent-dash--label session)
                    (if (plist-get item :final) (agent-dash--markdown text) text)))
          (agent-dash-images-string (plist-get item :images)))))
      ('tool
       (let* ((status (plist-get item :status))
              (head (format "%s %s  %s"
                            (pcase status ('success "✓") ('error "✗") (_ "…"))
                            (plist-get item :name)
                            (agent-dash--one-line (plist-get item :args) 70)))
              (output (plist-get item :output)))
         (concat
          (propertize
           (if (or folded (not output))
               head
             (let ((lines (split-string output "\n")))
               (concat head "\n"
                       (mapconcat (lambda (l) (concat "    " l))
                                  (seq-take lines agent-dash-tool-output-lines)
                                  "\n")
                       (when (> (length lines) agent-dash-tool-output-lines)
                         (format "\n    … %d more lines"
                                 (- (length lines) agent-dash-tool-output-lines))))))
           'face (if (eq status 'error) 'error 'agent-dash-process-face))
          (unless folded (agent-dash-images-string (plist-get item :images))))))
      ('request (agent-dash--request-text item))
      ('notice
       (propertize (format "[%s]" (plist-get item :text))
                   'face (pcase (plist-get item :level)
                           ('error 'error) ('warning 'warning) (_ 'shadow)))))))

(defun agent-dash--process-p (item)
  "Return non-nil when ITEM belongs in a turn's Process group."
  (or (eq (plist-get item :type) 'tool)
      (and (eq (plist-get item :type) 'assistant)
           (or (plist-get item :process)
               (and (not (plist-get item :images))
                    (string-blank-p (or (plist-get item :text) ""))
                    (not (string-blank-p
                          (or (plist-get item :thinking) ""))))))))

(defun agent-dash--item-text (session item)
  "Return SESSION's ITEM display string, with a foldable Process heading."
  (let* ((group (and (plist-get item :process-group)
                     (agent-dash-item session (plist-get item :process-group))))
         (closed (and group (not (plist-get group :process-open))))
         (body (agent-dash--item-body session item)))
    (concat
     (when (eq group item)
       (propertize
        (format "%s Process · %d steps\n"
                (if closed "▸" "▾") (plist-get group :process-count))
        'face 'agent-dash-process-face 'agent-dash-process-heading t
        'help-echo "RET / TAB: expand or collapse this turn's process"))
     (if closed (propertize body 'invisible 'agent-dash-process) body))))

(defun agent-dash--render-process (session changed)
  "Group SESSION's process items and redraw CHANGED or lifecycle changes.
The current turn starts expanded and folds only when the run ends.  Manual
visibility choices survive intermediate updates, but not the finish transition."
  (let (groups group active-first answered)
    (dolist (item (agent-dash-session-items session))
      (when (eq (plist-get item :type) 'user)
        (when group (push (nreverse group) groups))
        (setq group nil answered nil))
      (if (agent-dash--process-p item)
          (progn (push item group) (setq answered nil))
        (when (and (eq (plist-get item :type) 'assistant) (plist-get item :final)
                   (or (plist-get item :images)
                       (not (string-blank-p (or (plist-get item :text) "")))))
          (setq answered t))))
    (when group
      (setq group (nreverse group) active-first (car group))
      (push group groups))
    (dolist (items (nreverse groups))
      (let* ((first (car items)) (count (length items))
             (head-changed (not (equal (plist-get first :process-group)
                                       (plist-get first :id))))
             (active (and (eq first active-first)
                          (eq (agent-dash-session-state session) 'running)
                          (or (not (plist-get first :process-settled))
                              (and (memq changed items)
                                   (not (plist-get changed :process-settled))))))
             (transition (not (eq active (plist-get first :process-active)))))
        (when (or transition (and active head-changed))
          (plist-put first :process-open active))
        (dolist (item items)
          (let ((redraw (or (eq item changed) transition
                            (not (eq active (plist-get item :process-active)))
                            (not (equal (plist-get item :process-group)
                                        (plist-get first :id)))
                            (and (eq item first)
                                 (not (eql (plist-get item :process-count) count))))))
            (plist-put item :process-group (plist-get first :id))
            (plist-put item :process-active active)
            ;; Distinguish completed history from a snapshot received before
            ;; its running-state signal. Neither needs to infer from :final
            ;; while the backend is still running.
            (when (or active transition (not (eq first active-first))
                      (plist-get first :process-settled)
                      (and answered (not (eq (agent-dash-session-state session) 'running))))
              (plist-put item :process-settled (not active)))
            (when (eq item first) (plist-put item :process-count count))
            (when redraw (agent-dash--render session item))))))))

(defun agent-dash--render (session item)
  "Insert or redraw timeline ITEM of SESSION in the current buffer."
  (let ((inhibit-read-only t)
        (buffer-undo-list t)
        (start (plist-get item :start)))
    (save-excursion
      (if start
          (progn (delete-region start (plist-get item :end))
                 (goto-char start))
        (goto-char agent-dash--transcript-end)
        (setq start (copy-marker (point)))
        (plist-put item :start start))
      (insert (agent-dash--item-text session item))
      (unless (plist-get item :end)
        (insert "\n")
        (plist-put item :end (copy-marker (1- (point)) t)))
      (put-text-property (plist-get item :end) (1+ (plist-get item :end))
                         'invisible
                         (and (plist-get item :process-group)
                              (not (plist-get
                                    (agent-dash-item
                                     session (plist-get item :process-group))
                                    :process-open))
                              'agent-dash-process))
      (add-text-properties start (1+ (plist-get item :end))
                           (list 'read-only t 'front-sticky '(read-only)
                                 'agent-dash-item (plist-get item :id))))))

(defun agent-dash--on-update (session item)
  "Show SESSION's change of ITEM in its buffer."
  (let ((buffer (agent-dash-session-buffer session)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'agent-dash--transcript-end buffer))
      (with-current-buffer buffer
        (when item
          (unless (agent-dash--process-p item)
            (plist-put item :process-group nil)
            (plist-put item :process-active nil)
            (agent-dash--render session item)))
        (agent-dash--render-process session item)
        (agent-dash--sync-spinner)
        (agent-dash--schedule-answer)
        (force-mode-line-update)))))

(add-hook 'agent-dash-update-functions #'agent-dash--on-update)

(defun agent-dash--stop-spinner ()
  "Release this chat's activity timer."
  (when (timerp agent-dash--spinner-timer)
    (cancel-timer agent-dash--spinner-timer))
  (setq agent-dash--spinner-timer nil))

(defun agent-dash--sync-spinner ()
  "Animate only running chats; redraws never call backends or touch drafts."
  (if (and agent-dash--session
           (eq (agent-dash-session-state agent-dash--session) 'running))
      (unless agent-dash--spinner-timer
        (let ((buffer (current-buffer)) timer)
          (setq timer
                (run-at-time
                 0.15 0.15
                 (lambda ()
                   (if (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (if (and (eq timer agent-dash--spinner-timer)
                                  (derived-mode-p 'agent-dash-mode)
                                  agent-dash--session
                                  (eq (agent-dash-session-state agent-dash--session)
                                      'running))
                             (progn
                               (setq agent-dash--spinner-index
                                     (mod (1+ agent-dash--spinner-index) 4))
                               (force-mode-line-update t))
                           (cancel-timer timer)
                           (when (eq timer agent-dash--spinner-timer)
                             (setq agent-dash--spinner-timer nil))))
                     (cancel-timer timer)))))
          (setq agent-dash--spinner-timer timer)))
    (agent-dash--stop-spinner)))

(defun agent-dash--install-status-line ()
  "Install one compact status indicator in the ordinary mode-line info area."
  (let ((status '(:eval (agent-dash--mode-line))))
    ;; Remove the old process-slot indicator when hot loading.
    (when (equal mode-line-process status) (setq-local mode-line-process nil))
    (setq-local mode-line-misc-info
                (cons status
                      (cl-remove status
                                 (if (listp mode-line-misc-info) mode-line-misc-info
                                   (list mode-line-misc-info))
                                 :test #'equal)))))

(defun agent-dash--mode-line ()
  "Return compact activity, with detailed phase and actions in a tooltip."
  (when-let* ((s agent-dash--session))
    (let* ((state (agent-dash-session-state s))
           (running (eq state 'running))
           (queue (agent-dash-session-queue s))
           (steering (+ (length (plist-get queue :steering))
                        (length (agent-dash-queue-pending s 'steer))))
           (follow-up (+ (length (plist-get queue :follow-up))
                         (length (agent-dash-queue-pending s 'follow-up))))
           (phase (plist-get (agent-dash-session-meta s) :phase))
           (requests (length (agent-dash-session-requests s)))
           (name (agent-dash--backend-name (agent-dash-session-backend s)))
           (status (cond ((eq state 'dead) "disconnected")
                         ((> requests 0) "waiting")
                         (running "thinking") (t "idle"))))
      (propertize
       (string-replace
        "%" "%%"
        (concat " " name " " status
                (when running
                  (format " %c" (aref "|/-\\" (mod agent-dash--spinner-index 4))))
                (when (> (+ steering follow-up) 0)
                  (format " [S%d F%d%s]" steering follow-up
                          (if (and (agent-dash-data s :queue-paused)
                                   (agent-dash-queue-pending s)) " paused" "")))
                (when (> requests 0) (format " ?%d" requests))))
       'face 'agent-dash-status-face
       'help-echo
       (concat name ": " (symbol-name state)
               (when (and running phase) (concat " · " phase))
               (when (> requests 0) "\nC-c C-a: answer pending requests")
               (when (> (+ steering follow-up) 0)
                 (concat "\nS: steering; F: follow-up (local pending + native reported)."
                         "\nC-c q: manage local queue.")))))))

(defun agent-dash--format-tokens (value)
  "Format known token VALUE compactly."
  (cond ((>= value 1000000) (format "%.1fM" (/ value 1000000.0)))
        ((>= value 1000) (format "%.1fk" (/ value 1000.0)))
        (t (number-to-string value))))

(defun agent-dash--stat-segments (session)
  "Return SESSION's known statistics, highest priority first."
  (let* ((meta (agent-dash-session-meta session))
         (stats (plist-get meta :stats))
         (usage (plist-get meta :context-usage))
         (used (agent-dash-jget usage "tokens"))
         (window (agent-dash-jget usage "contextWindow"))
         (percent (agent-dash-jget usage "percent"))
         (tokens (agent-dash-jget stats "tokens"))
         (input (agent-dash-jget tokens "input"))
         (read (agent-dash-jget tokens "cacheRead"))
         (write (agent-dash-jget tokens "cacheWrite"))
         (total (agent-dash-jget tokens "total"))
         (cost (agent-dash-jget stats "cost"))
         (prompts (agent-dash-jget stats "userMessages"))
         (calls (agent-dash-jget stats "assistantMessages"))
         (turns (agent-dash-jget stats "turns"))
         (steps (agent-dash-jget stats "steps"))
         (decode-ms (agent-dash-jget stats "decodeMs"))
         (decode-tokens (agent-dash-jget stats "decodeTokens"))
         (context (when (and (numberp used) (numberp window))
                    (format "%s/%s%s" (agent-dash--format-tokens used)
                            (agent-dash--format-tokens window)
                            (if (numberp percent)
                                (format " (%.0f%%)" percent) "")))))
    (when (and context (numberp percent) (>= percent 80))
      (setq context (propertize context 'face
                                (if (>= percent 95) 'error 'warning))))
    (delq nil
          (list context
                (when (and (numberp turns) (numberp steps) (> steps 0))
                  (format "%d turns · %d steps" turns steps))
                (when (and (numberp decode-ms) (> decode-ms 0)
                           (numberp decode-tokens))
                  (format "%.0f tok/s" (/ (* 1000.0 decode-tokens) decode-ms)))
                (when (and (numberp prompts) (numberp calls))
                  (format "%d prompts · %d calls" prompts calls))
                (when (numberp total)
                  (format "%s tok" (agent-dash--format-tokens total)))
                (when (and (numberp input) (numberp read) (numberp write)
                           (> (+ input read write) 0))
                  (format "cache %.0f%%"
                          (* 100.0 (/ (float read) (+ input read write)))))
                (when (numberp cost) (format "$%.4f" cost))))))

(defun agent-dash--header ()
  "Align cached statistics left and model right, as in emacs-pi.
Redisplay never issues requests.  Run state belongs only in the mode line."
  (when-let* ((s agent-dash--session))
    (let* ((meta (agent-dash-session-meta s))
           (provider (plist-get meta :provider))
           (model (or (plist-get meta :model) "model pending"))
           (thinking (plist-get meta :thinking))
           (short-model
            (agent-dash--one-line
             (string-join
              (seq-filter #'stringp
                          (list model thinking (plist-get meta :agent-preset)
                                (plist-get meta :permission)))
              " · ")
             most-positive-fixnum))
           (right (if (stringp provider)
                      (format "(%s) %s" (agent-dash--one-line provider 100)
                              short-model)
                    short-model))
           (segments (agent-dash--stat-segments s))
           (help (concat (string-join segments " · ") "\n" right
                         "\nContext: current usage / model window."
                         "\nTokens and cost: session totals; estimate, not a bill."
                         "\nCache: cache-read / (input + cache-read + cache-write)."))
           (width (max 1 (- (window-total-width) 2))))
      ;; Keep context and model identity as the window narrows.
      (while (and (cdr segments)
                  (> (+ (string-width (string-join segments " · "))
                        (string-width right) 2) width))
        (setq segments (butlast segments)))
      (when (> (+ (string-width (or (car segments) ""))
                  (string-width right) 2) width)
        (setq right short-model))
      (let ((budget (max 0 (- width (min (string-width (or (car segments) ""))
                                         (/ width 2)) 2))))
        (setq right (if (> budget 0)
                        (truncate-string-to-width right budget nil nil "…") "")))
      (let* ((budget (max 0 (- width (string-width right) 2)))
             (left (if (> budget 0)
                       (truncate-string-to-width
                        (string-join segments " · ") budget nil nil "…") ""))
             (line (concat " " (string-replace "%" "%%" left) " "
                           (propertize " " 'display
                                       `(space :align-to
                                               (- right ,(1+ (string-width right)))))
                           (string-replace "%" "%%" right))))
        (propertize line 'help-echo help)))))

(defun agent-dash--pinned-prompt ()
  "Return the latest user prompt, pinned above the conversation."
  (when-let* ((s agent-dash--session)
              (item (seq-find (lambda (i) (eq (plist-get i :type) 'user))
                              (reverse (agent-dash-session-items s)))))
    (let* ((text (plist-get item :text))
           (cut (string-search agent-dash-reference-boundary text)))
      (propertize
       (string-replace
        "%" "%%"
        (concat " You: "
                (agent-dash--one-line (if cut (substring text 0 cut) text)
                                      (max 10 (- (window-body-width) 8)))))
       'face 'agent-dash-input-face))))

;;;; Buffer

(declare-function agent-dash-insert-reference "agent-dash-hub" ())

(defvar agent-dash-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-dash-ret)
    (define-key map (kbd "i") #'agent-dash-insert-or-focus)
    (define-key map (kbd "<S-return>") #'newline)
    (define-key map (kbd "TAB") #'agent-dash-tab)
    (define-key map [remap yank] #'agent-dash-paste)
    (define-key map [remap clipboard-yank] #'agent-dash-paste)
    (define-key map (kbd "s-v") #'agent-dash-paste)
    (define-key map (kbd "C-c C-v") #'agent-dash-paste-image)
    (define-key map (kbd "C-c C-f") #'agent-dash-attach-image)
    (define-key map (kbd "C-c C-d") #'agent-dash-remove-image)
    (define-key map (kbd "C-c C-o") #'agent-dash-open-image)
    (define-key map (kbd "C-c C-u") #'agent-dash-restore-image-draft)
    (define-key map (kbd "M-p") #'agent-dash-previous-prompt)
    (define-key map (kbd "M-n") #'agent-dash-next-prompt)
    (define-key map (kbd "C-c C-c") #'agent-dash-send)
    (define-key map (kbd "C-c C-s") #'agent-dash-steer)
    (define-key map (kbd "C-c q") #'agent-dash-queue)
    (define-key map (kbd "C-c C-k") #'agent-dash-cancel)
    (define-key map (kbd "C-c C-q") #'agent-dash-quit)
    (define-key map (kbd "C-c C-i") #'agent-dash-focus-input)
    (define-key map (kbd "C-c C-b") #'agent-dash-switch-chat)
    (define-key map (kbd "C-c C-a") #'agent-dash-answer)
    (define-key map (kbd "C-c C-r") #'agent-dash-resume)
    (define-key map (kbd "C-c @") #'agent-dash-insert-reference)
    map)
  "Keymap for `agent-dash-mode'.")

(define-derived-mode agent-dash-mode fundamental-mode "Agent"
  "Chat with an agent.  The composer is below the line.
\\{agent-dash-mode-map}"
  (agent-dash--install-status-line)
  (setq-local tab-line-format '(:eval (agent-dash--header)))
  (setq-local header-line-format '(:eval (agent-dash--pinned-prompt)))
  (add-to-invisibility-spec 'agent-dash-process)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (add-hook 'completion-at-point-functions #'agent-dash--file-capf nil t)
  (add-hook 'kill-buffer-hook #'agent-dash--on-kill nil t)
  (add-hook 'post-command-hook #'agent-dash--schedule-answer nil t)
  (add-hook 'change-major-mode-hook #'agent-dash--stop-answer-timer nil t)
  (add-hook 'change-major-mode-hook #'agent-dash--stop-spinner nil t))

(defun agent-dash--file-capf ()
  "Complete an @file reference in the composer, relative to the chat root."
  (when (and (agent-dash--in-input-p)
             (save-excursion
               (re-search-backward "@\\([^ \t\n@]*\\)\\=" agent-dash--input-start t)))
    (list (match-beginning 1) (point) #'read-file-name-internal :exclusive 'no)))

(defun agent-dash--setup-buffer (session)
  "Create and return the chat buffer of SESSION."
  (let ((buffer (generate-new-buffer
                 (format "*agent:%s:%s*" (agent-dash-session-backend session)
                         (file-name-nondirectory
                          (directory-file-name (agent-dash-session-root session)))))))
    (with-current-buffer buffer
      (agent-dash-mode)
      (setq agent-dash--session session
            default-directory (agent-dash-session-root session))
      (let ((inhibit-read-only t))
        (insert (propertize "\n" 'read-only t 'rear-nonsticky t)))
      (setq agent-dash--transcript-end (copy-marker (point-min) t)
            agent-dash--input-start (copy-marker (point-max)))
      (agent-dash--decorate-input))
    (setf (agent-dash-session-buffer session) buffer)
    (push session agent-dash--sessions)
    buffer))

(defun agent-dash--decorate-input ()
  "Decorate the composer without changing its text or prompt history."
  (when (overlayp agent-dash--input-overlay)
    (delete-overlay agent-dash--input-overlay))
  (setq agent-dash--input-overlay
        (make-overlay agent-dash--input-start (point-max) nil nil t))
  (overlay-put agent-dash--input-overlay 'face 'agent-dash-input-face)
  (overlay-put agent-dash--input-overlay 'before-string
               (concat (agent-dash-image-attachments-string)
                       (propertize "You> " 'face 'agent-dash-input-face)))
  ;; Empty composers have a zero-length overlay: :extend alone cannot
  ;; paint the area after the virtual prompt.  Fill to the window edge
  ;; with display-only space, never padding the draft with real text.
  ;; Anchor the cursor at the start of that space, not after the fill
  ;; (or before the virtual prompt when the composer is empty).
  (overlay-put agent-dash--input-overlay 'after-string
               (propertize " " 'face 'agent-dash-input-face 'cursor t
                           'display '(space :align-to right))))

(defun agent-dash-refresh-chat ()
  "Rebuild this chat's presentation without restarting its agent or losing drafts."
  (interactive)
  (unless agent-dash--session (user-error "Not an agent-dash chat"))
  (let ((draft (agent-dash--input))
        (offset (and (agent-dash--in-input-p)
                     (- (point) agent-dash--input-start)))
        (position (point))
        (inhibit-read-only t)
        (buffer-undo-list t))
    (when (overlayp agent-dash--input-overlay)
      (delete-overlay agent-dash--input-overlay))
    (dolist (item (agent-dash-session-items agent-dash--session))
      (dolist (key '(:start :end))
        (when (markerp (plist-get item key)) (set-marker (plist-get item key) nil))
        (plist-put item key nil))
      (plist-put item :process-group nil))
    (erase-buffer)
    (insert (propertize "\n" 'read-only t 'rear-nonsticky t))
    (setq agent-dash--transcript-end (copy-marker (point-min) t)
          agent-dash--input-start (copy-marker (point-max)))
    (setq-local tab-line-format '(:eval (agent-dash--header)))
    (setq-local header-line-format '(:eval (agent-dash--pinned-prompt)))
    (agent-dash--install-status-line)
    (add-hook 'change-major-mode-hook #'agent-dash--stop-spinner nil t)
    (add-to-invisibility-spec 'agent-dash-process)
    (dolist (item (agent-dash-session-items agent-dash--session))
      (agent-dash--render agent-dash--session item))
    (agent-dash--render-process agent-dash--session nil)
    (agent-dash--set-input draft)
    (agent-dash--decorate-input)
    (goto-char (if offset (+ agent-dash--input-start offset)
                 (min position (point-max)))))
  (agent-dash--sync-spinner)
  (force-mode-line-update))

(defun agent-dash--on-kill ()
  "Detach from the agent when its chat buffer dies."
  (agent-dash--stop-spinner)
  (agent-dash--stop-answer-timer)
  (when-let* ((s agent-dash--session))
    (when (agent-dash-queue-managed-p s) (agent-dash-queue-disconnect s))
    (setq agent-dash--sessions (delq s agent-dash--sessions))
    (unless agent-dash--quitting
      (agent-dash-backend-detach (agent-dash-session-backend s) s))))

(defun agent-dash-open (backend root &optional resume-id)
  "Open a chat with BACKEND in ROOT, resuming RESUME-ID if non-nil.
Return the session."
  (let* ((session (agent-dash-session-create backend root))
         (buffer (agent-dash--setup-buffer session)))
    (agent-dash-backend-start backend session resume-id)
    (pop-to-buffer buffer)
    (goto-char (point-max))
    session))

;;;; Composer

(defun agent-dash--input ()
  "Return the composer text."
  (buffer-substring-no-properties agent-dash--input-start (point-max)))

(defun agent-dash--set-input (text)
  "Replace the composer text with TEXT."
  (delete-region agent-dash--input-start (point-max))
  (goto-char (point-max))
  (insert text))

(defun agent-dash--in-input-p ()
  "Whether point is in the composer."
  (>= (point) agent-dash--input-start))

(defun agent-dash--submit (mode)
  "Send the composer text with MODE, or with prompt/follow-up when MODE is nil."
  (let* ((text (string-trim (agent-dash--input)))
         (images agent-dash--attachments)
         (s agent-dash--session)
         (auth (and (eq (agent-dash-session-backend s) 'pi)
                    (string-match-p "\\`/\\(?:login\\|logout\\)\\(?:[[:space:]]\\|\\'\\)" text))))
    (when (and (string-empty-p text) (not images)) (user-error "Nothing to send"))
    (when (and (eq mode 'steer) (string-prefix-p "/" text))
      (user-error "Slash commands cannot be staged as steering; use RET"))
    (when (and images (string-prefix-p "/" text))
      (user-error "Remove images before running slash commands"))
    (when images
      (agent-dash-image--check-chat)
      (mapc #'agent-dash-image-bytes images))
    (unless (agent-dash-input-dispatch text)
      (setq mode (or mode (if (or (eq (agent-dash-session-state s) 'running)
                                  (agent-dash-queue-managed-p s))
                              'follow-up 'prompt)))
      (let ((queued (and (not auth) (not (string-prefix-p "/" text))
                         (memq mode '(follow-up steer)))))
        (when (and images (not queued))
          (setq agent-dash--last-image-draft (list :text (agent-dash--input) :images images)))
        (agent-dash-set-data s :image-draft-token
                             (and images (not queued) agent-dash--last-image-draft))
        (agent-dash-set-data s :image-send-error nil)
        ;; Queuing is atomic. Failures leave the original composer untouched.
        (if queued
            (agent-dash-queue-add s text images mode)
          (let ((sent (if auth text
                        (seq-reduce (lambda (acc f) (funcall f acc))
                                    agent-dash-prompt-filter-functions text)))
                (backend (agent-dash-session-backend s)))
            (if (string-prefix-p "/" text)
                (agent-dash-backend-command backend s sent mode)
              (agent-dash-backend-send backend s sent images mode)))))
      ;; Local enqueue has no direct-send token. Two nil values are not a failure.
      (when-let* ((token (and images (agent-dash-data s :image-draft-token)))
                  ((eq (agent-dash-data s :image-send-error) token)))
        (user-error "Image submission rejected; draft kept"))
      (unless auth (push text agent-dash--history))
      (setq agent-dash--history-index -1 agent-dash--history-draft nil)
      (setq agent-dash--attachments nil)
      (agent-dash--set-input "")
      (agent-dash--decorate-input))))

(defun agent-dash-send ()
  "Send the draft; while the agent runs it queues as a follow-up."
  (interactive)
  (if (derived-mode-p 'agent-dash-queue-edit-mode)
      (agent-dash-queue-edit-save)
    (agent-dash--submit nil)))

(defun agent-dash-steer ()
  "Stage the draft as steering; apply it explicitly in `agent-dash-queue'."
  (interactive)
  (unless (agent-dash-capability agent-dash--session :steer)
    (user-error "This backend cannot steer"))
  (unless (eq (agent-dash-session-state agent-dash--session) 'running)
    (user-error "Nothing is running; use RET to send"))
  (agent-dash--submit 'steer))

(defun agent-dash-ret ()
  "Send from the composer; toggle the item at point elsewhere."
  (interactive)
  (cond
   ((agent-dash-session-requests agent-dash--session) (agent-dash-answer))
   ((agent-dash--in-input-p) (agent-dash-send))
   (t (agent-dash-toggle))))

(defun agent-dash-tab ()
  "Toggle the item at point, or complete in the composer."
  (interactive)
  (if (agent-dash--in-input-p)
      (agent-dash-complete-input current-prefix-arg)
    (agent-dash-toggle)))

(defun agent-dash-toggle ()
  "Fold or unfold the tool or thinking item at point."
  (interactive)
  (let* ((id (get-text-property (point) 'agent-dash-item))
         (item (and id (agent-dash-item agent-dash--session id))))
    (unless item (user-error "No item here"))
    (if (get-text-property (point) 'agent-dash-process-heading)
        (let ((group (agent-dash-item
                      agent-dash--session (plist-get item :process-group))))
          (plist-put group :process-open (not (plist-get group :process-open)))
          (dolist (member (agent-dash-session-items agent-dash--session))
            (when (equal (plist-get member :process-group) (plist-get group :id))
              (agent-dash--render agent-dash--session member)))
          (goto-char (plist-get item :start)))
      (plist-put item :folded (if (agent-dash--item-folded-p item) 'open nil))
      (let ((pos (point)))
        (agent-dash--render agent-dash--session item)
        (goto-char (min pos (plist-get item :end)))))))

(defun agent-dash--history-move (delta)
  "Move DELTA steps through the prompt history."
  (let ((index (+ agent-dash--history-index delta)))
    (cond
     ((>= index (length agent-dash--history)) (user-error "No older prompt"))
     ((< index -1) (user-error "No newer prompt")))
    (when (= agent-dash--history-index -1)
      (setq agent-dash--history-draft (agent-dash--input)))
    (setq agent-dash--history-index index)
    (agent-dash--set-input (if (= index -1)
                               (or agent-dash--history-draft "")
                             (nth index agent-dash--history)))))

(defun agent-dash-previous-prompt ()
  "Replace the draft with the previous sent prompt."
  (interactive)
  (agent-dash--history-move 1))

(defun agent-dash-next-prompt ()
  "Replace the draft with the next sent prompt, then the saved draft."
  (interactive)
  (agent-dash--history-move -1))

(defun agent-dash-insert-or-focus (count)
  "Insert COUNT copies of i in the composer, or focus it from the transcript."
  (interactive "p")
  (if (agent-dash--in-input-p)
      (self-insert-command count)
    (agent-dash-focus-input)))

(defun agent-dash-focus-input ()
  "Move point to the end of the composer."
  (interactive)
  (goto-char (point-max)))

;;;; Commands

(defun agent-dash--read-backend ()
  "Read a backend symbol."
  (unless agent-dash-backends (user-error "No agent-dash backends loaded"))
  (if (cdr agent-dash-backends)
      (intern (completing-read "Agent: " (mapcar #'symbol-name agent-dash-backends)
                               nil t))
    (car agent-dash-backends)))

;; Autoload the main file, which loads every backend, not just this one.
;;;###autoload (autoload 'agent-dash "agent-dash" "Start a new agent chat." t)
(defun agent-dash (backend root)
  "Start a new chat with BACKEND in directory ROOT."
  (interactive
   (list (agent-dash--read-backend)
         (read-directory-name "Directory: " nil nil t)))
  (agent-dash-open backend root))

(defun agent-dash-resume (backend root)
  "Pick a saved session of BACKEND under ROOT and open it."
  (interactive
   (let ((backend (if agent-dash--session
                      (agent-dash-session-backend agent-dash--session)
                    (agent-dash--read-backend))))
     (list backend (if agent-dash--session
                       (agent-dash-session-root agent-dash--session)
                     (read-directory-name "Directory: " nil nil t)))))
  (let* ((sessions (or (agent-dash-backend-sessions backend root)
                       (user-error "No saved %s sessions" backend)))
         (choices (mapcar (lambda (s)
                            (cons (format "%s  %s%s" (or (plist-get s :time) "")
                                          (agent-dash--one-line (plist-get s :title) 60)
                                          (if (plist-get s :running) "  [running]" ""))
                                  s))
                          sessions))
         (pick (cdr (assoc (completing-read "Session: " choices nil t) choices))))
    (agent-dash-open backend (or (plist-get pick :root) root) (plist-get pick :id))))

(defun agent-dash-switch-chat ()
  "Switch to another live chat buffer."
  (interactive)
  (let ((names (mapcar (lambda (s) (buffer-name (agent-dash-session-buffer s)))
                       agent-dash--sessions)))
    (unless names (user-error "No chats"))
    (pop-to-buffer (completing-read "Chat: " names nil t))))

(defun agent-dash-select-model ()
  "Switch this chat's model."
  (interactive)
  (let* ((s agent-dash--session)
         (backend (agent-dash-session-backend s)))
    (agent-dash-backend-set-model
     backend s (completing-read "Model: " (agent-dash-backend-models backend s) nil t))))

(defun agent-dash-cancel ()
  "Stop the current task; the session continues."
  (interactive)
  (when (agent-dash-queue-managed-p agent-dash--session)
    (agent-dash-queue-disconnect agent-dash--session))
  (agent-dash-backend-cancel (agent-dash-session-backend agent-dash--session)
                             agent-dash--session))

(defun agent-dash-quit ()
  "Close this chat.  Backends with :quit `stop' end the agent after confirming."
  (interactive)
  (let ((s agent-dash--session))
    (when (or (not (eq (agent-dash-capability s :quit) 'stop))
              (yes-or-no-p "Stop this agent and close the chat? "))
      (agent-dash-backend-quit (agent-dash-session-backend s) s)
      (setq agent-dash--quitting t)
      (kill-buffer))))

(defun agent-dash--request-text (request)
  "Render REQUEST visibly, independently of folded process output."
  (concat
   (propertize (format "Question [%s]" (plist-get request :status))
               'face 'agent-dash-assistant-face)
   (if (eq (plist-get request :status) 'pending)
       " — RET / C-c C-a to answer; C-g to cancel\n"
     "\n")
   (or (plist-get request :title) "Agent asks") "\n"
   (when-let* ((message (plist-get request :message))) (concat message "\n"))
   (when-let* ((placeholder (plist-get request :placeholder)))
     (concat "Hint: " placeholder "\n"))
   (mapconcat (lambda (option) (concat "  • " option "\n"))
              (plist-get request :options) "")
   (mapconcat (lambda (question)
                (concat (plist-get question :question) "\n"
                        (mapconcat (lambda (option) (concat "  • " option "\n"))
                                   (plist-get question :options) "")))
              (plist-get request :questions) "")))

(defun agent-dash--stop-answer-timer ()
  "Stop this chat's deferred dialog timer."
  (when (timerp agent-dash--answer-timer)
    (cancel-timer agent-dash--answer-timer))
  (setq agent-dash--answer-timer nil))

(defun agent-dash--schedule-answer ()
  "Defer dialogs until outside process filters, only for the selected chat."
  (when (and agent-dash-auto-answer (not noninteractive)
             agent-dash--session (not agent-dash--answer-timer)
             (not agent-dash--answering)
             (agent-dash-session-requests agent-dash--session)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (setq agent-dash--answer-timer
          (run-at-time 0.1 nil #'agent-dash--maybe-answer (current-buffer)))))

(defun agent-dash--maybe-answer (buffer)
  "Answer BUFFER's pending dialogs without nesting an existing minibuffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-dash--answer-timer nil)
      (when (and agent-dash-auto-answer agent-dash--session
                 (not agent-dash--answering)
                 (agent-dash-session-requests agent-dash--session)
                 (eq (window-buffer (selected-window)) buffer))
        (if (active-minibuffer-window)
            (agent-dash--schedule-answer)
          (condition-case err
              (agent-dash-answer)
            (error (message "Agent dialog failed; C-c C-a to retry: %s"
                            (error-message-string err)))))))))

(defun agent-dash--ask (request)
  "Ask the user REQUEST; return the answer.  Quitting cancels the whole request."
  (let ((title (concat (or (plist-get request :title) "Agent asks")
                       (when-let* ((message (plist-get request :message)))
                         (concat "\n" message))
                       (when-let* ((hint (plist-get request :placeholder)))
                         (format " (%s)" hint))
                       " ")))
    (pcase (plist-get request :kind)
      ('confirm (y-or-n-p title))
      ('select (completing-read title (plist-get request :options) nil t))
      ('input (read-string title (plist-get request :default)))
      ('secret (read-passwd title))
      ('permission
       (pcase (car (read-multiple-choice
                    title '((?y "yes" "Allow") (?n "no" "Deny"))))
         (?y 'allow) (_ 'deny)))
      ('questions
       (mapcar (lambda (q)
                 (let ((prompt (concat (plist-get q :question) " ")))
                   ;; A multi-select answer is a list of strings.
                   (if (plist-get q :multi)
                       (completing-read-multiple prompt (plist-get q :options) nil
                                                 (eq (plist-get q :freeform) :false))
                     (completing-read prompt (plist-get q :options) nil
                                      (eq (plist-get q :freeform) :false)))))
               (plist-get request :questions)))
      (kind (error "Unknown request kind %S" kind)))))

(defun agent-dash-answer ()
  "Answer pending dialogs.  Keyboard quit cancels rather than leaving one hung."
  (interactive)
  (when agent-dash--answering (user-error "An agent dialog is already open"))
  (let ((s agent-dash--session)
        (agent-dash--answering t)
        cancelled)
    (agent-dash--stop-answer-timer)
    (unless (agent-dash-session-requests s) (user-error "No pending requests"))
    (while (and (not cancelled) (agent-dash-session-requests s))
      (let* ((request (car (agent-dash-session-requests s)))
             (answer (condition-case nil (agent-dash--ask request)
                       (quit (setq cancelled t) :cancelled))))
        ;; Timers/process filters can withdraw a dialog while the user reads it.
        (when (memq request (agent-dash-session-requests s))
          (agent-dash-backend-respond (agent-dash-session-backend s) s request answer)
          (agent-dash-emit s (list :type 'request-done :id (plist-get request :id)
                                   :status (if cancelled 'cancelled 'answered))))))))

(provide 'agent-dash-ui)
;;; agent-dash-ui.el ends here
