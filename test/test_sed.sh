#!/bin/sh
# sed: differential tests against GNU sed 4.9 (C locale).
# References: POSIX sed, GNU sed manual. Known difference not tested: POSIX
# leftmost-longest alternation (regex-zig is leftmost-first).
UTIL="sed"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > nums
printf 'hello world\nfoo bar baz\nHello World\n\n  indented line\ttab\nlast line' > text
printf 'abc\nabcabc\naaa\nbab\n\nxyz\n' > abc
printf 'a,b,c\n1,2,3\nx,y,z\n' > csv
printf 'the quick brown fox\njumps over the lazy dog\nThe End\n' > prose
printf 'a\0b\0c\0' > nulld
printf 'x\n' > one; : > empty; printf 'no newline' > nonl; printf 'l1\nl2\nl3' > nonl3
printf 'tab\there\\back\001ctl\033esc\200hi\n' > weird
printf 'aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffgggggggggghhhhhhhhhhiiiiiiiiii\n' > longline
printf 'line1\nline2\n' > f1; printf 'line3\nline4\n' > f2
printf 's/o/0/\n' > scr1; printf '2d\n$a\\\nEND\n' > scr2; printf '#n\n/two/p\n' > scr3

sd() { d="$1"; f="$2"; shift 2; CMP_STDIN="$f" run_cmp "$d" "$@"; }

# ---- s command
for f in nums text abc prose csv; do
    sd "s/o/0/ $f" $f 's/o/0/'
    sd "s/o/0/g $f" $f 's/o/0/g'
    sd "s/o/0/2 $f" $f 's/o/0/2'
    sd "s/o/0/2g $f" $f 's/o/0/2g'
    sd "s///p -n $f" $f -n 's/e/E/p'
    sd "s///gp $f" $f -n 's/e/E/gp'
    sd "s/^/> / $f" $f 's/^/> /'
    sd 's/$/ </ '"$f" $f 's/$/ </'
    sd "s/x*/-/g $f" $f 's/x*/-/g'
    sd "s/a*/X/g $f" $f 's/a*/X/g'
    sd "s/.*/[&]/ $f" $f 's/.*/[&]/'
    sd "s/\\(.\\)\\(.\\)/\\2\\1/ $f" $f 's/\(.\)\(.\)/\2\1/'
    sd "s/\\(.\\)\\(.\\)/\\2\\1/g $f" $f 's/\(.\)\(.\)/\2\1/g'
    sd "-E s/(.)(.)/\\2\\1/g $f" $f -E 's/(.)(.)/\2\1/g'
    sd "-r s/[aeiou]/_/g $f" $f -r 's/[aeiou]/_/g'
    sd "s/[[:upper:]]/(&)/g $f" $f 's/[[:upper:]]/(&)/g'
    sd "s/[^a-z]//g $f" $f 's/[^a-z]//g'
    sd "s/\\bt/T/g $f" $f 's/\bt/T/g'
    sd "s/\\<./\\u&/g $f" $f 's/\<./\u&/g'
    sd "s/\\w\\+/<&>/g $f" $f 's/\w\+/<&>/g'
    sd "s/\\s\\+/ /g $f" $f 's/\s\+/ /g'
    sd "s/./\\U&/ $f" $f 's/./\U&/'
    sd "s/.*/\\U&/ $f" $f 's/.*/\U&/'
    sd "s/.*/\\L&/ $f" $f 's/.*/\L&/'
    sd "s/\\(.\\)\\(.*\\)/\\U\\1\\E\\2/ $f" $f 's/\(.\)\(.*\)/\U\1\E\2/'
    sd "s/\\(.\\)\\(.*\\)/\\l\\1\\U\\2/ $f" $f 's/\(.\)\(.*\)/\l\1\U\2/'
    sd "s|o|/|g $f" $f 's|o|/|g'
    sd "s,o,\\,,g $f" $f 's,o,\,,g'
    sd "s/o/\\n/g $f" $f 's/o/\n/g'
    sd "s/o/\\t/g $f" $f 's/o/\t/g'
    sd "s/o/&&/g $f" $f 's/o/&&/g'
    sd "s/o/\\&/g $f" $f 's/o/\&/g'
    sd "s/O/x/I $f" $f 's/O/x/I'
    sd "s/O/x/gi $f" $f 's/O/x/gi'
    sd "s/e\\{2\\}/EE/ $f" $f 's/e\{2\}/EE/'
    sd "-E s/e{1,2}/E/g $f" $f -E 's/e{1,2}/E/g'
    sd "s/a\\|e/X/g $f" $f 's/a\|e/X/g'
    sd "-E s/a|e/X/g $f" $f -E 's/a|e/X/g'
    sd "s/o\\+/0/g $f" $f 's/o\+/0/g'
    sd "s/o\\?/0/g $f" $f 's/o\?/0/g'
    sd "-E s/(o)+/0/g $f" $f -E 's/(o)+/0/g'
    sd "s/\\(a\\)\\1/DD/ $f" $f 's/\(a\)\1/DD/'
    sd "-E s/(a)\\1/DD/ $f" $f -E 's/(a)\1/DD/'
    sd "s/b*/X/3 $f" $f 's/b*/X/3'
    sd "s/b*/X/2g $f" $f 's/b*/X/2g'
    sd "s/\\n//  $f" $f 's/\n//'
    sd "s/o/0/;s/e/3/ $f" $f 's/o/0/;s/e/3/'
    sd "s/o/0/w /dev/stdout $f" $f 's/o/0/w /dev/stdout'
    sd "-n s/o/0/pw /dev/stdout $f" $f -n 's/o/0/pw /dev/stdout'
    sd "s//X/ no prev $f" $f 's//X/'
    sd "/o/s//0/g $f" $f '/o/s//0/g'
    sd "s/e/E/;ta;s/$/ -/;:a $f" $f 's/e/E/;ta;s/$/ -/;:a'
    sd "s/e/E/;Ta;s/$/ +/;:a $f" $f 's/e/E/;Ta;s/$/ +/;:a'
done
sd 's/a/b/M multiline' text 'N;N;s/^h/H/Mg'
sd 's/$/E/Mg multi' nums 'N;s/$/E/Mg'
sd 's/^/S/Mg multi' nums 'N;N;s/^/S/Mg'
sd 's/\`a/X/' abc 's/\`a/X/'
sd "s/c\\'/X/" abc "s/c\\'/X/"
sd 'N s/.*/x/ dotall' nums 'N;s/.*/x/'
sd 'empty regex flags err' nums 's//x/I'
sd 's ref too big' nums 's/\(a\)/\2/'
sd 's ERE ref too big' nums -E 's/(a)/\2/'
sd 's/o/\x41/' nums 's/o/\x41/'
sd 's/o/\o101/' nums 's/o/\o101/'
sd 's/o/\d65/' nums 's/o/\d65/'
sd 's/\x6f/0/' nums 's/\x6f/0/'
sd 's/o/\cA/' nums 's/o/\cA/'
sd 's/o/\//' nums 's/o/\//'
sd 's newline in repl' nums 's/o/a\
b/'
sd 's flags g g' nums 's/o/0/gg'
sd 's flags p p' nums 's/o/0/pp'
sd 's flags 0' nums 's/o/0/0'
sd 's flags 2 3' nums 's/o/0/2 3'
sd 's unknown flag' nums 's/o/0/z'
sd 's unterminated 1' nums 's/o'
sd 's unterminated 2' nums 's/o/0'
sd 's close brace' nums '{s/o/0/}'
sd 's flags then ;' nums 's/o/0/g;s/e/3/'
sd 's w file' nums -n 's/o/0/w out.txt'
sd 's bad regex [' nums 's/[/x/'
sd 's bad regex \(' nums 's/\(/x/'
sd 's bad regex \)' nums 's/\)/x/'
sd 's bad regex *' nums 's/*a/x/'
sd 's bad regex \{' nums 's/a\{1/x/'
sd 'ERE bad (' nums -E 's/(/x/'
sd 'ERE bad ?' nums -E 's/?/x/'
sd 'ERE a{1,2}{3}' nums -E 's/a{1,2}{3}/x/'
sd 's/.../\n/' nums 's/e$/\n/'

# ---- addresses and ranges
for f in nums text; do
    for a in 1 3 '$' '1,3' '2,$' '$!' '3,1' '2,2' '0~3' '1~3' '2~0' '2,~4' '3,+2' '/o/' '/o/,/e/' '/e/,+1' '/o/,3' '3,/e/' '/two/,/six/' '\,o,' '\,o,I' '/O/I' '/x/,/y/' '/one/,/one/' '0,/one/' '1,/one/' '0,/e/' '/e/,~3' '/t/!' '1!' '$!' '2,4!' '/e/,/e/' '2,/t/' '$,1' '5,2'; do
        case $a in *'!') a="${a}"; sd "-n ${a}p $f" $f -n "${a}p";; *) sd "-n ${a}p $f" $f -n "${a}p"; sd "${a}d $f" $f "${a}d";; esac
    done
    sd "-n '2!p' $f" $f -n '2!p'
    sd "-n '2,4!p' $f" $f -n '2,4!p'
    sd "-n '2 ! p' $f" $f -n '2 ! p'
    sd "-n '2!!p' $f" $f -n '2!!p'
    sd "= $f" $f -n '$='
    sd "-n 2{p} $f" $f -n '2{p}'
    sd "-n 2{p;p} $f" $f -n '2{p;p}'
    sd "-n /e/{/o/p} $f" $f -n '/e/{/o/p}'
    sd "nested ranges $f" $f -n '2,8{3,5{p}}'
    sd "nested ranges ! $f" $f -n '2,8{3,5!p}'
    sd "2,4{d} $f" $f '2,4{d}'
    sd "N ranges $f" $f -n '2,4{N;p}'
    sd "N then range $f" $f -n 'N;2,3p'
    sd "n then range $f" $f -n 'n;2,3p'
    sd "-s \$p $f" $f -s -n '$p' 
    sd "range end passed by N $f" $f -n '2,3{N;N;N;p}'
    sd "addr regex M $f" $f -n '/^t/Mp'
done
sd 'addr 0 bad' nums '0p'
sd 'addr 0,5' nums '0,5p'
sd 'addr 0,/x/' nums -n '0,/x/p'
sd 'addr +N first' nums '+1p'
sd 'addr ~N first' nums '~1p'
sd 'addr 1,' nums '1,p'
sd 'addr ,1' nums ',1p'
sd 'addr missing cmd' nums '1'
sd 'addr missing cmd 2' nums '1,2'
sd 'addr bad regex' nums '/o/,/[/p'
sd 'addr unterminated' nums '/o'
sd 'addr \\ delim' nums -n '\xoxp'
sd 'addr 2,+0' nums -n '2,+0p'
sd 'addr 2,~0' nums -n '2,~0p'
sd 'addr 4,~4' nums -n '4,~4p'
sd 'addr 5,~4' nums -n '5,~4p'
sd 'addr 0~0' nums -n '0~0p'
sd 'addr first~0' nums -n '3~0p'
sd 'addr 1,3 on two files' nums -n '1,3p' nums
sd 'addr multi files $' nums -n '$p' nums one
sd 'addr multi files line' nums -n '12p' nums one
sd 'addr -s multi' nums -s -n '1p;$p' nums one
sd 'addr 0,/re/ -s' nums -s -n '0,/o/p' nums nums
sd 'addr 2,4 -s' nums -s -n '2,4p' nums nums
sd 'addr 2,4 no -s' nums -n '2,4p' nums nums

# ---- other commands, per input
for f in nums text abc nonl nonl3 empty one; do
    sd "p $f" $f p
    sd "-n p $f" $f -n p
    sd "d $f" $f d
    sd "= $f" $f =
    sd "-n = $f" $f -n =
    sd "l $f" $f -n l
    sd "l 5 $f" $f -n 'l 5'
    sd "l 1 $f" $f -n 'l 1'
    sd "l 0 $f" $f -n 'l 0'
    sd "-l 4 l $f" $f -l 4 -n l
    sd "-l 1 l $f" $f -l 1 -n l
    sd "G $f" $f G
    sd "H;x $f" $f 'H;x'
    sd "H;\$!d;x $f" $f 'H;$!d;x'
    sd "h;G $f" $f 'h;G'
    sd "x $f" $f x
    sd "x;G $f" $f 'x;G'
    sd "g $f" $f g
    sd "1h;2g $f" $f '1h;2g'
    sd "1!G;h;\$!d  (tac) $f" $f -n '1!G;h;$p'
    sd "N $f" $f N
    sd "N;P;D $f" $f 'N;P;D'
    sd "\$!N;P;D $f" $f '$!N;P;D'
    sd "\$!N;s/\\n/ / $f" $f '$!N;s/\n/ /'
    sd "N;N $f" $f 'N;N'
    sd "n;d $f" $f 'n;d'
    sd "n $f" $f n
    sd "-n n;p $f" $f -n 'n;p'
    sd "n;n;p $f" $f -n 'n;n;p'
    sd "P $f" $f -n P
    sd "D $f" $f D
    sd "z $f" $f z
    sd "z;s/^\$/E/ $f" $f 'z;s/^$/E/'
    sd "y/abc/xyz/ $f" $f 'y/abc/xyz/'
    sd "y/abc/\\n\\t\\\\/ $f" $f 'y/abc/\n\t\\/'
    sd "y,a\\,b,x\\,y, $f" $f 'y,a\,b,x\,y,'
    sd "y/a/b/;y/b/c/ $f" $f 'y/a/b/;y/b/c/'
    sd "q $f" $f q
    sd "2q $f" $f 2q
    sd "q5 $f" $f q5
    sd "q 5 $f" $f 'q 5'
    sd "Q $f" $f Q
    sd "2Q $f" $f 2Q
    sd "Q7 $f" $f Q7
    sd "2q;s/o/0/ $f" $f '2q;s/o/0/'
    sd "-n 2q $f" $f -n 2q
    sd "a foo $f" $f 'a foo'
    sd "a\\ foo $f" $f 'a\ foo'
    sd "a\\\\nfoo $f" $f 'a\
foo'
    sd "a two lines $f" $f 'a\
foo\
bar'
    sd "2a foo $f" $f '2a foo'
    sd "\$a foo $f" $f '$a foo'
    sd "i foo $f" $f 'i foo'
    sd "2i\\ foo $f" $f '2i\
foo'
    sd "\$i foo $f" $f '$i foo'
    sd "c foo $f" $f 'c foo'
    sd "2c foo $f" $f '2c foo'
    sd "2,3c foo $f" $f '2,3c foo'
    sd "2,3!c foo $f" $f '2,3!c foo'
    sd "\$c foo $f" $f '$c foo'
    sd "a;i;c $f" $f -e '1a A' -e '1i I' -e '1c C'
    sd "a then d $f" $f -e 'a foo' -e d
    sd "a then n $f" $f -e 'a foo' -e n
    sd "a then N $f" $f -e 'a foo' -e N
    sd "a then q $f" $f -e 'a foo' -e q
    sd "a leading space $f" $f 'a   foo bar'
    sd "a backslash t $f" $f 'a foo\tbar'
    sd "a backslash n $f" $f 'a foo\nbar'
    sd "a trailing bs $f" $f 'a foo\\'
    sd "a empty $f" $f 'a'
    sd "a \\ only $f" $f 'a\'
    sd "a -e cont $f" $f -e 'a\' -e 'text'
    sd "a } $f" $f '1{a foo
}'
    sd "i multi -e $f" $f -e 'i\' -e 'one\' -e 'two'
    sd "r f1 $f" $f 'r f1'
    sd "2r f1 $f" $f '2r f1'
    sd "\$r f1 $f" $f '$r f1'
    sd "r missing $f" $f 'r nosuch'
    sd "r no name $f" $f 'r'
    sd "R f1 $f" $f 'R f1'
    sd "R f1 f2 $f" $f -e 'R f1' -e 'R f2'
    sd "w /dev/stdout $f" $f 'w /dev/stdout'
    sd "-n w /dev/stdout $f" $f -n 'w /dev/stdout'
    sd "W /dev/stdout $f" $f -n 'N;W /dev/stdout'
    sd "w out.txt $f" $f -n 'w out.txt'
    sd "b $f" $f b
    sd "b end $f" $f 'b end;s/o/0/;:end'
    sd "b label $f" $f ':a;s/o/0/;ta'
    sd "loop $f" $f ':a;s/^\(.\{1,10\}\)$/ \1/;ta'
    sd "t no flag $f" $f 't;s/o/0/'
    sd "t after reset $f" $f 's/o/0/;n;t x;s/$/-/;:x'
    sd "T $f" $f 'T;s/^/>/'
    sd "b skip $f" $f '2b;s/^/>/'
    sd "b range $f" $f '2,3b;s/^/>/'
    sd "ba undefined $f" $f 'ba'
    sd "label dup $f" $f ':a;:a'
    sd "label empty $f" $f ':'
    sd "{} empty $f" $f '{}'
    sd "{;} $f" $f '{;}'
    sd "{p} $f" $f -n '{p}'
    sd "{p;} $f" $f -n '{p;}'
    sd "}{ $f" $f '}'
    sd "{ unmatched $f" $f '{p'
    sd "p;p $f" $f -n 'p;p'
    sd "p p $f" $f -n 'p p'
    sd "p} $f" $f 'p}'
    sd "pp $f" $f pp
    sd "comment $f" $f '# comment
p'
    sd "p # c $f" $f -n 'p # c'
    sd "p;# c $f" $f -n 'p;# c'
    sd "1# c $f" $f '1# c'
    sd "#n first $f" $f '#n
p'
    sd "#n -e $f" $f -e '#n' -e p
    sd "#no $f" $f '#no
p'
    sd "unknown cmd $f" $f k
    sd "unknown cmd 2 $f" $f 'p;k'
    sd "= extra $f" $f '=x'
    sd "v $f" $f 'v;p'
    sd "v 4.2 $f" $f 'v 4.2'
    sd "v 9.9 $f" $f 'v 9.9'
    sd "F $f" $f F
    sd "e echo $f" $f '1e echo hi'
    sd "s///e $f" $f '1s/.*/echo X/e'
    sd "e no arg $f" $f -n '1{s/.*/echo X/;e
p}'
    sd "-s F $f" $f -s F
done

# ---- options
sd '-n' nums -n
sd 'no script' nums
sd '-e -e' nums -e 2d -e 4d
sd '-e a -e b multi cmd' nums -n -e '/o/{' -e p -e '}'
sd '-f script' nums -f scr1
sd '-f script 2' nums -f scr2
sd '-f script #n' nums -f scr3
sd '--file=' nums --file=scr1
sd '-f missing' nums -f nosuch
sd '-f and -e' nums -f scr1 -e 3d
sd '-e and -f' nums -e 3d -f scr1
sd '-f - stdin' nums -f - nums
sd '--expression=' nums --expression=3d
sd '--quiet' nums --quiet 3p
sd '--silent' nums --silent 3p
sd '-ne' nums -ne 3p
sd '-n -e' nums -n -e 3p
sd '-E' nums -E 's/(o)/[\1]/'
sd '-r' nums -r 's/(o)/[\1]/'
sd '--regexp-extended' nums --regexp-extended 's/(o)/[\1]/'
sd '-z' nulld -z 's/^/>/'
sd '-z N' nulld -z 'N;s/\x00/+/'
sd '-z =' nulld -z =
sd '-z $!d' nulld -z '$!d'
sd '-z G' nulld -z G
sd '-z l' nulld -z -n l
sd '-z a' nulld -z 'a foo'
sd '--null-data' nulld --null-data 's/^/>/'
sd '-z s/\n/' nums -z 's/\n/,/g'
sd '-s' nums -s -n '$p' nums one
sd '--separate' nums --separate -n '1p' nums one
sd '-u' nums -u 2p
sd '--unbuffered' nums --unbuffered 2p
sd '-b' nums -b 2p
sd '--binary' nums --binary 2p
sd '--posix' nums --posix 2p
sd '--posix N' nums --posix N
sd '--posix n at end' one --posix n
sd '--sandbox ok' nums --sandbox 2p
sd '--sandbox r' nums --sandbox 'r f1'
sd '--sandbox w' nums --sandbox 'w x'
sd '--sandbox e' nums --sandbox 'e echo'
sd '--sandbox s///e' nums --sandbox 's/a/b/e'
sd '--sandbox s///w' nums --sandbox 's/a/b/w x'
sd '--follow-symlinks' nums --follow-symlinks 2p
sd '-l bad' nums -l x p
sd '-l 5' nums -l 5 -n l
sd '--line-length=5' nums --line-length=5 -n l
sd 'bad option' nums -Z
sd 'bad long option' nums --bogus
sd 'ambiguous long' nums --s p
sd '-i no file' nums -i p
sd '--' nums -- 2d
sd '-n -- ' nums -n -- 2p
sd 'files missing' nums p nosuch
sd 'files missing first' nums p nosuch nums
sd 'file is dir' nums p .
sd 'file - ' nums p -
sd 'two files' nums p f1 f2
sd 'two files nonl' nums p nonl f1
sd 'two files nonl last' nums p f1 nonl
sd 'two files nonl both' nums p nonl nonl3
sd 'two files nonl -s' nums -s p nonl f1
sd '3 files $' nums -n '$p' f1 f2 empty
sd 'empty last file $' nums -n '$p' f1 empty
sd 'missing last file $' nums -n '$p' f1 nosuch
sd 'weird l' weird -n l
sd 'weird l 10' weird -n 'l 10'
sd 'weird p' weird p
sd 'longline l' longline -n l
sd 'longline l 20' longline -n 'l 20'
sd 'longline -l 30' longline -l 30 -n l
sd 'longline l 2' longline -n 'l 2'
sd 'longline s' longline 's/\(.\)\1*/[\1]/g'
sd 'longline -E s' longline -E 's/(.)\1{4}/<\1>/g'
sd 'q exit code' nums 3q42
sd 'Q exit code' nums 3Q42
sd 'q exit 300' nums 3q300
sd 'q with append' nums -e '1a foo' -e 1q
sd 'q with r' nums -e '1r f1' -e 1q
sd 'Q with append' nums -e '1a foo' -e 1Q
sd 'D no newline' nums 'D'
sd 'D loop' nums 'N;N;P;D'
sd 'D with N at EOF' nums '$!N;$!D'
sd 'x;$G' nums 'x;$G'
sd 'tac' nums -n '1!G;h;$p'
sd 'rev' nums '/\n/!G;s/\(.\)\(.*\n\)/&\2\1/;//D;s/.//'
sd 'cat -s' text '/./,/^$/!d'
sd 'join lines' text -e ':a' -e '$!N;s/\n/ /;ta'
sd 'number lines' nums = 
sd 'number lines 2' nums -n '$='
sd 'wc -l' text -n '$='
sd 'head' nums 3q
sd 'tail 3' nums -e ':a' -e '$q;N;4,$D;ba'
sd 'uniq' abc '$!N;/^\(.*\)\n\1$/!P;D'
sd 'every other' nums 'n;d'
sd 'dup' nums p
sd 'sub ! cmd' nums '/o/!s/e/E/'
sd 'swap' csv 's/\([^,]*\),\([^,]*\),\(.*\)/\3,\2,\1/'
sd 'trim' text 's/^[ \t]*//;s/[ \t]*$//'
sd 'html' prose 's/<[^>]*>//g'
sd 'strip comments' prose 's/#.*//;/^$/d'
sd 'blank del' text '/^$/d'
sd 'blank del2' text '/^[[:space:]]*$/d'
sd 'last line' nonl3 -n '$p'
sd 'change nonl last' nonl3 '$c X'
sd 'append nonl last' nonl3 '$a X'
sd 'insert nonl last' nonl3 '$i X'
sd 'r nonl last' nonl3 '$r f1'
sd 'r nonl file' nums '2r nonl'
sd 'r nonl file 2' nums -e '2r nonl' -e '3a X'
sd 'G nonl' nonl3 G
sd 'p nonl' nonl3 p
sd 'N nonl' nonl3 N
sd 'w nonl' nonl3 -n 'w /dev/stdout'
sd 'x nonl' nonl3 x
sd 'x;p nonl' nonl3 -n 'x;p;x;p'
sd 'h;g nonl' nonl3 'h;g'
sd 'D nonl' nonl3 'N;D'
sd 'P nonl' nonl3 -n 'N;P'
sd 'p \$ nonl' nonl3 '$p'
sd 'i before nonl' nonl3 'i X'
sd '= nonl' nonl3 -n '$='
sd 'l nonl' nonl3 -n l
sd 'two files p nonl' nums -n p nonl3 nonl3

# ---- in-place
SET='printf "a\nb\nc\n" > f; printf "x\ny\n" > g; printf "no nl" > h; mkdir d; printf "q\n" > d/k'
run_tree_t() { d="$1"; s="$2"; shift 2; TREE_CONTENT=1 run_tree "$d" "$s" "$@"; }
run_tree_t '-i s' "$SET" -i 's/a/A/' f
run_tree_t '-i two files' "$SET" -i 's/[ax]/Z/' f g
run_tree_t '-i nonl' "$SET" -i 's/n/N/' h
run_tree_t '-i nonl + other' "$SET" -i 's/n/N/' h f
run_tree_t '-i -n p' "$SET" -n -i '1p' f
run_tree_t '-i d' "$SET" -i '2d' f
run_tree_t '-i $' "$SET" -i '$d' f g
run_tree_t '-i 1 each file' "$SET" -i '1d' f g
run_tree_t '-i.bak' "$SET" -i.bak 's/a/A/' f
run_tree_t '-i.bak two' "$SET" -i.bak 's/[ax]/A/' f g
run_tree_t '-ibak' "$SET" -ibak 's/a/A/' f
run_tree_t '-i bak/*' "$SET" -i'bak_*' 's/a/A/' f
run_tree_t '-i *.orig' "$SET" -i'*.orig' 's/a/A/' f
run_tree_t '-i d/*' "$SET" -i'd/*' 's/a/A/' f
run_tree_t '-i sub dir file' "$SET" -i 's/q/Q/' d/k
run_tree_t '-i sub dir file bak' "$SET" -i.bak 's/q/Q/' d/k
run_tree_t '--in-place' "$SET" --in-place 's/a/A/' f
run_tree_t '--in-place=.b' "$SET" --in-place=.b 's/a/A/' f
run_tree_t '-i missing' "$SET" -i 's/a/A/' nosuch
run_tree_t '-i missing + ok' "$SET" -i 's/a/A/' nosuch f
run_tree_t '-i dir' "$SET" -i 's/a/A/' d
run_tree_t '-i w file' "$SET" -i 'w out' f
run_tree_t '-i w /dev/stdout' "$SET" -i 'w /dev/stdout' f
run_tree_t '-i p' "$SET" -i p f
run_tree_t '-i =' "$SET" -i = f
run_tree_t '-i F' "$SET" -i F f g
run_tree_t '-i q' "$SET" -i 2q f
run_tree_t '-i Q' "$SET" -i 2Q f
run_tree_t '-i a i c' "$SET" -i -e '1i I' -e '2a A' -e '3c C' f
run_tree_t '-i r' "$SET" -i '2r g' f
run_tree_t '-i N' "$SET" -i 'N;s/\n/+/' f
run_tree_t '-i G' "$SET" -i G f
run_tree_t '-i y' "$SET" -i 'y/abc/xyz/' f
run_tree_t '-i empty file' "$SET" -i 's/a/A/' empty_nosuch
run_tree_t '-i stdin' "$SET" -i 's/a/A/'
run_tree_t '-i chmod kept' "$SET; chmod 640 f" -i 's/a/A/' f
run_tree_t '-i chmod 755 kept' "$SET; chmod 755 f" -i 's/a/A/' f
run_tree_t '-i symlink' "$SET; ln -s f lnk" -i 's/a/A/' lnk
run_tree_t '-i --follow-symlinks' "$SET; ln -s f lnk" -i --follow-symlinks 's/a/A/' lnk
run_tree_t '-s -n' "$SET" -s -n '$p' f g
run_tree_t '-n -i -e' "$SET" -n -i -e '2p' f
run_tree_t '-i -E' "$SET" -i -E 's/(a)/[\1]/' f
run_tree_t '-ni' "$SET" -ni 2p f
run_tree_t '-in (suffix n)' "$SET" -in 2p f
run_tree_t '-i -s' "$SET" -i -s 1d f g
run_tree_t 'w new file' "$SET" -n 'w new' f
run_tree_t 'w two cmds same file' "$SET" -n -e '1w new' -e '3w new' f
run_tree_t 'w + s///w same file' "$SET" -n -e '1w new' -e 's/c/C/w new' f
run_tree_t 'w to dir' "$SET" -n 'w d' f
run_tree_t 'w to nosuchdir' "$SET" -n 'w nodir/x' f
run_tree_t 'w /dev/stderr' "$SET" 'w /dev/stderr' f
run_tree_t 'r then w' "$SET" -e 'r g' -e 'w new' f
run_tree_t 'W' "$SET" -n 'N;W new' f
run_tree_t 'w no name' "$SET" 'w' f

# ---- UTF-8 locale (C.UTF-8) and alternation
printf 'héllo wörld ñ ÀÉÎ 日本語 😀 abc_1\nstraße İ\n' > u8
printf '\377\376 abc \303 é\n' > u8bad
printf 'abcd abcd foobarbaz ababc\n' > altin
for sc in 's/./X/g' 's/.*/\U&/' 's/.*/\L&/' 's/\(.\)\(.\)/\2\1/g' 'y/éö日/EO月/' 'y/àé/ae/' 'y/a/é/' 'y/é/ab/' \
    's/[[:alpha:]]*/<&>/g' 's/\w\+/<&>/g' 's/\W\+/_/g' 's/[^a-z]/_/g' 's/[é-ö]/_/g' 's/[a-é]/_/g' 's/[[:upper:]]/_/g' \
    's/[[:lower:]]\+/_/g' 's/[[:punct:]]/_/g' 's/[[:space:]]/_/g' 's/[[:alnum:]_]*/[&]/g' 's/[[:print:]]/p/g' \
    's/[[:cntrl:]]/c/g' 's/[^é]/_/g' 's/[éñ]/_/g' 's/[[:upper:]é]/_/g' 's/[^[:space:]]\+/<&>/g' 's/[^[:alpha:]]/_/g' \
    's/é*/-/g' 's/x*/-/g' 's/ä*/Z/g' 's/é\+/-/' 's/É/x/I' 's/[É]/x/Ig' 's/日本/中/' 's/./&&/2' 's/\s/_/g' \
    's/.\{3\}/[&]/g' 's/\(.\)\1/D/' 's/\u./&/g' 's/\(.\)/\u\1/g' 's/\b./B/g' 's/\B./B/g' 's/\</[/g;s/\>/]/g' \
    's/\w*\b/<&>/' 's/\w\+\b/X/' 's/ÉL*/X/I' 's/.$/X/' 's/^./X/' 's/ß/SS/' 's/[[:alpha:]]/./2' 's/./&/3' \
    's/\xc3\xa9/E/' 's/\xc3/E/' 's/[\xc3]/E/' 's/[\x61-\x63]/E/g' '/é/d' '/É/Id' 'l' 'N;s/\n/+/' 's/\(.*\) \(.*\)/\U\1\E \2/' \
    's/a\|ab\|é/X/g' 's/\(é\)\+/<&>/' 's/é\{2\}/X/'; do
    CMP_LOCALE=C.UTF-8 sd "utf8 $sc (u8)" u8 -n "$sc;p"
    CMP_LOCALE=C.UTF-8 sd "utf8 $sc (u8) default" u8 "$sc"
done
for sc in 's/./X/g' 's/[^a]/X/g' 's/.*/\U&/' 'l' 's/\xc3/E/' 's/a*/-/g' 's/[[:alpha:]]/./2'; do
    CMP_LOCALE=C.UTF-8 sd "utf8 invalid bytes $sc" u8bad "$sc"
done
CMP_LOCALE=C.UTF-8 sd 'utf8 -E (é|ö)' u8 -E 's/(é|ö)/[\1]/g'
CMP_LOCALE=C.UTF-8 sd 'utf8 -n /alpha/p' u8 -n '/^[[:alpha:]]*$/p'
CMP_LOCALE=C.UTF-8 sd 'utf8 LANG only' u8 's/./X/g'
for sc in 's/a|ab/X/' 's/(a|ab)(c|bcd)/[&]/' 's/x*|y/Z/g' 's/(foo|foobar)baz/<&>/' 's/(a|ab)*c/<&>/' 's/(a|ab)(c|bcd)(d*)/[\1|\2|\3]/' \
    's/(ab|a)(bc|c)?/[\1|\2]/' 's/(a*)(ab)*(b*)/[\1|\2|\3]/' 's/(wee|week)(knights|night)/[\1|\2]/' 's/(a|b)*/[\1]/'; do
    sd "alt -E $sc" altin -E "$sc"
done
sd 'alt BRE' altin 's/a\|ab/X/'
sd 'alt BRE nested' altin 's/\(a\|ab\)\(c\|bcd\)/[&]/'
sd 'quant stack ERE a**' altin -E 's/a**/X/'
sd 'quant stack ERE a+?' altin -E 's/a+?/X/'
sd 'quant stack ERE a{1,2}{2}' altin -E 's/a{1,2}{2}/X/'
sd 'quant {,2}' altin -E 's/a{,2}/X/'
sd 'ERE leading ?' altin -E 's/?/x/'
sd 'ERE leading *' altin -E 's/*a/x/'
sd 'ERE leading +' altin -E 's/+a/x/'
sd 'ERE unmatched (' altin -E 's/(/x/'
sd 'ERE unmatched )' altin -E 's/)/x/'
sd 'BRE a**' altin 's/a**/x/'

# ---- --debug (program listing and execution trace)
printf 'a/b\n' > dab; printf 'tab\there\\x\001\n' > dweird; printf 'zz\n' > rf.txt
DBGCASES='p
-n p
1,2p
2!p
$!N
N;P;D
$!N;P;D
1h;2G;3x
s/o/0/
s/o/0/g
s/q/0/
s/o/0/2p
s,a/,[&],
s/\(o\)\(n\)/\2\1/
-E s/(o)|(t)/[\1\2]/
y/ot/OT/
2{p;s/t/T/;}
2!{p}
/o/{/e/p}
/two/I,/zz/Mp
0,/o/p
1~2p
2,~2p
2,+1p
$p
l
l 5
=
F
d
2d
D
G
g
h
H
x
z
n
N
q
2q
2q3
Q
a foo
i bar
c baz
2c baz
1,2c baz
r rf.txt
R rf.txt
w /dev/null
W /dev/null
b
bx;p;:x
s/o/0/;t;p
s/o/0/;T;p
:a;N;$!ba;s/\n/,/g
$!{N;P;D}
1!G;h;$!d
y/o/0/;2!d'
printf '%s\n' "$DBGCASES" > dbgcases
while IFS= read -r line; do
    opts=""; sc="$line"
    case "$line" in -n\ *) opts="-n"; sc="${line#-n }";; -E\ *) opts="-E"; sc="${line#-E }";; esac
    for f in nums dab dweird nonl3; do
        sd "--debug $line ($f)" $f --debug $opts "$sc"
    done
done < dbgcases
sd '--debug -s two files' nums --debug -s -n '$p' f1 f2
sd '--debug stdin file' nums --debug p -
sd '--debug -z' nulld --debug -z p
sd '--debug missing file' nums --debug p nosuch

help_text_cmp() {
    exp=$(PATH="/usr/bin" LC_ALL=C sed --help | sed 's#/usr/bin/sed#sed#')
    act=$(ours --help | sed 's#^Usage: [^ ]*#Usage: sed#')
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); printf "PASS --help text\n"
    else FAIL=$((FAIL + 1)); printf "FAIL --help text\n"; fi
}
help_text_cmp
cd /; print_summary
