#!/bin/sh
# pathchk: differential tests against GNU pathchk 9.7 (C locale). References:
# GNU manual "pathchk invocation"; POSIX.1-2024 pathchk. File-system limits are
# the Linux defaults (255/4096); see the compatibility record.
UTIL="pathchk"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"; mkdir d; touch d/f
L15=$(printf 'a%.0s' $(seq 15)); L14=$(printf 'a%.0s' $(seq 14)); L255=$(printf 'a%.0s' $(seq 255)); L256=$(printf 'a%.0s' $(seq 256))
run_cmp "no args"
for opt in "" -p -P "-p -P" --portability; do
    run_cmp "[$opt] plain"            $opt file
    run_cmp "[$opt] empty"            $opt ''
    run_cmp "[$opt] space"            $opt 'a b'
    run_cmp "[$opt] leading dash"     $opt -- -a
    run_cmp "[$opt] dash in comp"     $opt a/-b/c
    run_cmp "[$opt] dash inside"      $opt a-b
    run_cmp "[$opt] existing"         $opt d/f
    run_cmp "[$opt] under file"       $opt d/f/x
    run_cmp "[$opt] slashes"          $opt a//b///c
    run_cmp "[$opt] trailing slash"   $opt d/
    run_cmp "[$opt] root"             $opt /
    run_cmp "[$opt] dots"             $opt ../x/./y
    run_cmp "[$opt] 14 chars"         $opt "$L14"
    run_cmp "[$opt] 15 chars"         $opt "$L15"
    run_cmp "[$opt] 255 chars"        $opt "$L255"
    run_cmp "[$opt] 256 chars"        $opt "$L256"
    run_cmp "[$opt] path 255"         $opt "$(printf 'a/%.0s' $(seq 127))a"
    run_cmp "[$opt] path 256"         $opt "$(printf 'a/%.0s' $(seq 128))"
    run_cmp "[$opt] star"             $opt 'a*b'
    run_cmp "[$opt] tab"              $opt "$(printf 'a\tb')"
    run_cmp "[$opt] newline"          $opt "$(printf 'a\nb')x"
    run_cmp "[$opt] high byte"        $opt "$(printf 'a\351b')"
    run_cmp "[$opt] utf8"             $opt é
    run_cmp "[$opt] quote"            $opt "a'b"
    run_cmp "[$opt] two names"        $opt ok 'bad name'
    run_cmp "[$opt] several good"     $opt a b c
done
run_cmp "long path 5000"    "$(printf 'a/%.0s' $(seq 2500))"
run_cmp "-pP"               -pP x
run_cmp "-Pp bad"           -Pp -x
run_cmp "bad option"        -x file
run_cmp "-- file"           -- file
run_cmp "--port abbrev"     --port x
print_summary
[ "$FAIL" -eq 0 ]
