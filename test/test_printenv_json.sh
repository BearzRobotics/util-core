#!/bin/sh
# printenv --json: compared with GNU printenv (GNU coreutils 9.7) for the same
# environment. Needs python3 and GNU printenv.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
export DKT_PLAIN=plain DKT_QUOTE='a"b\c' DKT_SPACE='two words' DKT_EMPTY= DKT_NL='line1
line2' DKT_UTF8='café'

t "full environment equals GNU printenv" sh -c "env -i DKT_A=1 DKT_B='x y' '$BIN/printenv' --json | python3 -c 'import json,sys;assert json.load(sys.stdin)=={\"DKT_A\":\"1\",\"DKT_B\":\"x y\"}'"
for v in DKT_PLAIN DKT_QUOTE DKT_SPACE DKT_EMPTY DKT_UTF8; do
    want=$(printenv "$v")
    got=$("$BIN/printenv" --json "$v" | python3 -c "import json,sys; print(json.load(sys.stdin)['$v'])")
    [ "$want" = "$got" ] && ok || bad "value of $v: GNU=[$want] OURS=[$got]"
done
t "newline in a value" sh -c "'$BIN/printenv' --json DKT_NL | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"DKT_NL\"]==\"line1\nline2\"'"
t "several names" sh -c "'$BIN/printenv' --json DKT_PLAIN DKT_SPACE | python3 -c 'import json,sys;assert json.load(sys.stdin)=={\"DKT_PLAIN\":\"plain\",\"DKT_SPACE\":\"two words\"}'"
t "unset name: left out, status 1" sh -c "out=\$('$BIN/printenv' --json DKT_PLAIN NO_SUCH_VAR_ZZ); rc=\$?; [ \$rc = 1 ] && echo \"\$out\" | python3 -c 'import json,sys;assert json.load(sys.stdin)=={\"DKT_PLAIN\":\"plain\"}'"
t "same status as GNU for an unset name" sh -c "'$BIN/printenv' --json NO_SUCH_VAR_ZZ; a=\$?; printenv NO_SUCH_VAR_ZZ; b=\$?; [ \$a = \$b ]"
t "name containing = is never found" sh -c "'$BIN/printenv' --json DKT_PLAIN=plain; [ \$? = 1 ]"
t "empty environment is {}" sh -c "[ \"\$(env -i '$BIN/printenv' --json)\" = '{}' ]"
t "--json with -0 is refused" sh -c "! '$BIN/printenv' --json -0"
t "--json is not in --help" sh -c "! '$BIN/printenv' --help | grep -q json"
t "all variables match GNU printenv" sh -c "[ \"\$('$BIN/printenv' --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = \"\$(printenv | grep -c '^[A-Za-z_][A-Za-z0-9_]*=')\" ]"
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
