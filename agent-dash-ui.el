;;; agent-dash-ui.el --- Chat buffer for agent-dash sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; One chat buffer per session: a read-only transcript of timeline
;; items, a separator, and an editable composer at the bottom.  Each
;; item owns the region START..END (its trailing newline excluded), so
;; an update re-renders only that item and never touches the draft.

;;; Code:

(require 'agent-dash-core)
(require 'markdown-mode)

(defgroup agent-dash-ui nil "Chat buffer of `agent-dash'." :group (quote agent-dash))

(defcustom agent-dash-tool-output-lines 40
  "Lines of tool output shown when a tool item is expanded."
  :type 'integer)

(defface agent-dash-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user label.")
(defface agent-dash-assistant-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant label.")
(defface agent-dash-process-face '((t :inherit shadow))
  "Face for tool and thinking lines.")
(defface agent-dash-separator-face '((t :inherit shadow))
  "Face for the line above the composer.")

(defvar-local agent-dash--session nil "Session shown in this chat buffer.")
(defvar-local agent-dash--transcript-end nil
  "Marker where the next timeline item goes; advances on insertion.")
(defvar-local agent-dash--input-start nil "Marker at the composer start.")
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

(defun agent-dash--label (session)
  "Return the assistant label of SESSION."
  (propertize (format "%s: " (capitalize (symbol-name
                                          (agent-dash-session-backend session))))
              'face 'agent-dash-assistant-face))

(defun agent-dash--item-text (session item)
  "Return the display string of timeline ITEM of SESSION."
  (let ((folded (not (eq (plist-get item :folded) 'open))))
    (pcase (plist-get item :type)
      ('user
       (concat (propertize "You: " 'face 'agent-dash-user-face)
               (let* ((text (plist-get item :text))
                      (cut (string-search agent-dash-reference-boundary text)))
                 (if cut (substring text 0 cut) text))
               (if (plist-get item :images)
                   (format " [%d image(s)]" (length (plist-get item :images)))
                 "")))
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
                    (if (plist-get item :final) (agent-dash--markdown text) text))))))
      ('tool
       (let* ((status (plist-get item :status))
              (head (format "%s %s  %s"
                            (pcase status ('success "✓") ('error "✗") (_ "…"))
                            (plist-get item :name)
                            (agent-dash--one-line (plist-get item :args) 70)))
              (output (plist-get item :output)))
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
          'face (if (eq status 'error) 'error 'agent-dash-process-face))))
      ('notice
       (propertize (format "[%s]" (plist-get item :text))
                   'face (pcase (plist-get item :level)
                           ('error 'error) ('warning 'warning) (_ 'shadow)))))))

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
      (add-text-properties start (1+ (plist-get item :end))
                           (list 'read-only t 'front-sticky '(read-only)
                                 'agent-dash-item (plist-get item :id))))))

(defun agent-dash--on-update (session item)
  "Show SESSION's change of ITEM in its buffer."
  (let ((buffer (agent-dash-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when item (agent-dash--render session item))
        (force-mode-line-update)))))

(add-hook 'agent-dash-update-functions #'agent-dash--on-update)

(defun agent-dash--mode-line ()
  "Return the mode-line status of this chat."
  (when-let* ((s agent-dash--session))
    (let* ((queue (agent-dash-session-queue s))
           (q (+ (length (plist-get queue :steering))
                 (length (plist-get queue :follow-up))))
           (model (plist-get (agent-dash-session-meta s) :model))
           (requests (length (agent-dash-session-requests s))))
      (string-replace
       "%" "%%"
       (concat " " (symbol-name (agent-dash-session-state s))
               (if (> q 0) (format " Q%d" q) "")
               (if (> requests 0) (format " ?%d C-c C-a" requests) "")
               (if model (format " · %s" model) ""))))))

;;;; Buffer

(declare-function agent-dash-insert-reference "agent-dash-hub" ())

(defvar agent-dash-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-dash-ret)
    (define-key map (kbd "<S-return>") #'newline)
    (define-key map (kbd "TAB") #'agent-dash-tab)
    (define-key map (kbd "M-p") #'agent-dash-previous-prompt)
    (define-key map (kbd "M-n") #'agent-dash-next-prompt)
    (define-key map (kbd "C-c C-c") #'agent-dash-send)
    (define-key map (kbd "C-c C-s") #'agent-dash-steer)
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
  (setq-local mode-line-process '(:eval (agent-dash--mode-line)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (add-hook 'completion-at-point-functions #'agent-dash--file-capf nil t)
  (add-hook 'kill-buffer-hook #'agent-dash--on-kill nil t))

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
        (insert (propertize (concat (make-string 40 ?─) "\n")
                            'face 'agent-dash-separator-face 'read-only t
                            'rear-nonsticky t)))
      (setq agent-dash--transcript-end (copy-marker (point-min) t)
            agent-dash--input-start (copy-marker (point-max))))
    (setf (agent-dash-session-buffer session) buffer)
    (push session agent-dash--sessions)
    buffer))

(defun agent-dash--on-kill ()
  "Detach from the agent when its chat buffer dies."
  (when-let* ((s agent-dash--session))
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
  (let ((text (string-trim (agent-dash--input)))
        (s agent-dash--session))
    (when (string-empty-p text) (user-error "Nothing to send"))
    (setq mode (or mode (if (eq (agent-dash-session-state s) 'running)
                            'follow-up 'prompt)))
    ;; Clear only after the backend accepted the write; on error the
    ;; draft stays.
    (agent-dash-backend-send (agent-dash-session-backend s) s
                             (seq-reduce (lambda (acc f) (funcall f acc))
                                         agent-dash-prompt-filter-functions text)
                             nil mode)
    (push text agent-dash--history)
    (setq agent-dash--history-index -1 agent-dash--history-draft nil)
    (agent-dash--set-input "")))

(defun agent-dash-send ()
  "Send the draft; while the agent runs it queues as a follow-up."
  (interactive)
  (agent-dash--submit nil))

(defun agent-dash-steer ()
  "Send the draft to steer the running task."
  (interactive)
  (unless (agent-dash-capability agent-dash--session :steer)
    (user-error "This backend cannot steer"))
  (unless (eq (agent-dash-session-state agent-dash--session) 'running)
    (user-error "Nothing is running; use RET to send"))
  (agent-dash--submit 'steer))

(defun agent-dash-ret ()
  "Send from the composer; toggle the item at point elsewhere."
  (interactive)
  (if (agent-dash--in-input-p) (agent-dash-send) (agent-dash-toggle)))

(defun agent-dash-tab ()
  "Toggle the item at point, or complete in the composer."
  (interactive)
  (if (agent-dash--in-input-p) (completion-at-point) (agent-dash-toggle)))

(defun agent-dash-toggle ()
  "Fold or unfold the tool or thinking item at point."
  (interactive)
  (let* ((id (get-text-property (point) 'agent-dash-item))
         (item (and id (agent-dash-item agent-dash--session id))))
    (unless item (user-error "No item here"))
    (plist-put item :folded (if (eq (plist-get item :folded) 'open) nil 'open))
    (let ((pos (point)))
      (agent-dash--render agent-dash--session item)
      (goto-char (min pos (plist-get item :end))))))

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

;;;###autoload
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

(defun agent-dash--ask (request)
  "Ask the user REQUEST; return the answer."
  (let ((title (format "%s " (plist-get request :title))))
    (pcase (plist-get request :kind)
      ('confirm (y-or-n-p title))
      ('select (completing-read title (plist-get request :options) nil t))
      ('input (read-string title (plist-get request :default)))
      ('permission
       (pcase (car (read-multiple-choice
                    title '((?y "yes" "Allow") (?n "no" "Deny"))))
         (?y 'allow) (_ 'deny)))
      ('questions
       (mapcar (lambda (q)
                 (let ((prompt (concat (plist-get q :question) " ")))
                   ;; A multi-select answer is a list of strings.
                   (if (plist-get q :multi)
                       (completing-read-multiple prompt (plist-get q :options))
                     (completing-read prompt (plist-get q :options)))))
               (plist-get request :questions)))
      (kind (error "Unknown request kind %S" kind)))))

(defun agent-dash-answer ()
  "Answer the agent's pending questions and permission requests."
  (interactive)
  (let ((s agent-dash--session))
    (unless (agent-dash-session-requests s) (user-error "No pending requests"))
    (while (agent-dash-session-requests s)
      (let* ((request (car (agent-dash-session-requests s)))
             (answer (agent-dash--ask request)))
        (agent-dash-backend-respond (agent-dash-session-backend s) s request answer)
        (agent-dash-emit s (list :type 'request-done :id (plist-get request :id)))))))

(provide 'agent-dash-ui)
;;; agent-dash-ui.el ends here
