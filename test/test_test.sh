#!/bin/sh
# test and [: differential tests against GNU test 9.7 (C locale). Besides the
# hand-written table, thousands of seeded random token sequences are compared
# (stdout, stderr and exit status), once as `test` and once as `[ ... ]`.
UTIL="test"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
echo hi > f; : > e; mkdir d; ln -s f lf; ln -s d ld; ln -s nowhere dang; mkfifo p; chmod 4755 f; chmod 2755 d; chmod 1777 e
touch -d '2020-01-01' old; touch -d '2030-01-01' new; chmod 000 noperm 2>/dev/null; echo x > ro; chmod 444 ro; echo x > wo; chmod 200 wo; echo x > xo; chmod 100 xo

both() { # description, args...  -> as test and as [ ... ]
    d="$1"; shift
    UTIL="test"; run_cmp "test $d" "$@"
    UTIL="["; run_cmp "[ $d ]" "$@" ]
    UTIL="test"
}

QUOTE='s/\([()<>]\)/"\1"/g'   # shell metacharacters used as plain arguments
printf "\n[ Zero to four arguments ]\n"
both "no args"
for a in x '' ' ' -n -z '!' '(' ')' -a -o = -eq -t -f --help --version -- -x '-' 0 '!=' '<' '>'; do both "1: '$a'" "$a"; done
for a in '-n x' '-n ""' '-z x' '-z ""' '-n -n' '-z -z' '! x' '! ""' '! !' '-f f' '-f e' '-f d' '-d d' '-d f' '-e f' '-e nofile' '-e lf' '-e dang' '-h lf' '-h f' '-L lf' '-L ld' '-L dang' '-s f' '-s e' '-s d' '-b f' '-c /dev/null' '-c f' '-p p' '-p f' '-S f' '-g d' '-g f' '-u f' '-u d' '-k e' '-k f' '-O f' '-G f' '-N f' '-r ro' '-r wo' '-w wo' '-w ro' '-x xo' '-x ro' '-x d' '-t 0' '-t 1' '-t 99' '-t x' '-v x' '-a f' '-o f' 'x y' '= x' 'x =' '-eq x' '-bogus x' '--help x'; do
    eval "both \"2: $a\" $(echo "$a" | sed "s/\"\"/''/g; $QUOTE")"
done
for a in 'a = a' 'a = b' 'a == a' 'a != a' 'a != b' 'a < b' 'b < a' 'a > b' 'b > a' 'a < a' '"" = ""' '"" != ""' 'a = ""' '1 -eq 1' '1 -eq 2' '1 -ne 2' '1 -lt 2' '2 -lt 1' '1 -le 1' '1 -gt 0' '1 -ge 2' '-1 -lt 0' '+1 -eq 1' '01 -eq 1' '" 1" -eq 1' '"1 " -eq 1' '1 -eq a' 'a -eq 1' 'a -eq b' '"" -eq 0' '1.5 -eq 1' '0x10 -eq 16' '1e3 -eq 1000' '99999999999999999999 -gt 1' '99999999999999999999 -eq 99999999999999999999' '-99999999999999999999 -lt 1' '340282366920938463463374607431768211456 -gt 340282366920938463463374607431768211455' 'f -nt e' 'e -nt f' 'old -nt new' 'new -nt old' 'old -ot new' 'new -ot old' 'f -ef f' 'f -ef lf' 'f -ef e' 'nofile -ef nofile' 'f -nt nofile' 'nofile -nt f' 'nofile -ot f' 'nofile -nt nofile' 'x -a y' 'x -a ""' '"" -a y' 'x -o y' '"" -o ""' '"" -o y' '! x y' '! = x' '! -f f' '! -n x' '( x )' '( "" )' '( -f )' '( ) )' ') x (' '-a = -a' '-o = -o' '! = !' '( = )' '-n = ""' 'x -b y' 'x y z' '-f -f -f' '! ! !' '( ( (' 'a -eq' '-eq -eq -eq' '= = =' '-a -a -a' '-o -o -o'; do
    eval "both \"3: $a\" $(echo "$a" | sed "$QUOTE")"
done
for a in 'a = a -a' 'a = a -o' '! a = b' '! a = a' '! -f f' '! ! x' '( -f f )' '( a = a )' '( a )' '( a ) -a' 'a -a b -a' 'a = a -a b' 'a = a -a ""' 'a = b -o c' 'a = b -o ""' '! a -a b' '-n a -a -n b' '-n a -a -z b' '-z a -o -z b' '( ( a ) )' '( a ) ( b )' 'a b c d' '1 -eq 1 -a 2' '1 -eq 1 -o' '-f f -a -d d' '-f f -o -d d' '-d f -o -d f' '-a -a -a -a' '-o -o -o -o' '! ! ! !' '( ( ( (' ') ) ) )' '( ( ) )' '( )' '( ) )' ; do
    eval "both \"4: $a\" $(echo "$a" | sed "$QUOTE")"
done

printf "\n[ More than four arguments ]\n"
for a in 'a = a -a b = b' 'a = a -a b = c' 'a = b -o c = c' 'a = b -o c = d' '! a = b -a c' '( a = a -o b = c ) -a d' '( a = b -o c = c ) -a ! ( d = d )' '-f f -a -f f -a -f f' '-f f -a -f f -a -f nofile' '-f f -o -f nofile -o -f nofile' '! -f f -o ! -f e' '( -f f -a ( -d d -o -e e ) )' '( ( ( x ) ) )' '( ( ( x ) ) ) -a y' '( ( ( x ) ) ) -a ""' '1 -lt 2 -a 3 -gt 2 -o 5 -eq 6' '1 -lt 2 -a ( 3 -gt 2 -o 5 -eq 6 )' 'a b c d e' 'a = a b c d' '! ! ! ! x' '! ! ! ! !' 'x -a y -a z -a w -a ""' '"" -o "" -o "" -o "" -o x' '( a ) ( b ) ( c )' '( a' 'a )' '( a b )' '( a = b' 'x -a' 'x -o' '! -a x' '-a -a x -a y' '-n -a -n -a -n' '-z -o -z -o -z' '-f -a -f -a -f' '= = = = =' '-a -o -a -o -a' '-f f -a' '-f f -a -d' '-f f -a ! -d' '-f f -a ! -d d' '( -f f -a -d' '-t 0 -o -t 1 -o -t 2'; do
    eval "both \"n: $a\" $(echo "$a" | sed "$QUOTE")"
done

printf "\n[ Program name in messages ]\n"
UTIL="["; run_cmp "[ --help alone"       --help
# "[ --version" prints GNU's banner; ours names core-utils instead (by design).
run_cmp "[ no close"           x
run_cmp "[ no close 2"                    -f f
run_cmp "[ ] only"                        ]
run_cmp "[ no args"
run_cmp "[ ] ] "                          ] ]
run_cmp "[ x ] ]"                         x ] ]
run_cmp "[ x y ]"                         x y ]
run_cmp "[ a -eq 1 ]"                     a -eq 1 ]
run_cmp "[ ( ]"                           '(' ]
run_cmp "[ --help ]"                      --help ]
run_cmp "[ --version ]"                   --version ]
UTIL="test"

printf "\n[ Random token sequences ]\n"
awk 'BEGIN {
    srand(71)
    n = split("a b \"\" -f -d -e -n -z ! ( ) -a -o = != < > 1 2 -eq -lt -ne f d e nofile old new -nt -ef -L -s x -t 0", pool, " ")
    for (i = 0; i < 2500; i++) {
        k = 1 + int(rand() * 7); line = ""
        for (j = 0; j < k; j++) { t = pool[1 + int(rand() * n)]; if (t == "(" || t == ")" || t == "!" || t == "<" || t == ">") t = "\"" t "\""; line = line " " t }
        printf "both \"rnd %d\"%s\n", i, line
    } }' > rnd_cases.sh
. ./rnd_cases.sh
cd /; rm -rf "$W"
print_summary
