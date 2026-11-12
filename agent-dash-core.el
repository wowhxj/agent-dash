;;; agent-dash-core.el --- Sessions, events and backend interface -*- lexical-binding: t; -*-

;;; Commentary:

;; Data model shared by every backend and the UI.  Backends translate
;; their protocol into the unified events of docs/DESIGN.md §2.2 and
;; call `agent-dash-emit'; the timeline reducer here is the only code
;; that changes `agent-dash-session-items'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup agent-dash nil
  "Native agent clients and cross-agent session hub."
  :group 'tools)

(defcustom agent-dash-directory (locate-user-emacs-file "agent-dash/")
  "Directory for `agent-dash' runtime state, such as holder instances."
  :type 'directory)

(defvar agent-dash-backends nil
  "Backend symbols available to `agent-dash'; each backend file adds one.")

(defvar agent-dash-update-functions nil
  "Abnormal hook run as (SESSION ITEM) after an event changed ITEM.
ITEM is nil when only session-level state (run, queue, meta) changed.")

(cl-defstruct (agent-dash-session (:constructor agent-dash-session--make))
  "One chat.  ID is local; it is neither the backend session id nor ROOT."
  id backend root buffer
  (items nil) (index (make-hash-table :test #'equal))
  (state 'idle) (queue nil) (meta nil) (requests nil)
  (data nil))

(defun agent-dash-uuid ()
  "Return a random version-4 UUID string."
  (let ((h (md5 (format "%s%s%s%s" (current-time) (random) (emacs-pid)
                        (recent-keys)))))
    (format "%s-%s-4%s-%x%s-%s" (substring h 0 8) (substring h 8 12)
            (substring h 13 16) (+ 8 (random 4)) (substring h 17 20)
            (substring h 20 32))))

(defun agent-dash-json-read (string)
  "Parse JSON STRING: objects become hash tables, arrays lists, null/false nil."
  (json-parse-string string :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object nil))

(defun agent-dash-jget (object &rest keys)
  "Follow string KEYS into parsed JSON OBJECT; nil when any step is missing."
  (while (and keys (hash-table-p object))
    (setq object (gethash (pop keys) object)))
  (and (null keys) object))

(defun agent-dash-json-text (content)
  "Return the text of message CONTENT: a string or a list of blocks."
  (if (stringp content)
      content
    (mapconcat (lambda (block)
                 (if (equal (agent-dash-jget block "type") "text")
                     (or (agent-dash-jget block "text") "")
                   ""))
               content "")))

(defun agent-dash-labels (options)
  "Return the \"label\" of each parsed JSON object in OPTIONS."
  (mapcar (lambda (o) (agent-dash-jget o "label")) options))

(defun agent-dash-file-lines (file &optional limit)
  "Return the complete lines of FILE, reading at most LIMIT bytes if non-nil.
A last line without its newline is still being written, or was cut off by
LIMIT, so it is dropped."
  (with-temp-buffer
    (insert-file-contents file nil 0 limit)
    (butlast (split-string (buffer-string) "\n"))))

(defun agent-dash-session-create (backend root)
  "Return a new session for BACKEND in ROOT."
  (agent-dash-session--make :id (agent-dash-uuid) :backend backend
                            :root (file-name-as-directory
                                   (expand-file-name root))))

(defun agent-dash-data (session key)
  "Return backend-private value KEY of SESSION."
  (plist-get (agent-dash-session-data session) key))

(defun agent-dash-set-data (session key value)
  "Set backend-private KEY of SESSION to VALUE; return VALUE."
  (setf (agent-dash-session-data session)
        (plist-put (agent-dash-session-data session) key value))
  value)

(defun agent-dash-item (session id)
  "Return timeline item ID of SESSION, or nil."
  (gethash id (agent-dash-session-index session)))

(defun agent-dash--plist-merge (old new)
  "Return OLD with every key of NEW set to NEW's value."
  (cl-loop for (k v) on new by #'cddr do (setq old (plist-put old k v)))
  old)

(defun agent-dash--upsert (session event)
  "Insert or update the timeline item for EVENT in SESSION; return it."
  (let* ((id (or (plist-get event :id) (agent-dash-uuid)))
         (item (agent-dash-item session id)))
    (if item
        ;; In place: the item (and the UI's markers in it) keeps its identity.
        (agent-dash--plist-merge item event)
      (setq item (append (list :id id) (cl-copy-list event)))
      (puthash id item (agent-dash-session-index session))
      (setf (agent-dash-session-items session)
            (nconc (agent-dash-session-items session) (list item))))
    item))

(defun agent-dash-emit (session event)
  "Apply unified EVENT to SESSION and notify the UI."
  (let ((item nil))
    (pcase (plist-get event :type)
      ((or 'user 'assistant 'tool 'notice)
       (setq item (agent-dash--upsert session event)))
      ('run (setf (agent-dash-session-state session) (plist-get event :state)))
      ('queue (setf (agent-dash-session-queue session)
                    (list :steering (plist-get event :steering)
                          :follow-up (plist-get event :follow-up))))
      ('meta (setf (agent-dash-session-meta session)
                   (agent-dash--plist-merge (agent-dash-session-meta session)
                                            (cddr event))))
      ('request
        (setf (agent-dash-session-requests session)
              (append (cl-remove (plist-get event :id)
                                 (agent-dash-session-requests session)
                                 :key (lambda (r) (plist-get r :id))
                                 :test #'equal)
                      (list event))))
      ('request-done
       (setf (agent-dash-session-requests session)
             (cl-remove (plist-get event :id)
                        (agent-dash-session-requests session)
                        :key (lambda (r) (plist-get r :id)) :test #'equal)))
      (type (error "Unknown agent-dash event type: %S" type)))
    (run-hook-with-args 'agent-dash-update-functions session item)
    item))

;;;; Backend interface (docs/DESIGN.md §3)

(cl-defgeneric agent-dash-backend-capabilities (backend)
  "Return capabilities of BACKEND as a plist.
Keys: :quit (`stop' or `detach'), :steer, :images, :models.")

(cl-defgeneric agent-dash-backend-start (backend session &optional resume-id)
  "Start SESSION on BACKEND, resuming backend session RESUME-ID if non-nil.")

(cl-defgeneric agent-dash-backend-send (backend session text images mode)
  "Send TEXT with IMAGES to SESSION on BACKEND.
MODE is `prompt', `follow-up' or `steer'.")

(cl-defgeneric agent-dash-backend-cancel (backend session)
  "Stop the current task of SESSION on BACKEND; the session continues.")

(cl-defgeneric agent-dash-backend-quit (backend session)
  "End SESSION on BACKEND as its :quit capability says: stop or detach.")

(cl-defgeneric agent-dash-backend-detach (backend session)
  "Disconnect this Emacs from SESSION on BACKEND; the agent keeps running.")

(cl-defgeneric agent-dash-backend-respond (backend session request answer)
  "Answer REQUEST event of SESSION on BACKEND with ANSWER."
  (ignore session request answer)
  (user-error "Backend %s cannot answer requests" backend))

(cl-defgeneric agent-dash-backend-models (backend session)
  "Return model names SESSION on BACKEND can switch to."
  (ignore session)
  (user-error "Backend %s cannot list models" backend))

(cl-defgeneric agent-dash-backend-set-model (backend session model)
  "Switch SESSION on BACKEND to MODEL."
  (ignore session model)
  (user-error "Backend %s cannot switch models" backend))

(cl-defgeneric agent-dash-backend-sessions (backend root)
  "Return saved sessions of BACKEND under ROOT (nil means all).
Each is a plist (:id :title :root :time :running)."
  (ignore backend root)
  nil)

(cl-defgeneric agent-dash-backend-transcript (backend id)
  "Return saved session ID of BACKEND as a list of (ROLE . TEXT).
ROLE is `user' or `assistant'."
  (ignore id)
  (user-error "Backend %s cannot read saved transcripts" backend))

(defun agent-dash-capability (session key)
  "Return capability KEY of SESSION's backend."
  (plist-get (agent-dash-backend-capabilities (agent-dash-session-backend session))
             key))

(provide 'agent-dash-core)
;;; agent-dash-core.el ends here
