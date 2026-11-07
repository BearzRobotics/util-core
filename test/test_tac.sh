#!/bin/sh
# tac: differential tests against GNU tac. Reference: GNU manual "tac
# invocation" (POSIX does not specify tac).
UTIL="tac"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"
cd "$W"
mk() { printf "$2" > "$1"; }
mk lines 'a\nb\nc\n'; mk nonl 'a\nb\nc'; mk blank 'a\n\nb\n\n\n'; mk one 'a'; mk nl '\n'
mk empty ''; mk seps 'axxbxxxc'; mk sepsend 'xxaxx'; mk nul 'a\0b\0c\0'; head -c 100000 /dev/urandom > bin

printf "\n[ Default (newline after) ]\n"
for f in lines nonl blank one nl empty bin; do run_cmp "file $f" $f; done
CMP_STDIN="$W/lines"; run_cmp "stdin"
run_cmp "stdin as -" -
run_cmp "two files" lines nonl
run_cmp "-- then file" -- lines

printf "\n[ -b ]\n"
for f in lines nonl blank one nl empty; do run_cmp "-b $f" -b $f; done
run_cmp "--before" --before lines

printf "\n[ -s ]\n"
for f in seps sepsend lines; do
    run_cmp "-s xx $f" -s xx $f
    run_cmp "-b -s xx $f" -b -s xx $f
    run_cmp "-s a $f" -s a $f
done
run_cmp "-sxx attached" -sxx seps
run_cmp "--separator=xx" --separator=xx seps
run_cmp "--sep xx" --sep xx seps
run_cmp "empty separator is NUL" -s '' nul
run_cmp "-s with multi-byte" -s 'xxx' seps

printf "\n[ Errors ]\n"
run_cmp "missing file" nonexistent
run_cmp "missing among files" lines nonexistent nonl
run_cmp "invalid option" -x
run_cmp "unrecognized long" --nope

cd /
rm -rf "$W"
printf "\n[ Windowed reading, differential ]\n"
W="$(mktemp -d)"
# Lines of varying length so record boundaries land everywhere relative to the
# 64 KiB read windows; sizes straddle one, two and three windows.
awk 'BEGIN { srand(11); for (i = 0; i < 40000; i++) { n = int(rand() * 30); s = ""; for (j = 0; j < n; j++) s = s "x"; print i s } }' > "$W/lines"
head -c 65536 "$W/lines" > "$W/w1"
head -c 65537 "$W/lines" > "$W/w1p"
head -c 131072 "$W/lines" > "$W/w2"
head -c 131073 "$W/lines" > "$W/w2p"
head -c 196607 "$W/lines" > "$W/w3m"
{ head -c 200000 /dev/zero | tr '\0' 'y'; printf '\nshort\n'; } > "$W/hugeline"
{ printf 'short\n'; head -c 200000 /dev/zero | tr '\0' 'y'; } > "$W/hugeend"
head -c 70000 /dev/zero | tr '\0' '\n' > "$W/onlyseps"
{ head -c 65535 /dev/zero | tr '\0' 'a'; printf 'SEP'; head -c 65533 /dev/zero | tr '\0' 'b'; printf 'SEPtail'; } > "$W/sepsplit"
head -c 300000 /dev/urandom > "$W/rand"
printf 'a\n' > "$W/one"
: > "$W/empty"
for f in lines w1 w1p w2 w2p w3m hugeline hugeend onlyseps sepsplit one empty; do
    run_cmp "$f"             "$W/$f"
    run_cmp "$f -b"          -b "$W/$f"
    run_cmp "$f -s SEP"      -s SEP "$W/$f"
    run_cmp "$f -b -s SEP"   -b -s SEP "$W/$f"
    run_cmp "$f -s xy"       -s xy "$W/$f"
    run_cmp "$f -s y"        -s y "$W/$f"
    run_cmp "$f -s ''"       -s '' "$W/$f"
done
for o in "" -b "-s a" "-b -s ab" "-s aa"; do run_cmp "rand $o" $o "$W/rand"; done
run_cmp "two files"          "$W/w1p" "$W/one" "$W/sepsplit"
run_cmp "missing then file"  "$W/nonexistent" "$W/one"
CMP_STDIN="$W/lines" run_cmp "stdin"       
CMP_STDIN="$W/lines" run_cmp "stdin -b"    -b
CMP_STDIN="$W/sepsplit" run_cmp "stdin -s SEP" -s SEP -
rm -rf "$W"

print_summary
