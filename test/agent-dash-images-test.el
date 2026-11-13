;;; agent-dash-images-test.el --- Offline image regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; A one-pixel PNG, fake chats and intercepted protocols.  No clipboard, model or network IO.

;;; Code:
(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defconst agent-dash-images-test--png
  (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
          "AAAADUlEQVR4nGP438DwHwAGgAJ/EEwb4QAAAABJRU5ErkJggg=="))

(defun agent-dash-images-test--image ()
  "Return the tiny canonical fixture image."
  (list :name "tiny.png" :mime-type "image/png" :data agent-dash-images-test--png))

(defun agent-dash-images-test--json (value)
  "Convert fixture VALUE to a protocol hash table."
  (agent-dash-json-read (json-serialize value)))

(defun agent-dash-images-test--block (&optional style)
  "Return an image block in protocol STYLE."
  (agent-dash-images-test--json
   (pcase style
     ('claude (list :type "image" :source (list :type "base64" :media_type "image/png"
                                                :data agent-dash-images-test--png)))
     ('codex (list :type "image" :url (concat "data:image/png;base64,"
                                              agent-dash-images-test--png)))
     ('dsh (list :type "image" :mediaType "image/png" :data agent-dash-images-test--png))
     ('openai (list :type "image_url" :image_url
                    (list :url (concat "data:image/png;base64," agent-dash-images-test--png))))
     ('responses (list :type "input_image" :image_url
                       (concat "data:image/png;base64," agent-dash-images-test--png)))
     (_ (list :type "image" :mimeType "image/png" :data agent-dash-images-test--png)))))

(defmacro agent-dash-images-test-with-chat (&rest body)
  "Run BODY in an image-capable fake chat named `session'."
  (declare (indent 0))
  `(let* ((agent-dash-fake-calls nil)
          (session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect
           (cl-letf (((symbol-function 'agent-dash-backend-capabilities)
                      (lambda (_) '(:images t :steer t :quit stop))))
             ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))))))

(ert-deftest agent-dash-images-test-formats-and-trust-boundaries ()
  (let ((file (make-temp-file "dash-image-" nil ".not-a-png")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region (base64-decode-string agent-dash-images-test--png) nil file nil 'silent))
          (let ((image (agent-dash-image-from-file file)))
            (should (equal (plist-get image :mime-type) "image/png"))
            (should (equal (agent-dash-image-bytes image)
                           (base64-decode-string agent-dash-images-test--png))))
          (let ((agent-dash-image-max-bytes 4))
            (should-error (agent-dash-image-from-file file) :type 'user-error))
          (write-region "<svg><image href='file:///private/data'/></svg>" nil file nil 'silent)
          (should-error (agent-dash-image-from-file file) :type 'user-error)
          (should-error (agent-dash-image-from-file "/ssh:invalid:/image.png") :type 'user-error)
          (should-error (agent-dash-image-bytes '(:mime-type "image/png" :data "not-base64")))
          (should-error (agent-dash-image-bytes
                         (list :mime-type "image/jpeg" :data agent-dash-images-test--png))))
      (delete-file file))))

(ert-deftest agent-dash-images-test-normalizes-native-image-blocks ()
  (dolist (style '(pi claude codex dsh hermes openai responses))
    (let ((image (car (agent-dash-images-from-blocks
                       (list (agent-dash-images-test--block style))))))
      (should (equal (plist-get image :data) agent-dash-images-test--png))
      (should (equal (plist-get image :mime-type) "image/png")))))

(ert-deftest agent-dash-images-test-remote-placeholders-do-not-fetch ()
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _) (ert-fail "Downloading an untrusted image")))
            ((symbol-function 'display-images-p) (lambda (&rest _) t)))
    (let* ((block (agent-dash-images-test--json '(:type "image" :url "https://invalid/image.png")))
           (image (car (agent-dash-images-from-blocks (list block))))
           (label (agent-dash-image-string image)))
      (should (string-search "[image:" label))
      (should-not (get-text-property 0 'display label))
      (should (get-text-property 0 'agent-dash-image label)))))

(ert-deftest agent-dash-images-test-staging-refresh-and-removal-preserve-draft ()
  (agent-dash-images-test-with-chat
   (agent-dash--set-input "draft")
   (goto-char (+ agent-dash--input-start 2))
   (agent-dash-image--stage (agent-dash-images-test--image))
   (let ((image (car agent-dash--attachments)))
     (should (equal (agent-dash--input) "draft"))
     (should (= (point) (+ agent-dash--input-start 2)))
     (should (string-search "tiny.png" (overlay-get agent-dash--input-overlay 'before-string)))
     (should (get-text-property 0 'cursor
                                (overlay-get agent-dash--input-overlay 'after-string)))
     (agent-dash-emit session '(:type assistant :id "bg" :text "background"))
     (agent-dash-refresh-chat)
     (should (equal (agent-dash--input) "draft"))
     (should (= (point) (+ agent-dash--input-start 2)))
     (should (eq (car agent-dash--attachments) image))
     (cl-letf (((symbol-function 'agent-dash-image--choose) (lambda (_) image)))
       (agent-dash-remove-image))
     (should-not agent-dash--attachments)
     (should (equal (agent-dash--input) "draft"))
     (should (equal (overlay-get agent-dash--input-overlay 'before-string) "You> ")))
   (goto-char (point-min))
   (agent-dash-image--stage (agent-dash-images-test--image))
   (should (= (point) (point-max)))))

(ert-deftest agent-dash-images-test-clipboard-uses-binary-pipe ()
  (let (arguments)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "offline-pngpaste"))
              ((symbol-function 'process-file)
               (lambda (_program _input destination _display &rest args)
                 (setq arguments args)
                 (with-current-buffer (car destination)
                   (insert (base64-decode-string agent-dash-images-test--png)))
                 0)))
      (should (equal (agent-dash-image--clipboard)
                     (base64-decode-string agent-dash-images-test--png)))
      (should (equal arguments '("-"))))))

(ert-deftest agent-dash-images-test-text-and-image-paste-are-distinct ()
  (agent-dash-images-test-with-chat
   (cl-letf (((symbol-function 'agent-dash-image--clipboard) (lambda () nil))
             ((symbol-function 'yank) (lambda (&rest _) (insert "text"))))
     (agent-dash-paste)
     (should (equal (agent-dash--input) "text"))
     (should-error (agent-dash-paste-image) :type 'user-error)
     (should (equal (agent-dash--input) "text")))
   (cl-letf (((symbol-function 'agent-dash-image--clipboard)
              (lambda () (base64-decode-string agent-dash-images-test--png))))
     (agent-dash-paste))
   (should (= (length agent-dash--attachments) 1))
   (should (equal (agent-dash--input) "text"))))

(ert-deftest agent-dash-images-test-capability-limit-and-slash-guards ()
  (agent-dash-images-test-with-chat
   (agent-dash-set-data session :images-supported :false)
   (should-error (agent-dash-image--stage (agent-dash-images-test--image)) :type 'user-error)
   (should-not agent-dash--attachments)
   (agent-dash-set-data session :images-supported t)
   (dotimes (_ 10) (agent-dash-image--stage (agent-dash-images-test--image)))
   (should-error (agent-dash-image--stage (agent-dash-images-test--image)) :type 'user-error)
   (agent-dash--set-input "/quit")
   (should-error (agent-dash-send) :type 'user-error)
   (should (equal (agent-dash--input) "/quit"))
   (should (= (length agent-dash--attachments) 10))))

(ert-deftest agent-dash-images-test-image-only-send-and-explicit-recovery ()
  (agent-dash-images-test-with-chat
   (let ((image (agent-dash-images-test--image)))
     (agent-dash-image--stage image)
     (agent-dash-send)
     (should (equal (car agent-dash-fake-calls) (list 'send "" (list image) 'prompt)))
     (should-not agent-dash--attachments)
     (should (equal (agent-dash--input) ""))
     (agent-dash-restore-image-draft)
     (should (equal agent-dash--attachments (list image)))
     (should-error (agent-dash-restore-image-draft) :type 'user-error))))

(ert-deftest agent-dash-images-test-local-and-delayed-failures-preserve-data ()
  (agent-dash-images-test-with-chat
   (agent-dash--set-input "  original draft  ")
   (agent-dash-image--stage (agent-dash-images-test--image))
   (cl-letf (((symbol-function 'agent-dash-backend-send)
              (lambda (&rest _) (user-error "Offline write failed"))))
     (should-error (agent-dash-send) :type 'user-error))
   (should (equal (agent-dash--input) "  original draft  "))
   (should (= (length agent-dash--attachments) 1))
   (agent-dash-send)
   (let ((token (agent-dash-data session :image-draft-token)))
     (agent-dash-image-send-failed session token "Rejected")
     (should (equal (agent-dash--input) "  original draft  "))
     (should (= (length agent-dash--attachments) 1))
     (should (= (cl-count 'send agent-dash-fake-calls :key #'car) 1)))))

(ert-deftest agent-dash-images-test-stale-failure-never-overwrites-newer-draft ()
  (agent-dash-images-test-with-chat
   (agent-dash-image--stage (agent-dash-images-test--image))
   (agent-dash-send)
   (let ((token (agent-dash-data session :image-draft-token)))
     (agent-dash--set-input "new draft")
     (agent-dash-image-send-failed session token "Rejected")
     (should (equal (agent-dash--input) "new draft"))
     (should-not agent-dash--attachments)
     (agent-dash-send)
     (agent-dash-image-send-failed session token "Late old error")
     (should (equal (agent-dash--input) ""))
     (should-not agent-dash--attachments))))

(ert-deftest agent-dash-images-test-all-five-send-native-image-blocks ()
  (dolist (backend '(pi claude codex dsh hermes))
    (let ((session (agent-dash-session-create backend temporary-file-directory))
          payload method logged)
      (agent-dash-set-data session :sid "offline-session")
      (cl-letf (((symbol-function 'agent-dash-pi--request)
                 (lambda (_session value &rest _) (setq payload value)))
                ((symbol-function 'agent-dash-holder-write)
                 (lambda (_session value) (setq payload value)))
                ((symbol-function 'agent-dash-holder-request)
                 (lambda (_session operation value &rest _) (setq method operation payload value)))
                ((symbol-function 'agent-dash-holder-log)
                 (lambda (_session value) (setq logged value)))
                ((symbol-function 'agent-dash-dsh--call)
                 (lambda (operation value) (setq method operation payload value))))
        (should (agent-dash-capability session :images))
        (agent-dash-backend-send backend session "look"
                                 (list (agent-dash-images-test--image)) 'prompt)
        (pcase backend
          ('pi (should (equal (plist-get (aref (plist-get payload :images) 0) :mimeType)
                              "image/png")))
          ('claude
           (should (equal (plist-get (plist-get (aref (plist-get (plist-get payload :message)
                                                                 :content) 0) :source)
                                     :media_type) "image/png")))
          ('codex
           (should (equal method "turn/start"))
           (should (string-prefix-p "data:image/png;base64,"
                                    (plist-get (aref (plist-get payload :input) 1) :url))))
          ('dsh
           (should (equal method "session/prompt"))
           (should (equal (plist-get (aref (plist-get (plist-get payload :request) :content) 1)
                                     :mediaType) "image/png")))
          ('hermes
           (should (equal method "session/prompt"))
           (should (= (length (plist-get logged :images)) 1))
           (should (equal (plist-get (aref (plist-get payload :prompt) 1) :mimeType)
                          "image/png"))))))))

(ert-deftest agent-dash-images-test-backend-replay-user-assistant-and-tool-images ()
  (dolist (backend '(pi claude codex dsh hermes))
    (let* ((session (agent-dash-session-create backend temporary-file-directory))
           (style (if (eq backend 'hermes) nil backend))
           (block (agent-dash-images-test--block style)))
      (pcase backend
        ('pi
         (dolist (role '("user" "assistant" "toolResult"))
           (agent-dash-pi--message
            session (agent-dash-images-test--json
                     (list :role role :timestamp role :toolCallId "tool"
                           :content (vector block))))))
        ('claude
         (agent-dash-claude--user
          session (agent-dash-images-test--json
                   (list :uuid "user" :message (list :content (vector block)))))
         (agent-dash-claude--assistant
          session (agent-dash-images-test--json (list :message (list :id "assistant"
                                                                     :content (vector block)))))
         (agent-dash-claude--user
          session (agent-dash-images-test--json
                   (list :uuid "result" :message
                         (list :content (vector (list :type "tool_result" :tool_use_id "tool"
                                                      :content (vector block))))))))
        ('codex
         (agent-dash-codex--item
          session (agent-dash-images-test--json
                   (list :type "userMessage" :id "user" :content (vector block))))
         (agent-dash-codex--item session (agent-dash-images-test--json
                                          (list :type "imageGeneration" :id "assistant"
                                                :result agent-dash-images-test--png)))
         (agent-dash-codex--item
          session (agent-dash-images-test--json
                   (list :type "mcpToolCall" :id "tool" :status "completed"
                         :result (list :content (vector (agent-dash-images-test--block)))))))
        ('dsh
         (agent-dash-dsh--event session (agent-dash-images-test--json
                                         (list :type "user/message" :seq 1
                                               :data (list :id "user" :content (vector block)))))
         (agent-dash-dsh--event session (agent-dash-images-test--json
                                         (list :type "assistant/message" :seq 2
                                               :data (list :message
                                                           (list :id "assistant"
                                                                 :content (vector block))))))
         (agent-dash-dsh--event session (agent-dash-images-test--json
                                         (list :type "tool/result" :seq 3
                                               :data (list :message
                                                           (list :callId "tool"
                                                                 :content (vector block)))))))
        ('hermes
         (dolist (kind '("user_message_chunk" "agent_message_chunk"))
           (agent-dash-hermes--update session (agent-dash-images-test--json
                                               (list :sessionUpdate kind :content block))))
         (agent-dash-hermes--update
          session (agent-dash-images-test--json
                   (list :sessionUpdate "tool_call_update" :toolCallId "tool" :status "completed"
                         :content (vector (list :type "content" :content block)))))))
      (should (= (length (agent-dash-session-items session)) 3))
      (dolist (item (agent-dash-session-items session))
        (should (= (length (plist-get item :images)) 1))
        (should (equal (plist-get (car (plist-get item :images)) :data)
                       agent-dash-images-test--png))))))

(ert-deftest agent-dash-images-test-dsh-attachment-is-read-once-not-on-redraw ()
  (let ((session (agent-dash-session-create 'dsh temporary-file-directory)) (calls 0))
    (agent-dash-set-data session :sid "offline")
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (method _params)
                 (should (equal method "session/attachment"))
                 (cl-incf calls)
                 (agent-dash-images-test--json (list :attachment '(:mediaType "image/png")
                                                     :data agent-dash-images-test--png)))))
      (let* ((block (agent-dash-images-test--json
                     '(:type "image" :attachment (:id "attachment" :name "old.png"))))
             (first (agent-dash-dsh--images session (list block))))
        (should (equal (plist-get (car first) :data) agent-dash-images-test--png))
        (should (equal first (agent-dash-dsh--images session (list block))))
        (agent-dash-images-string first)
        (should (= calls 1))))))

(ert-deftest agent-dash-images-test-image-only-turns-and-terminal-previews ()
  (let* ((block (agent-dash-images-test--block))
         (line (json-serialize (list :message (list :role "user" :content (vector block)))))
         (entry (agent-dash-json-read line)))
    (should (agent-dash-pi--user-entry line))
    (should (equal (agent-dash-pi--entry-text entry) "[image]"))
    (should (equal (agent-dash-claude--prompt-text entry) "[image]")))
  (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
    (let ((preview (agent-dash-image-string (agent-dash-images-test--image))))
      (should (string-search "tiny.png" preview))
      (should-not (get-text-property 0 'display preview))
      (should (get-text-property 0 'agent-dash-image preview)))))

(ert-deftest agent-dash-images-test-thumbnail-cache-never-redecodes-on-redraw ()
  (let ((agent-dash--image-cache nil) (calls 0))
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
              ((symbol-function 'create-image)
               (lambda (_bytes type _data-p &rest args)
                 (should (eq type 'png))
                 (should (plist-get args :max-width))
                 (cl-incf calls)
                 '(image :type png))))
      (dotimes (_ 3)
        (let ((preview (agent-dash-image-string (agent-dash-images-test--image))))
          (should (equal (get-text-property 0 'display preview) '(image :type png)))
          (should-not (string-search agent-dash-images-test--png preview))))
      (should (= calls 1)))))

(ert-deftest agent-dash-images-test-correlated-protocol-rejections-restore-drafts ()
  (dolist (backend '(pi codex hermes))
    (agent-dash-images-test-with-chat
     (setf (agent-dash-session-backend session) backend)
     (agent-dash-set-data session :sid "offline")
     (agent-dash--set-input "original")
     (agent-dash-image--stage (agent-dash-images-test--image))
     (let (callback immediate)
       (cl-letf (((symbol-function 'agent-dash-holder-log) #'ignore)
                 ((symbol-function 'agent-dash-pi--request)
                  (lambda (_session _params handler)
                    (setq callback handler)
                    (when immediate (funcall handler nil nil "Rejected"))))
                 ((symbol-function 'agent-dash-holder-request)
                  (lambda (_session _method _params handler)
                    (setq callback handler)
                    (when immediate (funcall handler nil "Rejected")))))
         (agent-dash-send)
         (should (equal (agent-dash--input) ""))
         (if (eq backend 'pi) (funcall callback nil nil "Rejected")
           (funcall callback nil "Rejected"))
         (should (equal (agent-dash--input) "original"))
         (should (= (length agent-dash--attachments) 1))
         (setq immediate t)
         (should-error (agent-dash-send) :type 'user-error)
         (should (equal (agent-dash--input) "original"))
         (should (= (length agent-dash--attachments) 1)))))))

(ert-deftest agent-dash-images-test-files-require-explicit-user-history-context ()
  (let ((block (agent-dash-images-test--json '(:type "localImage" :path "/not-read.png"))))
    (cl-letf (((symbol-function 'agent-dash-image-from-file)
               (lambda (_) (ert-fail "Automatically reading an assistant path"))))
      (should-not (plist-get (car (agent-dash-images-from-blocks (list block))) :data)))))

(ert-deftest agent-dash-images-test-generated-data-url-and-untrusted-path ()
  (let ((session (agent-dash-session-create 'codex temporary-file-directory)))
    (agent-dash-codex--item
     session (agent-dash-images-test--json
              (list :type "imageGeneration" :id "generated"
                    :result (concat "data:image/png;base64," agent-dash-images-test--png))))
    (should (equal (plist-get (car (plist-get (agent-dash-item session "generated") :images)) :data)
                   agent-dash-images-test--png)))
  (let* ((block (agent-dash-images-test--json '(:type "localImage" :path "/not-read.png")))
         (image (car (agent-dash-images-from-blocks (list block)))))
    (should (plist-get image :ask-file))
    (cl-letf (((symbol-function 'agent-dash-image--at-event) (lambda (_) image))
              ((symbol-function 'yes-or-no-p) (lambda (_) nil))
              ((symbol-function 'agent-dash-image-from-file)
               (lambda (_) (ert-fail "Reading a declined image file"))))
      (should-error (agent-dash-open-image) :type 'user-error))))

(ert-deftest agent-dash-images-test-older-rejected-images-remain-recoverable ()
  (agent-dash-images-test-with-chat
   (agent-dash--set-input "first")
   (agent-dash-image--stage (agent-dash-images-test--image))
   (agent-dash-send)
   (let ((first (agent-dash-data session :image-draft-token)))
     (agent-dash--set-input "second")
     (agent-dash-image--stage (agent-dash-images-test--image))
     (agent-dash-send)
     (agent-dash-image-send-failed session first "Old rejection")
     (should (equal (agent-dash--input) ""))
     (should-not agent-dash--attachments)
     (should (memq first agent-dash--failed-image-drafts))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt choices &rest _) (caar choices))))
       (agent-dash-restore-image-draft))
     (should (equal (agent-dash--input) "first"))
     (should (= (length agent-dash--attachments) 1))
     (should-not agent-dash--failed-image-drafts)
     (should (= (cl-count 'send agent-dash-fake-calls :key #'car) 2)))))

(ert-deftest agent-dash-images-test-hermes-native-index-keeps-image-only-messages ()
  (cl-letf (((symbol-function 'agent-dash-sqlite-rows)
             (lambda (&rest _)
               (list (agent-dash-images-test--json
                      (list :role "user" :active 1 :compacted 0
                            :content (json-serialize
                                      (vector (agent-dash-images-test--block 'openai)))))))))
    (let ((messages (agent-dash-hermes--saved-messages "offline" "session")))
      (should (= (length messages) 1))
      (should (= (length (plist-get (car messages) :images)) 1))
      (should (equal (plist-get (car (plist-get (car messages) :images)) :data)
                     agent-dash-images-test--png))
      (should-not (string-search agent-dash-images-test--png (plist-get (car messages) :text))))))

(provide 'agent-dash-images-test)
;;; agent-dash-images-test.el ends here
