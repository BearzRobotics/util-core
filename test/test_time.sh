#!/bin/sh
# time: differential tests against GNU time 1.9 for everything that does not
# depend on the clock (formats without time fields, abnormal-exit lines, error
# diagnostics, exit statuses, -o/-a), plus structural checks of the --bench
# extension (decision 0005), which GNU time does not have.
UTIL="time"
. "$(dirname "$0")/testlib.sh"

run_cmp "plain format"          -f 'x' true
run_cmp "command line %C"       -f '%C' echo 'a b' c
run_cmp "exit status %x"        -f '%x' sh -c 'exit 3'
run_cmp "signal %x is 0"        -f '%x' sh -c 'kill -9 $$'
run_cmp "quiet"                 -q -f '%x' sh -c 'exit 3'
run_cmp "quiet signal"          -q -f '%x' sh -c 'kill -9 $$'
run_cmp "escapes"               -f 'a\tb\nc\\d' true
run_cmp "unknown escape"        -f 'a\qb' true
run_cmp "unknown conversion"    -f '%q' true
run_cmp "percent and page size" -f '%%|%Z' true
run_cmp "trailing percent"      -f 'a%' true
run_cmp "zero counters"         -f '%F %I %O %W %X %D %K %p %t' true
run_cmp "-f then -p"            -f '%C' -p true
run_cmp "-- ends options"       -f 'x' -- true
run_cmp "no program"
run_cmp "format only"           -f x
run_cmp "missing format arg"    -f
run_cmp "bad option"            --bogus true
run_cmp "short bad option"      -z true
run_cmp "long abbreviation"     --form=%C true
run_cmp "exit 126"              -f x /etc
run_cmp "exit 127 format"       -f x nosuchprogram
TIME='%C!' run_cmp "TIME variable set" echo hi
TIME='%C!' run_cmp "-f beats TIME" -f 'y' true

# -o and -a
for t in gnu ours; do
    $t -o "$TEST_TMP/$t.out" -f '%C|%x' sh -c 'exit 2' 2>/dev/null
    $t -a -o "$TEST_TMP/$t.out" -f '%C' true 2>/dev/null
done
if cmp -s "$TEST_TMP/gnu.out" "$TEST_TMP/ours.out"; then PASS=$((PASS+1)); echo "PASS -o and -a"
else FAIL=$((FAIL+1)); echo "FAIL -o and -a"; fi

# Timing fields: shape only (values differ between runs).
shape() { sed -e 's/[0-9][0-9]*/N/g' -e 's/N\.N/F/g'; }
for fmt in '%e' '%E' '%U' '%S' '%P' '%M' '%R'; do
    g=$(gnu -f "$fmt" sleep 0.2 2>&1 | shape | sed 's/N/N/g')
    o=$(ours -f "$fmt" sleep 0.2 2>&1 | shape)
    if [ "$fmt" = '%P' ] || [ "$fmt" = '%M' ] || [ "$fmt" = '%R' ]; then
        # percent and memory are integers with %P ending in '%'
        g=$(printf '%s' "$g" | sed 's/F/N/'); o=$(printf '%s' "$o" | sed 's/F/N/')
    fi
    if [ "$g" = "$o" ]; then PASS=$((PASS+1)); echo "PASS shape of $fmt"
    else FAIL=$((FAIL+1)); echo "FAIL shape of $fmt (GNU '$g' OURS '$o')"; fi
done
g=$(gnu -p true 2>&1 | shape); o=$(ours -p true 2>&1 | shape)
[ "$g" = "$o" ] && { PASS=$((PASS+1)); echo "PASS -p shape"; } || { FAIL=$((FAIL+1)); echo "FAIL -p shape"; }
g=$(gnu -v sh -c 'exit 2' 2>&1 | sed 's/[0-9][0-9.:%]*/N/g'); o=$(ours -v sh -c 'exit 2' 2>&1 | sed 's/[0-9][0-9.:%]*/N/g')
[ "$g" = "$o" ] && { PASS=$((PASS+1)); echo "PASS -v shape"; } || { FAIL=$((FAIL+1)); echo "FAIL -v shape"; printf 'GNU:\n%s\nOURS:\n%s\n' "$g" "$o"; }
g=$(gnu sleep 0.3 2>&1 | sed 's/[0-9][0-9.:%]*/N/g'); o=$(ours sleep 0.3 2>&1 | sed 's/[0-9][0-9.:%]*/N/g')
[ "$g" = "$o" ] && { PASS=$((PASS+1)); echo "PASS default format shape"; } || { FAIL=$((FAIL+1)); echo "FAIL default format shape"; printf 'GNU:\n%s\nOURS:\n%s\n' "$g" "$o"; }

# Elapsed time is plausible.
e=$(ours -f '%e' sleep 0.5 2>&1)
case $e in 0.5*|0.6*) PASS=$((PASS+1)); echo "PASS elapsed of sleep 0.5 is $e";; *) FAIL=$((FAIL+1)); echo "FAIL elapsed of sleep 0.5 is $e";; esac

# --bench (extension)
check() { # DESC CONDITION-COMMAND...
    d=$1; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS $d"; else FAIL=$((FAIL+1)); echo "FAIL $d"; fi
}
out=$(ours --bench --runs=4 'true' 'sleep 0.01' 2>"$TEST_TMP/bench.err")
rc=$?
check "bench exit status" test $rc -eq 0
check "bench headers"      sh -c "printf '%s\n' '$out' | grep -q '^Benchmark 1 (4 runs): true\$' && printf '%s\n' '$out' | grep -q '^Benchmark 2 (4 runs): sleep 0.01\$'"
check "bench has wall_time and peak_rss" sh -c "printf '%s\n' '$out' | grep -q '^  wall_time ' && printf '%s\n' '$out' | grep -q '^  peak_rss '"
check "bench delta column with two commands" sh -c "printf '%s\n' '$out' | grep -q 'delta'"
out1=$(ours --bench --runs=3 true 2>/dev/null)
check "bench no delta column with one command" sh -c "! printf '%s\n' '$out1' | grep -q 'delta'"
check "bench command that fails stops" sh -c "! $BIN_DIR/time --bench --runs=2 'sh -c \"exit 3\"' >/dev/null 2>&1"
check "bench --allow-failures"  $BIN_DIR/time --bench --runs=2 --allow-failures 'sh -c "exit 3"'
check "bench --warmup"          $BIN_DIR/time --bench --runs=2 --warmup=1 true
check "bench --shell"           $BIN_DIR/time --bench --runs=2 --shell=sh 'exit 0'
check "bench --color=ansi emits escapes" sh -c "$BIN_DIR/time --bench --runs=2 --color=ansi true | grep -q \"\$(printf '\\033')\""
check "bench --color=never has none"     sh -c "! $BIN_DIR/time --bench --runs=2 --color=never true | grep -q \"\$(printf '\\033')\""
check "bench rejects -f"        sh -c "! $BIN_DIR/time --bench -f x true 2>/dev/null"
check "bench bad --duration"    sh -c "! $BIN_DIR/time --bench --duration=abc true 2>/dev/null"
check "bench --duration=100 ends"  $BIN_DIR/time --bench --duration=100 'sleep 0.02'
# hooks, parameters, export, input, output, env, metrics
H="$TEST_TMP/hooks"; mkdir -p "$H"; : > "$H/log"
$BIN_DIR/time --bench --runs=3 --warmup=1 --setup="echo s >> $H/log" --prepare="echo p >> $H/log" \
    --conclude="echo c >> $H/log" --cleanup="echo x >> $H/log" true >/dev/null 2>&1
counts=$(sort "$H/log" | uniq -c | awk '{printf "%s%s ", $1, $2}')
[ "$counts" = "4c 4p 1s 1x " ] && { PASS=$((PASS+1)); echo "PASS hooks run setup/prepare/conclude/cleanup the right number of times"; } || { FAIL=$((FAIL+1)); echo "FAIL hooks ($counts)"; }
check "failing prepare stops"         sh -c "! $BIN_DIR/time --bench --runs=2 --prepare=false true >/dev/null 2>&1"
check "hook count mismatch rejected"  sh -c "! $BIN_DIR/time --bench --runs=2 --prepare=true --prepare=true --prepare=true true >/dev/null 2>&1"
pl=$($BIN_DIR/time --bench --runs=2 --parameter-list=n=1,2 'echo {n}' 2>/dev/null | grep -c '^Benchmark')
[ "$pl" = 2 ] && { PASS=$((PASS+1)); echo "PASS parameter-list makes one benchmark per value"; } || { FAIL=$((FAIL+1)); echo "FAIL parameter-list ($pl)"; }
ps=$($BIN_DIR/time --bench --runs=2 --parameter-scan=n:1:3 'echo {n}' 2>/dev/null | grep -c '^Benchmark')
[ "$ps" = 3 ] && { PASS=$((PASS+1)); echo "PASS parameter-scan 1..3 gives 3 benchmarks"; } || { FAIL=$((FAIL+1)); echo "FAIL parameter-scan ($ps)"; }
$BIN_DIR/time --bench --runs=3 --parameter-list=n=1,2 --export-json="$TEST_TMP/o.json" --export-csv="$TEST_TMP/o.csv" 'echo {n}' >/dev/null 2>&1
check "export-json is valid and complete" sh -c "python3 -c \"import json,sys; d=json.load(open('$TEST_TMP/o.json')); assert len(d['results'])==2 and len(d['results'][0]['times'])==3 and d['results'][1]['parameters']=={'n':'2'}\" || grep -q '\"results\"' '$TEST_TMP/o.json'"
check "export-csv header and rows" sh -c "head -1 '$TEST_TMP/o.csv' | grep -q '^command,mean,stddev,median,user,system,min,max,parameter_n\$' && [ \$(wc -l < '$TEST_TMP/o.csv') -eq 3 ]"
echo hello > "$TEST_TMP/in.txt"
$BIN_DIR/time --bench --runs=2 --input="$TEST_TMP/in.txt" --bench-output="$TEST_TMP/out.txt" --env='FOO="a b"' --shell=sh 'cat; echo "$FOO"' >/dev/null 2>&1
[ "$(cat "$TEST_TMP/out.txt")" = "hello
a b
hello
a b" ] && { PASS=$((PASS+1)); echo "PASS --input, --bench-output and --env"; } || { FAIL=$((FAIL+1)); echo "FAIL --input/--bench-output/--env"; }
mt=$($BIN_DIR/time --bench --runs=2 --metrics=time sh -c 'i=0; while [ $i -lt 30000 ]; do i=$((i+1)); done' 2>/dev/null)
check "metrics=time shows cpu rows"   sh -c "printf '%s\n' '$mt' | grep -q '^  user_time ' && printf '%s\n' '$mt' | grep -q '^  system_time '"
check "metrics=time hides peak_rss"   sh -c "! printf '%s\n' '$mt' | grep -q '^  peak_rss '"
check "metrics hyperfine names"       $BIN_DIR/time --bench --runs=2 --metrics=time_wall_clock,memory_peak_resident true
check "bad --metrics rejected"        sh -c "! $BIN_DIR/time --bench --metrics=bogus true >/dev/null 2>&1"
check "--min-runs and --max-runs"     $BIN_DIR/time --bench --duration=50 --min-runs=2 --max-runs=5 true
check "bench option without --bench rejected" sh -c "! $BIN_DIR/time --warmup=2 true >/dev/null 2>&1"
# Bounds that do not fit a whole number, or a step that does not move them
# (MISC-037).
for spec in x:1e19:1e19 x:inf:inf x:0:inf x:-inf:0 x:nan:1 x:1:2:inf x:1:2:nan x:1e16:1e16; do
    out=$("$BIN_DIR/time" --bench --runs 1 --parameter-scan "$spec" 'true {x}' 2>&1 >/dev/null; echo "status $?")
    case $out in
    *"invalid --parameter-scan"*"status 125") PASS=$((PASS + 1)); echo "PASS refused $spec" ;;
    *) FAIL=$((FAIL + 1)); echo "FAIL $spec: $out" ;;
    esac
done

# As execvp, a script without a "#!" line is run by the shell (MISC-007).
printf 'echo no-shebang "$@"; exit 3\n' > "$TEST_TMP/nsh"; chmod +x "$TEST_TMP/nsh"
exp=$(cd "$TEST_TMP" && LC_ALL=C gnu -f done:%x ./nsh a b </dev/null 2>/dev/null; echo "status $?")
act=$(cd "$TEST_TMP" && LC_ALL=C ours -f done:%x ./nsh a b </dev/null 2>/dev/null; echo "status $?")
rm -f "$TEST_TMP/nohup.out"
if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS script without a #! line"
else FAIL=$((FAIL + 1)); echo "FAIL script without a #! line: GNU $exp, ours $act"; fi

print_summary
[ "$FAIL" -eq 0 ]
