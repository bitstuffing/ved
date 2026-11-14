SHELL := /bin/bash
.DEFAULT_GOAL := check

SCRIPTS := ved $(shell find lib locale -type f -name '*.sh' -print)

.PHONY: check syntax test lint

check: syntax test lint

syntax:
	bash -n $(SCRIPTS)

test:
	bash tests/cli_test.sh

# SC2034: globals set in one module and read in another (multi-file sourced project).
# SC2054: false positive on space-separated multi-line array assignments.
# SC2148: lib files are sourced, so they have no standalone shebang (--shell=bash covers it).
# SC2154: locale message keys are assigned; declared array lives in lib/i18n.sh.
# SC2174/SC2221/SC2222: accepted style for this project's mkdir/case usage.
lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		printf 'shellcheck is not installed; skipping lint.\n' ; \
		printf 'Install it (for example: sudo dnf install ShellCheck) to enable lint locally.\n' >&2 ; \
		exit 0 ; \
	fi
	shellcheck --shell=bash --external-sources --source-path=SCRIPTDIR \
		-e SC2034 -e SC2054 -e SC2148 -e SC2154 -e SC2174 -e SC2221 -e SC2222 $(SCRIPTS)
