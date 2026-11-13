EMACS ?= emacs
# Existing package dir providing elisp-lint, package-lint and declared deps.
ELPA ?= $(HOME)/.emacs.d.default/elpa
ELISP = agent-dash-core.el agent-dash-images.el agent-dash-input.el agent-dash-queue.el agent-dash-ui.el agent-dash-holder.el agent-dash-pi-commands.el agent-dash-pi.el agent-dash-claude.el agent-dash-dsh.el agent-dash-codex.el agent-dash-hermes.el agent-dash-summary.el agent-dash-hub.el agent-dash-search.el agent-dash.el
INIT = --eval '(setq package-user-dir "$(ELPA)")' -f package-initialize
# Tests never start background summaries: they would read real sessions and call models.
OFFLINE = --eval '(setq agent-dash-summary-enable nil)'
TESTS = $(wildcard test/*-test.el)

.PHONY: check compile test test-node lint indent clean

check: compile test lint

compile:
	$(EMACS) -Q --batch $(INIT) -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

test-node:
	node --test test/agent-dash-pi-bridge.test.mjs

test: test-node
	$(EMACS) -Q --batch $(INIT) $(OFFLINE) -L . -L test --eval '(setq load-prefer-newer t)' $(TESTS:%=-l %) -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q --batch $(INIT) -L . -l elisp-lint -f elisp-lint-files-batch agent-dash.el
	$(EMACS) -Q --batch $(INIT) -L . -l elisp-lint -f elisp-lint-files-batch --no-package-lint $(filter-out agent-dash.el,$(ELISP))
	$(EMACS) -Q --batch $(INIT) -L . -L test -l elisp-lint -f elisp-lint-files-batch --no-package-lint --no-fill-column $(abspath $(TESTS))

# Reindent every source file the way the indent lint expects.
indent:
	$(EMACS) -Q --batch $(INIT) $(OFFLINE) -L . -L test -l agent-dash -l agent-dash-fake --eval '(dolist (f (quote ($(foreach f,$(ELISP) $(wildcard test/*.el),"$(f)")))) (with-current-buffer (find-file-noselect f) (indent-region (point-min) (point-max)) (save-buffer)))'

clean:
	rm -f *.elc test/*.elc agent-dash-autoloads.el
