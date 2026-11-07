#!/bin/sh
# chroot: differential tests against GNU chroot 9.7 (C locale). References: GNU
# manual "chroot invocation". chroot(2) needs privilege, so unprivileged runs
# compare the diagnostics; privileged runs (root) also run commands.
UTIL="chroot"
GNU_BIN=/usr/sbin
. "$(dirname "$0")/testlib.sh"
help_cmp
run_cmp "no args"
run_cmp "missing root"         /nonexistent
run_cmp "missing root cmd"     /nonexistent true
run_cmp "file as root"         /etc/passwd true
run_cmp "unprivileged /"       / true
run_cmp "skip-chdir not /"     --skip-chdir /usr true
run_cmp "skip-chdir /"         --skip-chdir / true
run_cmp "bad option"           -x /
run_cmp "-- operand"           -- / true
run_cmp "userspec"             --userspec=nobody / true
run_cmp "groups"               --groups=0 / true
if [ "$(id -u)" = 0 ]; then
    run_cmp "pwd in new root"  / pwd
    run_cmp "exit status"      / sh -c 'exit 3'
    run_cmp "not found"        / nonexistent-cmd
fi
print_summary
[ "$FAIL" -eq 0 ]
