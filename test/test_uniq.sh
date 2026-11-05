#!/bin/sh
# uniq: differential tests against GNU uniq (C locale). References: GNU manual
# "uniq invocation"; POSIX.1-2024 uniq.
UTIL="uniq"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'a\na\nb\nc\nc\nc\nd\na\n' > basic
printf 'A\na\nb\nB\nb\n' > cased
printf 'x 1 foo\ny 1 foo\nz 2 foo\nw 2 bar\n' > fields
printf 'abcX\nabcY\nabdZ\n' > chars
printf '  a b\n a b\nc a b\n' > blanks
printf 'a\n\n\nb\n\nc\nc\n' > withblank
printf 'one\ntwo' > nonl
printf 'a\0a\0b\0' > nul
: > empty
printf 'x\n' > single

printf "\n[ Default, -c, -d, -u ]\n"
for o in "" -c -d -u -cd -cu -du -cdu -i -ci -di -ui; do
    run_cmp "basic $o"       $o basic
    run_cmp "cased $o"       $o cased
done
run_cmp "empty input"         empty
run_cmp "-c empty"            -c empty
run_cmp "single line"         single
run_cmp "-c single"           -c single
run_cmp "no trailing newline" nonl
run_cmp "-c no trailing nl"   -c nonl
run_cmp "blank lines"         withblank
run_cmp "-c blank lines"      -c withblank
run_cmp "--count"             --count basic
run_cmp "--repeated"          --repeated basic
run_cmp "--unique"            --unique basic
run_cmp "--ignore-case"       --ignore-case cased
CMP_STDIN="$W/basic"
run_cmp "stdin"
run_cmp "stdin as -"          -
run_cmp "-c stdin"            -c

printf "\n[ -f -s -w ]\n"
for o in "-f 1" "-f 2" "-f 0" "-f 9" "-s 1" "-s 3" "-s 99" "-w 1" "-w 2" "-w 0" "-f 1 -s 1" "-f 1 -w 1" "-s 1 -w 2" "-f 1 -s 1 -w 1" "-1" "-2" "-fN"; do
    run_cmp "fields $o"       $o fields
    run_cmp "chars  $o"       $o chars
    run_cmp "blanks $o"       $o blanks
done
run_cmp "-c -f 1"             -c -f 1 fields
run_cmp "-f1 attached"        -f1 fields
run_cmp "--skip-fields=1"     --skip-fields=1 fields
run_cmp "--skip-fields 1"     --skip-fields 1 fields
run_cmp "--skip-chars=1"      --skip-chars=1 chars
run_cmp "--check-chars=3"     --check-chars=3 chars
run_cmp "-i with -f"          -i -f 1 fields

printf "\n[ -D --all-repeated ]\n"
for m in "" none prepend separate pre sep; do
    if [ -z "$m" ]; then run_cmp "-D"  -D basic; run_cmp "-D withblank" -D withblank
    else run_cmp "--all-repeated=$m" --all-repeated=$m basic; run_cmp "--all-repeated=$m blank" --all-repeated=$m withblank; fi
done
run_cmp "-D -i"               -D -i cased
run_cmp "-D -u"               -D -u basic
run_cmp "-D -d"               -D -d basic
run_cmp "-D no trailing nl"   -D nonl
run_cmp "--all-repeated alone" --all-repeated basic
run_cmp "--all-repeated=bad"  --all-repeated=bad basic

printf "\n[ --group ]\n"
for m in "" separate prepend append both; do
    if [ -z "$m" ]; then run_cmp "--group" --group basic; run_cmp "--group empty input" --group empty
    else run_cmp "--group=$m" --group=$m basic; run_cmp "--group=$m single" --group=$m single; fi
done
run_cmp "--group=bad"         --group=bad basic
run_cmp "--group -c"          --group -c basic
run_cmp "--group -d"          --group -d basic
run_cmp "--group -D"          --group -D basic
run_cmp "--group -u"          --group -u basic
run_cmp "-c -D"               -c -D basic
run_cmp "--group -i"          --group -i cased

printf "\n[ -z ]\n"
run_cmp "-z"                  -z nul
run_cmp "-z -c"               -z -c nul
run_cmp "-z --group"          -z --group nul
run_cmp "-z -D"               -z -D nul

printf "\n[ Output file ]\n"
rm -f outg outo
LC_ALL=C gnu basic outg; ours basic outo
cmp -s outg outo && { PASS=$((PASS + 1)); echo "PASS output file operand"; } || { FAIL=$((FAIL + 1)); echo "FAIL output file operand"; }
LC_ALL=C gnu -c basic - | od -c > og; ours -c basic - | od -c > oo
cmp -s og oo && { PASS=$((PASS + 1)); echo "PASS output operand -"; } || { FAIL=$((FAIL + 1)); echo "FAIL output operand -"; }

printf "\n[ Errors ]\n"
run_cmp "missing file"        nope
run_cmp "extra operand"       basic out extra
run_cmp "bad -f"              -f x basic
run_cmp "bad -s"              -s x basic
run_cmp "bad -w"              -w x basic
run_cmp "negative -f"         -f -1 basic
run_cmp "empty -f"            -f '' basic
run_cmp "invalid option"      -x basic
run_cmp "unrecognized long"   --nope basic
run_cmp "-f missing arg"      -f
run_cmp "output unwritable"   basic /nonexistent-dir/x
run_cmp "-- then file"        -- basic

cd /; rm -rf "$W"
print_summary
