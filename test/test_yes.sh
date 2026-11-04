#!/bin/sh
# yes tests. yes never terminates, so every comparison is bounded with head and
# compares the GNU and our output byte for byte (via od, so blank lines count). Reference: GNU coreutils
# manual, "yes invocation" (POSIX does not specify yes).
UTIL="yes"
. "$(dirname "$0")/testlib.sh"

# check DESCRIPTION LINES [ARG...]: first LINES lines must be identical.
check() {
    description="$1"; lines="$2"; shift 2
    expected=$(gnu "$@" 2>&1 | head -n "$lines" | od -c)
    actual=$(ours "$@" 2>&1 | head -n "$lines" | od -c)
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU : %s\n     OURS: %s\n" "$description" "$expected" "$actual"
    fi
}

printf "\n[ Basic usage ]\n"
check "default output y"   5
check "custom string"      5 hello
check "multiple args"      5 hello world
check "-- ends options"    3 -- --help
check "empty string arg"   3 ""

print_summary
