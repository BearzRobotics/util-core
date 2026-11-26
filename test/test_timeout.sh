#!/bin/sh
# timeout: differential tests against GNU timeout 9.7 (C locale). References:
# GNU manual "timeout invocation". Durations are short (0.1-0.3 s).
UTIL="timeout"
. "$(dirname "$0")/testlib.sh"
help_cmp
run_cmp "no args"
run_cmp "duration only"        1
run_cmp "bad duration"         abc true
run_cmp "bad suffix"           1x true
run_cmp "negative duration"    -- -1 true
run_cmp "empty duration"       '' true
run_cmp "suffix only"          s true
run_cmp "plus sign"            +1 true
run_cmp "nan"                  nan true
run_cmp "inf"                  inf true
run_cmp "fast command"         5 true
run_cmp "fast false"           5 false
run_cmp "exit status passes"   5 sh -c 'exit 3'
run_cmp "output passes"        5 echo hello
run_cmp "stdin passes"         5 cat
run_cmp "zero means none"      0 true
run_cmp "0s"                   0s true
run_cmp "0.0"                  0.0 true
run_cmp "1s suffix"            1s true
run_cmp "1m suffix"            1m true
run_cmp "1h suffix"            1h true
run_cmp "1d suffix"            1d true
run_cmp "fraction suffix"      .5s true
run_cmp "1e0"                  1e0 true
run_cmp "timeout 124"          0.2 sleep 5
run_cmp "timeout via suffix"   0.2s sleep 5
run_cmp "-s KILL"              -s KILL 0.2 sleep 5
run_cmp "-s 9"                 -s 9 0.2 sleep 5
run_cmp "-s HUP"               -s HUP 0.2 sleep 5
run_cmp "-sINT"                -sINT 0.2 sleep 5
run_cmp "--signal=KILL"        --signal=KILL 0.2 sleep 5
run_cmp "-s SIGTERM"           -s SIGTERM 0.2 sleep 5
run_cmp "-s lower"             -s term 0.2 sleep 5
run_cmp "-s bad"               -s FOO 1 true
run_cmp "-s needs arg"         -s
run_cmp "--preserve-status"    --preserve-status 0.2 sleep 5
run_cmp "-p with exit"         -p 5 sh -c 'exit 4'
run_cmp "-p -s KILL"           -p -s KILL 0.2 sleep 5
run_cmp "-v"                   -v 0.2 sleep 5
run_cmp "-v KILL"              -v -s KILL 0.2 sleep 5
run_cmp "-v long cmd"          -v 0.2 sleep 5.0
run_cmp "ignores TERM"         -k 0.2 0.2 sh -c 'trap "" TERM; sleep 5'
run_cmp "kill-after verbose"   -v -k 0.2 0.2 sh -c 'trap "" TERM; sleep 5'
run_cmp "--kill-after="        --kill-after=0.2 0.2 sh -c 'trap "" TERM; sleep 5'
run_cmp "-k bad"               -k abc 1 true
run_cmp "-k not needed"        -k 1 5 true
run_cmp "-f"                   -f 0.2 sleep 5
run_cmp "--foreground"         --foreground 5 true
run_cmp "child killed by sig"  5 sh -c 'kill -9 $$'
run_cmp "child TERM itself"    5 sh -c 'kill -TERM $$'
run_cmp "child HUP itself"     5 sh -c 'kill -HUP $$'
run_cmp "timeout then signaled" 0.2 sh -c 'sleep 5'
run_cmp "not found"            1 nonexistent-cmd
run_cmp "directory"            1 /etc
run_cmp "not executable"       1 /etc/passwd
run_cmp "options after cmd"    5 true --help
run_cmp "-- before command"    1 -- true
run_cmp "dash command"         1 --
run_cmp "bad option"           -x 1 true
run_cmp "long abbrev"          --pres 5 true
run_cmp "ambiguous"            --k 5 true
run_cmp "group kill"           0.2 sh -c 'sleep 5 & wait'
run_cmp "ignore TERM -s KILL"  -s KILL 0.2 sh -c 'trap "" TERM; sleep 5'
run_cmp "continues stopped"    -s TERM 0.3 sh -c 'kill -STOP $$'
# A command that reads the terminal while timeout is not in the foreground
# group (here: run by a shell) is stopped; timeout must keep running and end
# it at the limit. Each case runs a shell as the leader of a new session on a
# pty. Whatever is left after 10 s counts as a failure and is killed.
tty_run() { # SHELL-SCRIPT: prints the output, then "left=N" stray processes
    LC_ALL=C timeout 30 python3 -I - "$1" <<'PY'
import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])
def session():
    found = []
    for d in os.listdir("/proc"):
        if d.isdigit() and int(d) != pid:
            try:
                fields = open("/proc/%s/stat" % d).read().rpartition(")")[2].split()
            except OSError:
                continue
            if int(fields[3]) == pid and fields[0] != "Z":
                found.append(int(d))
    return found
out, done, end = b"", False, time.time() + 10
while not done and time.time() < end:
    if select.select([fd], [], [], 0.1)[0]:
        try:
            out += os.read(fd, 4096)
        except OSError:
            time.sleep(0.05)
    done = os.waitpid(pid, os.WNOHANG)[0] != 0
while done and select.select([fd], [], [], 0.2)[0]:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
time.sleep(0.3)
left = session()
for p in left + ([] if done else [pid]):
    try:
        os.kill(p, signal.SIGKILL)
    except OSError:
        pass
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
print("left=%d" % len(left))
PY
}
tty_case() { # DESC EXPECTED SHELL-SCRIPT
    got=$(tty_run "$3")
    if [ "$got" = "$2" ]; then
        PASS=$((PASS + 1)); echo "PASS $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $1"; printf '%s\n' "$got" | head -n 8
    fi
}
if command -v python3 > /dev/null; then
    tty_case "limit enforced on a command reading the terminal" "rc=124
left=0" "\"$BIN_DIR/timeout\" 1 cat; echo rc=\$?"
    tty_case "limit enforced when a grandchild reads the terminal" "rc=124
left=0" "\"$BIN_DIR/timeout\" 1 sh -c 'cat; :'; echo rc=\$?"
    tty_case "-v writes under stty tostop from the background" "timeout: sending signal TERM to command 'cat'
rc=124
left=0" "stty tostop; \"$BIN_DIR/timeout\" -v 1 cat 2>&1 | /bin/cat; \"$BIN_DIR/timeout\" 1 cat; echo rc=\$?"
else
    skip_test "timeout on a terminal (needs python3)"
fi
# The command gets the default actions of the terminal stop signals.
got=$(sh -c 'trap "" TTIN TTOU; "$1" 5 grep SigIgn /proc/self/status' sh "$BIN_DIR/timeout")
ref=$(sh -c 'trap "" TTIN TTOU; "$1" 5 grep SigIgn /proc/self/status' sh "${GNU_BIN:-/usr/bin}/timeout")
if [ -n "$got" ] && [ "$got" = "$ref" ]; then
    PASS=$((PASS + 1)); echo "PASS command does not inherit ignored terminal stops"
else
    FAIL=$((FAIL + 1)); echo "FAIL command does not inherit ignored terminal stops ($got, GNU $ref)"
fi
# -k 0 is no follow-up KILL at all.
for k in 0 0s; do
    got=$("$BIN_DIR/timeout" -k $k 0.3 sh -c 'trap "" TERM; sleep 1; echo survived'; echo "rc=$?")
    if [ "$got" = "survived
rc=124" ]; then PASS=$((PASS + 1)); echo "PASS -k $k sends no KILL"
    else FAIL=$((FAIL + 1)); echo "FAIL -k $k sends no KILL: $got"; fi
done
print_summary
[ "$FAIL" -eq 0 ]
