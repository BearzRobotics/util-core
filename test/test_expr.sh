#!/bin/sh
# expr: differential tests against GNU expr 9.7 (C locale). References: GNU
# manual "expr invocation"; POSIX.1-2024 expr. Regex cases are limited to
# constructs where POSIX leftmost-longest and our leftmost-first agree.
UTIL="expr"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Arithmetic ]\n"
run_cmp "add" 1 + 2
run_cmp "sub" 10 - 3
run_cmp "mul" 3 '*' 4
run_cmp "div" 10 / 3
run_cmp "mod" 10 % 3
run_cmp "neg div" -7 / 2
run_cmp "neg mod" -7 % 3
run_cmp "div zero" 1 / 0
run_cmp "mod zero" 1 % 0
run_cmp "big add" 9223372036854775807 + 1
run_cmp "big mul" 9223372036854775807 '*' 9223372036854775807
run_cmp "huge" 123456789012345678901234567890 + 1
run_cmp "huge div" 123456789012345678901234567890 / 7
run_cmp "huge mod" 123456789012345678901234567890 % 7
run_cmp "min" -9223372036854775808 - 1
run_cmp "plus sign" +5 + 1
run_cmp "non-integer" a + 1
run_cmp "chain" 1 + 2 '*' 3
run_cmp "paren" '(' 1 + 2 ')' '*' 3
run_cmp "unbalanced" '(' 1 + 2
run_cmp "extra )" 1 ')'

printf "\n[ Comparison ]\n"
for op in = == != '<' '>' '<=' '>='; do
    run_cmp "1 $op 2" 1 "$op" 2
    run_cmp "2 $op 1" 2 "$op" 1
    run_cmp "a $op b" a "$op" b
    run_cmp "10 $op 9" 10 "$op" 9
    run_cmp "x $op x" x "$op" x
    run_cmp "-1 $op 1" -1 "$op" 1
done

printf "\n[ Logic ]\n"
run_cmp "or first" a '|' b
run_cmp "or zero" 0 '|' b
run_cmp "or empty" '' '|' 0
run_cmp "or both false" 0 '|' ''
run_cmp "and both" a '&' b
run_cmp "and zero" 0 '&' b
run_cmp "and empty" a '&' ''
run_cmp "and-or" 1 '&' 2 '|' 3
run_cmp "div zero short" 0 '&' 1 / 0
run_cmp "or short" 1 '|' 1 / 0

printf "\n[ String ops ]\n"
run_cmp "length" length hello
run_cmp "length empty" length ''
run_cmp "substr" substr hello 2 3
run_cmp "substr 0" substr hello 0 3
run_cmp "substr past" substr hello 4 10
run_cmp "substr neg" substr hello -1 3
run_cmp "substr bad" substr hello a 3
run_cmp "index" index hello l
run_cmp "index chars" index hello xyzo
run_cmp "index none" index hello z
run_cmp "match" match hello 'h.*l'
run_cmp "match group" match hello 'h\(.*\)l'
run_cmp "colon" hello : 'h.*'
run_cmp "colon group" hello : 'h\(.*\)o'
run_cmp "colon nomatch" hello : 'x'
run_cmp "colon nomatch group" hello : 'x\(y\)'
run_cmp "colon anchored" hello : 'ell'
run_cmp "colon star" 'a*b' : 'a*b'
run_cmp "colon bracket" hello : '[a-h]*'
run_cmp "colon interval" aaa : 'a\{2\}'
run_cmp "colon bad" hello : '\('
run_cmp "colon caret" hello : '^h'
run_cmp "colon number" 12345 : '[0-9]*'
run_cmp "+ quoting" + length
run_cmp "quote word" + match : a
run_cmp "dollar" 'a$' : 'a$'
run_cmp "dot count" abc : '.*'
run_cmp "empty group" abc : '\(x*\)'

printf "\n[ Syntax ]\n"
run_cmp "no args"
run_cmp "single" abc
run_cmp "single zero" 0
run_cmp "single empty" ''
run_cmp "missing operand" 1 +
run_cmp "extra" 1 2
run_cmp "unknown op" 1 @ 2
run_cmp "-- " -- 1
run_cmp "nested" '(' '(' 1 ')' ')'
run_cmp "paren string" '(' abc ')'
run_cmp "paren op" '(' + ')'

printf "\n[ Random arithmetic ]\n"
for s in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    set -- $(awk -v s=$s 'BEGIN{srand(s); a=int(rand()*2000000-1000000); b=int(rand()*2000)-1000; printf "%d %d", a, b}')
    for op in + - '*' / %; do
        run_cmp "rand $1 $op $2" "$1" "$op" "$2"
    done
done

print_summary
[ "$FAIL" -eq 0 ]
