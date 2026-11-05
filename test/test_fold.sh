#!/bin/sh
# fold: differential tests against GNU fold (C locale). References: GNU manual
# "fold invocation"; POSIX.1-2024 fold. Multibyte/wide characters are not
# interpreted and not tested.
UTIL="fold"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'The quick brown fox jumps over the lazy dog and keeps running far away\nshort\n\nAnotherVeryLongWordWithoutAnySpacesAtAllThatExceedsTheWidth here\n' > text
printf 'a\tb\tc\td\te\tf\tg\th\ti\tj\n\tx\n\t\t\t\ty\n' > tabs
printf 'abc\bdef\bghi\b\b\bjklmnopqrstuvwxyz\n' > bs
printf 'abcdef\rXYZ0123456789\rQRSTUVWXYZ\n' > cr
printf 'no newline at the end of this rather long line of text that wraps' > nonl
printf 'a b c d e f g h i j k l m n o p q r s t u v w x y z\n' > words
printf 'aaaa   bbbb\tcccc  dddd eeee\n   leading spaces and more words here ok\n' > blanks
printf 'abcdefghij\n' > ten
: > empty
head -c 2000 /dev/urandom | tr -d '\n' > rnd
printf '\n' >> rnd

printf "\n[ Default width 80 and -w ]\n"
for w in 1 2 3 5 8 9 10 16 20 40 79 80 81 100; do
    run_cmp "-w $w text"   -w $w text
done
run_cmp "default"          text
run_cmp "empty"            empty
run_cmp "-w10 attached"    -w10 text
run_cmp "--width=10"       --width=10 text
run_cmp "--width 10"       --width 10 text
run_cmp "--wid=10 abbrev"  --wid=10 text
run_cmp "-10 obsolete"     -10 text
run_cmp "-5 obsolete"      -5 ten
run_cmp "exact width line" -w 10 ten
run_cmp "width 9"          -w 9 ten
run_cmp "no trailing newline" -w 10 nonl
run_cmp "binary"           -w 30 rnd

printf "\n[ Tabs, backspace, CR ]\n"
for w in 8 9 10 12 16 17 20; do
    run_cmp "tabs -w $w"   -w $w tabs
    run_cmp "backspace -w $w" -w $w bs
    run_cmp "CR -w $w"     -w $w cr
done
run_cmp "tabs -b"          -b -w 10 tabs
run_cmp "backspace -b"     -b -w 5 bs
run_cmp "CR -b"            -b -w 5 cr
run_cmp "--bytes"          --bytes -w 10 tabs

printf "\n[ -s ]\n"
for w in 1 5 10 15 20 30 80; do
    run_cmp "-s -w $w words"  -s -w $w words
    run_cmp "-s -w $w text"   -s -w $w text
    run_cmp "-s -w $w blanks" -s -w $w blanks
done
run_cmp "--spaces"         --spaces -w 12 text
run_cmp "-sb"              -sb -w 12 text
run_cmp "-s with tabs"     -s -w 12 tabs
run_cmp "-bs"              -bs -w 7 blanks

printf "\n[ stdin and files ]\n"
CMP_STDIN="$W/text"
run_cmp "stdin"            -w 20
run_cmp "stdin as -"       -w 20 -
run_cmp "two files"        -w 20 words ten
run_cmp "missing among"    -w 20 words nope ten
run_cmp "-- then file"     -w 20 -- ten

printf "\n[ Errors ]\n"
run_cmp "-w 0"             -w 0 text
run_cmp "-w x"             -w x text
run_cmp "-w -1"            -w -1 text
run_cmp "-w empty"         -w '' text
run_cmp "-0 obsolete"      -0 text
run_cmp "invalid option"   -x text
run_cmp "unrecognized long" --nope text
run_cmp "-w missing arg"   -w
run_cmp "missing file"     nope

cd /; rm -rf "$W"
print_summary
