#!/bin/sh
# comm: differential tests against GNU comm (C locale). References: GNU manual
# "comm invocation"; POSIX.1-2024 comm.
UTIL="comm"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'a\nb\nc\nd\ne\n' > f1
printf 'b\nc\nd\ne\nf\ng\n' > f2
printf 'a\nc\nx\n' > g1
printf 'b\nc\ny\nz\n' > g2
printf 'b\na\nc\n' > uns1
printf 'a\nb\nc\n' > srt
printf 'a\nb\nc' > nonl1
printf 'a\nb\nd' > nonl2
printf 'x\nx\ny\n' > dup1
printf 'x\ny\ny\n' > dup2
printf 'a\0b\0c\0' > nul1
printf 'b\0c\0d\0' > nul2
: > empty

printf "\n[ Columns ]\n"
for o in "" -1 -2 -3 -12 -13 -23 -123 "-1 -2" "-3 -1"; do
    run_cmp "f1 f2 $o"        $o f1 f2
    run_cmp "g1 g2 $o"        $o g1 g2
done
run_cmp "identical files"     f1 f1
run_cmp "disjoint"            g1 empty
run_cmp "empty first"         empty f1
run_cmp "both empty"          empty empty
run_cmp "no trailing newline" nonl1 nonl2
run_cmp "duplicates"          dup1 dup2
run_cmp "-12 duplicates"      -12 dup1 dup2
run_cmp "-z"                  -z nul1 nul2
run_cmp "--zero-terminated"   --zero-terminated nul1 nul2

printf "\n[ --output-delimiter and --total ]\n"
run_cmp "--output-delimiter=:"      --output-delimiter=: f1 f2
run_cmp "--output-delimiter ' | '"  --output-delimiter=' | ' g1 g2
run_cmp "--output-delimiter separate" --output-delimiter : g1 g2
run_cmp "--output-delimiter empty"  --output-delimiter= g1 g2
run_cmp "--output-delimiter -12"    --output-delimiter=: -12 g1 g2
run_cmp "--output-delimiter -3"     --output-delimiter=: -3 g1 g2
run_cmp "twice same"                --output-delimiter=: --output-delimiter=: g1 g2
run_cmp "twice different"           --output-delimiter=: --output-delimiter=, g1 g2
run_cmp "--total"                   --total f1 f2
run_cmp "--total -123"              --total -123 f1 f2
run_cmp "--total with delimiter"    --total --output-delimiter=, f1 f2
run_cmp "--total empty"             --total empty empty
run_cmp "--total -z"                --total -z nul1 nul2

printf "\n[ Order checking ]\n"
run_cmp "unsorted default"          uns1 srt
run_cmp "unsorted second default"   srt uns1
run_cmp "unsorted with unpairable"  uns1 g2
run_cmp "--check-order"             --check-order uns1 srt
run_cmp "--check-order sorted"      --check-order f1 f2
run_cmp "--check-order second"      --check-order srt uns1
run_cmp "--nocheck-order"           --nocheck-order uns1 g2
run_cmp "--nocheck-order sorted"    --nocheck-order f1 f2
run_cmp "both unsorted"             uns1 uns1
run_cmp "--check-order both"        --check-order uns1 uns1

printf "\n[ stdin and files ]\n"
CMP_STDIN="$W/f1"
run_cmp "stdin first"               - f2
run_cmp "stdin second"              f2 -
run_cmp "-- then files"             -- f1 f2

printf "\n[ Errors ]\n"
run_cmp "no operands"
run_cmp "one operand"               f1
run_cmp "three operands"            f1 f2 srt
run_cmp "missing file 1"            nope f2
run_cmp "missing file 2"            f1 nope
run_cmp "invalid option"            -x f1 f2
run_cmp "unrecognized long"         --nope f1 f2
run_cmp "--output-delimiter missing arg" --output-delimiter

cd /; rm -rf "$W"
print_summary
