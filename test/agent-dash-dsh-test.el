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

(ert-deftest agent-dash-dsh-test-model-picker ()
  "Client /model uses the catalog and selectModel APIs, never commands/execute."
  (let ((s (agent-dash-session-create 'dsh "/tmp")) calls)
    (agent-dash-set-data s :sid "session-1")
    (cl-letf (((symbol-function 'agent-dash-dsh--call)
               (lambda (method &optional args _retry)
                 (push (cons method args) calls)
                 (pcase method
                   ("session/modelCatalog"
                    (agent-dash-json-read
                     "{\"groups\":[{\"id\":\"proxy\",\"models\":[{\"id\":\"org/model\"}]},{\"id\":\"other\",\"models\":[{\"id\":\"org/model\"}]}]}"))
                   ("session/selectModel"
                    (agent-dash-json-read
                     "{\"selected\":{\"provider\":\"proxy\",\"model\":\"org/model\",\"reasoningEffort\":\"high\"}}"))
                   (_ (ert-fail (format "Unexpected RPC: %s" method)))))))
      (should (plist-get (agent-dash-backend-capabilities 'dsh) :models))
      (should (equal (agent-dash-backend-models 'dsh s)
                     '("proxy/org/model" "other/org/model")))
      (agent-dash-backend-set-model 'dsh s "proxy/org/model")
      (should (equal (car calls)
                     '("session/selectModel" :request
                       (:sessionId "session-1" :provider "proxy" :model "org/model"))))
      (should (equal (plist-get (agent-dash-session-meta s) :model) "org/model"))
      (should (equal (plist-get (agent-dash-session-meta s) :provider) "proxy"))
      (should-error (agent-dash-backend-set-model 'dsh s "missing") :type 'user-error)
      (with-temp-buffer
        (setq-local agent-dash--session s)
        (cl-letf (((symbol-function 'agent-dash--input) (lambda () "/model"))
                  ((symbol-function 'agent-dash--set-input) #'ignore)
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "other/org/model")))
          (should (agent-dash-input-dispatch "/model"))
          (should (equal (plist-get (plist-get (cdr (car calls)) :request) :provider) "other")))))))

(ert-deftest agent-dash-dsh-test-select-model-wire-request ()
  "The gateway descriptor names the selectModel JSON parameter request."
  (let ((s (agent-dash-session-create 'dsh "/tmp"))
        (agent-dash-dsh--host '(:base "http://localhost/" :cookie "test")))
    (agent-dash-set-data s :sid "session-1")
    (agent-dash-set-data s :model-choices
                         '(("proxy/model" :provider "proxy" :model "model")))
    (cl-letf (((symbol-function 'agent-dash-dsh--retrieve)
               (lambda (_url _method body _cookie)
                 (let* ((message (agent-dash-json-read body))
                        (args (agent-dash-jget (agent-dash-jget message "payload") "args"))
                        (request (agent-dash-jget args "request")))
                   (should (hash-table-p request))
                   (should (= (hash-table-count args) 1))
                   (should (equal (agent-dash-jget request "sessionId") "session-1"))
                   (should (equal (agent-dash-jget request "provider") "proxy"))
                   (should (equal (agent-dash-jget request "model") "model"))
                   (list 200 nil
                         (json-serialize
                          (list :rpcId (agent-dash-jget message "rpcId")
                                :result (list :ok t
                                              :value (list :selected
                                                           (list :provider "proxy"
                                                                 :model "model"))))))))))
      (agent-dash-backend-set-model 'dsh s "proxy/model")
      (should (equal (plist-get (agent-dash-session-meta s) :model) "model")))))

(ert-deftest agent-dash-dsh-test-empty-model-catalog ()
  (cl-letf (((symbol-function 'agent-dash-dsh--call)
             (lambda (&rest _) (agent-dash-json-read "{\"groups\":[]}"))))
    (should-error (agent-dash-backend-models 'dsh (agent-dash-session-create 'dsh "/tmp"))
                  :type 'user-error)))

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
    (should (equal (plist-get (agent-dash-session-meta s) :title) "T"))
    (should (equal (plist-get (agent-dash-session-meta s) :model) "ds"))
    (should-not (agent-dash-jget (plist-get (agent-dash-session-meta s) :stats)
                                 "tokens" "total"))))

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
