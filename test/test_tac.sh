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
print_summary
