#!/bin/sh
# expand: differential tests against GNU expand (C locale). References: GNU
# manual "expand invocation"; POSIX.1-2024 expand.
UTIL="expand"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'a\tb\tc\n\tx\n\t\t\ty\nabcdefgh\ti\nabcdefghi\tj\n  \tz\nno tabs here\n' > t1
printf 'ab\bc\td\n\b\bx\ty\n' > bs
printf '\t\ta\tb\n  \t  b\tc\td\n x\t\ty\n' > lead
printf 'last\tline no newline' > nonl
: > empty

printf "\n[ Default and -t N ]\n"
for f in t1 bs lead nonl empty; do run_cmp "default $f" $f; done
for n in 1 2 3 4 5 7 8 9 16 100; do run_cmp "-t $n" -t $n t1; done
run_cmp "-t3 attached"        -t3 t1
run_cmp "--tabs=3"            --tabs=3 t1
run_cmp "--tabs 3"            --tabs 3 t1
run_cmp "obsolete -4"         -4 t1
run_cmp "obsolete -4,8"       -4,8 t1
run_cmp "-t backspace"        -t 4 bs
run_cmp "-t 0 error"          -t 0 t1

printf "\n[ Tab lists ]\n"
for l in '2,4' '4,8,12' '1,2,3' '8,16' '2,/4' '2,+4' '1,+8' '/4' '+4' '3,5,/2' '3,6,+3' '10,20,30' '4,/0' '3,+0' '8,,16' '2, 4' '2 4' '2	4'; do
    run_cmp "-t '$l'"         -t "$l" t1
    run_cmp "-t '$l' lead"    -t "$l" lead
done
run_cmp "-t repeated options" -t3 -t5 t1
run_cmp "-t list then list"   -t 3,6 -t 9 t1

printf "\n[ -i initial ]\n"
run_cmp "-i"                  -i t1
run_cmp "-i lead"             -i lead
run_cmp "--initial"           --initial lead
run_cmp "-i -t 4"             -i -t 4 lead
run_cmp "-it 4"               -it 4 lead
run_cmp "-i bs"               -i bs

printf "\n[ stdin and files ]\n"
CMP_STDIN="$W/t1"
run_cmp "stdin"
run_cmp "stdin as -"          -
run_cmp "two files"           t1 lead
run_cmp "missing among files" t1 nope lead
run_cmp "-- then file"        -- t1

printf "\n[ Errors ]\n"
run_cmp "-t x"                -t x t1
run_cmp "-t 4x"               -t 4x t1
run_cmp "-t -1"               -t -1 t1
run_cmp "-t 4,2"              -t 4,2 t1
run_cmp "-t 4,4"              -t 4,4 t1
run_cmp "-t 4/"               -t 4/ t1
run_cmp "-t 4+"               -t 4+ t1
run_cmp "-t /4,8"             -t /4,8 t1
run_cmp "-t +4,8"             -t +4,8 t1
run_cmp "-t /4,/8"            -t /4,/8 t1
run_cmp "-t too large"        -t 18446744073709551616 t1
run_cmp "-t empty"            -t '' t1
run_cmp "invalid option"      -x t1
run_cmp "unrecognized long"   --nope t1
run_cmp "-t missing arg"      -t

printf "\n[ Random inputs ]\n"
python3 -I - "$W" <<'PY'
import random,sys
random.seed(11)
w=sys.argv[1]
chars=['a','b',' ',' ','\t','\t','\b','x','\n']
for k in range(40):
    s=''.join(random.choice(chars) for _ in range(random.randint(0,60)))
    open(f"{w}/rnd{k}","w").write(s)
PY
n=0; bad=0
for f in rnd*; do
    for o in "" "-i" "-t 3" "-t 4,9" "-t 2,/5" "-t 1,+3" "-i -t 5"; do
        e=$(LC_ALL=C /usr/bin/expand $o "$f" | od -c); a=$("$BIN_DIR/expand" $o "$f" | od -c)
        n=$((n+1)); [ "$e" = "$a" ] || { bad=$((bad+1)); echo "random mismatch: expand $o $f"; }
    done
done
[ $bad -eq 0 ] && { PASS=$((PASS + 1)); echo "PASS $n random comparisons"; } || { FAIL=$((FAIL + 1)); echo "FAIL $bad of $n random comparisons differ"; }

cd /; rm -rf "$W"
print_summary
