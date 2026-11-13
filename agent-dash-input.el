;;; agent-dash-input.el --- Minibuffer input completion -*- lexical-binding: t; -*-

;;; Commentary:

;; One input workflow for every backend.  TAB uses `completing-read', so
;; Vertico can render candidates and Orderless can match their metadata.
;; References reuse the Hub inventory; catalog reads never call a model.

;;; Code:

(require 'agent-dash-core)
(require 'project)

(defvar agent-dash--session)
(defvar agent-dash--input-start)
(defvar agent-dash--history)
(defvar agent-dash--history-index)
(defvar agent-dash--history-draft)
(declare-function agent-dash--input "agent-dash-ui")
(declare-function agent-dash--set-input "agent-dash-ui")
(declare-function agent-dash--one-line "agent-dash-ui")
(declare-function agent-dash-open "agent-dash-ui")
(declare-function agent-dash-resume "agent-dash-ui")
(declare-function agent-dash-select-model "agent-dash-ui")
(declare-function agent-dash-cancel "agent-dash-ui")
(declare-function agent-dash-quit "agent-dash-ui")
(declare-function agent-dash-hub "agent-dash-hub")
(declare-function agent-dash-hub-read-reference "agent-dash-hub")

(defun agent-dash-input-read (prompt choices &optional query)
  "Read a value from labelled CHOICES with PROMPT and initial QUERY.
Use standard minibuffer completion, preserving the user's Vertico setup.
Orderless, when installed, is enabled only for this picker."
  (unless choices (user-error "No candidates available"))
  (let* ((completion-styles (if (require 'orderless nil t)
                                '(orderless basic)
                              (append completion-styles '(substring))))
         (completion-ignore-case t)
         (table (completion-table-with-metadata
                 (mapcar #'car choices)
                 '((category . agent-dash-input)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity))))
         (choice (completing-read prompt table nil t query))
         (entry (assoc choice choices)))
    (unless entry (user-error "No candidate selected"))
    (cdr entry)))

(defun agent-dash-input-context ()
  "Return the completion context ending at point in the composer."
  (when (and agent-dash--session (markerp agent-dash--input-start)
             (>= (point) agent-dash--input-start))
    (let* ((begin (marker-position agent-dash--input-start))
           (head (buffer-substring-no-properties begin (point))))
      (cond
       ((string-match "\\`[ \t]*/\\([^ \t\n]*\\)\\'" head)
        (list :kind 'slash :query (match-string 1 head)
              :start (+ begin (1- (match-beginning 1)))
              :end (save-excursion (skip-chars-forward "^ \t\n") (point))))
       ((string-match
         "\\(?:\\`\\|[ \t\n]\\)@\\(session\\|dash\\)\\(?:[ \t]+\\([^@\n]*\\)\\)?\\'"
         head)
        (list :kind (intern (match-string 1 head))
              :query (or (match-string 2 head) "")
              :start (+ begin (1- (match-beginning 1))) :end (point)))
       ((string-match
         "\\(?:\\`\\|[ \t\n]\\)@\\(\"[^\"]*\"?\\|[^ \t\n@]*\\)\\'" head)
        (let* ((query (match-string 1 head))
               (start (+ begin (1- (match-beginning 1))))
               (quoted (string-prefix-p "\"" query)))
          (unless (string-prefix-p "[" query)
            (list :kind 'file :query (string-trim query "\"" "\"")
                  :start start
                  :end (save-excursion
                         (if quoted
                             (when (or (= (length query) 1)
                                       (not (string-suffix-p "\"" query)))
                               (search-forward "\"" (line-end-position) t))
                           (skip-chars-forward "^ \t\n"))
                         (point))))))))))

(defun agent-dash-input--files (root)
  "Return file candidates under ROOT, using the project inventory if available."
  (let* ((project (project-current nil root))
         (files (if project (project-files project)
                  (directory-files-recursively
                   root "." nil
                   (lambda (directory)
                     (not (member (file-name-nondirectory
                                   (directory-file-name directory))
                                  '(".git" ".hg" ".svn" "node_modules" ".venv"))))))))
    (delq nil
          (mapcar (lambda (file)
                    (let ((relative (file-relative-name file root)))
                      (unless (string-prefix-p "../" relative)
                        (cons relative relative))))
                  files))))

(defun agent-dash-input--commands (session &optional refresh)
  "Merge client commands with SESSION's advertised commands; REFRESH reloads."
  (let* ((backend (agent-dash-session-backend session))
         (local '(("help" . "Show available commands")
                  ("new" . "New session with this agent in this project")
                  ("resume" . "Resume a session with this agent")
                  ("dash" . "Open the cross-agent session Hub")
                  ("stop" . "Stop the current task")
                  ("quit" . "Quit using this backend's confirmation rules")))
         (seen (make-hash-table :test #'equal)))
    (when (agent-dash-capability session :models)
      (setq local (append local '(("model" . "Select a model")))))
    (when (or refresh (not (agent-dash-data session :commands-loaded)))
      (agent-dash-set-data
       session :command-catalog
       (condition-case nil (agent-dash-backend-commands backend session)
         (error (message "Backend catalog unavailable; showing client commands") nil)))
      (agent-dash-set-data session :commands-loaded t))
    (delq nil
          (mapcar
           (lambda (entry)
             (unless (gethash (car entry) seen)
               (puthash (car entry) t seen)
               entry))
           (append local (agent-dash-data session :command-catalog))))))

(defun agent-dash-complete-input (&optional refresh)
  "Complete /, @file, @session or @dash through the minibuffer.
With prefix argument REFRESH, reload the backend command catalog."
  (interactive "P")
  (let* ((context (or (agent-dash-input-context)
                      (user-error "TAB completes / commands and @ references")))
         (origin (current-buffer))
         (session agent-dash--session)
         (start (copy-marker (plist-get context :start)))
         (end (copy-marker (plist-get context :end) t))
         (original (buffer-substring-no-properties start end))
         (kind (plist-get context :kind))
         (query (plist-get context :query)))
    (unwind-protect
        (let ((replacement
               (pcase kind
                 ('slash
                  (concat
                   "/" (agent-dash-input-read
                        "Command: "
                        (mapcar (lambda (entry)
                                  (cons (format "/%s — %s" (car entry)
                                                (agent-dash--one-line (cdr entry) 100))
                                        (car entry)))
                                (agent-dash-input--commands session refresh)) query)))
                 ((or 'session 'dash)
                  (require 'agent-dash-hub)
                  (agent-dash-hub-read-reference
                   (and (eq kind 'session) (agent-dash-session-backend session)) query))
                 ('file
                  (let ((file (agent-dash-input-read
                               "Reference: "
                               (append '(("session — current agent's sessions" . session)
                                         ("dash — all agents' sessions" . dash))
                                       (agent-dash-input--files
                                        (agent-dash-session-root session))) query)))
                    (if (memq file '(session dash))
                        (progn
                          (require 'agent-dash-hub)
                          (agent-dash-hub-read-reference
                           (and (eq file 'session) (agent-dash-session-backend session))))
                      (concat "@" (if (string-match-p "[ \t\n\"]" file)
                                      (prin1-to-string file)
                                    (if (member file '("session" "dash"))
                                        (concat "./" file) file)))))))))
          (unless (buffer-live-p origin) (user-error "Chat was closed"))
          (with-current-buffer origin
            (unless (equal original (buffer-substring-no-properties start end))
              (user-error "Draft changed while selecting; nothing replaced"))
            (when (and (eq kind 'slash)
                       (not (memq (char-after end) '(?\s ?\t ?\n))))
              (setq replacement (concat replacement " ")))
            (delete-region start end)
            (goto-char start)
            (insert replacement)))
      (set-marker start nil)
      (set-marker end nil))))

(defun agent-dash-input-dispatch (text)
  "Handle client slash command TEXT, returning non-nil when handled.
Native commands return nil and are dispatched through the backend protocol."
  (when (string-match "\\`/\\([^[:space:]]+\\)\\(?:[[:space:]]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'" text)
    (let* ((command (match-string 1 text))
           (args (string-trim (or (match-string 2 text) "")))
           (session agent-dash--session)
           (backend (agent-dash-session-backend session))
           (origin (current-buffer))
           (draft (agent-dash--input)))
      (when (or (member command '("help" "new" "resume" "dash" "stop" "quit"))
                (and (equal command "model") (agent-dash-capability session :models)))
        (unless (string-empty-p args)
          (user-error "/%s does not accept arguments; use its picker" command))
        (pcase command
          ("help"
           (let ((entries (agent-dash-input--commands session)))
             (with-help-window "*agent-dash commands*"
               (princ "Client commands and backend-advertised commands/skills:\n\n")
               (dolist (entry entries)
                 (princ (format "/%s — %s\n" (car entry) (cdr entry))))
               (princ "\nTAB: minibuffer completion. C-u TAB: refresh commands.\n")
               (princ "@file: project files; @session: this agent; @dash: all agents.\n"))))
          ("new" (agent-dash-open backend (agent-dash-session-root session)))
          ("resume" (agent-dash-resume backend (agent-dash-session-root session)))
          ("dash" (require 'agent-dash-hub) (agent-dash-hub))
          ("stop" (agent-dash-cancel))
          ("quit" (agent-dash-quit))
          ("model" (agent-dash-select-model)))
        ;; Pickers may switch buffers.  C-g/errors preserve the original draft;
        ;; a declined /quit also keeps it.  Never clear a changed draft.
        (when (and (buffer-live-p origin) (not (equal command "quit")))
          (with-current-buffer origin
            (when (equal draft (agent-dash--input))
              (push text agent-dash--history)
              (setq agent-dash--history-index -1 agent-dash--history-draft nil)
              (agent-dash--set-input ""))))
        t))))

(provide 'agent-dash-input)
;;; agent-dash-input.el ends here
