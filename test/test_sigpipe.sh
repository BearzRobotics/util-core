#!/bin/sh
# SIGPIPE: every command keeps the disposition it was started with, and passes
# it on. When it is ignored, writing to a closed pipe is a write error that has
# to end the run (docs/bugs MISC-006).
UTIL="env" # for the oracle check; the suite covers many commands
. "$(dirname "$0")/testlib.sh"
G="${GNU_BIN:-/usr/bin}"
export LC_ALL=C

ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1: expected $2, got $3"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# The ignored signals of a command run through each wrapper.
ign() { grep SigIgn /proc/self/status; }
if [ -r /proc/self/status ]; then
    for state in default ignored; do
        if [ $state = ignored ]; then setup="trap '' PIPE;"; else setup=""; fi
        want=$(sh -c "$setup grep SigIgn /proc/self/status")
        for w in "env" "env -S ''" "nice" "nohup" "stdbuf -oL" "timeout 9" "timeout --foreground 9"; do
            [ -x "$BIN_DIR/${w%% *}" ] || continue
            got=$(sh -c "$setup \"$BIN_DIR\"/$w grep SigIgn /proc/self/status </dev/null 2>/dev/null")
            ref=$want
            # nohup ignores HUP besides.
            [ "$w" = nohup ] && ref=$(sh -c "$setup \"$G\"/nohup grep SigIgn /proc/self/status </dev/null 2>/dev/null")
            same "$w keeps SIGPIPE $state" "$ref" "$got"
        done
        got=$(sh -c "$setup echo x | \"$BIN_DIR/xargs\" -I{} grep SigIgn /proc/self/status")
        same "xargs keeps SIGPIPE $state" "$want" "$got"
        got=$(sh -c "$setup \"$BIN_DIR/find\" /dev/null -exec grep SigIgn /proc/self/status \;")
        same "find -exec keeps SIGPIPE $state" "$want" "$got"
        got=$(sh -c "$setup \"$BIN_DIR/time\" grep SigIgn /proc/self/status 2>/dev/null")
        same "time keeps SIGPIPE $state" "$want" "$got"
    done
    got=$(sh -c "trap '' PIPE; \"$BIN_DIR/env\" --default-signal=PIPE grep SigIgn /proc/self/status")
    same "env --default-signal=PIPE" "$(sh -c 'grep SigIgn /proc/self/status')" "$got"
else
    skip_test "inherited SIGPIPE (no /proc)"
fi

# Endless input into a closed pipe: ends, in little memory, as GNU does.
ended() { # DESC INPUT-COMMAND UTIL ARGS...: status and first message
    d="$1"; input="$2"; u="$3"; shift 3
    [ -x "$BIN_DIR/$u" ] || return 0
    out=$( (trap '' PIPE; ulimit -v 500000
        $input 2>/dev/null | { timeout 20 "$BIN_DIR/$u" "$@" 2>"$TEST_TMP/err"; echo $? >"$TEST_TMP/rc"; } | head -c 1 >/dev/null) )
    got="$(cat "$TEST_TMP/rc") $(head -n 1 "$TEST_TMP/err")"
    same "$d" "$WANT" "$got"
}
# Equal lines, two sorted inputs, and one that is only a "y".
echo y > "$TEST_TMP/one"
WANT="1 uniq: write error: Broken pipe"; ended "uniq -D stops" yes uniq -D
WANT="1 paste: write error: Broken pipe"; ended "paste -s stops" yes paste -s -
WANT="1 comm: write error: Broken pipe"; ended "comm stops" yes comm - /dev/null
WANT="1 od: write error: Broken pipe"; ended "od -v stops" yes od -v
WANT="1 split: write error: Broken pipe"; ended "split -n r/1/1 stops" yes split -n r/1/1
WANT="1 pr: write error: Broken pipe"; ended "pr stops" yes pr
WANT="1 cat: write error: Broken pipe"; ended "cat stops" yes cat
WANT="1 yes: standard output: Broken pipe"; ended "yes stops" true yes
WANT="4 sed: couldn't write 1 item to stdout: Broken pipe"; ended "sed says why" yes sed p
# tee says nothing about a closed pipe unless --output-error asks.
WANT="0 "; ended "tee is quiet" yes tee
WANT="1 tee: standard output: Broken pipe"; ended "tee --output-error=warn" yes tee --output-error=warn

# join over more equal keys than are worth reading once the output is gone.
awk 'BEGIN { for (i = 0; i < 100000; i++) print "k " i }' > "$TEST_TMP/keys"
WANT="1 join: write error: Broken pipe"; ended "join stops in a group" true join "$TEST_TMP/keys" "$TEST_TMP/keys"

# A reader that has gone is no error to less.
WANT="0 "; ended "less is quiet" yes less
print_summary
[ "$FAIL" -eq 0 ]
