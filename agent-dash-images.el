;;; agent-dash-images.el --- Shared image attachments and previews -*- lexical-binding: t; -*-

;;; Commentary:
;; Raster images only.  History rendering never fetches remote URLs or evaluates SVG.
;; Clipboard programs are optional; ordinary text paste still uses `yank'.

;;; Code:
(require 'agent-dash-core)
(require 'image)
(require 'image-mode)

(defcustom agent-dash-image-max-bytes (* 10 1024 1024)
  "Largest individual image accepted by the client, in bytes.
Providers may impose smaller limits."
  :type 'integer :group 'agent-dash)

(defcustom agent-dash-image-preview-width 240
  "Maximum thumbnail width in pixels."
  :type 'integer :group 'agent-dash)

(defcustom agent-dash-image-preview-height 160
  "Maximum thumbnail height in pixels."
  :type 'integer :group 'agent-dash)

(defcustom agent-dash-pngpaste-executable "pngpaste"
  "Optional macOS clipboard reader; an absolute path also works in GUI Emacs."
  :type 'string :group 'agent-dash)

(defvar agent-dash--session)
(defvar agent-dash--input-start)
(defvar-local agent-dash--attachments nil "Images staged for the next submission.")
(defvar-local agent-dash--last-image-draft nil "Last image submission, for explicit recovery.")
(defvar-local agent-dash--image-cache nil "Decoded thumbnail cache for this chat.")
(defvar-local agent-dash--failed-image-drafts nil "Failed submissions awaiting explicit recovery.")
(declare-function agent-dash--input "agent-dash-ui" ())
(declare-function agent-dash--set-input "agent-dash-ui" (text))
(declare-function agent-dash--decorate-input "agent-dash-ui" ())
(declare-function agent-dash-focus-input "agent-dash-ui" ())

(defun agent-dash-image--mime (bytes)
  "Identify raster BYTES by signature, never by filename or declared MIME."
  (cond ((string-prefix-p (unibyte-string 137 80 78 71 13 10 26 10) bytes) "image/png")
        ((string-prefix-p (unibyte-string 255 216 255) bytes) "image/jpeg")
        ((or (string-prefix-p "GIF87a" bytes) (string-prefix-p "GIF89a" bytes)) "image/gif")
        ((and (>= (length bytes) 12) (string-prefix-p "RIFF" bytes)
              (equal (substring bytes 8 12) "WEBP")) "image/webp")))

(defun agent-dash-image-bytes (image)
  "Decode and validate canonical IMAGE, rejecting oversized or mislabeled input."
  (let ((data (plist-get image :data)))
    (unless (and (stringp data)
                 (< (length data) (+ 4096 (* 4 (ceiling agent-dash-image-max-bytes 3)))))
      (user-error "Image is missing or too large"))
    (let ((bytes (condition-case nil (base64-decode-string data)
                   (error (user-error "Invalid image base64")))))
      (unless (<= (length bytes) agent-dash-image-max-bytes)
        (user-error "Image exceeds %d bytes" agent-dash-image-max-bytes))
      (unless (and (agent-dash-image--mime bytes)
                   (equal (agent-dash-image--mime bytes) (plist-get image :mime-type)))
        (user-error "Only matching PNG, JPEG, GIF and WebP data are supported"))
      bytes)))

(defun agent-dash-image-from-file (file)
  "Read local raster FILE into a canonical image without retaining a temporary path."
  (when (file-remote-p file) (user-error "Remote image files are not read automatically"))
  (unless (and (file-regular-p file) (file-readable-p file))
    (user-error "Image is not a readable regular file"))
  (unless (<= (file-attribute-size (file-attributes file)) agent-dash-image-max-bytes)
    (user-error "Image exceeds %d bytes" agent-dash-image-max-bytes))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 (1+ agent-dash-image-max-bytes))
    (when (> (buffer-size) agent-dash-image-max-bytes)
      (user-error "Image exceeds %d bytes" agent-dash-image-max-bytes))
    (let ((mime (agent-dash-image--mime (buffer-string))))
      (unless mime (user-error "Only PNG, JPEG, GIF and WebP images are supported"))
      (list :mime-type mime :data (base64-encode-string (buffer-string) t)
            :name (file-name-nondirectory file)))))

(defun agent-dash-image-data-url (image)
  "Return a validated data URL for IMAGE."
  (agent-dash-image-bytes image)
  (concat "data:" (plist-get image :mime-type) ";base64," (plist-get image :data)))

(defun agent-dash-images-from-blocks (content &optional local-user-files)
  "Extract canonical images from CONTENT, optionally reading LOCAL-USER-FILES.
Remote URLs remain placeholders.  No network requests are made here."
  (let (images)
    (dolist (block (if (listp content) content (and (vectorp content) (append content nil))))
      (when (member (agent-dash-jget block "type")
                    '("image" "localImage" "image_url" "input_image"))
        (let* ((source (agent-dash-jget block "source"))
               (image-url (agent-dash-jget block "image_url"))
               (url (or (agent-dash-jget block "url") (agent-dash-jget source "url")
                        (and (stringp image-url) image-url)
                        (agent-dash-jget block "image_url" "url")))
               (data (or (agent-dash-jget block "data") (agent-dash-jget source "data")))
               (mime (or (agent-dash-jget block "mimeType") (agent-dash-jget block "mediaType")
                         (agent-dash-jget source "media_type")))
               (file (agent-dash-jget block "path")))
          (when (and (stringp url)
                     (string-match "\\`data:\\(image/[^;,]+\\);base64,\\(.*\\)\\'" url))
            (setq mime (match-string 1 url) data (match-string 2 url)))
          (push (or (and file local-user-files
                         (condition-case nil (agent-dash-image-from-file file) (error nil)))
                    (list :data data :mime-type mime :file file :uri url
                          :ask-file (and file (not local-user-files))
                          :name (or (agent-dash-jget block "name") "image"))) images))))
    (nreverse images)))

(defun agent-dash-image--label (image)
  "Return a plain one-line label for IMAGE."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\r\t]" " " (or (plist-get image :name) "image")) 60 nil nil "…"))

(defvar agent-dash-image-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'agent-dash-open-image)
    (define-key map (kbd "RET") #'agent-dash-open-image)
    map)
  "Keymap for inline images.")

(defvar agent-dash-image-remove-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'agent-dash-remove-image)
    map)
  "Keymap for the staged image removal button.")

(defun agent-dash-image-string (image)
  "Return an accessible thumbnail or safe placeholder for IMAGE."
  (let* ((label (format "[image: %s]" (agent-dash-image--label image)))
         (key (list (plist-get image :data) (plist-get image :mime-type)
                    agent-dash-image-preview-width agent-dash-image-preview-height))
         (cached (and agent-dash--image-cache (gethash key agent-dash--image-cache)))
         (display
          (when (display-images-p)
            (unless agent-dash--image-cache
              (setq agent-dash--image-cache (make-hash-table :test #'equal)))
            (or cached
                (puthash key
                         (or (condition-case nil
                                 (create-image (agent-dash-image-bytes image)
                                               (intern (substring (plist-get image :mime-type) 6)) t
                                               :max-width agent-dash-image-preview-width
                                               :max-height agent-dash-image-preview-height :scale 1)
                               (error nil))
                             'unavailable)
                         agent-dash--image-cache)))))
    (propertize label 'agent-dash-image image 'keymap agent-dash-image-map
                'mouse-face 'highlight
                'help-echo (concat label " — RET / click / C-c C-o: view image")
                'display (unless (eq display 'unavailable) display))))

(defun agent-dash-images-string (images)
  "Return inline previews of IMAGES, separated from surrounding text."
  (when images (concat "\n" (mapconcat #'agent-dash-image-string images "\n") "\n")))

(defun agent-dash-image-attachments-string ()
  "Return display-only staged previews for the composer."
  (when agent-dash--attachments
    (concat
     (mapconcat
      (lambda (image)
        (concat (agent-dash-image-string image) "  "
                (propertize "× remove" 'agent-dash-image image
                            'keymap agent-dash-image-remove-map 'mouse-face 'highlight
                            'help-echo "Click to remove this attachment") "\n"))
      agent-dash--attachments "") "\n")))

(defun agent-dash-image--check-chat ()
  "Require a chat whose backend supports images."
  (unless (and (derived-mode-p 'agent-dash-mode) agent-dash--session)
    (user-error "Not an agent-dash chat"))
  (unless (and (agent-dash-capability agent-dash--session :images)
               (not (eq (agent-dash-data agent-dash--session :images-supported) :false)))
    (user-error "This backend does not support images")))

(defun agent-dash-image--stage (image)
  "Validate IMAGE and append it to the current draft without editing its text."
  (agent-dash-image--check-chat)
  (agent-dash-image-bytes image)
  (when (>= (length agent-dash--attachments) 10) (user-error "At most 10 images per draft"))
  (when (> (+ (length (plist-get image :data))
              (apply #'+ (mapcar (lambda (i) (length (plist-get i :data)))
                                 agent-dash--attachments)))
           (* 28 1024 1024))
    (user-error "Combined images exceed the client limit"))
  (setq agent-dash--attachments (append agent-dash--attachments (list image)))
  (when (< (point) agent-dash--input-start) (agent-dash-focus-input))
  (agent-dash--decorate-input)
  (message "Attached %s" (agent-dash-image--label image)))

(defun agent-dash-attach-image (file)
  "Attach a local raster FILE to the current draft."
  (interactive "fImage file: ")
  (agent-dash-image--check-chat)
  (agent-dash-image--stage (agent-dash-image-from-file file)))

(defun agent-dash-image--clipboard ()
  "Return clipboard PNG bytes, or nil when unavailable or the clipboard is text."
  (let* ((program (or (executable-find agent-dash-pngpaste-executable)
                      (and (eq system-type 'darwin)
                           (seq-find #'file-executable-p
                                     '("/opt/homebrew/bin/pngpaste" "/usr/local/bin/pngpaste")))))
         (command (cond (program (list program "-"))
                        ((executable-find "wl-paste") '("wl-paste" "--type" "image/png"))
                        ((executable-find "xclip")
                         '("xclip" "-selection" "clipboard" "-t" "image/png" "-o")))))
    (when command
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (let ((coding-system-for-read 'no-conversion))
          (when (and (equal (apply #'process-file (car command) nil
                                   (list (current-buffer) nil) nil (cdr command)) 0)
                     (equal (agent-dash-image--mime (buffer-string)) "image/png"))
            (buffer-string)))))))

(defun agent-dash-paste (&optional image-only)
  "Paste a clipboard image, otherwise yank text unless IMAGE-ONLY is non-nil."
  (interactive)
  (unless (derived-mode-p 'agent-dash-mode) (user-error "Not an agent-dash chat"))
  (let ((bytes (agent-dash-image--clipboard)))
    (if bytes
        (agent-dash-image--stage (list :name "clipboard.png" :mime-type "image/png"
                                       :data (base64-encode-string bytes t)))
      (when image-only
        (user-error "No clipboard image; install pngpaste on macOS or select a file"))
      (when (< (point) agent-dash--input-start) (agent-dash-focus-input))
      (yank))))

(defun agent-dash-paste-image ()
  "Paste only an image; never insert clipboard text by accident."
  (interactive)
  (agent-dash-paste t))

(defun agent-dash-image--at-event (event)
  "Return the image at mouse EVENT or point, including overlay strings."
  (if (mouse-event-p event)
      (let* ((position (event-end event)) (string (posn-string position))
             (window (posn-window position)) (point (posn-point position)))
        (if string (get-text-property (cdr string) 'agent-dash-image (car string))
          (when (and (window-live-p window) (integerp point))
            (with-current-buffer (window-buffer window)
              (get-text-property point 'agent-dash-image)))))
    (or (get-text-property (point) 'agent-dash-image)
        (and (> (point) (point-min)) (get-text-property (1- (point)) 'agent-dash-image)))))

(defun agent-dash-image--choose (prompt)
  "Choose a staged image with PROMPT."
  (unless agent-dash--attachments (user-error "No staged images"))
  (let ((choices (cl-loop for image in agent-dash--attachments for n from 1
                          collect (cons (format "%d %s" n (agent-dash-image--label image)) image))))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun agent-dash-remove-image (&optional event)
  "Remove the staged image at EVENT, or choose one without changing the draft."
  (interactive (list last-input-event))
  (let* ((image (or (agent-dash-image--at-event event)
                    (agent-dash-image--choose "Remove image: ")))
         (window (and (mouse-event-p event) (posn-window (event-end event)))))
    (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
      (unless (memq image agent-dash--attachments) (user-error "This image is not staged"))
      (setq agent-dash--attachments (remq image agent-dash--attachments))
      (agent-dash--decorate-input))))

(defun agent-dash-open-image (&optional event)
  "View the image at EVENT or point, otherwise choose a staged attachment."
  (interactive (list last-input-event))
  (let* ((image (or (agent-dash-image--at-event event)
                    (agent-dash-image--choose "View image: ")))
         (bytes (agent-dash-image-bytes
                 (if (plist-get image :data) image
                   (if (plist-get image :file)
                       (progn
                         (when (and (plist-get image :ask-file)
                                    (not (yes-or-no-p
                                          (format "Open local image file %S? "
                                                  (plist-get image :file)))))
                           (user-error "Image file was not opened"))
                         (agent-dash-image-from-file (plist-get image :file)))
                     (user-error "Remote or unavailable image; no automatic downloads")))))
         (buffer (get-buffer-create "*agent-dash image*")))
    (unless (display-images-p) (user-error "This Emacs frame cannot display images"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (set-buffer-multibyte nil)
        (insert bytes))
      (image-mode)
      (setq buffer-read-only t)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

(defun agent-dash-restore-image-draft (&optional draft)
  "Restore DRAFT, or choose a failed/recent image draft, without sending it.
Never overwrite newer input; automatic rejection handling supplies DRAFT explicitly."
  (interactive)
  (unless (and (string-empty-p (agent-dash--input)) (not agent-dash--attachments))
    (user-error "Clear the current draft before restoring the previous one"))
  (unless draft
    (let* ((drafts (delete-dups (append agent-dash--failed-image-drafts
                                        (and agent-dash--last-image-draft
                                             (list agent-dash--last-image-draft)))))
           (choices (cl-loop for value in drafts for n from 1
                             collect (cons (format "%d %s (%d images): %s" n
                                                   (if (memq value agent-dash--failed-image-drafts)
                                                       "failed" "recent")
                                                   (length (plist-get value :images))
                                                   (truncate-string-to-width
                                                    (replace-regexp-in-string
                                                     "[\n\r\t]+" " " (plist-get value :text)) 60))
                                           value))))
      (unless choices (user-error "No image submission to recover"))
      (setq draft (if (cdr choices)
                      (cdr (assoc (completing-read "Recover image draft: " choices nil t) choices))
                    (cdar choices)))))
  (agent-dash--set-input (plist-get draft :text))
  (setq agent-dash--attachments (copy-sequence (plist-get draft :images))
        agent-dash--failed-image-drafts (remq draft agent-dash--failed-image-drafts))
  (agent-dash--decorate-input))

(defun agent-dash-image-send-failed (session token error)
  "Report ERROR for SESSION's submission TOKEN, restoring only an untouched draft."
  (when token
    (when-let* ((buffer (agent-dash-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and (derived-mode-p 'agent-dash-mode) (eq agent-dash--session session))
            (cl-pushnew token agent-dash--failed-image-drafts :test #'eq)
            (when (eq token (agent-dash-data session :image-draft-token))
              (agent-dash-set-data session :image-send-error token)
              (when (and (eq token agent-dash--last-image-draft)
                         (string-empty-p (agent-dash--input)) (not agent-dash--attachments))
                (agent-dash-restore-image-draft token))))))))
  (agent-dash-emit session (list :type 'notice :level 'error
                                 :text (concat (or error "Image submission failed")
                                               "; not resent. C-c C-u recovers the image draft"))))

(provide 'agent-dash-images)
;;; agent-dash-images.el ends here
