#!/bin/sh
# users: differential tests against GNU users 9.7. Hand-made utmp files cover
# the record layout (384 bytes; type 7 = user process).
UTIL="users"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
rec() { # type user -> one 384-byte utmp record on stdout
    awk -v t="$1" -v u="$2" 'BEGIN {
        printf "%c%c", t % 256, int(t / 256); printf "%c%c", 0, 0
        for (i = 0; i < 4; i++) printf "%c", 0
        for (i = 0; i < 32; i++) printf "%c", 0
        for (i = 0; i < 4; i++) printf "%c", 0
        s = u; while (length(s) < 32) s = s "\001"; gsub(/\001/, "\000", s)
        printf "%s", substr(u, 1, 32); for (i = length(u); i < 32; i++) printf "%c", 0
        for (i = 76; i < 384; i++) printf "%c", 0 }' | head -c 384
}
{ rec 7 zed; rec 7 alice; rec 8 dead; rec 7 bob; rec 7 alice; } > utmp1
{ rec 8 x; rec 1 y; } > utmp2
: > utmp3
head -c 100 utmp1 > utmp4
rec 7 averyveryverylongusernamethatexceeds32chars > utmp5
# GNU falls back to systemd-logind sessions when /var/run/utmp is absent; not reproduced.
run_cmp "users file"         utmp1
run_cmp "no user processes"  utmp2
run_cmp "empty file"         utmp3
run_cmp "truncated record"   utmp4
run_cmp "name over 32 bytes" utmp5
run_cmp "missing file"       nonexistent
run_cmp "directory"          .
run_cmp "two files"          utmp1 utmp2
run_cmp "-x"                 -x
run_cmp "--bogus"            --bogus
rm -rf "$W"
print_summary
