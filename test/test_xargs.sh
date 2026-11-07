#!/bin/sh
# xargs: differential tests against GNU findutils xargs 4.10 (C locale).
# References: POSIX xargs, GNU findutils manual. Commands run are echo, printf
# and sh so that the arguments they receive are visible.
UTIL="xargs"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
printf 'a b c\nd e\n\nf\n' > in1; printf 'a\nb\nc\nd\ne\n' > in2; printf "it's \"quoted\" 'x y' \"p q\"\n" > in3
printf 'a\0b c\0\0d\0' > in4; printf 'one\ntwo  \nthree\\\nfour\n' > in5; printf '  lead and trail  \n' > in6
printf 'a b\nEND c\nd\n' > in7; printf 'x\\ y \\\\z \\"q\n' > in8; printf 'a\tb\tc\n' > in9; printf 'a,b,c' > in10
printf 'unterminated "quote\n' > in11; printf "unterminated 'quote\n" > in12; : > empty; printf '\n\n\n' > blank
printf 'a b \nc\n' > in13; printf 'a\n\n\nb\n' > in14; seq 1 25 > in15; printf 'x\0' > in16
printf '%s\n' "$(printf 'z%.0s' $(seq 1 3000))" "$(printf 'y%.0s' $(seq 1 3000))" > in17

run_x() { d="$1"; f="$2"; shift 2; CMP_STDIN="$f" run_cmp "$d" "$@"; }
for f in in1 in2 in3 in4 in5 in6 in7 in8 in9 in10 in11 in12 empty blank in13 in14 in15 in16; do
    run_x "default $f" $f
    run_x "echo $f" $f echo
    run_x "-n1 $f" $f -n1 echo
    run_x "-n2 $f" $f -n 2 echo
    run_x "-n3 $f" $f --max-args=3 echo
    run_x "-L1 $f" $f -L1 echo
    run_x "-L2 $f" $f -L 2 echo
    run_x "-l $f" $f -l echo
    run_x "-l2 $f" $f -l2 echo
    run_x "-I{} $f" $f -I{} echo "<{}>"
    run_x "-I{} two $f" $f -I{} echo "{}-{}" x
    run_x "-i $f" $f -i echo "[{}]"
    run_x "-iXX $f" $f -iXX echo "[XX]"
    run_x "-0 $f" $f -0 echo
    run_x "-0 -n1 $f" $f -0 -n1 echo
    run_x "-d, $f" $f -d, echo
    run_x "-d '\\n' $f" $f -d '\n' echo
    run_x "-d '\\t' $f" $f -d '\t' echo
    run_x "-E END $f" $f -E END echo
    run_x "-eEND $f" $f -eEND echo
    run_x "-E '' $f" $f -E '' echo
    run_x "-r $f" $f -r echo
    run_x "-t $f" $f -t echo
    run_x "-t -n1 $f" $f -t -n1 echo
    run_x "-s 20 $f" $f -s 20 echo
    case $f in in4|in5) ;; *) run_x "-s 12 -x $f" $f -s 12 -x echo ;; esac
    run_x "-x -n1 $f" $f -x -n1 echo
    run_x "printf $f" $f printf '[%s]\n'
    run_x "sh -c $f" $f sh -c 'echo "$#: $*"' _
    run_x "-n2 sh $f" $f -n2 sh -c 'echo "$#: $*"' _
    run_x "-P1 -n1 $f" $f -P1 -n1 echo
    run_x "-a $f" /dev/null -a $f echo
    run_x "--arg-file $f" /dev/null --arg-file=$f -n1 echo
done
run_x "in17 default" in17 echo
run_x "in17 -s 4000" in17 -s 4000 echo
run_x "in17 -s 3500" in17 -s 3500 echo
run_x "in17 -s 3001 -n1" in17 -s 3001 -n1 echo
run_x "in17 -x -s 3500" in17 -x -s 3500 echo
run_x "in17 -I{}" in17 -I{} echo x{}
run_x "exit 1" in2 sh -c 'exit 1'
run_x "exit 1 -n1" in2 -n1 sh -c 'exit 1'
run_x "exit 255" in2 -n1 sh -c 'exit 255'
run_x "exit 3" in2 -n2 sh -c 'exit 3'
run_x "mixed exit" in2 -n1 sh -c 'test "$0" != c'
run_x "false" in2 false
run_x "true" in2 true
run_x "signal" in2 -n1 sh -c 'kill -9 $$'
run_x "signal TERM" in2 -n1 sh -c 'kill -15 $$'
run_x "missing command" in2 /nonexistent
run_x "missing command -r" empty -r /nonexistent
run_x "not executable" in2 /etc/passwd
run_x "directory command" in2 /tmp
run_x "stdin /dev/null for child" in2 sh -c 'cat | wc -c'
run_x "env passthrough" in2 -n1 sh -c 'echo $HOME_TEST'
run_x "-P2 slot" in2 -P2 -n1 --process-slot-var=SLOT sh -c 'echo slot=$SLOT >/dev/null'
run_x "-t quoting" in3 -t printf '%s\n'
run_x "--verbose" in2 --verbose -n2 echo
run_x "--no-run-if-empty" empty --no-run-if-empty echo
run_x "--null" in4 --null -n1 echo
run_x "--delimiter" in10 --delimiter=, echo
run_x "--eof" in7 --eof=END echo
run_x "--eof no arg" in7 --eof echo
run_x "--replace" in2 --replace=@ echo @
run_x "--replace no arg" in2 --replace echo {}
run_x "--max-lines" in2 --max-lines=2 echo
run_x "--max-lines no arg" in2 --max-lines echo
run_x "--max-chars" in2 --max-chars=10 echo
run_x "--exit" in2 --exit -s 8 echo
run_x "-n 0" in2 -n 0 echo
run_x "-n x" in2 -n x echo
run_x "-n -1" in2 -n -1 echo
run_x "-L 0" in2 -L 0 echo
run_x "-L x" in2 -L x echo
run_x "-l 0" in2 -l0 echo
run_x "-P x" in2 -P x echo
run_x "-P -1" in2 -P -1 echo
run_x "-s x" in2 -s x echo
run_x "-s 0" in2 -s 0 echo
run_x "-s 1" in2 -s 1 echo
run_x "-s small" in2 -s 6 echo
run_x "-s fits" in2 -s 10 echo
run_x "-d bad" in2 -d ab echo
run_x "-d empty" in2 -d '' echo
run_x "-d missing arg" in2 -d
run_x "-d \\x41" in2 -d '\x41' echo
run_x "-d \\101" in2 -d '\101' echo
run_x "-d \\0" in4 -d '\0' echo
run_x "-0 -d" in4 -0 -d, echo
run_x "-d -0" in4 -d, -0 echo
run_x "-a missing" /dev/null -a nosuch echo
run_x "-a dir" /dev/null -a / echo
run_x "bad option" in2 -z echo
run_x "bad long option" in2 --bogus echo
run_x "amb long option" in2 --ma echo
run_x "-- command" in2 -- echo
run_x "option after command" in2 echo -n
run_x "-I and -n" in2 -n2 -I{} echo {}
run_x "-n then -I" in2 -n2 -I{} echo {}
run_x "-I then -n" in2 -I{} -n2 echo {}
run_x "-I and -L" in2 -L2 -I{} echo {}
run_x "-L then -n" in2 -L2 -n3 echo
run_x "-n then -L" in2 -n3 -L2 echo
run_x "-I with empty lines" in1 -I{} echo [{}]
run_x "-I leading blanks" in6 -I{} echo "[{}]"
run_x "-I multiple replace" in2 -I{} echo {} and {}
run_x "-I replace in command name" in2 -I{} {} hello
run_x "-I long input" in17 -I{} echo {}
run_x "no command echo" in2
for a in "--show-limits" "--show-limits -s 1000" "-s 50 --show-limits"; do
    e=$(env -i LC_ALL=C /usr/bin/xargs $a -r < /dev/null 2>&1 | sed 's#/usr/bin/xargs#xargs#'); o=$(env -i LC_ALL=C "$BIN_DIR/xargs" $a -r < /dev/null 2>&1)
    if [ "$e" = "$o" ]; then PASS=$((PASS+1)); echo "PASS env -i $a"; else FAIL=$((FAIL+1)); echo "FAIL env -i $a"; fi
done
cd /; print_summary
