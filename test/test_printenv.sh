#!/bin/sh
# printenv: differential tests against GNU printenv. Reference: GNU manual
# "printenv invocation" (POSIX does not specify printenv).
UTIL="printenv"
. "$(dirname "$0")/testlib.sh"

export FOO=bar EMPTY= SPACE="a b"
printf "\n[ Variables ]\n"
run_cmp "one variable"           FOO
run_cmp "empty value"            EMPTY
run_cmp "value with space"       SPACE
run_cmp "several variables"      FOO SPACE
run_cmp "unset variable"         NOT_SET_XYZ
run_cmp "mixed set/unset"        FOO NOT_SET_XYZ SPACE
run_cmp "name containing ="      FOO=bar
run_cmp "-0"                     -0 FOO SPACE
run_cmp "--null"                 --null FOO
run_cmp "-- ends options"        -- FOO

printf "\n[ Whole environment ]\n"
e=$(env -i A=1 B=2 /usr/bin/printenv); a=$(env -i A=1 B=2 "$BIN_DIR/printenv")
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS whole environment"; } || { FAIL=$((FAIL + 1)); echo "FAIL whole environment"; }
e=$(env -i A=1 B=2 /usr/bin/printenv -0 | od -c); a=$(env -i A=1 B=2 "$BIN_DIR/printenv" -0 | od -c)
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS whole environment -0"; } || { FAIL=$((FAIL + 1)); echo "FAIL whole environment -0"; }

printf "\n[ Errors ]\n"
run_cmp "invalid option"     -x
run_cmp "unrecognized long"  --nope

print_summary
