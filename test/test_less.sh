#!/bin/sh
# less: the non-interactive behaviour against GNU less 668 (when standard
# output is not a terminal both copy their input), and the interactive
# behaviour on a pseudo-terminal (test/pty_less.py, needs python3).
UTIL="less"
. "$(dirname "$0")/testlib.sh"

F="$TEST_TMP/in.txt"
printf 'one\ntwo\nthree\n' > "$F"
printf 'a\tb\n\n\nlast without newline' > "$TEST_TMP/odd.txt"
: > "$TEST_TMP/empty.txt"

run_cmp "copy a file"             "$F"
run_cmp "copy two files"          "$F" "$TEST_TMP/odd.txt"
run_cmp "copy an empty file"      "$TEST_TMP/empty.txt"
run_cmp "odd file"                "$TEST_TMP/odd.txt"
run_cmp "-F on a pipe"            -F "$F"
run_cmp "-R"                      -R "$F"
run_cmp "-N copies without numbers off a terminal" -N "$F"
CMP_STDIN="$F" run_cmp "stdin implicit"
CMP_STDIN="$F" run_cmp "stdin by name -"   -

check() { d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS $d"; else FAIL=$((FAIL+1)); echo "FAIL $d"; fi; }
check "missing file fails"       sh -c "! $BIN_DIR/less $TEST_TMP/nope 2>/dev/null"
check "missing file still shows the others" sh -c "$BIN_DIR/less $TEST_TMP/nope $F 2>/dev/null | grep -q three; [ \$? -eq 0 ]"
check "--help"                   sh -c "$BIN_DIR/less --help | grep -q 'Usage: less'"
check "--version"                sh -c "$BIN_DIR/less --version | grep -q 'less (util-core)'"
# Status 1 and a reason: a missing or crashing less must not pass (VIEW-028).
check "bad option"               sh -c "out=\$($BIN_DIR/less --nonsense 2>&1 </dev/null); [ \$? = 1 ] && echo \"\$out\" | grep -q \"unrecognized option '--nonsense'\""

if command -v python3 >/dev/null 2>&1; then
    if python3 "$(dirname "$0")/pty_less.py" "$BIN_DIR" >"$TEST_TMP/pty.out" 2>&1; then
        PASS=$((PASS+1)); echo "PASS pseudo-terminal session (scroll, search, stream, follow, quit)"
    else
        FAIL=$((FAIL+1)); echo "FAIL pseudo-terminal session"; cat "$TEST_TMP/pty.out"
    fi
else
    SKIP=$((SKIP+1)); echo "SKIP pseudo-terminal session (no python3)"
fi
print_summary
[ "$FAIL" -eq 0 ]
