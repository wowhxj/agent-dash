;;; agent-dash-ui-test.el --- Chat presentation regressions -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure in-memory rendering and stubbed RPC: never call real agents or models.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defmacro agent-dash-ui-test-with-chat (&rest body)
  "Run BODY with a fake chat named `session'."
  (declare (indent 0))
  `(let* ((agent-dash-fake-calls nil)
          (session (agent-dash-open 'fake temporary-file-directory)))
     (with-current-buffer (agent-dash-session-buffer session)
       (unwind-protect (progn ,@body)
         (let ((agent-dash--quitting t)) (kill-buffer))))))

(defun agent-dash-ui-test-transcript ()
  "Return the chat transcript without the editable composer."
  (buffer-substring-no-properties (point-min) agent-dash--transcript-end))

(ert-deftest agent-dash-ui-test-composer-and-pinned-prompt ()
  "Decoration must not become sent text, history or reference context."
  (agent-dash-ui-test-with-chat
   (goto-char (point-max))
   (insert "draft")
   (agent-dash-emit session '(:type user :id "u" :text "100% ready"))
   (should (equal (agent-dash--input) "draft"))
   (should (equal (overlay-get agent-dash--input-overlay 'before-string)
                  "You> "))
   (should (= (overlay-start agent-dash--input-overlay)
              agent-dash--input-start))
   (should (string-match-p "100%% ready" (agent-dash--pinned-prompt)))
   (should (eq (get-text-property (1+ (point-min)) 'face)
               'agent-dash-user-face))
   (agent-dash--set-input "replacement")
   (should (equal (agent-dash--input) "replacement"))
   (should (= (overlay-start agent-dash--input-overlay)
              agent-dash--input-start))))

(ert-deftest agent-dash-ui-test-composer-full-line-background ()
  "Fill empty and multiline composers to the edge without modifying drafts."
  (agent-dash-ui-test-with-chat
   (dolist (draft '("" "short" "first line\nsecond line" ""))
     (agent-dash--set-input draft)
     (agent-dash-emit session '(:type assistant :id "a" :text "background output"))
     (let ((fill (overlay-get agent-dash--input-overlay 'after-string)))
       (should (equal fill " "))
       (should (equal (get-text-property 0 'display fill)
                      '(space :align-to right)))
       (should (eq (get-text-property 0 'face fill) 'agent-dash-input-face))
       (should (eq (get-text-property 0 'cursor fill) t))
       (should (face-attribute 'agent-dash-input-face :extend nil t))
       (should-not (face-attribute 'agent-dash-input-face :underline nil t)))
     (should (= (overlay-end agent-dash--input-overlay) (point-max)))
     (should (equal (agent-dash--input) draft)))
   (agent-dash--set-input "send exactly this")
   (agent-dash-send)
   (should (equal (car agent-dash-fake-calls)
                  '(send "send exactly this" nil prompt)))
   (should (equal agent-dash--history '("send exactly this")))
   (should (equal (agent-dash--input) ""))))

(ert-deftest agent-dash-ui-test-i-focuses-composer-across-backends ()
  "Transcript i focuses the draft without inserting text or calling a backend."
  (let ((agent-dash--sessions nil)
        (last-command-event ?i))
    (dolist (backend '(pi claude codex hermes dsh))
      (let* ((session (agent-dash-session-create backend temporary-file-directory))
             (buffer (agent-dash--setup-buffer session)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'agent-dash-backend-send)
                         (lambda (&rest _) (ert-fail "Sending on i"))))
                (agent-dash-emit session '(:type assistant :id "a" :text "Reply"))
                (dolist (draft '("" "draft" "one\ntwo"))
                  (agent-dash--set-input draft)
                  (goto-char (point-min))
                  (should-not (agent-dash--in-input-p))
                  (call-interactively (key-binding "i"))
                  (should (= (point) (point-max)))
                  (should (equal (agent-dash--input) draft))
                  (call-interactively (key-binding "i"))
                  (should (equal (agent-dash--input) (concat draft "i"))))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (let ((agent-dash--quitting t)) (kill-buffer)))))))))

(ert-deftest agent-dash-ui-test-i-inserts-at-point-with-prefix ()
  "Composer i remains an ordinary self-insert, including numeric prefixes."
  (agent-dash-ui-test-with-chat
   (agent-dash--set-input "abc")
   (goto-char (1+ agent-dash--input-start))
   (let ((last-command-event ?i) (current-prefix-arg 3))
     (call-interactively (key-binding "i")))
   (should (equal (agent-dash--input) "aiiibc"))
   (should (= (point) (+ agent-dash--input-start 4)))
   (agent-dash-emit session '(:type assistant :id "a" :text "Background"))
   (should (= (point) (+ agent-dash--input-start 4)))
   (agent-dash-refresh-chat)
   (should (= (point) (+ agent-dash--input-start 4)))
   (should (equal (agent-dash--input) "aiiibc"))
   (should (get-text-property
            0 'cursor (overlay-get agent-dash--input-overlay 'after-string)))))

(ert-deftest agent-dash-ui-test-process-group-growth-and-toggle ()
  "Process groups stay folded while growing, without hiding final answers."
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type user :id "u" :text "work"))
   (agent-dash-emit session '(:type tool :id "t1" :name "read"))
   (agent-dash-emit session '(:type assistant :id "thought"
                                    :text "" :thinking "plan"))
   (agent-dash-emit
    session '(:type assistant :id "answer" :text "Done" :final t))
   (let* ((first (agent-dash-item session "t1"))
          (answer (agent-dash-item session "answer")))
     (should (= (plist-get first :process-count) 2))
     (goto-char (plist-get first :start))
     (forward-line 1)
     (should (invisible-p (point)))
     (should-not (invisible-p (plist-get answer :start)))
     (goto-char (plist-get first :start))
     (agent-dash-toggle)
     (forward-line 1)
     (should-not (invisible-p (point)))
     (agent-dash-emit session '(:type tool :id "t2" :name "write"))
     (should (= (plist-get first :process-count) 3))
     (should (plist-get first :process-open))
     (agent-dash-emit session '(:type user :id "u2" :text "next"))
     (agent-dash-emit session '(:type tool :id "t3" :name "bash"))
     (should (= (plist-get (agent-dash-item session "t3") :process-count) 1))
     (should-not (plist-get (agent-dash-item session "t3") :process-open)))))

(ert-deftest agent-dash-ui-test-streamed-thinking-becomes-answer ()
  "A thinking-only item leaves Process when it gains a visible answer."
  (agent-dash-ui-test-with-chat
   (agent-dash-emit
    session '(:type assistant :id "a" :text "" :thinking "plan"))
   (agent-dash-emit session '(:type assistant :id "a" :text "Answer" :final t))
   (should-not (plist-get (agent-dash-item session "a") :process-group))
   (should-not (invisible-p (point-min)))
   (should-not (string-search "Process" (agent-dash-ui-test-transcript)))))

(ert-deftest agent-dash-ui-test-refresh-preserves-chat ()
  "Hot reload keeps items, draft cursor, history and connection intact."
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type user :id "u" :text "question"))
   (agent-dash-emit session '(:type tool :id "t" :name "read"))
   (agent-dash-emit session '(:type assistant :id "a" :text "answer"))
   (goto-char (point-max))
   (insert "unfinished draft")
   (backward-char 3)
   (let ((before (agent-dash-ui-test-transcript))
         (calls agent-dash-fake-calls)
         (items (agent-dash-session-items session)))
     (agent-dash-refresh-chat)
     (agent-dash-refresh-chat)
     (should (eq items (agent-dash-session-items session)))
     (should (equal before (agent-dash-ui-test-transcript)))
     (should (equal (agent-dash--input) "unfinished draft"))
     (should (= (point) (- (point-max) 3)))
     (should (equal calls agent-dash-fake-calls))
     (should-error (delete-region (point-min) (1+ (point-min)))
                   :type 'text-read-only))))

(ert-deftest agent-dash-ui-test-cached-statistics-only ()
  "Redisplay is pure and omits unsupported statistics."
  (agent-dash-ui-test-with-chat
   (should-not (string-search "tok" (agent-dash--header)))
   (agent-dash-emit
    session (list :type 'meta :model "m1" :provider "provider" :thinking "high"
                  :stats (agent-dash-json-read
                          (concat "{\"tokens\":{\"total\":1200},\"cost\":0.02,"
                                  "\"userMessages\":2,\"assistantMessages\":3}"))))
   (cl-letf (((symbol-function 'agent-dash-pi--request)
              (lambda (&rest _) (ert-fail "RPC during redisplay")))
             ((symbol-function 'window-total-width) (lambda (&rest _) 200)))
     (should (string-search "1.2k tok" (agent-dash--header)))
     (should (string-search "2 prompts · 3 calls" (agent-dash--header)))
     (let ((header (agent-dash--header)))
       (should (string-search "$0.0200" header))
       (should (string-search "estimate, not a bill"
                              (get-text-property 0 'help-echo header))))
     (should (string-search "(provider) m1 · high" (agent-dash--header))))))

(ert-deftest agent-dash-ui-test-pi-stats-refresh-and-waiting ()
  "Pi exposes its phase and requests stats only while attached."
  (let ((session (agent-dash-session-create 'pi "/tmp")) calls)
    (agent-dash-pi--record
     session (agent-dash-json-read "{\"type\":\"agent_start\"}"))
    (should (equal (plist-get (agent-dash-session-meta session) :phase)
                   "waiting for model"))
    (agent-dash-set-data session :writer 'fake)
    (cl-letf (((symbol-function 'process-live-p) #'always)
              ((symbol-function 'agent-dash-pi--request)
               (lambda (_s command callback)
                 (push (plist-get command :type) calls)
                 (funcall callback t
                          (agent-dash-json-read
                           (concat "{\"cost\":0,\"contextUsage\":{"
                                   "\"tokens\":12,\"contextWindow\":100}}"))
                          nil))))
      (agent-dash-pi--record
       session (agent-dash-json-read "{\"type\":\"agent_settled\"}")))
    (should (eq (agent-dash-session-state session) 'idle))
    (should (equal calls '("get_session_stats")))
    (should (= (agent-dash-jget
                (plist-get (agent-dash-session-meta session) :context-usage)
                "tokens") 12))
    (should (= (agent-dash-jget
                (plist-get (agent-dash-session-meta session) :stats) "cost")
               0))))

(ert-deftest agent-dash-ui-test-header-alignment-and-narrow-widths ()
  "Use a right-edge display anchor and retain model identity when narrow."
  (agent-dash-ui-test-with-chat
   (agent-dash-emit
    session (list :type 'meta :model "gpt-6.1-sol" :provider "openai-codex"
                  :thinking "medium"
                  :context-usage (agent-dash-json-read
                                  "{\"tokens\":600,\"contextWindow\":1000,\"percent\":60}")
                  :stats (agent-dash-json-read
                          (concat "{\"tokens\":{\"input\":100,\"cacheRead\":300,"
                                  "\"cacheWrite\":200,\"total\":1200},\"cost\":0.02}"))))
   (cl-letf (((symbol-function 'window-total-width) (lambda (&rest _) 200)))
     (let* ((header (agent-dash--header))
            (right "(openai-codex) gpt-6.1-sol · medium")
            (start (string-search right header)))
       (should start)
       (should (equal (get-text-property (1- start) 'display header)
                      `(space :align-to (- right ,(1+ (string-width right))))))
       (should (string-search "600/1.0k (60%%)" header))
       (should (string-search "cache 50%%" header))
       (should-not (string-search "idle" header))))
   (dolist (width '(24 40 60 80))
     (cl-letf (((symbol-function 'window-total-width)
                (lambda (&rest _) width)))
       (let ((header (agent-dash--header)))
         (should (<= (string-width (string-replace "%%" "%" header)) width))
         (should (string-search "gpt-" header))
         (when (>= width 40)
           (should (string-search "gpt-6.1-sol" header)))
         (should (string-search "$0.0200"
                                (get-text-property 0 'help-echo header))))))))

(ert-deftest agent-dash-ui-test-shared-layout-across-backends ()
  "All five backends share layout, input styling and nonduplicate status."
  (let ((agent-dash--sessions nil))
    (dolist (backend '(pi claude codex hermes dsh))
      (let* ((session (agent-dash-session-create backend temporary-file-directory))
             (buffer (agent-dash--setup-buffer session)))
        (unwind-protect
            (with-current-buffer buffer
              (agent-dash-emit session '(:type user :id "u" :text "question"))
              (agent-dash-emit session '(:type meta :model "test-model"
                                               :provider "provider" :thinking "high"
                                               :phase "waiting for model"))
              (agent-dash-emit session '(:type run :state running))
              (agent-dash-emit session '(:type queue :follow-up ("queued")))
              (agent-dash-emit session '(:type request :id "r" :kind confirm))
              (should (equal tab-line-format '(:eval (agent-dash--header))))
              (should (equal header-line-format
                             '(:eval (agent-dash--pinned-prompt))))
              (should (string-search "test-model" (agent-dash--header)))
              (should-not (string-search "running" (agent-dash--header)))
              (should-not (string-search "waiting" (agent-dash--header)))
              (should (equal
                       (agent-dash--mode-line)
                       (format " %s waiting | [S0 F1] ?1"
                               (agent-dash--backend-name backend))))
              (should (string-search
                       "waiting for model"
                       (get-text-property 0 'help-echo (agent-dash--mode-line))))
              (should-not (string-search "test-model" (agent-dash--mode-line)))
              (should-not (face-attribute 'agent-dash-input-face :underline nil t))
              (should (eq (face-attribute 'agent-dash-input-face :inherit)
                          'widget-field))
              (should (equal (overlay-get agent-dash--input-overlay 'before-string)
                             "You> "))
              (should (get-text-property
                       0 'cursor (overlay-get agent-dash--input-overlay 'after-string)))
              (goto-char (point-max))
              (insert "draft")
              (agent-dash-refresh-chat)
              (should (equal (agent-dash--input) "draft"))
              (should (equal
                       (get-text-property
                        0 'display
                        (overlay-get agent-dash--input-overlay 'after-string))
                       '(space :align-to right))))
          (with-current-buffer buffer
            (let ((agent-dash--quitting t)) (kill-buffer))))))))

(ert-deftest agent-dash-ui-test-spinner-lifecycle ()
  "Animation is deterministic, redraw-only, and stops with activity."
  (agent-dash-ui-test-with-chat
   (goto-char (point-max))
   (insert "draft")
   (should (equal (agent-dash--mode-line) " Fake idle"))
   (should-not agent-dash--spinner-timer)
   (agent-dash-emit session '(:type run :state running))
   (let* ((timer agent-dash--spinner-timer)
          (tick (timer--function timer))
          (calls agent-dash-fake-calls))
     (should (timerp timer))
     (cl-letf (((symbol-function 'agent-dash-backend-send)
                (lambda (&rest _) (ert-fail "Sending during animation")))
               ((symbol-function 'agent-dash-pi--request)
                (lambda (&rest _) (ert-fail "RPC during animation"))))
       (dotimes (index 4)
         (funcall tick)
         (should (equal (agent-dash--mode-line)
                        (format " Fake thinking %c"
                                (aref "|/-\\" (mod (1+ index) 4)))))))
     (should (equal calls agent-dash-fake-calls))
     (should (equal (agent-dash--input) "draft"))
     (agent-dash-refresh-chat)
     (agent-dash-refresh-chat)
     (should (eq timer agent-dash--spinner-timer))
     (agent-dash-emit session '(:type run :state idle))
     (should-not agent-dash--spinner-timer)
     (should-not (memq timer timer-list))
     (agent-dash-emit session '(:type run :state running))
     (let ((current agent-dash--spinner-timer)
           (index agent-dash--spinner-index))
       ;; A callback from a canceled timer must not tick or cancel its successor.
       (funcall tick)
       (should (= index agent-dash--spinner-index))
       (should (eq current agent-dash--spinner-timer)))
     (agent-dash-emit session '(:type run :state dead))
     (should-not agent-dash--spinner-timer)
     (should (equal (agent-dash--mode-line) " Fake disconnected")))))

(ert-deftest agent-dash-ui-test-spinner-cleanup-and-single-status-slot ()
  "Mode changes and buffer death cancel timers; hot loading never duplicates UI."
  (let ((agent-dash--sessions nil))
    (dolist (action '(kill-buffer fundamental-mode))
      (let* ((session (agent-dash-session-create 'fake temporary-file-directory))
             (buffer (agent-dash--setup-buffer session)) timer)
        (unwind-protect
            (with-current-buffer buffer
              (setq-local mode-line-process '(:eval (agent-dash--mode-line)))
              (agent-dash--install-status-line)
              (agent-dash--install-status-line)
              (should-not mode-line-process)
              (should (= 1 (cl-count '(:eval (agent-dash--mode-line))
                                     mode-line-misc-info :test #'equal)))
              (agent-dash-emit session '(:type run :state running))
              (setq timer agent-dash--spinner-timer)
              (let ((agent-dash--quitting t)) (funcall action))
              (should-not (memq timer timer-list)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (let ((agent-dash--quitting t)) (kill-buffer)))))))))

(defun agent-dash-ui-test-position (text)
  "Return the first transcript position of TEXT, failing if absent."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward text agent-dash--transcript-end t))
    (- (point) (length text))))

(ert-deftest agent-dash-ui-test-active-process-expands-and-settles-across-backends ()
  "A final message is not the run boundary; preserve drafts through both states."
  (let ((agent-dash--sessions nil))
    (dolist (backend '(pi claude codex dsh hermes))
      (let* ((session (agent-dash-session-create backend temporary-file-directory))
             (buffer (agent-dash--setup-buffer session)))
        (unwind-protect
            (with-current-buffer buffer
              (agent-dash--set-input "keep draft")
              (goto-char (+ agent-dash--input-start 3))
              (agent-dash-emit session '(:type run :state running))
              (agent-dash-emit session '(:type user :id "u" :text "question"))
              (agent-dash-emit session '(:type assistant :id "thought" :text ""
                                               :thinking "First thought\nDetailed second thought"
                                               :final t))
              (agent-dash-emit session '(:type tool :id "tool" :name "working-tool"
                                               :args "inspect" :output "DETAILED OUTPUT"
                                               :status running))
              (should (plist-get (agent-dash-item session "thought") :process-open))
              (should (agent-dash--item-folded-p (agent-dash-item session "thought")))
              (should (agent-dash--item-folded-p (agent-dash-item session "tool")))
              (should-not (invisible-p (agent-dash-ui-test-position "▸ Thinking")))
              (should-not (invisible-p (agent-dash-ui-test-position "working-tool")))
              (should-not (string-search "First thought\nDetailed second thought"
                                         (agent-dash-ui-test-transcript)))
              (should-not (string-search "DETAILED OUTPUT" (agent-dash-ui-test-transcript)))
              (agent-dash-refresh-chat)
              (agent-dash-emit session '(:type tool :id "tool" :output "UPDATED OUTPUT"
                                               :status success))
              (agent-dash-emit session '(:type assistant :id "answer"
                                               :text "FINAL ANSWER" :final t))
              (should (plist-get (agent-dash-item session "thought") :process-open))
              (should-not (string-search "UPDATED OUTPUT" (agent-dash-ui-test-transcript)))
              (should (agent-dash--item-folded-p (agent-dash-item session "thought")))
              (should (agent-dash--item-folded-p (agent-dash-item session "tool")))
              (agent-dash-emit session '(:type run :state idle))
              (should-not (plist-get (agent-dash-item session "thought") :process-open))
              (should (invisible-p (agent-dash-ui-test-position "working-tool")))
              (should-not (invisible-p (agent-dash-ui-test-position "FINAL ANSWER")))
              (should (equal (agent-dash--input) "keep draft"))
              (should (= (point) (+ agent-dash--input-start 3))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (let ((agent-dash--quitting t)) (kill-buffer)))))))))

(ert-deftest agent-dash-ui-test-active-process-manual-visibility-survives-updates ()
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type user :id "u" :text "question"))
   (agent-dash-emit session '(:type tool :id "tool" :name "tool" :output "DETAIL"))
   (let ((item (agent-dash-item session "tool")))
     (should (agent-dash--item-folded-p item))
     (goto-char (agent-dash-ui-test-position "tool  "))
     (agent-dash-toggle)
     (should-not (agent-dash--item-folded-p item))
     (agent-dash-emit session '(:type tool :id "tool" :output "MORE DETAIL"))
     (should-not (agent-dash--item-folded-p item))
     (should-not (invisible-p (agent-dash-ui-test-position "MORE DETAIL")))
     (goto-char (plist-get item :start))
     (agent-dash-toggle)
     (agent-dash-emit session '(:type tool :id "other" :name "next-tool"))
     (should-not (plist-get item :process-open))
     (goto-char (plist-get item :start))
     (agent-dash-toggle)
     (agent-dash-refresh-chat)
     (should (plist-get item :process-open))
     (should-not (agent-dash--item-folded-p item))
     (should (agent-dash--item-folded-p (agent-dash-item session "other")))
     (should-not (invisible-p (agent-dash-ui-test-position "MORE DETAIL")))
     (agent-dash-emit session '(:type run :state idle))
     (should-not (plist-get item :process-open))
     (goto-char (plist-get item :start))
     (agent-dash-toggle)
     (agent-dash-emit session '(:type meta :phase "idle metadata"))
     (should (plist-get item :process-open)))))

(ert-deftest agent-dash-ui-test-new-run-does-not-reopen-historical-process ()
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type user :id "old" :text "old question"))
   (agent-dash-emit session '(:type tool :id "old-tool" :name "history-tool"))
   (agent-dash-emit session '(:type assistant :id "old-answer" :text "old answer" :final t))
   (agent-dash-emit session '(:type run :state running))
   (should-not (plist-get (agent-dash-item session "old-tool") :process-open))
   (agent-dash-emit session '(:type user :id "new" :text "new question"))
   (agent-dash-emit session '(:type tool :id "new-tool" :name "live-tool" :output "live"))
   (should (plist-get (agent-dash-item session "new-tool") :process-open))
   (should (invisible-p (agent-dash-ui-test-position "history-tool")))
   (agent-dash-emit session '(:type run :state idle))
   (agent-dash-emit session '(:type run :state running))
   (should-not (plist-get (agent-dash-item session "new-tool") :process-open))
   ;; Continuations without a new user echo reopen only on fresh activity.
   (agent-dash-emit session '(:type tool :id "continuation" :name "continuing" :output "fresh"))
   (should (plist-get (agent-dash-item session "new-tool") :process-open))
   (agent-dash-emit session '(:type meta :phase "continuing"))
   (should (plist-get (agent-dash-item session "new-tool") :process-open))))

(ert-deftest agent-dash-ui-test-process-head-can-become-a-visible-final-answer ()
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type user :id "u" :text "question"))
   (agent-dash-emit session '(:type assistant :id "a" :text "" :thinking "thinking"))
   (agent-dash-emit session '(:type tool :id "t" :name "tool" :output "visible detail"))
   (agent-dash-emit session '(:type assistant :id "a" :text "final answer" :final t))
   (should-not (plist-get (agent-dash-item session "a") :process-group))
   (should (plist-get (agent-dash-item session "t") :process-open))
   (should-not (invisible-p (agent-dash-ui-test-position "tool")))
   (should (agent-dash--item-folded-p (agent-dash-item session "t")))
   (should-not (string-search "visible detail" (agent-dash-ui-test-transcript)))
   (agent-dash-emit session '(:type run :state idle))
   (should (invisible-p (agent-dash-ui-test-position "tool")))
   (should-not (invisible-p (agent-dash-ui-test-position "final answer")))))

(ert-deftest agent-dash-ui-test-late-running-state-opens-an-unfinished-snapshot ()
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type user :id "u" :text "restored task"))
   (agent-dash-emit session '(:type tool :id "t" :name "snapshot-tool" :output "LIVE OUTPUT"))
   (should-not (plist-get (agent-dash-item session "t") :process-open))
   (agent-dash-emit session '(:type run :state running))
   (should (plist-get (agent-dash-item session "t") :process-open))
   (should-not (invisible-p (agent-dash-ui-test-position "snapshot-tool")))
   (should (agent-dash--item-folded-p (agent-dash-item session "t")))
   (should-not (string-search "LIVE OUTPUT" (agent-dash-ui-test-transcript)))
   (agent-dash-emit session '(:type run :state idle))
   (should-not (plist-get (agent-dash-item session "t") :process-open))))

(ert-deftest agent-dash-ui-test-thinking-details-only-open-on-user-toggle ()
  (agent-dash-ui-test-with-chat
   (agent-dash-emit session '(:type run :state running))
   (agent-dash-emit session '(:type user :id "u" :text "question"))
   (agent-dash-emit session '(:type assistant :id "a" :thinking "Summary\nTHOUGHT DETAIL"))
   (let ((item (agent-dash-item session "a")))
     (should (plist-get item :process-open))
     (should (agent-dash--item-folded-p item))
     (goto-char (agent-dash-ui-test-position "▸ Thinking"))
     (agent-dash-toggle)
     (should-not (agent-dash--item-folded-p item))
     (agent-dash-emit session '(:type assistant :id "a" :thinking "Summary\nUPDATED DETAIL"))
     (should-not (invisible-p (agent-dash-ui-test-position "UPDATED DETAIL")))
     (agent-dash-emit session '(:type tool :id "t" :name "new-tool" :output "HIDDEN OUTPUT"))
     (agent-dash-refresh-chat)
     (should (plist-get item :process-open))
     (should-not (agent-dash--item-folded-p item))
     (should (agent-dash--item-folded-p (agent-dash-item session "t")))
     (should-not (string-search "HIDDEN OUTPUT" (agent-dash-ui-test-transcript)))
     (goto-char (agent-dash-ui-test-position "▾ Thinking"))
     (agent-dash-toggle)
     (agent-dash-emit session '(:type assistant :id "a" :thinking "Summary\nCLOSED DETAIL"))
     (should (agent-dash--item-folded-p item))
     (should-not (string-search "▾ Thinking" (agent-dash-ui-test-transcript))))))

(provide 'agent-dash-ui-test)
;;; agent-dash-ui-test.el ends here
