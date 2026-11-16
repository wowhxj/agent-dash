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
                        (if (equal name "*agent-dash hub*") hub
                          (apply original name args))))))
           (agent-dash-hub)
           (should (equal (alist-get 'name (tab-bar--current-tab)) "agent-dash"))
           (should (= (length (tab-bar-tabs)) 2))
           (should (eq (current-buffer) hub))
           (should (= (length (window-list)) 1))
           (agent-dash-hub-quit)
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
                 (let ((details-window (selected-window)))
                   (should (= (length (window-list)) (1+ count)))
                   ;; Reusing a visible detail must retain its original quit record.
                   (agent-dash-hub-show-details '(:backend fake :id "saved"))
                   (call-interactively (key-binding "q"))
                   (should-not (window-live-p details-window)))
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
             (should-not (window-live-p queue-window)))
           (should (= (length (window-list)) 1))
           (should (eq (selected-window) chat-window))
           (should (eq (window-buffer chat-window)
                       (agent-dash-session-buffer session))))
       (when-let* ((queue (get-buffer queue-name))) (kill-buffer queue))))))

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

(ert-deftest agent-dash-tab-test-splits-largest-not-selected-window ()
  "Repeated additions subdivide the largest window, leaving smaller ones alone."
  (agent-dash-tab-test-with-tabs
   (let ((first (generate-new-buffer " *dash largest first*"))
         (next (generate-new-buffer " *dash largest next*")))
     (unwind-protect
         (progn
           (agent-dash-pop-to-buffer first)
           (let* ((small (selected-window))
                  (large (split-window small 20 'right))
                  (small-edges (window-edges small)))
             (should (eq (get-largest-window (selected-frame)) large))
             (dotimes (_ 2)
               (let ((largest (get-largest-window (selected-frame))))
                 (select-window small)
                 (agent-dash-pop-to-buffer next)
                 (should (eq (window-parent (selected-window))
                             (window-parent largest)))
                 (should (equal (window-edges small) small-edges))
                 ;; A native quit removes only the newly created split.
                 (quit-window)))))
       (kill-buffer first)
       (kill-buffer next)))))

(provide 'agent-dash-tab-test)
;;; agent-dash-tab-test.el ends here
