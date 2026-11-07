#!/bin/sh
# tsort: differential tests against GNU tsort. References: GNU manual "tsort
# invocation"; POSIX.1-2024 tsort. Acyclic input must match GNU exactly. For
# cyclic input the choice of reported cycle is only compared on simple cases
# (see src/commands/tsort.zig header); elsewhere status and node set are checked.
UTIL="tsort"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"

printf "\n[ Acyclic: exact match ]\n"
t() { printf '%s' "$2" > in.txt; CMP_STDIN="$W/in.txt" run_cmp "$1"; }
t "doc example"            'a b c
d
e f
b c d e
'
t "empty"                  ''
t "self pairs only"        'a a b b'
t "single pair"            'a b'
t "chain"                  'a b b c c d d e'
t "fan out"                'a b a c a d'
t "fan in"                 'b a c a d a'
t "diamond"                'a b a c b d c d'
t "two roots"              'z y y x q p'
t "duplicates"             'a b a b b c'
t "tabs and newlines"      'a	b
b	c
'
t "long names"             'alpha beta beta gamma'
t "call graph" 'main parse_options
main tail_file
main tail_forever
tail_file pretty_name
tail_file write_header
tail_file tail
tail_forever recheck
tail_forever pretty_name
tail_forever write_header
tail_forever dump_remainder
tail tail_lines
tail tail_bytes
tail_lines start_lines
tail_lines dump_remainder
tail_lines file_lines
tail_lines pipe_lines
tail_bytes xlseek
tail_bytes start_bytes
tail_bytes dump_remainder
tail_bytes pipe_bytes
file_lines dump_remainder
recheck pretty_name
'
t "numbers"                '10 9 9 8 2 1 1 10'
t "mixed self and edges"   'a a a b b b c c'

printf "\n[ Cycles: simple cases exact ]\n"
t "2-cycle"                'a b b a'
t "3-cycle"                'a b b c c a'
t "3-cycle reversed names" 'c b b a a c'
t "cycle with tail"        'd a a b b c c a'
t "self loop ignored"      'a a a b'

printf "\n[ Random graphs ]\n"
python3 -I - "$W" <<'PY'
import random,sys
random.seed(21)
w=sys.argv[1]
names=[f"n{i}" for i in range(40)]
for k in range(60):                     # DAGs: edges only from lower to higher index
    n=random.randint(2,30)
    toks=[]
    for _ in range(random.randint(1,50)):
        a=random.randint(0,n-2); b=random.randint(a+1,n-1)
        toks += [names[a],names[b]]
    if random.random()<0.3: toks += [names[random.randint(0,n-1)]]*2
    open(f"{w}/dag{k}","w").write(' '.join(toks)+'\n')
for k in range(60):                     # arbitrary graphs (may have cycles)
    n=random.randint(2,6)
    toks=[]
    for _ in range(random.randint(2,9)):
        toks += [names[random.randint(0,n-1)],names[random.randint(0,n-1)]]
    open(f"{w}/cyc{k}","w").write(' '.join(toks)+'\n')
PY
bad=0; n=0
for f in dag*; do
    e=$(LC_ALL=C /usr/bin/tsort "$f" 2>&1); a=$("$BIN_DIR/tsort" "$f" 2>&1)
    n=$((n+1)); [ "$e" = "$a" ] || { bad=$((bad+1)); [ $bad -le 3 ] && echo "DAG mismatch: $f"; }
done
[ $bad -eq 0 ] && { PASS=$((PASS + 1)); echo "PASS $n random DAGs match exactly"; } || { FAIL=$((FAIL + 1)); echo "FAIL $bad of $n DAGs differ"; }
bad=0; same=0; n=0
for f in cyc*; do
    LC_ALL=C /usr/bin/tsort "$f" > g.out 2> g.err; gr=$?
    "$BIN_DIR/tsort" "$f" > o.out 2> o.err; orc=$?
    n=$((n+1))
    [ "$gr" = "$orc" ] && [ "$(sort g.out)" = "$(sort o.out)" ] && [ "$(head -1 g.err)" = "$(head -1 o.err | sed 's#^tsort#tsort#')" ] || { bad=$((bad+1)); echo "cyclic mismatch (status/nodes): $f"; }
    cmp -s g.out o.out && cmp -s g.err o.err && same=$((same+1))
done
[ $bad -eq 0 ] && { PASS=$((PASS + 1)); echo "PASS $n random cyclic graphs: status and node set match ($same identical diagnostics+order)"; } || { FAIL=$((FAIL + 1)); echo "FAIL $bad cyclic graphs differ in status or node set"; }

printf "\n[ Errors and files ]\n"
CMP_STDIN="$W/dag0"
run_cmp "stdin"
run_cmp "stdin as -"       -
run_cmp "file operand"     dag1
run_cmp "odd token count"  /dev/null
printf 'a b c' > odd; run_cmp "odd tokens" odd
printf 'a' > odd1; run_cmp "single token" odd1
run_cmp "missing file"     nope
mkdir d; run_cmp "directory" d
run_cmp "two operands"     dag0 dag1
run_cmp "invalid option"   -x dag0
run_cmp "unrecognized long" --nope dag0
run_cmp "-- then file"     -- dag0

printf "\n[ POSIX -w ]\n"
printf 'a b b a c d d c e f\n' > two
"$BIN_DIR/tsort" -w two >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && { PASS=$((PASS + 1)); echo "PASS -w exit status counts cycles (2)"; } || { FAIL=$((FAIL + 1)); echo "FAIL -w status $rc"; }
"$BIN_DIR/tsort" -w dag2 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && { PASS=$((PASS + 1)); echo "PASS -w on acyclic input exits 0"; } || { FAIL=$((FAIL + 1)); echo "FAIL -w acyclic status $rc"; }

cd /; rm -rf "$W"
print_summary
