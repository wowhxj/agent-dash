;;; agent-dash.el --- Native agent clients and cross-agent session hub -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (markdown-mode "2.3") (websocket "1.15") (transient "0.7.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/wowhxj/agent-dash

;;; Commentary:

;; Single package bundling native chat clients for Pi, DSH and
;; Claude Code with a cross-agent session hub.  See HANDOFF.md.

;;; Code:

(require 'agent-dash-core)
(require 'agent-dash-ui)
(require 'agent-dash-pi)
(require 'agent-dash-claude)
(require 'agent-dash-dsh)
(require 'agent-dash-codex)
(require 'agent-dash-hermes)
(require 'agent-dash-hub)
(require 'agent-dash-search)

(when agent-dash-summary-enable
  (agent-dash-summary-mode 1))

(provide 'agent-dash)
;;; agent-dash.el ends here
