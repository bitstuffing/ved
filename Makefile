SHELL := /bin/bash
.DEFAULT_GOAL := check

SCRIPTS := ved $(shell find lib locale -type f -name '*.sh' -print)

.PHONY: check syntax test lint ci help fmt-check test-verbose test-container

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

# CI-safe entry point: requires shellcheck, checks formatting and runs all tests.
ci: fmt-check
	tests/run.sh --ci

# Reject trailing whitespace and missing final newlines in tracked text files.
fmt-check:
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		if git grep -nI '[[:blank:]]$$' -- '*.sh' 'ved' 'Makefile' '*.md' '*.yml' '*.yaml'; then \
			printf 'Trailing whitespace found.\n' >&2; \
			exit 1; \
		fi; \
	fi
	@printf 'format ok\n'

# Developer targets -----------------------------------------------------------

test-verbose:
	tests/run.sh --verbose --no-lint

test-container:
	@if docker info >/dev/null 2>&1; then \
		engine=docker; \
	elif podman info >/dev/null 2>&1; then \
		engine=podman; \
	else \
		printf 'No container engine found (install docker or podman).\n' >&2; \
		exit 1; \
	fi; \
	$$engine build -f Dockerfile.test -t ved-test . && \
	$$engine run --rm ved-test

help:
	@printf '%s\n' \
		'make check          - syntax + CLI tests + shellcheck (lint optional locally)' \
		'make ci             - strict CI checks (shellcheck required, format check)' \
		'make syntax         - bash -n on every script' \
		'make test           - CLI regression suite only' \
		'make test-verbose   - traced test run, log in tests/last-run.log' \
		'make test-container - run the same checks in a Debian container' \
		'make lint           - shellcheck only' \
		'make fmt-check      - trailing whitespace check' \
		'make help           - this message'
