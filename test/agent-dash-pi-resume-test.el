;;; agent-dash-pi-resume-test.el --- Explicit Pi history restoration -*- lexical-binding: t; -*-

;;; Commentary:
;; Temporary history and a strict offline CLI, never real sessions or models.

;;; Code:
(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defun agent-dash-pi-resume-test--file (base relative id root)
  "Write fixture session ID to BASE/RELATIVE for ROOT and return its path."
  (let ((file (expand-file-name relative base)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-serialize (list :type "session" :id id :cwd root)) "\n")
      (insert (json-serialize
               '(:type "message" :id "u" :parentId :null
                       :message (:role "user" :content "saved question" :timestamp 1))) "\n")
      (insert (json-serialize
               '(:type "message" :id "a" :parentId "u"
                       :message (:role "assistant"
                                       :content [(:type "text" :text "saved answer")]
                                       :timestamp 2))) "\n"))
    file))

(ert-deftest agent-dash-pi-resume-test-startup-distinguishes-new-from-saved ()
  (let* ((base (make-temp-file "dash resume " t))
         (agent-dash-directory base)
         (agent-dash-pi-sessions-directory base)
         (agent-dash-pi-arguments '("--test-option"))
         started attached alive)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-holder-alive-p) (lambda (_) alive))
                  ((symbol-function 'agent-dash-holder-start)
                   (lambda (_dir _root command) (push command started)))
                  ((symbol-function 'agent-dash-holder-attach)
                   (lambda (&rest _) (setq attached t)))
                  ((symbol-function 'agent-dash-pi--request) #'ignore)
                  ((symbol-function 'executable-find) (lambda (_) "offline-pi")))
          (dolist (spec '(("date_flat.jsonl" "flat")
                          ("--old--/parent/child/run-0/date_nested.jsonl" "nested")))
            (let* ((id (cadr spec))
                   (file (agent-dash-pi-resume-test--file base (car spec) id base))
                   (session (agent-dash-session-create 'pi base)))
              (agent-dash-backend-start 'pi session id)
              (should attached)
              (should (equal (car started)
                             (list "offline-pi" "--mode" "rpc" "--extension"
                                   agent-dash-pi-bridge-file "--session" file "--test-option")))))
          (setq started nil)
          (let ((session (agent-dash-session-create 'pi base)))
            (agent-dash-backend-start 'pi session)
            (should (equal (seq-take (car started) 6)
                           (list "offline-pi" "--mode" "rpc" "--extension"
                                 agent-dash-pi-bridge-file "--session-id")))
            (should (equal (nth 6 (car started)) (agent-dash-data session :sid))))
          ;; A missing saved file must not silently become an empty new session.
          (setq started nil attached nil)
          (should-error (agent-dash-backend-start
                         'pi (agent-dash-session-create 'pi base) "missing") :type 'user-error)
          (should-not started)
          (should-not attached)
          ;; A live unsaved holder can still be reattached without a disk history.
          (setq alive t)
          (agent-dash-backend-start 'pi (agent-dash-session-create 'pi base) "live")
          (should attached)
          (should-not started))
      (delete-directory base t))))

(ert-deftest agent-dash-pi-resume-test-holder-loads-selected-history ()
  (agent-dash-test-with-holders
    (let* ((history (make-temp-file "dash-history-" t))
           (agent-dash-pi-sessions-directory history)
           (agent-dash-pi-executable (expand-file-name "fake-pi-history" agent-dash-test--bin))
           (file (agent-dash-pi-resume-test--file history "date_saved.jsonl" "saved" history))
           session)
      (unwind-protect
          (progn
            ;; get_messages will contain only the post-compaction model context.
            ;; get_entries also holds an abandoned branch, which must stay hidden.
            (dolist (entry
                     '((:type "message" :id "abandoned" :parentId "u"
                              :message (:role "user" :content "wrong branch" :timestamp 99))
                       (:type "compaction" :id "c" :parentId "a" :summary "model context")
                       (:type "message" :id "u3" :parentId "c"
                              :message (:role "user" :content "new question" :timestamp 3))
                       (:type "message" :id "a4" :parentId "u3"
                              :message (:role "assistant"
                                              :content [(:type "text" :text "new answer")]
                                              :timestamp 4))))
              (write-region (concat (json-serialize entry) "\n") nil file t 'silent))
            ;; Go through the same Hub open path used for real historical sessions.
            (agent-dash-hub-open-row (list :backend 'pi :id "saved" :root history))
            (setq session agent-dash--session)
            (with-current-buffer (agent-dash-session-buffer session)
              (agent-dash--set-input "keep draft")
              (goto-char (+ agent-dash--input-start 4))
              (agent-dash-test-wait (lambda () (agent-dash-data session :history-loaded)))
              (should (equal (agent-dash--input) "keep draft"))
              (should (= (point) (+ agent-dash--input-start 4)))
              (should (equal (plist-get (agent-dash-item session "u1") :text) "saved question"))
              (should (equal (plist-get (agent-dash-item session "a2") :text) "saved answer"))
              (should (equal (plist-get (agent-dash-item session "u3") :text) "new question"))
              (should (equal (plist-get (agent-dash-item session "a4") :text) "new answer"))
              (should-not (agent-dash-item session "u99"))
              (should (= (length (agent-dash-session-items session)) 4))
              (should (eq (agent-dash-session-state session) 'idle))
              (let* ((dir (agent-dash-data session :holder))
                     (log (expand-file-name "out.jsonl" dir))
                     (records (mapcar #'agent-dash-json-read (agent-dash-file-lines log)))
                     (state (seq-find (lambda (record)
                                        (equal (agent-dash-jget record "command") "get_state"))
                                      records)))
                (should (equal (agent-dash-jget state "data" "sessionFile") file)))))
        (when session
          (with-current-buffer (agent-dash-session-buffer session)
            (agent-dash-backend-detach 'pi session)
            (let ((agent-dash--quitting t)) (kill-buffer))))
        (delete-directory history t)))))

(ert-deftest agent-dash-pi-resume-test-context-fallback-is-visible ()
  (let ((session (agent-dash-session-create 'pi temporary-file-directory)) calls)
    (cl-letf (((symbol-function 'agent-dash-pi--refresh-stats) #'ignore)
              ((symbol-function 'agent-dash-pi--request)
               (lambda (_session request callback)
                 (push (plist-get request :type) calls)
                 (if (equal (plist-get request :type) "get_entries")
                     (funcall callback nil nil "Unknown command")
                   (funcall callback t (agent-dash-json-read
                                        (concat "{\"messages\":[{\"role\":\"user\","
                                                "\"content\":\"context\",\"timestamp\":1}]}"))
                            nil)))))
      (agent-dash-pi--load-history session)
      (should (equal (nreverse calls) '("get_entries" "get_messages")))
      (should (agent-dash-data session :history-loaded))
      (should (agent-dash-item session "u1"))
      (should (seq-some (lambda (item) (eq (plist-get item :level) 'warning))
                        (agent-dash-session-items session))))))

(ert-deftest agent-dash-pi-resume-test-corrupt-branch-cannot-loop ()
  (let ((entries (agent-dash-jget
                  (agent-dash-json-read "{\"entries\":[{\"id\":\"loop\",\"parentId\":\"loop\"}]}")
                  "entries")))
    (should-error (agent-dash-pi--branch-messages entries "loop"))))

(provide 'agent-dash-pi-resume-test)
;;; agent-dash-pi-resume-test.el ends here
