#!/bin/sh
# cut: differential tests against GNU cut (C locale). References: GNU manual
# "cut invocation"; POSIX.1-2024 cut. Multibyte (UTF-8) behaviour is not
# implemented and not tested.
UTIL="cut"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'abcdefghij\nABCDEFGHIJ\n0123456789\nshort\n\n' > txt
printf 'a:b:c:d:e\n1:2:3\nnodelim\n::\n:x:\na:b:c:d:e:f:g' > col
printf 'a\tb\tc\nd\te\tf\n\tx\t\nplain\n' > tab
printf 'a\0b\0c\0d' > nul
printf 'a,b;c d\n' > mixed
head -c 3000 /dev/urandom > bin

printf "\n[ -b / -c ]\n"
for l in 1 3 1,3 2-4 -3 8- 1-3,5-7 3-1,2 1,1,1 4-4 5-2,1 1-2,2-3 1-2,3-4 11 20- 1,20 -1,3- 3,1 2-,1- '1 3' '2-3 5'; do
    run_cmp "-b $l" -b "$l" txt
done
run_cmp "-c same as -b"           -c 2-4 txt
run_cmp "-n accepted"             -n -b 1-3 txt
run_cmp "--bytes=2-3"             --bytes=2-3 txt
run_cmp "--characters 2-3"        --characters 2-3 txt
run_cmp "-b2-3 attached"          -b2-3 txt
run_cmp "--complement -b"         --complement -b 2-4 txt
run_cmp "--complement -b 1"       --complement -b 1 txt
run_cmp "--complement open"       --complement -b 3- txt
run_cmp "--complement -3"         --complement -b -3 txt
run_cmp "--complement all"        --complement -b 1- txt
run_cmp "--output-delimiter -b"   -b 1-2,5-6 --output-delimiter=: txt
run_cmp "--output-delimiter adjacent" -b 1-2,3-4 --output-delimiter=: txt
run_cmp "--output-delimiter single" -b 1,3,5 --output-delimiter=-- txt
run_cmp "output-delimiter complement" --complement -b 2-3 --output-delimiter=: txt
run_cmp "binary -b"               -b 1-5,100-110 bin
run_cmp "no trailing newline"     -b 1-2 col

printf "\n[ -f ]\n"
for l in 1 2 1,3 2- -2 1-2,4 3 5 6 7 1,1 2-3,1 3-1,2 10; do
    run_cmp "-f $l -d:" -f "$l" -d: col
done
run_cmp "default tab delimiter"    -f 2 tab
run_cmp "-f 1,3 tab"               -f 1,3 tab
run_cmp "-s"                       -f 1 -d: -s col
run_cmp "-s tab"                   -f 2 -s tab
run_cmp "--only-delimited"         -f 1 -d: --only-delimited col
run_cmp "--delimiter=:"            -f 2 --delimiter=: col
run_cmp "-d: attached"             -f2 -d: col
run_cmp "-d with space"            -f 1 -d ' ' mixed
run_cmp "-d,"                      -f 2 -d, mixed
run_cmp "--output-delimiter -f"    -f 1,3 -d: --output-delimiter=' | ' col
run_cmp "--output-delimiter empty" -f 1,3 -d: --output-delimiter= col
run_cmp "--complement -f"          --complement -f 2 -d: col
run_cmp "--complement -f 1-2"      --complement -f 1-2 -d: col
run_cmp "--complement -s"          --complement -s -f 1 -d: col
run_cmp "-d empty (NUL delim)"     -f 1 -d '' nul
run_cmp "empty fields kept"        -f 2 -d: col
run_cmp "-f beyond last field"     -f 9 -d: col

printf "\n[ -z ]\n"
run_cmp "-z -b"                    -z -b 1 nul
run_cmp "-z -f"                    -z -f 1 -d: nul
run_cmp "--zero-terminated"        --zero-terminated -b 1 nul

printf "\n[ stdin and multiple files ]\n"
CMP_STDIN="$W/txt"
run_cmp "stdin"                    -b 1-2
run_cmp "stdin as -"               -b 1-2 -
run_cmp "two files"                -b 1-2 txt col
run_cmp "missing among files"      -b 1-2 txt nope col
run_cmp "-- then file"             -b 1 -- txt

printf "\n[ Errors ]\n"
run_cmp "no list"                  txt
run_cmp "no list, no file"
run_cmp "-b and -f"                -b 1 -f 1 txt
run_cmp "-d with -b"               -b 1 -d: txt
run_cmp "-s with -b"               -b 1 -s txt
run_cmp "-d multi-char"            -f 1 -d:: col
run_cmp "zero position"            -b 0 txt
run_cmp "zero field"               -f 0 col
run_cmp "-0"                       -b -0 txt
run_cmp "decreasing"               -b 3-1 txt
run_cmp "bad range"                -b a txt
run_cmp "bad range 2"              -b 1-a txt
run_cmp "bad field"                -f x col
run_cmp "just dash"                -b - txt
run_cmp "empty list"               -b '' txt
run_cmp "list of commas"           -b ',' txt
run_cmp "invalid option"           -x txt
run_cmp "unrecognized long"        --nope txt
run_cmp "-b missing arg"           -b
run_cmp "missing file only"        -b 1 nope

cd /; rm -rf "$W"
print_summary
