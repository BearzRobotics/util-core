#!/bin/sh
# sleep: tests against GNU sleep. References: GNU manual "sleep invocation";
# POSIX.1-2024 sleep. Timing checks use short sleeps.
UTIL="sleep"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Valid intervals (exit status and silence) ]\n"
run_cmp "zero"                  0
run_cmp "fraction"              0.01
run_cmp "suffix s"              0.01s
run_cmp "exponent"              1e-2
run_cmp "two operands summed"   0.01 0.01
run_cmp "-- separator"          -- 0

printf "\n[ Invalid input ]\n"
run_cmp "missing operand"       
run_cmp "negative"              -- -1
run_cmp "garbage"               abc
run_cmp "empty string"          ""
run_cmp "bad suffix"            1x
run_cmp "valid then invalid"    0 abc
run_cmp "nan"                   nan
run_cmp "unrecognized option"   --nope
run_cmp "invalid short option"  -x

printf "\n[ Duration ]\n"
start=$(date +%s%N); "$BIN_DIR/sleep" 0.3; end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
[ "$ms" -ge 290 ] && [ "$ms" -lt 1500 ] && { PASS=$((PASS + 1)); echo "PASS sleeps about 0.3s (${ms}ms)"; } || { FAIL=$((FAIL + 1)); echo "FAIL duration ${ms}ms"; }
start=$(date +%s%N); "$BIN_DIR/sleep" 0.1 0.2; end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
[ "$ms" -ge 290 ] && [ "$ms" -lt 1500 ] && { PASS=$((PASS + 1)); echo "PASS operands are summed (${ms}ms)"; } || { FAIL=$((FAIL + 1)); echo "FAIL sum ${ms}ms"; }
"$BIN_DIR/sleep" inf & pid=$!; sleep 0.2
kill -0 "$pid" 2>/dev/null && { PASS=$((PASS + 1)); echo "PASS inf keeps sleeping"; } || { FAIL=$((FAIL + 1)); echo "FAIL inf returned"; }
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

print_summary
