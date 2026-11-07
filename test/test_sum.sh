#!/bin/sh
# sum: differential tests against GNU sum 9.7 (C locale). Reference: GNU
# manual "sum invocation".
UTIL="sum"
. "$(dirname "$0")/testlib.sh"
H="$(mktemp -d)"; cd "$H"
printf 'hello\n' > a
printf 'world' > 'b c'
printf '' > empty
mkdir -p dir
head -c 1000000 /dev/urandom > rnd
for n in 1 255 256 511 512 513 1023 1024 1025 2047 2048 2049 65535 65536 65537; do head -c $n /dev/urandom > "len$n"; done
printf '\377\377\377\377' > ff
head -c 70000 /dev/zero | tr '\0' '\377' > manyff
for o in "" -r -s --sysv "-r -s" "-s -r" -rs -sr; do
    run_cmp "a $o"               $o a
    run_cmp "two files $o"       $o a 'b c'
    run_cmp "empty $o"           $o empty
    run_cmp "ff $o"              $o ff
    run_cmp "manyff $o"          $o manyff
    run_cmp "1 MB $o"            $o rnd
    for n in 1 255 256 511 512 513 1023 1024 1025 2047 2048 2049 65535 65536 65537; do
        run_cmp "len$n $o"       $o len$n
    done
    run_cmp "missing $o"         $o nonexistent
    run_cmp "directory $o"       $o dir
    CMP_STDIN=a run_cmp "stdin $o"          $o
    CMP_STDIN=a run_cmp "stdin - $o"        $o -
    CMP_STDIN=a run_cmp "stdin and file $o" $o - a
done
run_cmp "unknown option"         -x a
run_cmp "--bogus"                --bogus a
run_cmp "-- operand"             -- a
run_cmp "--sysv=x"               --sysv=x a
rm -rf "$H"
print_summary
