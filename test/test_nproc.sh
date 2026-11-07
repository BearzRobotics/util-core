#!/bin/sh
# nproc: differential tests against GNU nproc 9.7.
UTIL="nproc"
. "$(dirname "$0")/testlib.sh"
run_cmp "nproc"
run_cmp "--all"             --all
for n in 0 1 2 3 5 11 12 13 100 99999999999; do
    run_cmp "--ignore=$n"       --ignore=$n
    run_cmp "--ignore $n"       --ignore $n
    run_cmp "--all --ignore=$n" --all --ignore=$n
done
run_cmp "--ignore=x"        --ignore=x
run_cmp "--ignore=-1"       --ignore=-1
run_cmp "--ignore missing"  --ignore
run_cmp "operand"           5
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
for v in 1 2 4 8 100 0 -1 x "3,4" " 5" "2,"; do
    OMP_NUM_THREADS="$v"; export OMP_NUM_THREADS
    run_cmp "OMP_NUM_THREADS=$v"          
    run_cmp "OMP_NUM_THREADS=$v --all"    --all
    run_cmp "OMP_NUM_THREADS=$v --ignore=1" --ignore=1
    for l in 1 3 50 0 x; do
        OMP_THREAD_LIMIT="$l"; export OMP_THREAD_LIMIT
        run_cmp "OMP_NUM_THREADS=$v OMP_THREAD_LIMIT=$l"
    done
    unset OMP_THREAD_LIMIT
done
unset OMP_NUM_THREADS
OMP_THREAD_LIMIT=2; export OMP_THREAD_LIMIT; run_cmp "OMP_THREAD_LIMIT=2 alone"; unset OMP_THREAD_LIMIT
print_summary
