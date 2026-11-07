#!/bin/sh
# unexpand: differential tests against GNU unexpand (C locale). References: GNU
# manual "unexpand invocation"; POSIX.1-2024 unexpand.
UTIL="unexpand"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf '        a        b\n  \t  c   d\n     x    y     z\n\t\tq\n' > s1
printf 'abcdefg h\nabcdefgh  i\nabcdef  gh\nab      cd\n a b  c   d    e\n' > s2
printf '        \n \n  \t\n\t \n' > blank
printf 'ab\b      c\n\b\b        d\n' > bs
printf 'x        y        z' > nonl
: > empty

printf "\n[ Defaults and -a ]\n"
for f in s1 s2 blank bs nonl empty; do
    run_cmp "default $f"     $f
    run_cmp "-a $f"          -a $f
    run_cmp "--all $f"       --all $f
done
run_cmp "--first-only"        --first-only s1
run_cmp "-a --first-only"     -a --first-only s2
run_cmp "--first-only -a"     --first-only -a s2

printf "\n[ -t ]\n"
for l in 1 2 3 4 5 7 8 16 '2,4' '4,8,12' '3,6,9' '1,2,3' '2,/4' '2,+4' '1,+8' '/4' '+4' '3,5,/2' '8,16' '10,20' '4,/0'; do
    run_cmp "-t '$l' s1"     -t "$l" s1
    run_cmp "-t '$l' s2"     -t "$l" s2
done
run_cmp "-t4 attached"        -t4 s1
run_cmp "--tabs=4"            --tabs=4 s1
run_cmp "-t 4 --first-only"   -t 4 --first-only s2
run_cmp "obsolete -4"         -4 s1
run_cmp "obsolete -4 s2"      -4 s2
run_cmp "obsolete -4,8"       -4,8 s1
run_cmp "-t repeated"         -t3 -t6 s1
run_cmp "-t bs"               -t 4 bs
run_cmp "-t nonl"             -t 3 nonl

printf "\n[ stdin and files ]\n"
CMP_STDIN="$W/s1"
run_cmp "stdin"
run_cmp "stdin as -"          -
run_cmp "two files"           s1 s2
run_cmp "missing among files" s1 nope s2
run_cmp "-- then file"        -- s1

printf "\n[ Errors ]\n"
run_cmp "-t 0"                -t 0 s1
run_cmp "-t x"                -t x s1
run_cmp "-t 4,2"              -t 4,2 s1
run_cmp "-t 4/"               -t 4/ s1
run_cmp "-t /4,8"             -t /4,8 s1
run_cmp "-t empty"            -t '' s1
run_cmp "invalid option"      -x s1
run_cmp "unrecognized long"   --nope s1
run_cmp "-t missing arg"      -t

printf "\n[ Random inputs ]\n"
python3 -I - "$W" <<'PY'
import random,sys
random.seed(5)
w=sys.argv[1]
chars=[' ',' ',' ',' ','\t','a','b','\b','\n']
for k in range(60):
    s=''.join(random.choice(chars) for _ in range(random.randint(0,70)))
    open(f"{w}/rnd{k}","w").write(s)
PY
n=0; bad=0
for f in rnd*; do
    for o in "" "-a" "--first-only" "-t 3" "-t 4,9" "-t 2,/5" "-t 1,+3" "-t 5 --first-only" "-4" "-3,7" "-t 1" "-t 2,6,7"; do
        e=$(LC_ALL=C /usr/bin/unexpand $o "$f" | od -c); a=$("$BIN_DIR/unexpand" $o "$f" | od -c)
        n=$((n+1)); [ "$e" = "$a" ] || { bad=$((bad+1)); [ $bad -le 5 ] && echo "random mismatch: unexpand $o $f"; }
    done
done
[ $bad -eq 0 ] && { PASS=$((PASS + 1)); echo "PASS $n random comparisons"; } || { FAIL=$((FAIL + 1)); echo "FAIL $bad of $n random comparisons differ"; }

cd /; rm -rf "$W"
print_summary
