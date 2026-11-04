#!/bin/sh
# pwd: differential tests against GNU pwd. References: GNU manual "pwd
# invocation"; POSIX.1-2024 pwd.
UTIL="pwd"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; mkdir -p "$W/real/sub"; ln -s "$W/real" "$W/link"
REAL="$(cd "$W/real" && pwd -P)"

printf "\n[ Physical / logical ]\n"
cd "$W/real/sub"
run_cmp "default"       
run_cmp "-P"            -P
run_cmp "-L (PWD matches)" -L
cd "$W/link/sub" 2>/dev/null || cd "$W/real/sub"
export PWD="$W/link/sub"
run_cmp "-L through symlink" -L
run_cmp "-P through symlink" -P
run_cmp "-L -P: last wins"   -L -P
run_cmp "-P -L: last wins"   -P -L
run_cmp "--logical"          --logical
run_cmp "--physical"         --physical
run_cmp "abbreviated --phys" --phys
POSIXLY_CORRECT=1 run_cmp "POSIXLY_CORRECT defaults to -L"
PWD="$W/real/nonexistent" run_cmp "-L with stale PWD falls back" -L
PWD="$W/link/../real/sub" run_cmp "-L with .. in PWD falls back" -L
PWD="relative" run_cmp "-L with relative PWD falls back" -L
saved=$PWD; unset PWD; run_cmp "-L with PWD unset" -L; PWD=$saved; export PWD

printf "\n[ Errors ]\n"
run_cmp "invalid option"      -x
run_cmp "unrecognized long"   --nope
run_cmp "extra operand warns" extra
run_cmp "-- then operand"     -- extra
run_test_exit "--help exit status"  --help

rm -rf "$W"
print_summary
