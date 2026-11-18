;;; agent-dash-history-async-test.el --- Real reader isolation tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Real batch Emacs children, but only the offline fixture backend.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)
(require 'agent-dash-history-fixture)

(defmacro agent-dash-history-async-test-with-reader (&rest body)
  "Run BODY with isolated worker state and no real agents or summaries."
  (declare (indent 0))
  `(let ((agent-dash-history--jobs (make-hash-table :test #'equal))
         (agent-dash-history--completed (make-hash-table))
         (agent-dash-history-worker-variables
          (append '(agent-dash-history-fixture-delay agent-dash-history-fixture-mode
                                                     agent-dash-history-fixture-id)
                  agent-dash-history-worker-variables))
         (agent-dash-history-fixture-delay 0.2)
         (agent-dash-history-fixture-mode 'ok)
         (agent-dash-history-fixture-id "custom-session")
         (agent-dash-backends '(history-fixture))
         (agent-dash-hub--sources (make-hash-table))
         (agent-dash-hub--render-timer nil)
         (agent-dash-summary--sessions (make-hash-table :test #'equal))
         (agent-dash-summary--cache (make-hash-table :test #'equal))
         (agent-dash-summary--loaded t)
         (agent-dash-summary--job nil))
     (unwind-protect (progn ,@body)
       (dolist (process (hash-table-values agent-dash-history--jobs))
         (agent-dash-history--finish process '(:ok nil :error "Test cleanup")))
       (when (timerp agent-dash-hub--render-timer)
         (cancel-timer agent-dash-hub--render-timer)))))

(ert-deftest agent-dash-history-async-test-main-loop-keeps-running ()
  "A slow reader runs in another PID while main-loop heartbeats continue."
  (agent-dash-history-async-test-with-reader
   (let* ((agent-dash-history-fixture-delay 0.5)
          (ticks 0) result
          (timer (run-at-time 0.01 0.01 (lambda () (cl-incf ticks)))))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-dash-backend-sessions)
                    (lambda (&rest _) (ert-fail "History read in the GUI process"))))
           (let* ((process (agent-dash-history-request
                            'history-fixture 'sessions (lambda (r) (setq result r))))
                  (output (process-buffer process)))
             (agent-dash-test-wait (lambda () (>= ticks 3)))
             (should (process-live-p process))
             (should-not result)
             (agent-dash-test-wait (lambda () result))
             (should (plist-get result :ok))
             (let ((row (car (plist-get result :value))))
               (should (equal (plist-get row :id) "custom-session"))
               (should (/= (plist-get row :worker-pid) (emacs-pid))))
             (should (equal (plist-get result :warnings) '("Fixture warning")))
             (should-not (buffer-live-p output))
             (should (= (hash-table-count agent-dash-history--jobs) 0))))
       (cancel-timer timer)))))

(ert-deftest agent-dash-history-async-test-hub-and-summary-share-worker ()
  "Repeated hub and summary refreshes share one worker and its snapshot."
  (agent-dash-history-async-test-with-reader
   (let ((calls 0))
     (let ((process (agent-dash-history-request
                     'history-fixture 'sessions (lambda (_) (cl-incf calls)))))
       (should (eq process (agent-dash-history-request
                            'history-fixture 'sessions (lambda (_) (cl-incf calls)))))
       (agent-dash-summary--scan)
       (agent-dash-hub-refresh)
       (agent-dash-hub-refresh)
       (should (= (hash-table-count agent-dash-history--jobs) 1))
       (agent-dash-test-wait (lambda () (= calls 2)))
       (should (eq (plist-get (gethash 'history-fixture agent-dash-hub--sources) :status) 'ok))
       (should (gethash "history-fixture:custom-session" agent-dash-summary--sessions))
       ;; A scheduler tick after a fresh hub snapshot must not read again.
       (agent-dash-summary--scan)
       (should (= (hash-table-count agent-dash-history--jobs) 0))))))

(ert-deftest agent-dash-history-async-test-consumer-errors-are-isolated ()
  (agent-dash-history-async-test-with-reader
   (let* ((calls nil)
          (agent-dash-history-update-hook
           (list (lambda (&rest _) (push 'broken-hook calls) (error "Broken hook"))
                 (lambda (&rest _) (push 'hook calls))))
          (process (agent-dash-history-request
                    'history-fixture 'sessions
                    (lambda (_) (push 'broken-callback calls) (error "Broken callback"))))
          (output (process-buffer process))
          (stderr (process-get process 'agent-dash-stderr))
          result)
     (should (eq process (agent-dash-history-request
                          'history-fixture 'sessions
                          (lambda (reply) (push 'callback calls) (setq result reply)))))
     (agent-dash-test-wait (lambda () result))
     (should (plist-get result :ok))
     (should (equal (reverse calls) '(broken-hook hook broken-callback callback)))
     (should (gethash 'history-fixture agent-dash-history--completed))
     (should (zerop (hash-table-count agent-dash-history--jobs)))
     (should-not (buffer-live-p output))
     (should-not (buffer-live-p stderr))
     ;; Completion remains exactly-once even after a consumer failed.
     (agent-dash-history--finish process result)
     (should (= (length calls) 4)))))

(ert-deftest agent-dash-history-async-test-errors-preserve-old-rows ()
  "Reader failures, crashes and invalid output retain usable cached rows."
  (dolist (mode '(error exit invalid))
    (agent-dash-history-async-test-with-reader
     (let* ((agent-dash-history-fixture-mode mode)
            (old '((:backend history-fixture :id "cached")))
            result)
       (puthash 'history-fixture (list :status 'ok :rows old) agent-dash-hub--sources)
       (agent-dash-hub--load 'history-fixture (lambda (r) (setq result r)))
       (agent-dash-test-wait (lambda () result))
       (should-not (plist-get result :ok))
       (should (stringp (plist-get result :error)))
       (let ((source (gethash 'history-fixture agent-dash-hub--sources)))
         (should (eq (plist-get source :status) 'error))
         (should (equal (plist-get source :rows) old)))
       (should (= (hash-table-count agent-dash-history--jobs) 0))))))

(ert-deftest agent-dash-history-async-test-timeout-releases-resources ()
  "A hung backend cannot leave a worker, loading state or callback behind."
  (agent-dash-history-async-test-with-reader
   (let* ((agent-dash-history-fixture-delay 5)
          (agent-dash-history-timeout 0.05)
          (calls 0) result
          (process (agent-dash-history-request
                    'history-fixture 'sessions
                    (lambda (r) (setq result r) (cl-incf calls))))
          (output (process-buffer process)))
     (agent-dash-test-wait (lambda () result))
     (should (equal (plist-get result :error) "History reader timed out"))
     (should-not (process-live-p process))
     (should-not (buffer-live-p output))
     (should (= (hash-table-count agent-dash-history--jobs) 0))
     (accept-process-output nil 0.05)
     (should (= calls 1)))))

(ert-deftest agent-dash-history-async-test-summary-dialogue-is-isolated ()
  "Summary preparation never reads a transcript in the GUI process."
  (agent-dash-history-async-test-with-reader
   (let (text)
     (cl-letf (((symbol-function 'agent-dash-backend-transcript)
                (lambda (&rest _) (ert-fail "Transcript read in the GUI process")))
               ((symbol-function 'agent-dash-summary--summarize)
                (lambda (_job value) (setq text value agent-dash-summary--job nil))))
       (agent-dash-summary--start '(:backend history-fixture :id "custom-session"))
       (should agent-dash-summary--job)
       (should-not text)
       (agent-dash-test-wait (lambda () text))
       (should (equal text "User: 测试问题\n\nAssistant: worker reply"))))))

(ert-deftest agent-dash-history-async-test-cold-full-search-waits-for-readers ()
  "Cold full-text search waits for inventory and dialogue without GUI reads."
  (agent-dash-history-async-test-with-reader
   (with-temp-buffer
     (agent-dash-search-mode)
     (let ((run (agent-dash-search--make :buffer (current-buffer) :mode 'full :query "test"))
           items)
       (setq agent-dash-search--current run)
       (cl-letf (((symbol-function 'agent-dash-backend-sessions)
                  (lambda (&rest _) (ert-fail "Search scanned history in the GUI")))
                 ((symbol-function 'agent-dash-backend-transcript)
                  (lambda (&rest _) (ert-fail "Search read dialogue in the GUI")))
                 ((symbol-function 'agent-dash-search--extract)
                  (lambda (active)
                    (setq items (agent-dash-search--run-items active)))))
         (agent-dash-search--collect run)
         (should-not items)
         (agent-dash-test-wait (lambda () items))
         (should (= (agent-dash-search--run-total run) 1))
         (should (string-search "测试问题" (plist-get (car items) :text))))))))

(ert-deftest agent-dash-history-async-test-late-dialogue-cannot-start-summary ()
  "Disabling or replacing a job while reading cannot send a model request."
  (agent-dash-history-async-test-with-reader
   (cl-letf (((symbol-function 'agent-dash-summary--summarize)
              (lambda (&rest _) (ert-fail "Summarized a cancelled job"))))
     (agent-dash-summary--start '(:backend history-fixture :id "custom-session"))
     (agent-dash-summary--release agent-dash-summary--job)
     (agent-dash-test-wait (lambda () (zerop (hash-table-count agent-dash-history--jobs))))
     (should-not agent-dash-summary--job))))

(ert-deftest agent-dash-history-async-test-burst-updates-share-one-redraw ()
  "Several reader completions coalesce instead of rebuilding the table repeatedly."
  (agent-dash-history-async-test-with-reader
   (let ((redraws 0))
     (cl-letf (((symbol-function 'agent-dash-hub--redisplay)
                (lambda () (cl-incf redraws))))
       (dotimes (_ 5) (agent-dash-hub--schedule-redisplay))
       (should (= redraws 0))
       (agent-dash-test-wait (lambda () (= redraws 1)))
       (should-not agent-dash-hub--render-timer)))))

(ert-deftest agent-dash-history-async-test-cold-reference-does-not-block ()
  "A cold picker reports background loading, then uses the shared snapshot."
  (agent-dash-history-async-test-with-reader
   (should-error (agent-dash-hub-read-reference 'history-fixture) :type 'user-error)
   (should (= (hash-table-count agent-dash-history--jobs) 1))
   (agent-dash-test-wait (lambda () (zerop (hash-table-count agent-dash-history--jobs))))
   (cl-letf (((symbol-function 'agent-dash-input-read)
              (lambda (_prompt choices &optional _query) (cdar choices))))
     (should (string-search "agent-dash:history-fixture:custom-session"
                            (agent-dash-hub-read-reference 'history-fixture))))))

(ert-deftest agent-dash-history-async-test-scheduler-waits-for-fresh-live-state ()
  "A scheduler pass cannot choose a summary from a stale in-flight snapshot."
  (agent-dash-history-async-test-with-reader
   (let ((agent-dash-summary-mode t)
         (agent-dash-summary--next-scan 0)
         (agent-dash-summary--last-request 0)
         (agent-dash-summary--paused nil)
         (agent-dash-summary--timer nil)
         selected)
     (unwind-protect
         (cl-letf (((symbol-function 'agent-dash-summary--candidate)
                    (lambda () (setq selected t) nil)))
           (agent-dash-summary--tick)
           (should (= (hash-table-count agent-dash-history--jobs) 1))
           (should-not selected)
           (agent-dash-test-wait
            (lambda () (zerop (hash-table-count agent-dash-history--jobs)))))
       (when (timerp agent-dash-summary--timer)
         (cancel-timer agent-dash-summary--timer))))))

(provide 'agent-dash-history-async-test)
;;; agent-dash-history-async-test.el ends here
