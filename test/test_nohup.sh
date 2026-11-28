#!/bin/sh
# nohup: differential tests against GNU nohup 9.7 (C locale). References: GNU
# manual "nohup invocation"; POSIX.1-2024 nohup. The terminal cases run under
# script(1) when it is installed.
UTIL="nohup"
. "$(dirname "$0")/testlib.sh"
help_cmp
run_cmp "no args"
run_cmp "true"                  true
run_cmp "false"                 false
run_cmp "exit status"           sh -c 'exit 7'
run_cmp "output passes"         echo hello
run_cmp "stderr passes"         sh -c 'echo err >&2'
run_cmp "SIGHUP ignored"        sh -c 'trap'
run_cmp "not found"             nonexistent-cmd
run_cmp "directory"             /etc
run_cmp "not executable"        /etc/passwd
run_cmp "args"                  printf '[%s]' a b c
run_cmp "-- is the command"     --
run_cmp "options are command"   -x
run_cmp "--help not alone"      true --help
run_cmp "stdin not tty"         cat

# Terminal cases: stdin/stdout/stderr on a pty; compare messages and the file.
if command -v script >/dev/null 2>&1; then
    D="$TEST_TMP/nh"; mkdir -p "$D"
    tty_case() {
        desc="$1"; shell="$2"
        for x in g o; do
            mkdir -p "$D/$x"; rm -rf "$D/$x"/*
            if [ $x = g ]; then bin="$GNU_BIN_DIR/nohup"; else bin="$BIN_DIR/nohup"; fi
            (cd "$D/$x" && HOME="$D/$x" script -qec "sh -c \"$(printf '%s' "$shell" | sed "s#NOHUP#$bin#g")\"" /dev/null | sed "s#$bin#nohup#g; s#$D/$x#D#g" > ../$x.out; ls -A > ../$x.ls; [ -f nohup.out ] && { sed "s#$bin#nohup#g; s#$D/$x#D#g" nohup.out > ../$x.sz; stat -c %a nohup.out >> ../$x.sz; } || echo none > ../$x.sz)
        done
        if cmp -s "$D/g.out" "$D/o.out" && cmp -s "$D/g.ls" "$D/o.ls" && cmp -s "$D/g.sz" "$D/o.sz"; then
            PASS=$((PASS + 1)); printf "PASS %s\n" "$desc"
        else
            FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$desc"; diff "$D/g.out" "$D/o.out" | head -5; diff "$D/g.ls" "$D/o.ls" | head -3; diff "$D/g.sz" "$D/o.sz" | head -3
        fi
    }
    GNU_BIN_DIR="${GNU_BIN:-/usr/bin}"
    tty_case "tty all"              'NOHUP echo hi'
    tty_case "tty stdout file"      'NOHUP echo hi > o.txt'
    tty_case "tty stdin+err only"   'NOHUP echo hi > o.txt 2>&1'
    tty_case "stdin devnull"        'NOHUP echo hi < /dev/null'
    tty_case "stdin devnull out"    'NOHUP echo hi < /dev/null > o.txt'
    tty_case "stderr file"          'NOHUP echo hi 2> e.txt'
    tty_case "stdout closed"        'NOHUP echo hi >&-'
    tty_case "stdout closed err null" 'NOHUP echo hi >&- 2>/dev/null'
    tty_case "stdin devnull stderr" 'NOHUP echo hi < /dev/null > o.txt 2>&1'
    tty_case "reading stdin fails"  'NOHUP cat; echo rc=$?'
    tty_case "append existing"      'echo old > nohup.out; NOHUP echo new'
    tty_case "unwritable cwd"       'mkdir ro; chmod 555 ro; cd ro; NOHUP echo hi'
else
    skip_test "terminal cases (script not installed)"
fi
# As execvp, a script without a "#!" line is run by the shell (MISC-007).
printf 'echo no-shebang "$@"; exit 3\n' > "$TEST_TMP/nsh"; chmod +x "$TEST_TMP/nsh"
exp=$(cd "$TEST_TMP" && LC_ALL=C gnu  ./nsh a b </dev/null 2>/dev/null; echo "status $?")
act=$(cd "$TEST_TMP" && LC_ALL=C ours  ./nsh a b </dev/null 2>/dev/null; echo "status $?")
rm -f "$TEST_TMP/nohup.out"
if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS script without a #! line"
else FAIL=$((FAIL + 1)); echo "FAIL script without a #! line: GNU $exp, ours $act"; fi

# nohup.out is 0600 whatever the umask, and the command keeps the umask
# (MISC-013). nohup only writes the file when standard output is a terminal.
if command -v script >/dev/null 2>&1; then
    for mask in 000 277 777; do
        rm -rf "$TEST_TMP/nh" && mkdir "$TEST_TMP/nh"
        (cd "$TEST_TMP/nh" && umask $mask && script -qec "$BIN_DIR/nohup sh -c umask" /dev/null >/dev/null 2>&1)
        got="$(stat -c %a "$TEST_TMP/nh/nohup.out" 2>/dev/null) $(cat "$TEST_TMP/nh/nohup.out" 2>/dev/null)"
        if [ "$got" = "600 0$mask" ]; then PASS=$((PASS + 1)); echo "PASS nohup.out under umask $mask"
        else FAIL=$((FAIL + 1)); echo "FAIL nohup.out under umask $mask: $got"; fi
    done
fi

print_summary
[ "$FAIL" -eq 0 ]
