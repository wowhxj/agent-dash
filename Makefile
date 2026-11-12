EMACS ?= emacs
# Existing package dir providing elisp-lint, package-lint and declared deps.
ELPA ?= $(HOME)/.emacs.d.default/elpa
ELISP = agent-dash-core.el agent-dash-ui.el agent-dash-holder.el agent-dash-pi.el agent-dash-claude.el agent-dash-dsh.el agent-dash-codex.el agent-dash-hermes.el agent-dash-hub.el agent-dash.el
INIT = --eval '(setq package-user-dir "$(ELPA)")' -f package-initialize
TESTS = $(wildcard test/*-test.el)

.PHONY: check compile test lint indent clean

check: compile test lint

compile:
	$(EMACS) -Q --batch -L . $(INIT) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

test:
	$(EMACS) -Q --batch -L . -L test $(INIT) --eval '(setq load-prefer-newer t)' $(TESTS:%=-l %) -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q --batch -L . $(INIT) -l elisp-lint -f elisp-lint-files-batch agent-dash.el
	$(EMACS) -Q --batch -L . $(INIT) -l elisp-lint -f elisp-lint-files-batch --no-package-lint $(filter-out agent-dash.el,$(ELISP))
	$(EMACS) -Q --batch -L . -L test $(INIT) -l elisp-lint -f elisp-lint-files-batch --no-package-lint --no-fill-column $(abspath $(TESTS))

# Reindent every source file the way the indent lint expects.
indent:
	$(EMACS) -Q --batch -L . -L test $(INIT) -l agent-dash -l agent-dash-fake --eval '(dolist (f (quote ($(foreach f,$(ELISP) $(wildcard test/*.el),"$(f)")))) (with-current-buffer (find-file-noselect f) (indent-region (point-min) (point-max)) (save-buffer)))'

clean:
	rm -f *.elc test/*.elc agent-dash-autoloads.el
