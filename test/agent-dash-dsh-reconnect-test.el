;;; agent-dash-dsh-reconnect-test.el --- DSH reconnect tests -*- lexical-binding: t; -*-

;;; Commentary:

;; No Host or inference: exercise both disconnected channels with fake sockets.

;;; Code:

(require 'ert)
(require 'agent-dash)
(require 'agent-dash-fake)

(ert-deftest agent-dash-dsh-reconnect-follow-close-and-detach ()
  (let ((session (agent-dash-session-create 'dsh "/tmp"))
        (agent-dash-dsh--session-list nil)
        on-close on-item)
    (agent-dash-set-data session :sid "S")
    (cl-letf (((symbol-function 'agent-dash-dsh--load-default-model) #'ignore)
              ((symbol-function 'agent-dash-dsh--socket)
               (lambda (_open item &optional close)
                 (setq on-close close on-item item) 'socket))
              ((symbol-function 'websocket-openp) #'always)
              ((symbol-function 'websocket-close) (lambda (ws) (funcall on-close ws))))
      (agent-dash-dsh--follow session)
      (agent-dash-emit session '(:type run :state running))
      ;; A delayed close from an obsolete connection must not affect the new one.
      (funcall on-close 'old-socket)
      (should (eq (agent-dash-session-state session) 'running))
      (funcall on-close 'socket)
      (should (eq (agent-dash-session-state session) 'dead))
      (let ((timer (agent-dash-data session :reconnect-timer)))
        (unwind-protect
            (progn
              (should (timerp timer))
              (funcall on-close 'socket)
              (should (eq timer (agent-dash-data session :reconnect-timer)))
              (funcall on-item (agent-dash-json-read
                                (concat "{\"streamId\":\"agent-dash-state\",\"type\":\"item\","
                                        "\"value\":{\"running\":false}}")))
              (should (eq (agent-dash-session-state session) 'idle))
              (funcall on-item (agent-dash-json-read
                                (concat "{\"streamId\":\"agent-dash-state\",\"type\":\"item\","
                                        "\"value\":{\"running\":true}}")))
              (should (eq (agent-dash-session-state session) 'running))
              (agent-dash-backend-detach 'dsh session)
              (should-not (agent-dash-data session :reconnect-timer))
              (should-not (memq timer timer-list))
              (should (agent-dash-data session :detached)))
          (cancel-timer timer))))))

(ert-deftest agent-dash-dsh-reconnect-retry-is-passive ()
  (let ((session (agent-dash-session-create 'dsh "/tmp"))
        (agent-dash-dsh--host 'old) calls)
    (cl-letf (((symbol-function 'agent-dash-dsh--ensure-events)
               (lambda () (push 'events calls)))
              ((symbol-function 'agent-dash-dsh--follow)
               (lambda (s) (should (eq s session)) (push 'follow calls)))
              ((symbol-function 'agent-dash-dsh--call)
               (lambda (&rest _) (ert-fail "Reconnect must not send an RPC command"))))
      (agent-dash-dsh--reconnect session)
      (should-not agent-dash-dsh--host)
      (should (equal (reverse calls) '(events follow)))
      (agent-dash-set-data session :detached t)
      (agent-dash-dsh--reconnect session)
      (should (= (length calls) 2)))))

(ert-deftest agent-dash-dsh-reconnect-failure-backs-off ()
  (let ((session (agent-dash-session-create 'dsh "/tmp")))
    (cl-letf (((symbol-function 'agent-dash-dsh--ensure-events)
               (lambda () (error "Host offline"))))
      (unwind-protect
          (progn
            (agent-dash-set-data session :reconnect-delay 30)
            (agent-dash-dsh--reconnect session)
            (should (eq (agent-dash-session-state session) 'dead))
            (should (equal (agent-dash-data session :reconnect-delay) 30))
            (should (timerp (agent-dash-data session :reconnect-timer)))
            (should (equal (plist-get (agent-dash-item session "dsh-reconnect-error") :text)
                           "Host offline")))
        (cancel-timer (agent-dash-data session :reconnect-timer))))))

(defun agent-dash-dsh-reconnect-test-question ()
  "Return a forwarded question fixture."
  (agent-dash-json-read
   (concat "{\"type\":\"item\",\"value\":{\"type\":\"waterfall\",\"eventId\":\"Q\","
           "\"agentId\":\"S\",\"event\":\"user-questions/request\",\"request\":{"
           "\"questions\":[{\"id\":\"q\",\"question\":\"Pick\","
           "\"options\":[{\"label\":\"A\"}]}]}}}")))

(ert-deftest agent-dash-dsh-reconnect-events-replays-pending-question ()
  (let* ((session (agent-dash-session-create 'dsh "/tmp"))
         (buffer (generate-new-buffer " dsh-reconnect"))
         (agent-dash-dsh--session-list (list session))
         (agent-dash-dsh--waiting (make-hash-table :test #'equal))
         (agent-dash-dsh--events nil)
         on-item on-close)
    (setf (agent-dash-session-buffer session) buffer)
    (agent-dash-set-data session :sid "S")
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-dsh--socket)
                   (lambda (_open item &optional close)
                     (setq on-item item on-close close) 'events-socket)))
          (agent-dash-dsh--ensure-events)
          (funcall on-item (agent-dash-json-read
                            (concat "{\"type\":\"item\",\"value\":{\"type\":\"ready\","
                                    "\"clientId\":\"old-client\"}}")))
          (funcall on-item (agent-dash-dsh-reconnect-test-question))
          (should (= (length (agent-dash-session-requests session)) 1))
          (funcall on-close 'events-socket)
          (should (eq (agent-dash-session-state session) 'dead))
          (should-not agent-dash-dsh--events)
          (should-not (agent-dash-session-requests session))
          (should (= (hash-table-count agent-dash-dsh--waiting) 0))
          (agent-dash-dsh--ensure-events)
          (funcall on-item (agent-dash-json-read
                            (concat "{\"type\":\"item\",\"value\":{\"type\":\"ready\","
                                    "\"clientId\":\"new-client\"}}")))
          (funcall on-item (agent-dash-dsh-reconnect-test-question))
          (should (equal (plist-get agent-dash-dsh--events :client) "new-client"))
          (should (= (length (agent-dash-session-requests session)) 1))
          (should (eq (plist-get (agent-dash-item session '(request . "Q")) :status)
                      'pending)))
      (when-let* ((timer (agent-dash-data session :reconnect-timer))) (cancel-timer timer))
      (kill-buffer buffer))))

(ert-deftest agent-dash-dsh-reconnect-snapshot-catches-up-without-duplicates ()
  (let ((session (agent-dash-session-create 'dsh "/tmp")))
    (agent-dash-dsh--event session (agent-dash-json-read
                                    "{\"seq\":1,\"type\":\"turn/start\",\"data\":{}}"))
    (let ((snapshot (agent-dash-json-read
                     (concat "{\"type\":\"item\",\"value\":{\"type\":\"snapshot\",\"records\":["
                             "{\"event\":{\"seq\":1,\"type\":\"turn/start\",\"data\":{}}},"
                             "{\"event\":{\"seq\":2,\"type\":\"assistant/message\",\"data\":{"
                             "\"message\":{\"id\":\"M\",\"content\":[{\"type\":\"text\","
                             "\"text\":\"Missed reply\"}]}}}},"
                             "{\"event\":{\"seq\":3,\"type\":\"turn/end\","
                             "\"data\":{\"reason\":{\"kind\":\"completed\"}}}}]}}"))))
      (agent-dash-dsh--item session snapshot)
      (agent-dash-dsh--item session snapshot)
      (should (eq (agent-dash-session-state session) 'idle))
      (should (= (length (agent-dash-session-items session)) 1))
      (should (equal (plist-get (agent-dash-item session "M") :text) "Missed reply")))))

(ert-deftest agent-dash-dsh-remember-open-chat-across-restart ()
  (let ((agent-dash-directory (make-temp-file "agent-dash-dsh-live-" t))
        (agent-dash-dsh--session-list nil)
        (agent-dash--sessions nil)
        (session (agent-dash-session-create 'dsh "/tmp")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-dash-dsh--ensure-events) #'ignore)
                  ((symbol-function 'agent-dash-dsh--follow) #'ignore)
                  ((symbol-function 'agent-dash-dsh--call)
                   (lambda (method _args)
                     (should (equal method "session/list"))
                     (agent-dash-json-read
                      (concat "{\"items\":["
                              "{\"sessionId\":\"open\",\"blank\":true,\"running\":false},"
                              "{\"sessionId\":\"active\",\"blank\":true,\"running\":true},"
                              "{\"sessionId\":\"saved\",\"blank\":true,\"running\":false}]}")))))
          (agent-dash-backend-start 'dsh session "open")
          (let* ((agent-dash-dsh--session-list nil)
                 (rows (agent-dash-backend-sessions 'dsh nil)))
            (should (equal (mapcar (lambda (row) (plist-get row :id))
                                   (seq-filter #'agent-dash-hub-live-p rows))
                           '("open" "active"))))
          (agent-dash-backend-quit 'dsh session)
          (should (equal (mapcar (lambda (row) (plist-get row :id))
                                 (seq-filter #'agent-dash-hub-live-p
                                             (agent-dash-backend-sessions 'dsh nil)))
                         '("active"))))
      (delete-directory agent-dash-directory t))))

(ert-deftest agent-dash-dsh-permission-only-new-sessions ()
  (dolist (permission '("auto" nil))
    (let ((agent-dash-dsh-permission permission)
          (agent-dash-dsh--session-list nil) commands)
      (cl-letf (((symbol-function 'agent-dash-dsh--remember-chat) #'ignore)
                ((symbol-function 'agent-dash-dsh--call)
                 (lambda (method _args &rest _)
                   (agent-dash-json-read
                    (if (equal method "workspace/create")
                        "{\"workspace\":{\"workspaceId\":\"W\"}}" "{\"sessionId\":\"S\"}"))))
                ((symbol-function 'agent-dash-backend-send)
                 (lambda (_backend s text _images _mode)
                   (should (equal (agent-dash-data s :sid) "S")) (push text commands)))
                ((symbol-function 'agent-dash-dsh--ensure-events) #'ignore)
                ((symbol-function 'agent-dash-dsh--follow) #'ignore))
        (agent-dash-backend-start 'dsh (agent-dash-session-create 'dsh "/tmp"))
        (should (equal commands (when permission '("/permission auto"))))
        (setq commands nil)
        (agent-dash-backend-start 'dsh (agent-dash-session-create 'dsh "/tmp") "existing")
        (should-not commands)))))

(provide 'agent-dash-dsh-reconnect-test)
;;; agent-dash-dsh-reconnect-test.el ends here
