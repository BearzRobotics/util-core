#!/bin/sh
# testlib.sh - Shared helpers for all util test scripts

PASS=0
FAIL=0
SKIP=0

# Check if we should use colors
USE_COLOR=0
if [ -z "${NO_COLOR+x}" ] && [ -t 1 ]; then
    USE_COLOR=1
fi

# Resolve the bin dir relative to the test script location
BIN_DIR="$(cd "$(dirname "$0")/../zig-out/bin" 2>/dev/null && pwd)"

# The reference must be GNU: a different implementation (e.g. uutils) would make
# every differential comparison below meaningless.
if ! "/usr/bin/$UTIL" --version 2>/dev/null | head -n 1 | grep -q 'GNU'; then
    echo "FATAL: /usr/bin/$UTIL is not a GNU implementation; refusing to run." >&2
    exit 2
fi

gnu() { "/usr/bin/$UTIL" "$@"; }
ours() { "$BIN_DIR/$UTIL" "$@"; }

run_test() {
    description="$1"
    shift

    expected=$(gnu "$@" 2>&1)
    actual=$(ours "$@" 2>&1)

    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;32mPASS\033[0m %s\n" "$description"
        else
            printf "PASS %s\n" "$description"
        fi
    else
        FAIL=$((FAIL + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;31mFAIL\033[0m %s\n" "$description"
        else
            printf "FAIL %s\n" "$description"
        fi
        printf "     GNU : %s\n" "$(printf '%s' "$expected" | cat -A)"
        printf "     OURS: %s\n" "$(printf '%s' "$actual"   | cat -A)"
    fi
}

# For tests that check exit codes only
run_test_exit() {
    description="$1"
    shift

    gnu "$@" > /dev/null 2>&1
    expected_exit=$?
    ours "$@" > /dev/null 2>&1
    actual_exit=$?

    if [ "$expected_exit" = "$actual_exit" ]; then
        PASS=$((PASS + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;32mPASS\033[0m %s\n" "$description"
        else
            printf "PASS %s\n" "$description"
        fi
    else
        FAIL=$((FAIL + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;31mFAIL\033[0m %s\n" "$description"
        else
            printf "FAIL %s\n" "$description"
        fi
        printf "     GNU exit : %s\n" "$expected_exit"
        printf "     OURS exit: %s\n" "$actual_exit"
    fi
}

# For tests comparing output on files
run_test_file() {
    description="$1"
    input_file="$2"
    shift 2

    expected=$(gnu "$@" "$input_file" 2>&1)
    actual=$(ours "$@" "$input_file" 2>&1)

    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;32mPASS\033[0m %s\n" "$description"
        else
            printf "PASS %s\n" "$description"
        fi
    else
        FAIL=$((FAIL + 1))
        if [ "$USE_COLOR" -eq 1 ]; then
            printf "\033[0;31mFAIL\033[0m %s\n" "$description"
        else
            printf "FAIL %s\n" "$description"
        fi
        printf "     GNU : %s\n" "$(printf '%s' "$expected" | cat -A)"
        printf "     OURS: %s\n" "$(printf '%s' "$actual"   | cat -A)"
    fi
}

# run_cmp DESCRIPTION ARG...
# Compares stdout, stderr and exit status separately. Stdin comes from the file
# named by $CMP_STDIN (default /dev/null). GNU runs with LC_ALL=C so its quotes
# are ASCII; the "Try '<program> --help'" program path is normalised because GNU
# prints the path it was invoked with.
norm_err() { sed -e "s#^[^ ]*/\\([a-z0-9]*\\): #\\1: #" -e "s#Try '[^']*'#Try 'PROG'#"; }
run_cmp() {
    description="$1"
    shift
    in="${CMP_STDIN:-/dev/null}"
    LC_ALL=C gnu "$@" < "$in" > "$TMPDIR_CMP.go" 2> "$TMPDIR_CMP.ge"; gx=$?
    ours "$@" < "$in" > "$TMPDIR_CMP.oo" 2> "$TMPDIR_CMP.oe"; ox=$?
    norm_err < "$TMPDIR_CMP.ge" > "$TMPDIR_CMP.ge2"; norm_err < "$TMPDIR_CMP.oe" > "$TMPDIR_CMP.oe2"
    if cmp -s "$TMPDIR_CMP.go" "$TMPDIR_CMP.oo" && cmp -s "$TMPDIR_CMP.ge2" "$TMPDIR_CMP.oe2" && [ "$gx" = "$ox" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$description"
        printf "     GNU  (rc=%s) out: %s err: %s\n" "$gx" "$(cat -A "$TMPDIR_CMP.go")" "$(cat -A "$TMPDIR_CMP.ge2")"
        printf "     OURS (rc=%s) out: %s err: %s\n" "$ox" "$(cat -A "$TMPDIR_CMP.oo")" "$(cat -A "$TMPDIR_CMP.oe2")"
    fi
}
TMPDIR_CMP="$(mktemp -d)/cmp"
trap 'rm -rf "$(dirname "$TMPDIR_CMP")"' EXIT

skip_test() {
    SKIP=$((SKIP + 1))
    if [ "$USE_COLOR" -eq 1 ]; then
        printf "\033[0;33mSKIP\033[0m %s\n" "$1"
    else
        printf "SKIP %s\n" "$1"
    fi
}

print_summary() {
    TOTAL=$((PASS + FAIL + SKIP))
    printf "\n======================================\n"
    printf " %s: %d/%d passed" "$UTIL" "$PASS" "$TOTAL"
    if [ "$SKIP" -gt 0 ]; then
        printf " (%d skipped)" "$SKIP"
    fi
    printf "\n"
    if [ "$FAIL" -gt 0 ]; then
        if [ "$USE_COLOR" -eq 1 ]; then
            printf " \033[0;31m%d test(s) failed\033[0m\n" "$FAIL"
        else
            printf " %d test(s) failed\n" "$FAIL"
        fi
    else
        if [ "$USE_COLOR" -eq 1 ]; then
            printf " \033[0;32mAll tests passed!\033[0m\n"
        else
            printf " All tests passed!\n"
        fi
    fi
    printf "======================================\n"
}