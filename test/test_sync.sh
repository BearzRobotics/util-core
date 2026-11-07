#!/bin/sh
# sync: differential tests against GNU sync 9.7 (C locale). References: GNU
# manual "sync invocation"; POSIX.1-2024 sync. Effects are not observable, so
# exit statuses and diagnostics are compared.
UTIL="sync"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"; echo x > file; mkdir dir; touch 'we ird'
run_cmp "no args"
run_cmp "file"                 file
run_cmp "directory"            dir
run_cmp "several"              file dir 'we ird'
run_cmp "missing"              nofile
run_cmp "missing and present"  nofile file
run_cmp "-d file"              -d file
run_cmp "--data file"          --data file
run_cmp "-d dir"               -d dir
run_cmp "-d no args"           -d
run_cmp "--data no args"       --data
run_cmp "-f file"              -f file
run_cmp "--file-system file"   --file-system file
run_cmp "-f dir"               -f dir
run_cmp "-f no args"           -f
run_cmp "-d -f"                -d -f file
run_cmp "-df"                  -df file
run_cmp "-d missing"           -d nofile
run_cmp "-f missing"           -f nofile
run_cmp "unreadable"           /etc/shadow
run_cmp "-- file"              -- file
run_cmp "-- -dash"             -- -x
run_cmp "bad option"           -x
run_cmp "long abbrev"          --da file
run_cmp "stdin dash"           -
print_summary
[ "$FAIL" -eq 0 ]
