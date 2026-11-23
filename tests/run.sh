#!/usr/bin/env bash
# Local test runner. Mirrors what CI does, with extra options for development.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PROJECT_ROOT

filter=""
verbose=0
keep_tmp=0
run_syntax=1
run_tests=1
run_lint=1
strict=0

usage() {
    cat <<'EOF'
Usage: tests/run.sh [options]

Options:
  --filter PATTERN  Run only cases whose name contains PATTERN.
  --list            List available case names and exit.
  --verbose         Trace with 'bash -x' and save the log to tests/last-run.log.
  --keep-tmp        Do not delete the temporary test directory.
  --no-syntax       Skip 'bash -n' checks.
  --no-tests        Skip the CLI regression suite.
  --no-lint         Skip shellcheck.
  --ci              Strict mode: require shellcheck and fail on skipped cases.
  -h, --help        Show this help.

Examples:
  tests/run.sh                       # everything (same as 'make check')
  tests/run.sh --filter docker       # only Docker-related cases
  tests/run.sh --filter docker --verbose
  tests/run.sh --ci                  # exactly what GitHub Actions runs
EOF
}

list_cases() {
    {
        sed -nE "s/^run_ved ([A-Za-z0-9_]+) .*/\1/p" "$PROJECT_ROOT/tests/cli_test.sh"
        sed -nE "s/^run_case '([^']+)'.*/\1/p" "$PROJECT_ROOT/tests/cli_test.sh"
    } | sort -u
}

while (($#)); do
    case "$1" in
        --filter)
            [[ $# -ge 2 ]] || { printf 'Missing value for --filter\n' >&2; exit 2; }
            filter="$2"
            shift 2
            ;;
        --filter=*)
            filter="${1#*=}"
            shift
            ;;
        --list)
            list_cases
            exit 0
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        --keep-tmp)
            keep_tmp=1
            shift
            ;;
        --no-syntax)
            run_syntax=0
            shift
            ;;
        --no-tests)
            run_tests=0
            shift
            ;;
        --no-lint)
            run_lint=0
            shift
            ;;
        --ci)
            strict=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

export VED_TEST_FILTER="$filter"
export VED_TEST_KEEP_TMP="$keep_tmp"

scripts=("$PROJECT_ROOT/ved")
while IFS= read -r file; do
    scripts+=("$file")
done < <(find "$PROJECT_ROOT/lib" "$PROJECT_ROOT/locale" -type f -name '*.sh' -print | sort)

log_file="$PROJECT_ROOT/tests/last-run.log"
if ((verbose)); then
    : >"$log_file"
    exec > >(tee -a "$log_file") 2>&1
    trace=(-x)
else
    trace=()
fi

section() {
    printf '\n== %s ==\n' "$1"
}

if ((run_syntax)); then
    section 'syntax'
    bash -n "${scripts[@]}"
    printf 'syntax ok\n'
fi

if ((run_tests)); then
    section 'tests'
    bash "${trace[@]}" "$PROJECT_ROOT/tests/cli_test.sh"
    if ((strict)) && [[ -n "$filter" ]]; then
        printf 'Strict mode cannot be combined with --filter.\n' >&2
        exit 2
    fi
fi

if ((run_lint)); then
    section 'lint'
    if ! command -v shellcheck >/dev/null 2>&1; then
        if ((strict)); then
            printf 'shellcheck is required in CI mode.\n' >&2
            exit 1
        fi
        printf 'shellcheck not installed; skipping lint.\n'
    else
        # SC2034: globals shared between sourced modules.
        # SC2054: false positive on multi-line array assignments.
        # SC2148: sourced files have no shebang (--shell=bash covers it).
        # SC2154: locale keys live in lib/i18n.sh.
        # SC2174/SC2221/SC2222: accepted project style.
        shellcheck --shell=bash --external-sources --source-path=SCRIPTDIR \
            -e SC2034 -e SC2054 -e SC2148 -e SC2154 \
            -e SC2174 -e SC2221 -e SC2222 "${scripts[@]}"
        printf 'lint ok\n'
    fi
fi

section 'summary'
printf 'All requested checks passed.\n'
