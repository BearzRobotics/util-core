#!/bin/sh
# csplit: differential tests against GNU csplit 9.7 (C locale). References: GNU
# manual "csplit invocation"; POSIX.1-2024 csplit. File names, contents (cksum)
# and printed byte counts must match, including after errors.
UTIL="csplit"
. "$(dirname "$0")/testlib.sh"
TREE_CONTENT=1
help_cmp
S='seq 1 20 > n20; seq 1 100 > n100; printf "a\nb\nc\n" > abc; printf "no newline at end" > nonl; printf "x1\ny1\nx2\ny2\nx3\ny3\nx4\n" > xy; : > empty; printf "line\n\nline\n\n\nline\n" > blanks; printf "foo\nbar\nfoo\nbaz\nfoo\nqux\n" > foo; printf "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n" > words; LC_ALL=C awk "BEGIN{srand(3); for(i=0;i<300;i++){ n=int(rand()*12); s=\"\"; for(j=0;j<n;j++) s=s sprintf(\"%c\",97+int(rand()*26)); print s}}" > rnd'

printf "\n[ Line numbers ]\n"
for n in 1 2 5 10 19 20 21 25; do
    run_tree "n20 $n"           "$S" n20 $n
    run_tree "n20 $n {1}"       "$S" n20 $n '{1}'
    run_tree "n20 $n {*}"       "$S" n20 $n '{*}'
    run_tree "n20 $n {3}"       "$S" n20 $n '{3}'
done
run_tree "multiple lines"       "$S" n20 3 8 12 15
run_tree "multiple + repeat"    "$S" n20 3 '{2}' 15
run_tree "same line warning"    "$S" n20 5 5
run_tree "decreasing"           "$S" n20 8 3
run_tree "zero"                 "$S" n20 0
run_tree "negative"             "$S" n20 -3
run_tree "not a number"         "$S" n20 abc
run_tree "plus number"          "$S" n20 +5
run_tree "huge"                 "$S" n20 99999999999999999999
run_tree "repeat past end"      "$S" n20 5 '{10}'
run_tree "repeat exact"         "$S" n20 5 '{3}'
run_tree "repeat exact+1"       "$S" n20 5 '{4}'
run_tree "line = last+1"        "$S" abc 4
run_tree "line = last"          "$S" abc 3
run_tree "line = last+1 -s"     "$S" -s abc 4
run_tree "abc 2"                "$S" abc 2
run_tree "nonl 1"               "$S" nonl 1
run_tree "nonl 2"               "$S" nonl 2
run_tree "empty 1"              "$S" empty 1
run_tree "empty /x/"            "$S" empty /x/

printf "\n[ Regular expressions ]\n"
for off in "" +0 +1 +2 -1 -2 +9 -9 +100 -100 +x -x +; do
    run_tree "/x/$off"          "$S" xy "/x/$off"
    run_tree "%x%$off"          "$S" xy "%x%$off"
    run_tree "/foo/$off {*}"    "$S" foo "/foo/$off" '{*}'
    run_tree "/foo/$off {1}"    "$S" foo "/foo/$off" '{1}'
    run_tree "%foo%$off {1}"    "$S" foo "%foo%$off" '{1}'
done
run_tree "regex no match"       "$S" xy /zzz/
run_tree "regex no match %"     "$S" xy %zzz%
run_tree "regex no match -k"    "$S" -k xy /zzz/
run_tree "regex no match -s"    "$S" -s xy /zzz/
run_tree "regex {*} no more"    "$S" xy '/y/' '{*}'
run_tree "regex repeat fails"   "$S" xy '/y/' '{9}'
run_tree "regex repeat fails -k" "$S" -k xy '/y/' '{9}'
run_tree "regex repeat fails %" "$S" xy '%y%' '{9}'
run_tree "anchors"              "$S" foo '/^foo$/' '{*}'
run_tree "anchor start"         "$S" words '/^t/' '{*}'
run_tree "anchor end"           "$S" words '/e$/' '{*}'
run_tree "dot star"             "$S" words '/o.*e/'
run_tree "bracket"              "$S" words '/[aeiou]x/'
run_tree "bre group"            "$S" words '/\(t\)\(h\)/'
run_tree "bre interval"         "$S" words '/e\{2\}/'
run_tree "star start"           "$S" words '/*/'
run_tree "empty regex"          "$S" words '//'
run_tree "bad regex ["          "$S" words '/[/'
run_tree "bad regex group"      "$S" words '/\(/'
run_tree "bad regex brace"      "$S" words '/a\{/'
run_tree "missing delimiter"    "$S" words '/abc'
run_tree "missing delimiter %"  "$S" words '%abc'
run_tree "delim in middle"      "$S" words '/a\/b/'
run_tree "delim last wins"      "$S" words '/e/+1'
run_tree "percent delim"        "$S" words '%e%+1'
run_tree "regex then number"    "$S" words '/three/' 8
run_tree "number then regex"    "$S" words 2 '/five/' 
run_tree "regex regex"          "$S" words '/three/' '/seven/'
run_tree "regex skip regex"     "$S" words '%three%' '/seven/'
run_tree "offset 0 repeat"      "$S" foo '/foo/+0' '{1}'
run_tree "negative offset first line" "$S" words '/one/-1'
run_tree "neg offset beyond"    "$S" words '/two/-5'
run_tree "pos offset beyond"    "$S" words '/nine/+5'
run_tree "blank lines"          "$S" blanks '/^$/' '{*}'
run_tree "blank lines +1"       "$S" blanks '/^$/+1' '{*}'
run_tree "blank lines -s z"     "$S" -z blanks '/^$/' '{*}'
run_tree "rnd split a"          "$S" rnd '/^a/' '{*}'
run_tree "rnd split lines"      "$S" rnd 10 '{*}'
run_tree "rnd mixed"            "$S" rnd 5 '/^b/' '/^c/+2' 100 '{3}'
run_tree "rnd neg"              "$S" rnd '/^z/-1' '{*}'

printf "\n[ Options ]\n"
for o in -s -q --silent --quiet -z -k "-z -s" "-f out" "-f out/ " "-f ." "-n 3" "-n 1" "-n 0" "-n 10" "-n x" "-n -1" "-b %03d" "-b %d" "-b %x" "-b %o" "-b %X" "-b %i" "-b %u" "-b .%02d.txt" "-b %'d" "-b %#x" "-b %#o" "-b %5d" "-b %-5d|" "-b %.3d" "-b %05.2d" "-b abc" "-b %" "-b %%d" "-b %d%d" "-b %s" "-b %c" "-b %5" "-b %ld" "-b %f" "-b %e" "--suppress-matched" "-s --suppress-matched"; do
    run_tree "[$o] lines"       "$S; mkdir out" $o n20 5 10 '{*}'
    run_tree "[$o] regex"       "$S; mkdir out" $o xy '/x/' '{*}'
done
run_tree "-f prefix"            "$S" -f pre- n20 10
run_tree "--prefix=P"           "$S" --prefix=P n20 10
run_tree "--digits=4"           "$S" --digits=4 n20 10
run_tree "--suffix-format"      "$S" --suffix-format=_%02d n20 10
run_tree "--keep-files"         "$S" --keep-files n20 5 30
run_tree "--elide-empty-files"  "$S" --elide-empty-files blanks '/^$/' '{*}'
run_tree "-z empty first piece" "$S" -z words '/one/' '{*}'
run_tree "-z %%"                "$S" -z words '%one%' '/four/'
run_tree "suppress matched"     "$S" --suppress-matched words '/three/' '/seven/'
run_tree "suppress matched n"   "$S" --suppress-matched n20 5 10
run_tree "suppress matched {*}" "$S" --suppress-matched foo '/foo/' '{*}'
run_tree "suppress matched neg" "$S" --suppress-matched words '/three/-1'
run_tree "suppress matched pos" "$S" --suppress-matched words '/three/+1'
run_tree "suppress lines past end" "$S" --suppress-matched abc 3
run_tree "no operands"          "$S"
run_tree "one operand"          "$S" n20
run_tree "missing input"        "$S" nofile 5
run_tree "directory input"      "$S; mkdir dd" dd 5
run_tree "bad option"           "$S" -x n20 5
run_tree "output exists dir"    "$S; mkdir xx00" n20 5
run_tree "output unwritable"    "$S; mkdir ro; chmod 555 ro" -f ro/p n20 5
run_tree "second unwritable"    "$S; : > xx01; chmod 000 xx01" n20 5 10
TREE_STDIN=n20 run_tree "stdin -"      "$S" - 5 10
TREE_STDIN=n20 run_tree "stdin -s"     "$S" -s - 5 '{*}'
run_tree "long abbrev"          "$S" --suppress n20 5
run_tree "ambiguous"            "$S" --s n20 5
run_tree "-- operand"           "$S" -- n20 5
run_tree "pattern like option"  "$S" n20 -5

printf "\n[ Large inputs ]\n"
LC_ALL=C awk 'BEGIN{for(i=1;i<=50000;i++) printf "line %d some text to make the file larger\n", i}' > /dev/null
BIG='LC_ALL=C awk "BEGIN{for(i=1;i<=20000;i++) printf \"line %d some text to make the file larger\\n\", i}" > big'
run_tree "big split 5000"       "$BIG" big 5000 10000 15000
run_tree "big regex {*}"        "$BIG" big '/0 some/' '{*}'
run_tree "big neg offset"       "$BIG" big '/^line 9000 /-100' 
run_tree "big -n 5 {*}"         "$BIG" -n 5 big 100 '{*}'
run_tree "big past end"         "$BIG" big 20001
print_summary
[ "$FAIL" -eq 0 ]
