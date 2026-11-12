;;; agent-dash-hub-test.el --- Hub tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: the fake backend provides saved sessions and transcripts.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(cl-defmethod agent-dash-backend-sessions ((_ (eql broken)) _root)
  "A source whose listing always fails."
  (error "Source unavailable"))

(defmacro agent-dash-hub-test-with-hub (&rest body)
  "Run BODY in a hub listing two fake sessions and one broken source."
  (declare (indent 0))
  `(let ((agent-dash-backends '(fake broken))
         (agent-dash-fake-calls nil)
         (agent-dash-fake-saved
          (list (list :id "s1" :root temporary-file-directory :time "2026-11-01T10:00"
                      :title "fix the parser")
                (list :id "s2" :root temporary-file-directory :time "2026-11-02T10:00"
                      :title "write docs" :running t))))
     (save-window-excursion
       (agent-dash-hub)
       (unwind-protect (progn ,@body)
         (kill-buffer "*agent-dash hub*")))))

(defun agent-dash-hub-test-ids ()
  "Return the session ids listed in the hub, top to bottom."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (tabulated-list-get-id)
        (push (plist-get (cdr (tabulated-list-get-id)) :id) ids)
        (forward-line 1)))
    (nreverse ids)))

(ert-deftest agent-dash-hub-test-lists-newest-first-and-reports-errors ()
  (agent-dash-hub-test-with-hub
   (should (equal (agent-dash-hub-test-ids) '("s2" "s1")))
   (should (string-match-p "broken: Source unavailable" (format "%s" header-line-format)))
   (goto-char (point-min))
   (should (string-match-p "●" (buffer-substring (line-beginning-position) (line-end-position))))
   (agent-dash-hub-filter "parser")
   (should (equal (agent-dash-hub-test-ids) '("s1")))
   (agent-dash-hub-filter "")
   (should (equal (agent-dash-hub-test-ids) '("s2" "s1")))))

(ert-deftest agent-dash-hub-test-open-resumes-then-switches ()
  (agent-dash-hub-test-with-hub
   (goto-char (point-min))
   (agent-dash-hub-open)
   (let ((session (car agent-dash--sessions)))
     (should (equal (car agent-dash-fake-calls)
                    (list 'start (agent-dash-session-id session) "s2")))
     ;; A backend records its session id; a second RET switches to that chat.
     (agent-dash-set-data session :sid "s2")
     (with-current-buffer "*agent-dash hub*"
       (goto-char (point-min))
       (agent-dash-hub-open))
     (should (= 1 (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-dash-fake-calls))))
     (should (eq (current-buffer) (agent-dash-session-buffer session)))
     (let ((agent-dash--quitting t)) (kill-buffer (agent-dash-session-buffer session))))))

(ert-deftest agent-dash-hub-test-reference-expands-and-displays-short ()
  (let ((agent-dash-backends '(fake))
        (agent-dash-fake-calls nil)
        (agent-dash-fake-saved (list (list :id "s1" :title "fix [the] parser"))))
    (let ((session (agent-dash-open 'fake temporary-file-directory)))
      (with-current-buffer (agent-dash-session-buffer session)
        (unwind-protect
            (progn
              (goto-char (point-max))
              (insert "see ")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest _) (caar choices))))
                (agent-dash-insert-reference))
              (should (equal (agent-dash--input) "see @[fix  the  parser](agent-dash:fake:s1)"))
              (agent-dash-send)
              (let ((sent (nth 1 (car agent-dash-fake-calls))))
                (should (string-prefix-p (concat "see @[fix  the  parser](agent-dash:fake:s1)"
                                                 agent-dash-reference-boundary)
                                         sent))
                (should (string-match-p "User: question of s1\n\nAgent: answer" sent))
                (should (equal (car agent-dash--history)
                               "see @[fix  the  parser](agent-dash:fake:s1)"))
                (agent-dash-emit session (list :type 'user :id "u" :text sent))
                (should (equal (buffer-substring-no-properties (point-min) agent-dash--transcript-end)
                               "You: see @[fix  the  parser](agent-dash:fake:s1)\n"))))
          (let ((agent-dash--quitting t)) (kill-buffer)))))))

(ert-deftest agent-dash-hub-test-file-completion-bounds ()
  (let ((agent-dash-fake-calls nil))
    (with-current-buffer (agent-dash-session-buffer (agent-dash-open 'fake temporary-file-directory))
      (unwind-protect
          (progn
            (goto-char (point-max))
            (insert "read @src/ma")
            (let ((capf (agent-dash--file-capf)))
              (should (equal (buffer-substring (nth 0 capf) (nth 1 capf)) "src/ma"))
              (should (eq (nth 2 capf) #'read-file-name-internal)))
            (insert " now")
            (should-not (agent-dash--file-capf)))
        (let ((agent-dash--quitting t)) (kill-buffer))))))

(provide 'agent-dash-hub-test)
;;; agent-dash-hub-test.el ends here
