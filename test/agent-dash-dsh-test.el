;;; agent-dash-dsh-test.el --- DSH backend tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline: frames are fed by hand and Host RPC is stubbed.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(defun agent-dash-dsh-test-item (session json)
  "Feed follow-stream frame JSON (a string) to SESSION."
  (agent-dash-dsh--item session (agent-dash-json-read json)))

(ert-deftest agent-dash-dsh-test-turn ()
  (let ((s (agent-dash-session-create 'dsh "/tmp")))
    (dolist (f '("{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":1,\"type\":\"turn/start\",\"data\":{}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":2,\"type\":\"user/message\",\"data\":{\"message\":{\"id\":\"u1\",\"source\":{\"kind\":\"user\"},\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":3,\"type\":\"user/message\",\"data\":{\"message\":{\"id\":\"u2\",\"source\":{\"kind\":\"system\"},\"content\":[{\"type\":\"text\",\"text\":\"injected\"}]}}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":4,\"type\":\"tool/call\",\"data\":{\"callId\":\"c1\",\"name\":\"bash\",\"arguments\":{\"command\":\"ls\"}}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":5,\"type\":\"tool/result\",\"data\":{\"message\":{\"callId\":\"c1\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"assistant-stream\",\"frame\":{\"type\":\"start\",\"attemptId\":\"x\"}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"assistant-stream\",\"frame\":{\"type\":\"chunk\",\"attemptId\":\"x\",\"chunk\":{\"type\":\"text-delta\",\"text\":\"Do\"}}}}"))
      (agent-dash-dsh-test-item s f))
    (should (eq (agent-dash-session-state s) 'running))
    (should (equal (plist-get (agent-dash-item s "live-x") :text) "Do"))
    (dolist (f '("{\"type\":\"item\",\"value\":{\"type\":\"assistant-stream\",\"frame\":{\"type\":\"end\",\"attemptId\":\"x\"}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":6,\"type\":\"assistant/message\",\"data\":{\"message\":{\"id\":\"m1\",\"content\":[{\"type\":\"reasoning\",\"text\":\"hm\"},{\"type\":\"text\",\"text\":\"Done\"}]}}}}}"
                 ;; A replayed snapshot repeats seqs; they are skipped.
                 "{\"type\":\"item\",\"value\":{\"type\":\"snapshot\",\"records\":[{\"event\":{\"seq\":2,\"type\":\"user/message\",\"data\":{\"message\":{\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}}}],\"projections\":{\"values\":{\"title\":\"T\",\"modelSelection\":{\"next\":{\"model\":\"ds\"}}}}}}"
                 "{\"type\":\"item\",\"value\":{\"type\":\"event\",\"event\":{\"seq\":7,\"type\":\"turn/end\",\"data\":{\"reason\":{\"kind\":\"cancelled\"}}}}}"))
      (agent-dash-dsh-test-item s f))
    (should (equal (mapcar (lambda (i) (list (plist-get i :type) (plist-get i :id)))
                           (agent-dash-session-items s))
                   '((user "u1") (tool "c1") (assistant "live-x") (notice "s7"))))
    (let ((m (agent-dash-item s "live-x")))
      (should (equal (plist-get m :text) "Done"))
      (should (equal (plist-get m :thinking) "hm"))
      (should (plist-get m :final)))
    (should (eq (plist-get (agent-dash-item s "c1") :status) 'success))
    (should (equal (plist-get (agent-dash-item s "s7") :text) "turn cancelled"))
    (should (eq (agent-dash-session-state s) 'idle))
    (should (equal (agent-dash-session-meta s) '(:title "T" :model "ds")))))

(ert-deftest agent-dash-dsh-test-interactions ()
  (let* ((agent-dash-dsh--session-list nil)
         (agent-dash-dsh--events '(:client "cl"))
         (agent-dash-dsh--waiting (make-hash-table :test #'equal))
         (calls nil)
         (buffer (generate-new-buffer " dsh"))
         (s (agent-dash-session-create 'dsh "/tmp")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-dsh--call)
                   (lambda (method args) (push (list method args) calls) nil)))
          (setf (agent-dash-session-buffer s) buffer)
          (agent-dash-set-data s :sid "S1")
          (push s agent-dash-dsh--session-list)
          (dolist (f '("{\"type\":\"item\",\"value\":{\"type\":\"waterfall\",\"eventId\":\"e1\",\"agentId\":\"S1\",\"event\":\"approval/request\",\"request\":{\"toolName\":\"bash\",\"reason\":\"rm\"}}}"
                       "{\"type\":\"item\",\"value\":{\"type\":\"waterfall\",\"eventId\":\"e2\",\"agentId\":\"S1\",\"event\":\"user-questions/request\",\"request\":{\"questions\":[{\"id\":\"q1\",\"question\":\"Pick\",\"multiSelect\":true,\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}]}}}"
                       "{\"type\":\"item\",\"value\":{\"type\":\"waterfall\",\"eventId\":\"e3\",\"agentId\":\"OTHER\",\"event\":\"approval/request\",\"request\":{}}}"))
            (agent-dash-dsh--events-item (agent-dash-json-read f)))
          ;; Not our session: passed on to other clients.
          (should (equal (car calls) '("$events/result" (:clientId "cl" :eventId "e3"
                                                                   :outcome (:kind "next")))))
          (let ((requests (agent-dash-session-requests s)))
            (should (equal (plist-get (car requests) :title) "DSH wants bash (rm)"))
            (agent-dash-backend-respond 'dsh s (car requests) 'allow)
            (agent-dash-backend-respond 'dsh s (cadr requests) '(("A" "other"))))
          (should (equal (cadr calls)
                         '("$events/result" (:clientId "cl" :eventId "e1"
                                                       :outcome (:kind "result" :value "allowed-once")))))
          (should (equal (car calls)
                         '("$events/result"
                           (:clientId "cl" :eventId "e2"
                                      :outcome (:kind "result"
                                                      :value (:answers [(:id "q1" :selected ["A"]
                                                                             :custom "other")]))))))
          (agent-dash-dsh--events-item
           (agent-dash-json-read "{\"type\":\"item\",\"value\":{\"type\":\"cancel\",\"eventId\":\"e2\"}}")))
      (kill-buffer buffer))))

(ert-deftest agent-dash-dsh-test-quit-only-detaches ()
  (let ((detached nil) (asked nil))
    (cl-letf (((symbol-function 'agent-dash-backend-start) #'ignore)
              ((symbol-function 'agent-dash-dsh--sessions) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t)))
              ((symbol-function 'websocket-openp) #'always)
              ((symbol-function 'websocket-close) (lambda (_) (setq detached t))))
      (let ((s (agent-dash-open 'dsh temporary-file-directory)))
        (agent-dash-set-data s :socket 'fake-socket)
        (with-current-buffer (agent-dash-session-buffer s) (agent-dash-quit))))
    (should detached)
    (should-not asked)))

(provide 'agent-dash-dsh-test)
;;; agent-dash-dsh-test.el ends here
