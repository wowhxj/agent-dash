;;; agent-dash-dsh-metrics-test.el --- DSH metrics tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline Host projection fixtures.  Never use credentials or call a model.

;;; Code:

(require 'ert)
(require 'agent-dash)

(defconst agent-dash-dsh-metrics-test-values
  (concat "{\"contextPressure\":{\"projectedTokens\":24200,"
          "\"pressureTokens\":25000,\"contextWindow\":1000000},"
          "\"sessionStats\":{\"turns\":2,\"steps\":3,"
          "\"decodeTokens\":52,\"decodeMs\":2000},"
          "\"tokenUsage\":{\"uncachedInputTokens\":100,\"cacheReadTokens\":200,"
          "\"cacheWriteTokens\":100,\"outputTokens\":50},"
          "\"modelSelection\":{\"next\":{\"provider\":\"cliproxyapi\","
          "\"model\":\"gpt-6.1-sol\",\"reasoningEffort\":\"medium\"}},"
          "\"agentPreset\":\"standard\","
          "\"permissions\":{\"currentValue\":\"workspace-write\"}}")
  "Complete, synthetic Host projections.")

(defun agent-dash-dsh-metrics-test-session ()
  "Return a detached session addressed by the fixture id."
  (let ((session (agent-dash-session-create 'dsh temporary-file-directory)))
    (agent-dash-set-data session :sid "fixture")
    session))

(defun agent-dash-dsh-metrics-test-change (session seq changes)
  "Feed projection CHANGES at SEQ to SESSION."
  (agent-dash-dsh--control-item
   session (agent-dash-json-read
            (format (concat "{\"type\":\"projection\",\"sessionId\":\"fixture\","
                            "\"seq\":%d,\"changes\":%s}") seq changes))))

(ert-deftest agent-dash-dsh-metrics-snapshot-and-shared-header ()
  "Restore all header metrics using the Host's distinct billing buckets."
  (let ((session (agent-dash-dsh-metrics-test-session)))
    (agent-dash-dsh--item
     session (agent-dash-json-read
              (concat "{\"type\":\"item\",\"value\":{\"type\":\"snapshot\","
                      "\"projections\":{\"asOfSeq\":10,\"values\":"
                      agent-dash-dsh-metrics-test-values "}}}")))
    (let* ((meta (agent-dash-session-meta session))
           (stats (plist-get meta :stats)))
      (should (= (agent-dash-jget stats "tokens" "total") 450))
      (should (= (agent-dash-jget stats "tokens" "input") 100))
      (should (= (agent-dash-jget (plist-get meta :context-usage) "tokens")
                 24200))
      (should (equal (plist-get meta :permission) "workspace-write")))
    (with-temp-buffer
      (setq-local agent-dash--session session)
      (cl-letf (((symbol-function 'window-total-width) (lambda (&rest _) 300)))
        (let ((header (agent-dash--header)))
          (dolist (text '("24.2k/1.0M" "2 turns · 3 steps" "26 tok/s"
                          "450 tok" "cache 50%%" "(cliproxyapi) gpt-6.1-sol"
                          "medium · standard · workspace-write"))
            (should (string-search text header)))
          (should-not (string-search "$" header)))))))

(ert-deftest agent-dash-dsh-metrics-control-baseline-and-replacements ()
  "Ignore other sessions and stale data; preserve absent and clear null keys."
  (let ((session (agent-dash-dsh-metrics-test-session)))
    (agent-dash-dsh--control-item
     session (agent-dash-json-read
              (concat "{\"type\":\"baseline\",\"value\":{\"projections\":{"
                      "\"fixture\":{\"asOfSeq\":10,\"values\":"
                      agent-dash-dsh-metrics-test-values "},"
                      "\"other\":{\"asOfSeq\":99,\"values\":{"
                      "\"agentPreset\":\"not-ours\"}}}}}")))
    (agent-dash-dsh-metrics-test-change
     session 12 "[{\"key\":\"permissions\",\"val\":null}]")
    (should-not (plist-get (agent-dash-session-meta session) :permission))
    (should (equal (plist-get (agent-dash-session-meta session) :agent-preset)
                   "standard"))
    (agent-dash-dsh-metrics-test-change
     session 11 "{\"permissions\":{\"currentValue\":\"stale\"}}")
    (should-not (plist-get (agent-dash-session-meta session) :permission))
    (agent-dash-dsh--control-item
     session (agent-dash-json-read
              (concat "{\"type\":\"projection\",\"sessionId\":\"other\",\"seq\":100,"
                      "\"changes\":{\"agentPreset\":\"not-ours\"}}")))
    (should (equal (plist-get (agent-dash-session-meta session) :agent-preset)
                   "standard"))
    (agent-dash-dsh--control-item
     session (agent-dash-json-read
              (concat "{\"type\":\"projection\",\"sessionId\":\"fixture\",\"seq\":13,"
                      "\"key\":\"permissions\",\"value\":{"
                      "\"currentValue\":\"read-only\"}}")))
    (should (equal (plist-get (agent-dash-session-meta session) :permission)
                   "read-only"))))

(ert-deftest agent-dash-dsh-metrics-missing-data-and-model-change ()
  "Never invent throughput, totals or cache rates from incomplete data."
  (let ((session (agent-dash-dsh-metrics-test-session)))
    (agent-dash-dsh--apply-projections
     session (agent-dash-json-read agent-dash-dsh-metrics-test-values) 10)
    (agent-dash-dsh-metrics-test-change
     session 11 (concat "{\"sessionStats\":{\"turns\":0,\"steps\":0,"
                        "\"decodeTokens\":52,\"decodeMs\":0},"
                        "\"tokenUsage\":{\"uncachedInputTokens\":100},"
                        "\"contextPressure\":null,\"agentPreset\":null}"))
    (agent-dash-dsh--event
     session (agent-dash-json-read
              (concat "{\"seq\":12,\"type\":\"model/selection\",\"data\":{"
                      "\"model\":\"new-model\",\"provider\":\"new-provider\","
                      "\"reasoningEffort\":\"high\"}}")))
    (with-temp-buffer
      (setq-local agent-dash--session session)
      (let ((header (agent-dash--header)))
        (should (string-search "new-model" header))
        (dolist (text '("tok/s" "cache" "turns" "standard" "tok"))
          (should-not (string-search text header)))))))

(ert-deftest agent-dash-dsh-metrics-null-preset-and-header-fallback ()
  "Header preset is only a fallback, not an override of explicit null."
  (dolist (values '("{}" "{\"agentPreset\":null}"))
    (let ((session (agent-dash-dsh-metrics-test-session)))
      (agent-dash-dsh--item
       session (agent-dash-json-read
                (concat "{\"type\":\"item\",\"value\":{\"type\":\"snapshot\","
                        "\"header\":{\"agentPreset\":\"standard\"},"
                        "\"projections\":{\"values\":" values "}}}")))
      (should (equal (plist-get (agent-dash-session-meta session) :agent-preset)
                     (and (equal values "{}") "standard"))))))

(ert-deftest agent-dash-dsh-metrics-follow-subscribes-control ()
  "Subscribe both streams and route control frames without another connection."
  (let ((session (agent-dash-dsh-metrics-test-session)) sent handler)
    (cl-letf (((symbol-function 'agent-dash-dsh--socket)
               (lambda (on-open on-item)
                 (setq handler on-item)
                 (funcall on-open 'socket)
                 'socket))
              ((symbol-function 'websocket-send-text)
               (lambda (_socket text) (push (agent-dash-json-read text) sent))))
      (agent-dash-dsh--follow session))
    (should (equal (mapcar (lambda (frame) (agent-dash-jget frame "endpoint")) sent)
                   '("session/control" "session/follow")))
    (funcall handler
             (agent-dash-json-read
              (concat "{\"streamId\":\"agent-dash-control\",\"type\":\"item\","
                      "\"value\":{\"type\":\"projection\",\"sessionId\":\"fixture\","
                      "\"seq\":1,\"changes\":{\"agentPreset\":\"standard\"}}}")))
    (should (equal (plist-get (agent-dash-session-meta session) :agent-preset)
                   "standard"))
    (funcall handler
             (agent-dash-json-read
              "{\"streamId\":\"agent-dash-control\",\"type\":\"error\"}"))
    (should (eq (plist-get (agent-dash-item session "dsh-metrics-error") :level)
                'warning))
    (should (eq (agent-dash-session-state session) 'idle))))

(provide 'agent-dash-dsh-metrics-test)
;;; agent-dash-dsh-metrics-test.el ends here
