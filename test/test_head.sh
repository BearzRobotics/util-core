#!/bin/sh
# head: differential tests against GNU head. References: GNU manual "head
# invocation"; POSIX.1-2024 head.
UTIL="head"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"
seq 1 25 > "$W/n25"
printf 'a\nb\nc' > "$W/nonl"
printf 'a\0b\0c\0d\0' > "$W/nul"
: > "$W/empty"
head -c 300000 /dev/urandom > "$W/bin"
mkdir "$W/dir"
cd "$W"

printf "\n[ Defaults and -n ]\n"
CMP_STDIN="$W/n25"
run_cmp "default (10 lines) from stdin"
run_cmp "file operand"           n25
run_cmp "-n 3"                   -n 3 n25
run_cmp "-n3"                    -n3 n25
run_cmp "-n 0"                   -n 0 n25
run_cmp "-n larger than file"    -n 100 n25
run_cmp "--lines=4"              --lines=4 n25
run_cmp "--lines 4"              --lines 4 n25
run_cmp "--li=4 abbreviation"    --li=4 n25
run_cmp "no trailing newline"    -n 2 nonl
run_cmp "-n 10 no trailing nl"   nonl
run_cmp "empty file"             empty
run_cmp "-n -3 (all but last)"   -n -3 n25
run_cmp "-n -0"                  -n -0 n25
run_cmp "-n -100"                -n -100 n25
run_cmp "-n -1 no trailing nl"   -n -1 nonl
run_cmp "-n -2 binary"           -n -2 bin
run_cmp "-n 1K"                  -n 1K n25
run_cmp "-n 99999999999999999999999" n25 -n 99999999999999999999999
run_cmp "last of -n/-c wins"     -c 3 -n 2 n25
run_cmp "stdin as -"             -n 2 -

printf "\n[ Bytes ]\n"
run_cmp "-c 7"                   -c 7 n25
run_cmp "-c 0"                   -c 0 n25
run_cmp "-c -7 (all but last)"   -c -7 n25
run_cmp "-c 1b"                  -c 1b bin
run_cmp "-c 2KB"                 -c 2KB bin
run_cmp "-c 2K"                  -c 2K bin
run_cmp "-c 1M"                  -c 1M bin
run_cmp "-c -1M"                 -c -1M bin
run_cmp "-c -299999"             -c -299999 bin
run_cmp "-n 5000 binary"         -n 5000 bin
run_cmp "-n -5000 binary"        -n -5000 bin
run_cmp "--bytes=3"              --bytes=3 n25

printf "\n[ Headers ]\n"
run_cmp "two files"              -n 2 n25 nonl
run_cmp "-q two files"           -q -n 2 n25 nonl
run_cmp "--quiet"                --quiet -n 2 n25 nonl
run_cmp "--silent"               --silent -n 2 n25 nonl
run_cmp "-v one file"            -v -n 2 n25
run_cmp "--verbose"              --verbose -n 2 n25
run_cmp "stdin among files"      -n 1 n25 - nonl
run_cmp "three files all but last" -n -23 n25 nonl empty

printf "\n[ -z ]\n"
run_cmp "-z -n 2"                -z -n 2 nul
run_cmp "-z -n -1"               -z -n -1 nul
run_cmp "--zero-terminated"      --zero-terminated -n 3 nul

printf "\n[ Obsolete -NUM ]\n"
run_cmp "-3"                     -3 n25
run_cmp "-3q two files"          -3q n25 nonl
run_cmp "-5c"                    -5c n25
run_cmp "-2v"                    -2v n25
run_cmp "-1k"                    -1k n25

printf "\n[ POSIX 1.4: seekable stdin is left just past the consumed part ]\n"
for opt in "-n 1" "-n 2" "-c 3" "-c 0" "-n 0"; do
    e=$( (gnu $opt; cat) < n25 | od -c ); a=$( (ours $opt; cat) < n25 | od -c )
    [ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS stdin offset after head $opt"; } || { FAIL=$((FAIL + 1)); echo "FAIL stdin offset after head $opt"; }
done

printf "\n[ Errors ]\n"
run_cmp "missing file"           nonexistent
run_cmp "missing among files"    -n 1 n25 nonexistent nonl
run_cmp "directory"              dir
run_cmp "directory among files"  -n 1 n25 dir
run_cmp "invalid -n"             -n abc n25
run_cmp "invalid -c"             -c 1x n25
run_cmp "empty count"            -n "" n25
run_cmp "invalid option"         -x
run_cmp "unrecognized long"      --nope
run_cmp "-n needs argument"      -n
run_cmp "digit after other option" -q3 n25
run_cmp "-- ends options"        -- -n

cd /
rm -rf "$W"
print_summary
