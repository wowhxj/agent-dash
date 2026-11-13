;;; agent-dash-dsh-cache-test.el --- DSH projection cache tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Temporary fixtures only: no real Host, bridge credentials or model calls.

;;; Code:

(require 'ert)
(require 'agent-dash-dsh)

(defun agent-dash-dsh-test-with-cache (version prompts callback)
  "Call CALLBACK with a temporary cache file of VERSION and PROMPTS."
  (let* ((directory (make-temp-file "agent-dash-dsh-test-" t))
         (coding-system-for-write 'utf-8-unix)
         (agent-dash-dsh-bridge-file
          (expand-file-name "bridge.json" directory))
         (file (expand-file-name
                "storages/session_projcache/sessions/fixture.json"
                directory)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (set-buffer-multibyte t)
            (insert
             (json-serialize
              (list :record
                    (list :rows
                          (list :turnOutline
                                (list :ver version
                                      :val
                                      (list :turns
                                            (vconcat
                                             (mapcar
                                              (lambda (prompt)
                                                (list :prompt prompt))
                                              prompts))))))))))
          (funcall callback file))
      (delete-directory directory t))))

(ert-deftest agent-dash-dsh-prompts-version-two ()
  "Read version two prompts in their original order."
  (agent-dash-dsh-test-with-cache
   2 '("First question" "最后一句")
   (lambda (_file)
     (should (equal (agent-dash-dsh--prompts "fixture")
                    '("First question" "最后一句"))))))

(ert-deftest agent-dash-dsh-prompts-missing-file ()
  "Missing projection files produce no prompts."
  (agent-dash-dsh-test-with-cache
   2 '("First")
   (lambda (file)
     (delete-file file)
     (should-not (agent-dash-dsh--prompts "fixture")))))

(ert-deftest agent-dash-dsh-prompts-unsupported-version ()
  "Do not trust an unsupported projection format."
  (agent-dash-dsh-test-with-cache
   1 '("First")
   (lambda (_file)
     (should-not (agent-dash-dsh--prompts "fixture")))))

(ert-deftest agent-dash-dsh-prompts-ignore-empty-values ()
  "Filter empty, whitespace-only and non-string prompts."
  (agent-dash-dsh-test-with-cache
   2 '("" " \n\t" nil 42 "Keep me" "")
   (lambda (_file)
     (should (equal (agent-dash-dsh--prompts "fixture") '("Keep me"))))))

(provide 'agent-dash-dsh-cache-test)
;;; agent-dash-dsh-cache-test.el ends here
