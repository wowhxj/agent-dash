;;; agent-dash-hub.el --- Cross-agent session hub -*- lexical-binding: t; -*-

;;; Commentary:

;; One list of the saved sessions of every backend, built only from
;; `agent-dash-backend-sessions' and `agent-dash-backend-transcript'.
;; RET opens a session (or switches to its live chat), N starts one,
;; / filters, d shows details.  `agent-dash-insert-reference' puts an
;; @session reference into a chat draft; sending expands it into the
;; referenced conversation.

;;; Code:

(require 'agent-dash-ui)
(require 'tabulated-list)
(require 'transient)

(defgroup agent-dash-hub nil "Session hub of `agent-dash'." :group 'agent-dash)

(defcustom agent-dash-reference-max-chars 20000
  "Characters of conversation appended for all @session references of a prompt."
  :type 'integer)

(defconst agent-dash--reference-regexp
  "@\\[[^]\n]*\\](agent-dash:\\([a-z]+\\):\\([^)\n]+\\))"
  "An @session reference; group 1 is the backend, group 2 the session id.")

(defvar-local agent-dash-hub--filter nil "Regexp rows must match, or nil.")
(defvar-local agent-dash-hub--errors nil "Sources that failed to list, as strings.")

;;;; Rows

(defun agent-dash-hub--chat (backend id)
  "Return the live chat session of BACKEND session ID, or nil."
  (seq-find (lambda (s) (and (eq (agent-dash-session-backend s) backend)
                             (equal (agent-dash-data s :sid) id)))
            agent-dash--sessions))

(defun agent-dash-hub--collect ()
  "Return (ROWS . ERRORS): every backend's sessions as (BACKEND . PLIST)."
  (let (rows errors)
    (dolist (backend agent-dash-backends)
      ;; One broken source must not hide the others; its error is shown.
      (condition-case err
          (dolist (s (agent-dash-backend-sessions backend nil))
            (push (cons backend s) rows))
        (error (push (format "%s: %s" backend (error-message-string err)) errors))))
    (cons (nreverse rows) (nreverse errors))))

(defun agent-dash-hub--entry (row)
  "Return the tabulated-list entry of ROW."
  (let* ((backend (car row)) (s (cdr row))
         (live (or (plist-get s :running) (agent-dash-hub--chat backend (plist-get s :id)))))
    (list row
          (vector (symbol-name backend)
                  (if live (propertize "●" 'face 'success) " ")
                  (or (plist-get s :time) "")
                  (abbreviate-file-name (or (plist-get s :root) ""))
                  (agent-dash--one-line (plist-get s :title) 200)))))

(defun agent-dash-hub--refresh ()
  "Rebuild the hub rows."
  (let ((result (agent-dash-hub--collect)))
    (setq agent-dash-hub--errors (cdr result)
          tabulated-list-entries
          (seq-filter (lambda (entry)
                        (or (not agent-dash-hub--filter)
                            (string-match-p agent-dash-hub--filter
                                            (mapconcat #'identity (cadr entry) " "))))
                      (mapcar #'agent-dash-hub--entry (car result))))
    (setq header-line-format
          (concat (if agent-dash-hub--filter (format " filter: %s " agent-dash-hub--filter) "")
                  (if agent-dash-hub--errors
                      (propertize (concat " " (string-join agent-dash-hub--errors "; "))
                                  'face 'error)
                    "")))
    (tabulated-list-print t)))

(defun agent-dash-hub--row ()
  "Return the row at point."
  (or (tabulated-list-get-id) (user-error "No session here")))

;;;; Commands

(defun agent-dash-hub-open ()
  "Open the session at point, or switch to its live chat."
  (interactive)
  (let* ((row (agent-dash-hub--row))
         (chat (agent-dash-hub--chat (car row) (plist-get (cdr row) :id))))
    (if chat
        (pop-to-buffer (agent-dash-session-buffer chat))
      (agent-dash-open (car row) (or (plist-get (cdr row) :root) default-directory)
                       (plist-get (cdr row) :id)))))

(defun agent-dash-hub-filter (regexp)
  "Show only rows matching REGEXP; empty shows all."
  (interactive (list (read-regexp "Filter (agent, project, prompt): ")))
  (setq agent-dash-hub--filter (and (not (string-empty-p regexp)) regexp))
  (agent-dash-hub--refresh))

(defun agent-dash-hub--transcript-text (backend id max)
  "Return saved session ID of BACKEND as text of at most MAX chars."
  (let ((text (mapconcat (lambda (turn) (format "%s: %s" (if (eq (car turn) 'user) "User" "Agent")
                                                (cdr turn)))
                         (agent-dash-backend-transcript backend id) "\n\n")))
    (if (> (length text) max)
        (concat "…" (substring text (- (length text) max)))
      text)))

(defun agent-dash-hub-details ()
  "Show the session at point and its conversation."
  (interactive)
  (let* ((row (agent-dash-hub--row)) (s (cdr row)))
    (with-current-buffer (get-buffer-create "*agent-dash details*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Agent:   %s\nSession: %s\nProject: %s\nTime:    %s\nRunning: %s\n\n"
                        (car row) (plist-get s :id) (plist-get s :root)
                        (plist-get s :time) (if (plist-get s :running) "yes" "no")))
        (insert (condition-case err
                    (agent-dash-hub--transcript-text (car row) (plist-get s :id) 200000)
                  (user-error (error-message-string err)))))
      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(defun agent-dash-hub-new ()
  "Start a new session, choosing agent and directory."
  (interactive)
  (call-interactively #'agent-dash))

(transient-define-prefix agent-dash-hub-menu ()
  "Commands of the session hub."
  [["Session"
    ("RET" "open / resume" agent-dash-hub-open)
    ("d" "details" agent-dash-hub-details)
    ("N" "new" agent-dash-hub-new)]
   ["List"
    ("/" "filter" agent-dash-hub-filter)
    ("g" "refresh" revert-buffer)
    ("q" "quit" quit-window)]])

(defvar agent-dash-hub-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-dash-hub-open)
    (define-key map (kbd "d") #'agent-dash-hub-details)
    (define-key map (kbd "N") #'agent-dash-hub-new)
    (define-key map (kbd "/") #'agent-dash-hub-filter)
    (define-key map (kbd "?") #'agent-dash-hub-menu)
    map)
  "Keymap for `agent-dash-hub-mode'.")

(define-derived-mode agent-dash-hub-mode tabulated-list-mode "Agent-Hub"
  "Saved sessions of every agent.  \\<agent-dash-hub-mode-map>\\[agent-dash-hub-menu] for commands."
  (setq tabulated-list-format [("Agent" 7 t) ("" 1 t) ("Time" 16 t)
                               ("Project" 28 t) ("First prompt" 0 nil)]
        tabulated-list-sort-key '("Time" . t))
  (add-hook 'tabulated-list-revert-hook #'agent-dash-hub--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-dash-hub ()
  "List the saved sessions of every agent."
  (interactive)
  (let ((buffer (get-buffer-create "*agent-dash hub*")))
    (with-current-buffer buffer
      (agent-dash-hub-mode)
      (agent-dash-hub--refresh))
    (pop-to-buffer-same-window buffer)))

;;;; @session references

(defun agent-dash-insert-reference ()
  "Insert an @session reference to a saved session at point."
  (interactive)
  (let* ((choices (mapcar (lambda (row)
                            (cons (format "%-6s %s  %s" (car row)
                                          (or (plist-get (cdr row) :time) "")
                                          (agent-dash--one-line (plist-get (cdr row) :title) 70))
                                  row))
                          (car (agent-dash-hub--collect))))
         (row (cdr (assoc (completing-read "Reference session: " choices nil t) choices))))
    (insert (format "@[%s](agent-dash:%s:%s)"
                    (replace-regexp-in-string
                     "[][\n]" " " (agent-dash--one-line (plist-get (cdr row) :title) 40))
                    (car row) (plist-get (cdr row) :id)))))

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
