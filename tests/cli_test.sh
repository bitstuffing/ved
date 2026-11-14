#!/usr/bin/env bash
# Non-privileged CLI regression tests. These must never mount devices or invoke sudo.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VED="$PROJECT_ROOT/ved"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TEST"' EXIT

passed=0
failed=0

pass() {
    printf 'ok - %s\n' "$1"
    ((passed += 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failed=1
}

run_directory_isolation() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }

    VED_RUNTIME_BASE="$TMPDIR_TEST/runtime"
    initialize_run_directory
    local first_run="$VED_RUN_DIR"
    local first_vm="$VED_VM_DIR"

    initialize_run_directory
    local second_run="$VED_RUN_DIR"
    local second_vm="$VED_VM_DIR"

    [[ "$first_run" != "$second_run" ]]
    [[ -d "$first_vm" && -d "$second_vm" ]]

    cleanup_run >/dev/null
    [[ ! -e "$first_run" && ! -e "$second_run" ]]
)

run_ved() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    local output="$TMPDIR_TEST/$name.out"
    local status

    if env LC_ALL=C LANG=C "$VED" "$@" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi

    if [[ "$status" != "$expected_status" ]]; then
        printf 'Expected status %s, got %s. Output:\n' "$expected_status" "$status" >&2
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" >&2
        done <"$output"
        fail "$name"
        return
    fi

    if ! grep -Fq -- "$expected_text" "$output"; then
        printf 'Expected output to contain %q. Output:\n' "$expected_text" >&2
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" >&2
        done <"$output"
        fail "$name"
        return
    fi

    pass "$name"
}

run_ved version 0 'ved 2.0.0' --version
run_ved help 0 'Usage:' --help
run_ved unsupported_language 0 'unsupported language "zz"; using English.' --lang zz --version
run_ved unknown_option 1 'Unknown option: --not-an-option' --not-an-option
run_ved invalid_backend 1 'Invalid backend: unsupported' --backend unsupported --version
run_ved invalid_gui_target 1 'Invalid display target: detached' --gui detached --version
run_ved gui_target_alias 0 'ved 2.0.0' --gui-target host --version
run_ved zero_ram 1 'Invalid format. Use, for example: 8G, 16G or 8192M.' --ram 0M --version
run_ved efi_loader_traversal 1 'Invalid EFI loader path: ../etc/shadow' --efi-loader ../etc/shadow --version

if run_directory_isolation; then
    pass 'run directory isolation'
else
    fail 'run directory isolation'
fi

if ((failed)); then
    exit 1
fi

printf '%s CLI regression tests passed.\n' "$passed"
