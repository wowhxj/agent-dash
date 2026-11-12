;;; agent-dash-holder.el --- Detached stdio holder for JSONL agents -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs an agent that speaks JSONL on stdio so that it outlives the chat
;; buffer and Emacs itself (docs/DESIGN.md §4):
;;
;;   nohup sh:  FIFO `in' --> cat --> AGENT --> append-only `out.jsonl'
;;
;; The holder opens the FIFO read-write, so the agent never sees EOF
;; when a writer goes away.  Emacs only follows `out.jsonl' with
;; `tail -f' and feeds the FIFO through a long-lived `cat'.  When the
;; agent exits, the holder appends {"type":"agent_dash_exit","code":N}.

;;; Code:

(require 'agent-dash-core)

(defconst agent-dash-holder--script
  "cd \"$1\" || exit 1
d=$2; shift 2
exec 3<>\"$d/in\"
cat \"$d/outp\" >>\"$d/out.jsonl\" &
reader=$!
cat <&3 | {
  \"$@\" <&0 >\"$d/outp\" 2>>\"$d/err\" &
  echo $! > \"$d/pid\"
  wait $!
  echo $? > \"$d/code\"
  exec 0<&-
  echo >&3
}
wait $reader
printf '{\"type\":\"agent_dash_exit\",\"code\":%s}\\n' \"$(cat \"$d/code\")\" >>\"$d/out.jsonl\""
  "Shell program: ROOT DIR COMMAND...
The agent reads through `cat' because Claude stops reading a FIFO stdin
after about 64 KiB, and writes to the FIFO `outp' that another `cat'
appends to the log, because Hermes ACP refuses a regular file as stdout.
`<&0' is needed because sh gives background jobs /dev/null as stdin.
Once the agent exits nothing reads the input pipe, so the final newline
makes the relay `cat' fail on its next write and exit; the exit record
is written after the log reader has drained the agent's output.")

(defun agent-dash-holder-dir (backend id)
  "Return the holder directory of BACKEND session ID."
  (expand-file-name (format "instances/%s-%s/" backend id) agent-dash-directory))

(defun agent-dash-holder--file (dir name)
  "Return holder file NAME in DIR."
  (expand-file-name name dir))

(defun agent-dash-holder-pid (dir)
  "Return the agent pid recorded in holder DIR, or nil."
  (let ((file (agent-dash-holder--file dir "pid")))
    (when (file-readable-p file)
      (let ((pid (string-to-number
                  (with-temp-buffer (insert-file-contents file) (buffer-string)))))
        (and (> pid 0) pid)))))

(defun agent-dash-holder-alive-p (dir)
  "Whether the agent of holder DIR is running."
  ;; ponytail: trusts the pid file; a recycled pid would look alive.
  (when-let* ((pid (agent-dash-holder-pid dir)))
    (eq 0 (signal-process pid 0))))

(defun agent-dash-holder-start (dir root command)
  "Start COMMAND, a list, detached in ROOT with holder directory DIR."
  (with-file-modes #o700 (make-directory dir t))
  (let ((log (agent-dash-holder--file dir "out.jsonl")))
    ;; The agent keeps its own transcript; keep one previous log anyway.
    (when (file-exists-p log)
      (rename-file log (agent-dash-holder--file dir "out.prev.jsonl") t))
    (dolist (name '("in" "outp" "pid" "err" "code"))
      (when (file-exists-p (agent-dash-holder--file dir name))
        (delete-file (agent-dash-holder--file dir name))))
    (unless (eq 0 (call-process "mkfifo" nil nil nil (agent-dash-holder--file dir "in")
                                (agent-dash-holder--file dir "outp")))
      (error "Cannot create FIFOs in %s" dir))
    (with-file-modes #o600
      (write-region "" nil log nil 'silent)
      (write-region root nil (agent-dash-holder--file dir "root") nil 'silent))
    ;; Destination 0: Emacs neither waits for nor owns the holder.
    (let ((default-directory root))
      (apply #'call-process "nohup" nil 0 nil "sh" "-c" agent-dash-holder--script
             "agent-dash" root dir command))
    ;; Writes before the pid exists would be refused by `alive-p'.
    (let ((deadline (+ (float-time) 5)))
      (while (and (not (agent-dash-holder-pid dir)) (< (float-time) deadline))
        (sleep-for 0.01)))
    (unless (agent-dash-holder-pid dir)
      (error "Agent holder did not start; see %s" (agent-dash-holder--file dir "err")))))

(defun agent-dash-holder--lines (session on-record)
  "Return a process filter that calls ON-RECORD with SESSION per JSON line."
  (let ((pending ""))
    (lambda (_process chunk)
      (setq pending (concat pending chunk))
      (let ((start 0) end)
        (while (setq end (string-search "\n" pending start))
          (let ((line (string-trim-right (substring pending start end) "\r")))
            (setq start (1+ end))
            (unless (string-empty-p line)
              ;; One bad record must not drop the rest of the chunk.
              (condition-case err
                  (funcall on-record session (agent-dash-json-read line))
                (error
                 (agent-dash-emit session
                                  (list :type 'notice :level 'error
                                        :text (format "Bad agent record: %s"
                                                      (error-message-string err)))))))))
        (setq pending (substring pending start))))))

(defun agent-dash-holder-attach (session dir on-record &optional from-start)
  "Follow holder DIR for SESSION, calling ON-RECORD with each parsed record.
Read the whole log when FROM-START, else only records written from now."
  (let* ((log (agent-dash-holder--file dir "out.jsonl"))
         (offset (if from-start 0 (file-attribute-size (file-attributes log)))))
    (agent-dash-set-data session :holder dir)
    (agent-dash-set-data
     session :tail
     (make-process :name "agent-dash-tail" :noquery t :connection-type 'pipe
                   :coding 'utf-8-unix
                   :command (list "tail" "-c" (format "+%d" (1+ offset)) "-f" log)
                   :filter (agent-dash-holder--lines session on-record)
                   :sentinel #'ignore))))

(defun agent-dash-holder-write (session object)
  "Send OBJECT, a plist, as one JSON line to SESSION's holder."
  (let ((dir (agent-dash-data session :holder))
        (writer (agent-dash-data session :writer)))
    (unless (agent-dash-holder-alive-p dir)
      (user-error "Agent is not running; C-c C-r resumes this session"))
    ;; One long-lived writer: Emacs never blocks on the FIFO, and lines
    ;; larger than a pipe buffer cannot interleave.
    (unless (process-live-p writer)
      (setq writer (make-process :name "agent-dash-writer" :noquery t
                                 :connection-type 'pipe :coding 'utf-8-unix
                                 :command (list "sh" "-c" "exec cat > \"$0\""
                                                (agent-dash-holder--file dir "in"))))
      (agent-dash-set-data session :writer writer))
    (process-send-string writer (concat (json-serialize object :false-object :false)
                                        "\n"))))

(defun agent-dash-holder-detach (session)
  "Stop following SESSION's holder; the agent keeps running."
  (let ((tail (agent-dash-data session :tail))
        (writer (agent-dash-data session :writer)))
    (when (process-live-p tail) (delete-process tail))
    (when (process-live-p writer) (process-send-eof writer))))

(defun agent-dash-holder-stop (session)
  "Terminate SESSION's agent and detach."
  (when-let* ((pid (agent-dash-holder-pid (agent-dash-data session :holder))))
    (signal-process pid 'TERM))
  (agent-dash-holder-detach session))

(defun agent-dash-holder-log (session object)
  "Append OBJECT as a record to SESSION's holder log.
For what only the client knows, such as prompts an agent does not echo,
so a later attach replays them in order."
  (write-region (concat (json-serialize object :false-object :false) "\n") nil
                (agent-dash-holder--file (agent-dash-data session :holder) "out.jsonl")
                t 'silent))

;;;; Agents whose session id the server chooses

(defun agent-dash-holder-set-sid (session sid)
  "Record backend session id SID for SESSION and in its holder directory."
  (agent-dash-set-data session :sid sid)
  (write-region sid nil (agent-dash-holder--file (agent-dash-data session :holder) "sid")
                nil 'silent))

(defun agent-dash-holder-find (backend sid)
  "Return the directory of the live holder of BACKEND session SID, or nil."
  (seq-find (lambda (dir)
              (let ((file (agent-dash-holder--file dir "sid")))
                (and (file-readable-p file)
                     (equal sid (with-temp-buffer (insert-file-contents file) (buffer-string)))
                     (agent-dash-holder-alive-p dir))))
            (mapcar #'file-name-as-directory
                    (file-expand-wildcards
                     (expand-file-name (format "instances/%s-*" backend) agent-dash-directory)))))

;;;; JSON-RPC 2.0 over a holder (Codex app-server, ACP)

(defun agent-dash-holder-request (session method params &optional callback)
  "Send SESSION's agent JSON-RPC request METHOD with PARAMS.
CALLBACK, if non-nil, gets (RESULT ERROR).
Ids are uuids, so a log replayed by a later Emacs never answers this call."
  (let ((id (agent-dash-uuid)))
    (when callback
      (puthash id callback (or (agent-dash-data session :rpc)
                               (agent-dash-set-data session :rpc
                                                    (make-hash-table :test #'equal)))))
    (agent-dash-holder-write session (list :jsonrpc "2.0" :id id :method method
                                           :params (or params (make-hash-table))))))

(defun agent-dash-holder-notify (session method params)
  "Send SESSION's agent JSON-RPC notification METHOD with PARAMS."
  (agent-dash-holder-write session (list :jsonrpc "2.0" :method method
                                         :params (or params (make-hash-table)))))

(defun agent-dash-holder-reply (session id result &optional error)
  "Answer request ID of SESSION's agent with RESULT, or with ERROR message."
  (agent-dash-holder-write
   session (if error
               (list :jsonrpc "2.0" :id id :error (list :code -32601 :message error))
             (list :jsonrpc "2.0" :id id :result (or result (make-hash-table))))))

(defun agent-dash-holder-settle (session record)
  "Run the callback of SESSION that RECORD answers, if any; return it."
  (when-let* ((table (agent-dash-data session :rpc))
              (id (agent-dash-jget record "id"))
              (callback (gethash id table)))
    (remhash id table)
    (funcall callback (agent-dash-jget record "result")
             (agent-dash-jget record "error" "message"))
    callback))

(defun agent-dash-holder-oneshot (command requests &optional on-notify timeout)
  "Run COMMAND, send REQUESTS ((METHOD . PARAMS)...), return the last result.
ON-NOTIFY, if non-nil, receives each notification before that result.
The process is killed afterwards; TIMEOUT defaults to 30 seconds."
  (let* ((pending "") (result nil) (done nil)
         (last-id (format "%d" (length requests)))
         (process
          (make-process
           :name "agent-dash-oneshot" :noquery t :connection-type 'pipe
           :coding 'utf-8-unix :command command :stderr (get-buffer-create " *agent-dash-stderr*")
           :filter (lambda (_p chunk)
                     (setq pending (concat pending chunk))
                     (while (string-match "\n" pending)
                       (let ((line (substring pending 0 (match-beginning 0))))
                         (setq pending (substring pending (match-end 0)))
                         (when (string-prefix-p "{" line)
                           (let ((record (agent-dash-json-read line)))
                             (cond ((equal (agent-dash-jget record "id") last-id)
                                    (setq done t result record))
                                   ((and on-notify (not (agent-dash-jget record "id")))
                                    (funcall on-notify record)))))))))))
    (unwind-protect
        (progn
          (cl-loop for (method . params) in requests
                   for n from 1
                   do (process-send-string
                       process (concat (json-serialize
                                        (list :jsonrpc "2.0" :id (format "%d" n) :method method
                                              :params (or params (make-hash-table)))
                                        :false-object :false)
                                       "\n")))
          (with-timeout ((or timeout 30) (error "%s did not answer %s" (car command)
                                                (car (car (last requests)))))
            (while (not done) (accept-process-output process 0.05)))
          (when-let* ((error (agent-dash-jget result "error" "message")))
            (error "%s: %s" (car command) error))
          (agent-dash-jget result "result"))
      (delete-process process))))

(provide 'agent-dash-holder)
;;; agent-dash-holder.el ends here
