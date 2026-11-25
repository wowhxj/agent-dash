;;; agent-dash-tab-test.el --- Dedicated workspace tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Real tab/window operations with offline backends only.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-tab-test-with-tabs (&rest body)
  "Run BODY with isolated tabs, restoring the original frame afterwards."
  (declare (indent 0))
  `(let ((tabs (copy-tree (frame-parameter nil 'tabs)))
         (agent-dash--sessions nil)
         (agent-dash-hub--lifecycle-pending (make-hash-table))
         (agent-dash-hub--lifecycle-timer nil)
         (agent-dash-fake-calls nil))
     (save-window-excursion
       (unwind-protect
           (progn
             (set-frame-parameter nil 'tabs nil)
             (tab-bar-rename-tab "files")
             ,@body)
         (dolist (session agent-dash--sessions)
           (when (buffer-live-p (agent-dash-session-buffer session))
             (with-current-buffer (agent-dash-session-buffer session)
               (let ((agent-dash--quitting t)) (kill-buffer)))))
         (when (timerp agent-dash-hub--lifecycle-timer)
           (cancel-timer agent-dash-hub--lifecycle-timer))
         (set-frame-parameter nil 'tabs tabs)))))

(ert-deftest agent-dash-tab-test-hub-reuses-tab-and-buffer ()
  "Repeated hub entry must preserve the file tab's split layout."
  (agent-dash-tab-test-with-tabs
   (split-window-right)
   (let ((layout (window-state-get))
         (hub (generate-new-buffer " *agent-dash tab hub*")))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-dash-hub-refresh) #'ignore)
                   ((symbol-function 'get-buffer-create)
                    (let ((original (symbol-function 'get-buffer-create)))
                      (lambda (name &rest args)
                        (if (equal name "*agent-dash hub*")
                            (if (buffer-live-p hub) hub
                              (setq hub (generate-new-buffer " *agent-dash tab hub*")))
                          (apply original name args))))))
           (agent-dash-hub)
           (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
           (should (= (length (tab-bar-tabs)) 2))
           (should (eq (current-buffer) hub))
           (should (= (length (window-list)) 1))
           (agent-dash-hub-quit)
           (should-not (buffer-live-p hub))
           (should (equal (alist-get 'name (tab-bar--current-tab)) "files"))
           (should (equal (window-state-get) layout))
           (agent-dash-hub)
           (agent-dash-hub)
           (should (= (length (tab-bar-tabs)) 2))
           (should (eq (current-buffer) hub))
           (let ((frames (frame-list))
                 (row (list :backend 'fake :id "saved" :root temporary-file-directory)))
             (agent-dash-hub-open-row row)
             (agent-dash-set-data (car agent-dash--sessions) :sid "saved")
             (let ((chat-window (selected-window)))
               (should (= (length (window-list)) 2))
               (should (get-buffer-window hub))
               (agent-dash-hub)
               (should (= (length (window-list)) 2))
               (agent-dash-hub-open-row row)
               (should (eq (selected-window) chat-window))
               (should (= (length agent-dash--sessions) 1))
               (agent-dash-open 'fake temporary-file-directory)
               (should (= (length (window-list)) 3))
               (should (get-buffer-window hub))
               (should (equal (frame-list) frames)))))
       (kill-buffer hub)))))

(ert-deftest agent-dash-tab-test-chat-entry-and-switch ()
  "Every backend's chat entry and live-chat switching use the existing tab."
  (agent-dash-tab-test-with-tabs
   (tab-bar-new-tab)
   (tab-bar-rename-tab "agent-dash")
   (tab-bar-switch-to-tab "files")
   (cl-letf (((symbol-function 'agent-dash-backend-start) #'ignore))
     (dolist (backend '(pi claude codex hermes dsh))
       (let* ((session (agent-dash-open backend temporary-file-directory))
              (buffer (agent-dash-session-buffer session)))
         (should (eq (current-buffer) buffer))
         (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
         (should (= (length (tab-bar-tabs)) 2))
         (tab-bar-switch-to-tab "files")
         (cl-letf (((symbol-function 'completing-read)
                    (lambda (&rest _) (buffer-name buffer))))
           (agent-dash-switch-chat))
         (should (eq (current-buffer) buffer))
         (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
         (tab-bar-switch-to-tab "files"))))))

(ert-deftest agent-dash-tab-test-queue-and-details ()
  "Auxiliary buffers stay in the agent workspace even from the file tab."
  (agent-dash-tab-test-with-tabs
   (let ((session (agent-dash-open 'fake temporary-file-directory))
         (details (get-buffer "*agent-dash details*")))
     (unwind-protect
         (progn
           (tab-bar-switch-to-tab "files")
           (agent-dash-queue session)
           (should (derived-mode-p 'agent-dash-queue-mode))
           (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
           (tab-bar-switch-to-tab "files")
           (agent-dash-hub-show-details '(:backend fake :id "saved"))
           (should (derived-mode-p 'agent-dash-hub-details-mode))
           (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
           (should (= (length (tab-bar-tabs)) 2)))
       (kill-buffer (format "*agent-queue:%s*" (agent-dash-session-id session)))
       (unless details (kill-buffer "*agent-dash details*"))))))

(ert-deftest agent-dash-tab-test-quit-closes-only-chat-windows ()
  "Confirmed quit closes the chat's split, not the hub or another agent."
  (agent-dash-tab-test-with-tabs
   (let ((hub (generate-new-buffer " *dash window hub*"))
         (agent-dash-fake-quit 'detach))
     (unwind-protect
         (progn
           (agent-dash-pop-to-buffer hub)
           (let* ((first (agent-dash-open 'fake temporary-file-directory))
                  (second (agent-dash-open 'fake temporary-file-directory))
                  (buffer (agent-dash-session-buffer first))
                  (window (get-buffer-window buffer))
                  (frames (frame-list)))
             (agent-dash-pop-to-buffer buffer)
             (should (= (length (window-list)) 3))
             (agent-dash-quit)
             (should-not (buffer-live-p buffer))
             (should-not (window-live-p window))
             (should (= (length (window-list)) 2))
             (should (get-buffer-window hub))
             (should (get-buffer-window (agent-dash-session-buffer second)))
             (should (equal (frame-list) frames))))
       (kill-buffer hub)))))

(ert-deftest agent-dash-tab-test-cancelled-quit-keeps-window ()
  "Declining stop must not close the chat or its window."
  (agent-dash-tab-test-with-tabs
   (let* ((agent-dash-fake-quit 'stop)
          (session (agent-dash-open 'fake temporary-file-directory))
          (window (selected-window)))
     (cl-letf (((symbol-function 'yes-or-no-p) #'ignore))
       (agent-dash-quit))
     (should (buffer-live-p (agent-dash-session-buffer session)))
     (should (eq (get-buffer-window (agent-dash-session-buffer session)) window))
     (should-not (assq 'quit agent-dash-fake-calls)))))

(ert-deftest agent-dash-tab-test-last-window-keeps-frame ()
  "Closing the last visible chat keeps the frame and returns to the hub."
  (agent-dash-tab-test-with-tabs
   (let* ((existing (get-buffer "*agent-dash hub*"))
          (hub (get-buffer-create "*agent-dash hub*"))
          (agent-dash-fake-quit 'detach)
          (frames (frame-list)))
     (unwind-protect
         (progn
           (agent-dash-open 'fake temporary-file-directory)
           (delete-other-windows)
           (agent-dash-quit)
           (should (= (length (window-list)) 1))
           (should (eq (window-buffer) hub))
           (should (equal (frame-list) frames)))
       (unless existing (kill-buffer hub))))))

(ert-deftest agent-dash-tab-test-no-space-never-opens-frame ()
  "No split space must not start a hidden agent or open another frame."
  (agent-dash-tab-test-with-tabs
   (let ((hub (generate-new-buffer " *dash no-space hub*")))
     (unwind-protect
         (progn
           (agent-dash-pop-to-buffer hub)
           (let ((layout (window-state-get)))
             (cl-letf (((symbol-function 'window-splittable-p) #'ignore)
                       ((symbol-function 'make-frame)
                        (lambda (&rest _) (ert-fail "Created another frame"))))
               (should-error (agent-dash-open 'fake temporary-file-directory)
                             :type 'user-error))
             (should-not (assq 'start agent-dash-fake-calls))
             (should-not agent-dash--sessions)
             (should (equal (window-state-get) layout))))
       (kill-buffer hub)))))

(ert-deftest agent-dash-tab-test-ignores-cross-frame-display-rules ()
  "User display rules cannot send the chat to a new frame."
  (agent-dash-tab-test-with-tabs
   (let ((first (generate-new-buffer " *dash display first*"))
         (second (generate-new-buffer " *dash display second*"))
         (switch-to-buffer-obey-display-actions t)
         (display-buffer-overriding-action '(display-buffer-pop-up-frame)))
     (unwind-protect
         (cl-letf (((symbol-function 'make-frame)
                    (lambda (&rest _) (ert-fail "Created another frame"))))
           (agent-dash-pop-to-buffer first)
           (agent-dash-pop-to-buffer second)
           (should (get-buffer-window first (selected-frame)))
           (should (get-buffer-window second (selected-frame)))
           (should (= (length (window-list)) 2)))
       (kill-buffer first)
       (kill-buffer second)))))

(ert-deftest agent-dash-tab-test-details-q-removes-its-split ()
  "The actual hub i/details q keys must restore the original windows."
  (agent-dash-tab-test-with-tabs
   (let ((hub (generate-new-buffer " *dash details origin*"))
         (existing (get-buffer "*agent-dash details*")))
     (unwind-protect
         (progn
           (with-current-buffer hub
             (agent-dash-hub-mode)
             (let ((inhibit-read-only t))
               (insert (propertize "saved\n" 'agent-dash-row
                                   (list :backend 'fake :id "saved")))))
           (agent-dash-pop-to-buffer hub)
           (let* ((chat (agent-dash-open 'fake temporary-file-directory))
                  (chat-window (selected-window))
                  (frames (frame-list)))
             (agent-dash-pop-to-buffer hub)
             (goto-char (point-min))
             (let ((hub-window (selected-window))
                   (count (length (window-list))))
               (dotimes (_ 3)
                 (call-interactively (key-binding "i"))
                 (should (derived-mode-p 'agent-dash-hub-details-mode))
                 (let ((details-window (selected-window))
                       (details-buffer (current-buffer)))
                   (should (= (length (window-list)) (1+ count)))
                   ;; Reusing a visible detail must retain its original quit record.
                   (agent-dash-hub-show-details '(:backend fake :id "saved"))
                   (call-interactively (key-binding "q"))
                   (should-not (window-live-p details-window))
                   (should-not (buffer-live-p details-buffer)))
                 (should (= (length (window-list)) count))
                 (should (eq (selected-window) hub-window))
                 (should (= (length (get-buffer-window-list hub)) 1))
                 (should (eq (window-buffer chat-window)
                             (agent-dash-session-buffer chat)))
                 (should (equal frames (frame-list)))))))
       (kill-buffer hub)
       (unless existing
         (when-let* ((details (get-buffer "*agent-dash details*")))
           (kill-buffer details)))))))

(ert-deftest agent-dash-tab-test-queue-q-removes-its-split ()
  "Other special buffers use the same native `quit-window' lifecycle."
  (agent-dash-tab-test-with-tabs
   (let* ((session (agent-dash-open 'fake temporary-file-directory))
          (chat-window (selected-window))
          (queue-name (format "*agent-queue:%s*" (agent-dash-session-id session))))
     (unwind-protect
         (progn
           (agent-dash-queue session)
           (let ((queue-window (selected-window)))
             (call-interactively (key-binding "q"))
             (should-not (window-live-p queue-window))
             (should-not (get-buffer queue-name)))
           (should (= (length (window-list)) 1))
           (should (eq (selected-window) chat-window))
           (should (eq (window-buffer chat-window)
                       (agent-dash-session-buffer session))))
       (when-let* ((queue (get-buffer queue-name))) (kill-buffer queue))))))

(ert-deftest agent-dash-tab-test-queue-editor-save-and-cancel-close-windows ()
  "Finishing an editor removes its window; declining discard changes nothing."
  (dolist (save '(nil t))
    (agent-dash-tab-test-with-tabs
     (cl-letf (((symbol-function 'agent-dash-queue--schedule) #'ignore))
       (let* ((session (agent-dash-open 'fake temporary-file-directory))
              (entry (agent-dash-queue-add session "original" nil))
              (queue (agent-dash-queue session))
              (editor (agent-dash-queue--edit session (plist-get entry :id)))
              (window (selected-window))
              (frames (frame-list)))
         (unwind-protect
             (progn
               (should (= (length (window-list)) 3))
               (agent-dash--set-input "edited")
               (cl-letf (((symbol-function 'yes-or-no-p) #'ignore))
                 (agent-dash-queue-edit-cancel))
               (should (buffer-live-p editor))
               (should (window-live-p window))
               (should (= (length (window-list)) 3))
               (should (equal (agent-dash--input) "edited"))
               (if save
                   (agent-dash-queue-edit-save)
                 (cl-letf (((symbol-function 'yes-or-no-p) #'always))
                   (agent-dash-queue-edit-cancel)))
               (should-not (buffer-live-p editor))
               (should-not (window-live-p window))
               (should (= (length (window-list)) 2))
               (should (equal (plist-get entry :text) (if save "edited" "original")))
               (should-not (plist-get entry :editor))
               (should (get-buffer-window (agent-dash-session-buffer session)))
               (select-window (get-buffer-window queue))
               (call-interactively (key-binding "q"))
               (should (= (length (window-list)) 1))
               (should (eq (window-buffer) (agent-dash-session-buffer session)))
               (should (equal frames (frame-list))))
           (when (buffer-live-p editor)
             (with-current-buffer editor
               (let ((agent-dash-queue--saved t)) (kill-buffer))))
           (when (buffer-live-p queue) (kill-buffer queue))))))))

(ert-deftest agent-dash-tab-test-queue-q-closes-window-with-previous-buffers ()
  "Closing a queue removes its pane even after its window acquired history."
  (agent-dash-tab-test-with-tabs
   (let* ((session (agent-dash-open 'fake temporary-file-directory))
          (queue (agent-dash-queue session))
          (window (selected-window)))
     (unwind-protect
         (progn
           (set-window-prev-buffers window (list (list (get-buffer-create "*scratch*") 1 1)))
           (call-interactively (key-binding "q"))
           (should-not (window-live-p window))
           (should (= (length (window-list)) 1))
           (should (eq (window-buffer) (agent-dash-session-buffer session))))
       (kill-buffer queue)))))

(ert-deftest agent-dash-tab-test-split-direction-follows-pixel-shape ()
  "Use physical aspect ratio, not incomparable character columns and lines."
  (dolist (shape '((600 1400 below) (1400 600 right)))
    (agent-dash-tab-test-with-tabs
     (let ((first (generate-new-buffer " *dash aspect first*"))
           (second (generate-new-buffer " *dash aspect second*")))
       (unwind-protect
           (progn
             (agent-dash-pop-to-buffer first)
             (let ((original (selected-window))
                   (pixel-width (symbol-function 'window-pixel-width))
                   (pixel-height (symbol-function 'window-pixel-height))
                   (split (symbol-function 'split-window)))
               ;; Simulate display geometry only for the direction decision.
               ;; Real splits still use the batch frame's actual dimensions.
               (cl-letf (((symbol-function 'window-pixel-width)
                          (lambda (&optional _) (nth 0 shape)))
                         ((symbol-function 'window-pixel-height)
                          (lambda (&optional _) (nth 1 shape)))
                         ((symbol-function 'split-window)
                          (lambda (&rest args)
                            (cl-letf (((symbol-function 'window-pixel-width) pixel-width)
                                      ((symbol-function 'window-pixel-height) pixel-height))
                              (apply split args)))))
                 (agent-dash-pop-to-buffer second))
               (let ((old-edges (window-edges original))
                     (new-edges (window-edges (selected-window))))
                 (if (eq (nth 2 shape) 'below)
                     (progn
                       (should (= (car old-edges) (car new-edges)))
                       (should (< (cadr old-edges) (cadr new-edges))))
                   (should (= (cadr old-edges) (cadr new-edges)))
                   (should (< (car old-edges) (car new-edges)))))))
         (kill-buffer first)
         (kill-buffer second))))))

(defmacro agent-dash-tab-test-with-wide-frame (&rest body)
  "Run BODY in an isolated, physically wide test frame."
  (declare (indent 0))
  `(agent-dash-tab-test-with-tabs
    (let ((width (frame-width)) (height (frame-height)))
      (unwind-protect
          (progn (set-frame-size (selected-frame) 160 80) ,@body)
        (set-frame-size (selected-frame) width height)))))

(ert-deftest agent-dash-tab-test-additions-reflow-into-grid ()
  "Two and three windows form equal columns; four form a cross."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffers (cl-loop repeat 4 collect (generate-new-buffer " *dash grid*"))))
     (unwind-protect
         (progn
           (dolist (buffer buffers)
             (agent-dash-pop-to-buffer buffer)
             (should (eq (window-buffer) buffer))
             (when (memq (length (window-list)) '(2 3))
               (let ((widths (mapcar #'window-total-width (window-list))))
                 (should (<= (- (apply #'max widths) (apply #'min widths)) 1)))))
           (let ((edges (mapcar #'window-edges (window-list))))
             (should (= (length (delete-dups (mapcar #'car edges))) 2))
             (should (= (length (delete-dups (mapcar #'cadr edges))) 2)))
           (dolist (buffer buffers) (should (get-buffer-window buffer))))
       (mapc #'kill-buffer buffers)))))

(ert-deftest agent-dash-tab-test-native-deletion-and-manual-resize ()
  "Native deletion reflows; focus and manual size changes do not."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffers (cl-loop repeat 4 collect (generate-new-buffer " *dash delete*"))))
     (unwind-protect
         (progn
           (mapc #'agent-dash-pop-to-buffer buffers)
           (delete-window)
           ;; Batch mode has no redisplay: run the same native hook explicitly.
           (run-hooks 'window-configuration-change-hook)
           (let ((edges (mapcar #'window-edges (window-list))))
             (should (= (length (delete-dups (mapcar #'car edges))) 3))
             (should (= (length (delete-dups (mapcar #'cadr edges))) 1)))
           (other-window 1)
           (window-resize (selected-window) 5 t)
           (let ((state (window-state-get)))
             (run-hooks 'window-configuration-change-hook)
             (should (equal state (window-state-get))))
           (delete-other-windows)
           (run-hooks 'window-configuration-change-hook)
           (should (= (length (window-list)) 1)))
       (mapc #'kill-buffer buffers)))))

(ert-deftest agent-dash-tab-test-reflow-preserves-view-and-quit ()
  "Rebuilding the tree preserves views and remaps native quit destinations."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffers (cl-loop repeat 3 collect (generate-new-buffer " *dash views*")))
         (details (generate-new-buffer " *dash transient*")))
     (unwind-protect
         (progn
           (mapc #'agent-dash-pop-to-buffer buffers)
           (with-current-buffer (car buffers)
             (dotimes (_ 200) (insert "A line of chat history\n")))
           (let ((window (get-buffer-window (car buffers))))
             (set-window-point window 300)
             (set-window-start window 100)
             (set-window-hscroll window 4))
           (agent-dash-pop-to-buffer (cadr buffers))
           (agent-dash-pop-to-buffer details)
           (let ((window (get-buffer-window (car buffers))))
             (should (= (window-point window) 300))
             (should (= (window-start window) 100))
             (should (= (window-hscroll window) 4)))
           (quit-window)
           (run-hooks 'window-configuration-change-hook)
           (should-not (get-buffer-window details))
           (should (eq (window-buffer) (cadr buffers)))
           (should (= (length (window-list)) 3)))
       (mapc #'kill-buffer (cons details buffers))))))

(ert-deftest agent-dash-tab-test-native-addition-and-frame-resize ()
  "Native splits and frame geometry changes use the same reflow hook."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffers (cl-loop repeat 3 collect (generate-new-buffer " *dash resize*"))))
     (unwind-protect
         (progn
           (mapc #'agent-dash-pop-to-buffer buffers)
           (split-window-right)
           (run-hooks 'window-configuration-change-hook)
           (let ((edges (mapcar #'window-edges (window-list))))
             (should (= (length (delete-dups (mapcar #'car edges))) 2))
             (should (= (length (delete-dups (mapcar #'cadr edges))) 2)))
           (set-frame-size (selected-frame) 80 160)
           (run-hooks 'window-configuration-change-hook)
           (let ((edges (mapcar #'window-edges (window-list))))
             (should (= (length (delete-dups (mapcar #'car edges))) 1))
             (should (= (length (delete-dups (mapcar #'cadr edges))) 4)))
           (should (= (length (get-buffer-window-list (car (last buffers)))) 2)))
       (mapc #'kill-buffer buffers)))))

(ert-deftest agent-dash-tab-test-reflow-is-tab-local ()
  "The global native hook leaves other tabs' windows and sizes untouched."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffer (generate-new-buffer " *dash isolation*")))
     (unwind-protect
         (progn
           (agent-dash-pop-to-buffer buffer)
           (tab-bar-switch-to-tab "files")
           (split-window-right 35)
           (split-window-below 20)
           (let ((state (window-state-get)))
             (run-hooks 'window-configuration-change-hook)
             (should (equal state (window-state-get)))))
       (kill-buffer buffer)))))

(ert-deftest agent-dash-tab-test-reflow-rollback-on-split-error ()
  "A failed tree rebuild restores all existing windows and their contents."
  (agent-dash-tab-test-with-wide-frame
   (let ((buffers (cl-loop repeat 3 collect (generate-new-buffer " *dash rollback*"))))
     (unwind-protect
         (progn
           (mapc #'agent-dash-pop-to-buffer buffers)
           (let ((state (window-state-get))
                 (selected (selected-window)))
             (cl-letf (((symbol-function 'split-window)
                        (lambda (&rest _) (error "Split failed"))))
               (should-error (agent-dash--layout-rebuild (agent-dash--layout-windows) 2)))
             (should (equal state (window-state-get)))
             (should (eq selected (selected-window)))))
       (mapc #'kill-buffer buffers)))))

(ert-deftest agent-dash-tab-test-hub-resizes-without-rereading ()
  "Hub columns follow real split widths, without rescanning or stealing focus."
  (agent-dash-tab-test-with-wide-frame
   (let ((hub (generate-new-buffer " *dash responsive hub*"))
         (chat (generate-new-buffer " *dash responsive chat*"))
         (agent-dash-backends '(fake))
         (agent-dash-hub--sources (make-hash-table))
         (agent-dash-hub--render-timer nil)
         (agent-dash-summary--loaded t)
         (agent-dash-summary--cache (make-hash-table :test #'equal))
         (render (symbol-function 'agent-dash-hub--render))
         (redraws 0))
     (unwind-protect
         (cl-labels ((notify (window)
                       ;; Redisplay is absent in batch mode: run only local hooks.
                       (with-current-buffer (window-buffer window)
                         (dolist (function window-size-change-functions)
                           (unless (eq function t) (funcall function window))))))
           (puthash 'fake
                    (list :status 'ok
                          :rows (list (list :backend 'fake :id "first-id" :key "fake:first-id"
                                            :root temporary-file-directory :time 1
                                            :first (make-string 200 ?a) :last "last prompt")))
                    agent-dash-hub--sources)
           (agent-dash-pop-to-buffer hub)
           (agent-dash-hub-mode)
           (agent-dash-hub--render)
           (should (memq #'agent-dash-hub--resize window-size-change-functions))
           (setq agent-dash-hub--agent 'fake)
           (puthash "folded" t agent-dash-hub--collapsed)
           (puthash "fake:first-id" t agent-dash-hub--marks)
           (cl-letf (((symbol-function 'agent-dash-history-request)
                      (lambda (&rest _) (ert-fail "Resize reread history")))
                     ((symbol-function 'agent-dash-hub-refresh)
                      (lambda (&rest _) (ert-fail "Resize refreshed inventory")))
                     ((symbol-function 'agent-dash-hub--render)
                      (lambda () (cl-incf redraws) (funcall render))))
             (agent-dash-pop-to-buffer chat)
             (let ((window (get-buffer-window hub))
                   (selected (selected-window)))
               (notify window)
               (let ((timer agent-dash-hub--render-timer))
                 (should (timerp timer))
                 (notify window)
                 (should (eq timer agent-dash-hub--render-timer)))
               (agent-dash-test-wait (lambda () (null agent-dash-hub--render-timer)))
               (should (= redraws 1))
               (should (eq (selected-window) selected))
               (with-current-buffer hub
                 (should (= agent-dash-hub--width (window-body-width window)))
                 (should-not (string-match-p "^ +Agent.*项目" (buffer-string)))
                 (should (eq agent-dash-hub--agent 'fake))
                 (should (gethash "folded" agent-dash-hub--collapsed))
                 (should (gethash "fake:first-id" agent-dash-hub--marks))
                 (should (equal (get-text-property (point) 'agent-dash-key) "fake:first-id")))
               ;; Height-only changes need no column redraw.
               (let ((below (split-window window nil 'below)))
                 (notify window)
                 (notify below)
                 (should-not agent-dash-hub--render-timer)
                 (delete-window below))
               ;; Manual horizontal resize must update the hub too.
               (window-resize window 10 t)
               (notify window)
               (agent-dash-test-wait (lambda () (null agent-dash-hub--render-timer)))
               (should (= redraws 2))
               (delete-window selected)
               (notify window)
               (agent-dash-test-wait (lambda () (null agent-dash-hub--render-timer)))
               (should (= redraws 3))
               (with-current-buffer hub
                 (should (= agent-dash-hub--width (window-body-width window)))
                 (should (string-match-p "^ +Agent.*项目" (buffer-string))))
               ;; One shared buffer cannot have two different column layouts.
               (let ((other (split-window window 50 'right)))
                 (notify window)
                 (notify other)
                 (agent-dash-test-wait (lambda () (null agent-dash-hub--render-timer)))
                 (should (= redraws 4))
                 (with-current-buffer hub
                   (should (= agent-dash-hub--width
                              (min (window-body-width window) (window-body-width other)))))
                 (notify window)
                 (notify other)
                 (should-not agent-dash-hub--render-timer)))))
       (when (timerp agent-dash-hub--render-timer)
         (cancel-timer agent-dash-hub--render-timer))
       (kill-buffer hub)
       (kill-buffer chat)))))

(provide 'agent-dash-tab-test)
;;; agent-dash-tab-test.el ends here
