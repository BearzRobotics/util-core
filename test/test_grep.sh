#!/bin/sh
# grep: differential tests against GNU grep 3.12 (C locale unless noted).
UTIL="grep"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
printf 'one\ntwo\nthree\nfour two\nfive\nsix\nseven\neight\nnine\nten\n' > nums
printf 'hello world\nfoo bar baz\nHello World\n\n  indented line\ttab\nlast line' > text
printf 'abc\nabcabc\naaa\nbab\n\nxyz\nfoo.bar\nfoo-bar\nfoo_bar\n(paren)\n[brack]\na+b\na|b\nback\\slash\n' > abc
printf 'the quick brown fox\njumps over the lazy dog\nThe End\nfoobar foo barfoo\n' > prose
printf 'a,b,c\n1,2,3\nx,y,z\n' > csv
printf 'bin\0ary two\nline\n' > b.bin
printf 'x\nmatch\0z\nmatch2\n' > n2
printf 'match\nmore\0\n' > n3
printf 'a\0b\nc\n' > n1
: > empty; printf 'one' > nonl; printf 'x\n' > one
printf 'l1 two\nl2\nl3 two\nl4\nl5\nl6\nl7 two\nl8\nl9\nl10\nl11\nl12 two\n' > ctx
seq 1 120 > n120
printf 'ab\r\ncd\r\n' > crlf
printf 'two\n\nthree\n' > pat1; printf 'one\ntwo\n' > pat2; : > patempty
mkdir -p d/sub d/skip; printf 'two in d\nother\n' > d/x.txt; printf 'two in sub\n' > d/sub/y.c; printf 'two skip\n' > d/skip/z.txt; printf 'two h\n' > d/.hidden; printf 'two txt\n' > d/b.txt
ln -s ../nums d/link 2>/dev/null
printf 'x\n' > unreadable; chmod 000 unreadable
head -c 300000 /dev/zero | tr '\0' x > longline; printf '\nxyz\n' >> longline
printf 'caf\303\251 \303\251t\303\251\n\377\376 match\nok match\nstra\303\237e \316\261\316\262\n\346\227\245\346\234\254\n' > u8

gd() { d="$1"; f="$2"; shift 2; CMP_STDIN="$f" run_cmp "$d" "$@"; }

# ---- basic options over several inputs
for f in nums text abc prose csv nonl empty ctx; do
    for opts in "" "-n" "-c" "-v" "-vn" "-vc" "-i" "-in" "-l" "-L" "-q" "-o" "-on" "-ob" "-b" "-H" "-Hn" "-hn" "-s" "-T" "-nT" "-bT" "-HnT" "-x" "-w" "-xn" "-wn" "-nv" "-Z" "-HZ" "-lZ" "-cH" "-m1" "-m2 -n" "-m1 -c" "-m1 -v" "-ov" "-oi" "-onb" "-A1" "-B1" "-C1" "-A1 -n" "-B2 -n" "-C2 -nb" "-A0" "-A0 -n" "-1" "-2 -n" "-A1 -B2" "-A3 -m1" "-C1 -v" "-C1 -c" "-A1 -o" "-A1 -H -n" "--color=always" "--color=always -n" "--color=always -o" "--color=always -v" "--color=always -c" "--color=always -l" "--color=always -A1 -n" "--color=always -Hnb" "--color=always -T -n" "--color=always -i" "--color=always -x" "--color=always -w"; do
        for pat in e o '^' '$' '.' 'o.*e' 'one' 'two' 'l' ''; do
            case $opts in *-A*|*-B*|*-C*|*-1*|*-2*|*Hnb*|*-T*|*-bT*) [ "$pat" = "e" ] || [ "$pat" = "two" ] || [ "$pat" = "" ] || continue;; esac
            gd "$opts '$pat' $f" $f $opts -- "$pat" $f
        done
    done
done

# ---- regex syntax: BRE, ERE, fixed, Perl
for f in abc prose text; do
    for re in 'a.c' 'a*' 'a\+' 'a\?b' 'ab\|xy' '\(ab\)\1' '\(a\)\(b\)\2\1' '^a' 'c$' '^$' 'a\{2\}' 'a\{2,\}' 'a\{,2\}' '[[:alpha:]]\+' '[[:digit:]]' '[^a-c]' '[]]' '[a-]' '[]a]' '[[:space:]]' '[[.a.]]' '[[=a=]]' '\<foo' 'bar\>' '\bfoo\b' '\Bo' '\w\+' '\W' '\s' '\S' 'foo.bar' 'foo\.bar' '*a' 'a**' '\(\)' 'x\|' '\|x' '.\{3\}' '\(foo\|bar\)\+' 'back\\slash' '\[brack\]' '(paren)' 'a+b' 'a|b' '\.' '[.]' 'o\{1,2\}b' '\(^a\)' 'a\(^b\)' 'a^b' 'a$b' '^*' '\(*a\)' '\x'; do
        gd "BRE '$re' $f" $f -- "$re" $f
        gd "BRE -o '$re' $f" $f -o -- "$re" $f
    done
    for re in 'a.c' 'a*' 'a+' 'a?b' 'ab|xy' '(ab)\1' '(a)(b)\2\1' '^a' 'c$' '^$' 'a{2}' 'a{2,}' 'a{,2}' 'a{1' 'a{x}' 'a{1,2' '{1}' '[[:alpha:]]+' '\<foo' 'bar\>' '\bfoo\b' '\w+' 'foo\.bar' '*a' '+a' '?a' 'a**' 'a+?' 'a|' '|a' '()' '(|a)' '(a|b)*c' '(foo|bar)+' 'back\\slash' '\(paren\)' '\[brack\]' 'a\+b' 'a\|b' '(' ')' 'a)' '[' '[a' 'a{1}{2}' '^*' '(^a)' 'a(^b)' 'a^b' 'a$b' '(a|ab)(c|bcd)' 'x*' 'o{1,2}b' '\x' '\d'; do
        gd "ERE '$re' $f" $f -E -- "$re" $f
        gd "ERE -o '$re' $f" $f -Eo -- "$re" $f
    done
    for re in 'a.c' 'a+b' 'a|b' 'o' '.' '[a]' '\' '*' 'foo.bar' '(paren)' '^a' 'c$' 'back\slash' ''; do
        gd "F '$re' $f" $f -F -- "$re" $f
        gd "F -o '$re' $f" $f -Fo -- "$re" $f
        gd "F -i '$re' $f" $f -Fi -- "$re" $f
        gd "F -w '$re' $f" $f -Fw -- "$re" $f
        gd "F -x '$re' $f" $f -Fx -- "$re" $f
    done
    for re in 'a.c' '\d+' '\w+' '(?<=a)b' 'a(?=b)' '(?i)ABC' 'a{2}' '[[:alpha:]]+' '^a' 'c$' '(a|ab)(c|bcd)' '\bfoo\b' 'x*' 'a++' '(?:ab)+' '\Aabc' '(?<n>a)\k<n>'; do
        gd "PCRE '$re' $f" $f -P -- "$re" $f
        gd "PCRE -o '$re' $f" $f -Po -- "$re" $f
    done
    for re in 'a' 'foo' 'o' 'b' 'abc' 'ab' ''; do
        for o in -w -x -iw -ix -wo -wv -xv -wc -xn -Ew -Ex -Fw -Fx; do
            gd "$o '$re' $f" $f $o -- "$re" $f
        done
    done
done
gd 'multi -e' prose -e fox -e dog prose
gd 'multi -e -o' prose -o -e 'o' -e 'ow' -e 'qu' prose
gd 'multi -e -o longest' prose -o -e 'qui' -e 'quick' prose
gd 'multi newline pattern' prose "$(printf 'fox\ndog')" prose
gd 'multi -E alt -o' prose -Eo 'qui|quick|brow|brown' prose
gd 'empty pattern' nums '' nums
gd 'empty pattern -v' nums -v '' nums
gd 'empty pattern -c' nums -c '' nums
gd 'empty -e plus other' nums -e '' -e two nums
gd 'empty pattern -o' nums -o '' nums
gd 'empty pattern -w' prose -w '' prose
gd 'empty pattern -x' nums -x '' text
gd '-e a newline-ending' nums -e "$(printf 'two\n')" nums
gd '-f file' nums -f pat1 nums
gd '-f file2' nums -f pat2 nums
gd '-f empty' nums -f patempty nums
gd '-f empty -v' nums -v -f patempty nums
gd '-f empty -c' nums -c -f patempty nums
gd '-f and -e' nums -f pat2 -e five nums
gd '-f missing' nums -f nosuch nums
gd '-f - stdin' nums -f - nums
gd '-f twice' nums -f pat1 -f pat2 nums
gd '-F -f' nums -F -f pat2 nums
gd '-w -f' nums -w -f pat2 nums
gd '-x -f' nums -x -f pat2 nums
gd '-e -e -f order -o' nums -o -e t -f pat2 nums
gd 'matcher override -E -F' abc -E -F 'a+b' abc
gd 'matcher override -F -E' abc -F -E 'a+b' abc
gd 'matcher override -G -E' abc -G -E 'a+b' abc
gd '-i ERE' prose -Ei 'THE|FOX' prose
gd '-i backref' abc -i '\(A\)\1' abc
gd '-i bracket' abc -i '[A-C]\+' abc
gd '-y' prose -y THE prose
gd '--no-ignore-case' prose -i --no-ignore-case THE prose
gd '-i then --no-ignore-case then -i' prose --no-ignore-case -i THE prose

# ---- context, separators, max count
for opts in "-A1" "-B1" "-C1" "-A2 -B1" "-A0" "-B0" "-C0" "-A1 -n" "-C1 -n" "-C1 -nb" "-C1 -H" "-A1 -v" "-B1 -v" "-C1 -c" "-C1 -l" "-C1 -o" "-A1 -m1" "-A2 -m2" "-B1 -m1" "-C1 -m1 -n" "-A1 --group-separator=XX" "-A1 --no-group-separator" "-C1 --group-separator=" "-A1 --color=always" "-C1 --color=always -n" "-C1 --color=always --group-separator=@@" "-3" "-1 -n" "-C 2" "-A 1 -B 3" "-2 -A0" "-A 1 -C 2" "-C 2 -A 1" "-5 -3" "-n -5" "-A1 -x" "-A1 -w" "-A100" "-B100" "-m1 -A2" "-m3 -C1"; do
    gd "ctx $opts" ctx $opts two ctx
    gd "ctx $opts nums" nums $opts -e two -e seven nums
    gd "ctx $opts n120" n120 $opts -e '^1[05]$' -e '^7$' n120
done
gd 'ctx two files' ctx -A1 two ctx nums
gd 'ctx two files -n' ctx -C1 -n two ctx nums
gd 'ctx bad arg' ctx -A x two ctx
gd 'ctx bad arg C' ctx -C -1 two ctx
gd 'ctx bad arg B' ctx -B '' two ctx
gd 'ctx huge' ctx -A 99999999999999999999 two ctx
gd '-m 0' ctx -m0 two ctx
gd '-m 0 -c' ctx -m0 -c two ctx
gd '-m -1' ctx -m -1 two ctx
gd '-m x' ctx -m x two ctx
gd '-m big' ctx -m 99999999999999999999 two ctx
gd '-m1 stdin' ctx -m1 two
gd '-m1 two files' ctx -m1 two ctx nums
gd '-m1 -l' ctx -m1 -l two ctx
gd '-m1 -L' ctx -m1 -L zzz ctx

# ---- color
for opts in "--color=always" "--color=always -n" "--color=always -H" "--color=always -b" "--color=always -Hnb" "--color=always -o" "--color=always -on" "--color=always -v" "--color=always -vn" "--color=always -c" "--color=always -cH" "--color=always -l" "--color=always -L" "--color=always -Z -l" "--color=always -T -n" "--color=always -A1 -n" "--color=always -C1 -nH" "--color=always -i" "--color=always -w" "--color=always -x" "--color=always -E" "--color=always --colour=never" "--color=never" "--color=auto" "--colour=always" "--color" "--color=yes" "--color=force" "--color=tty" "--color=bogus"; do
    gd "color $opts" prose $opts -e o -e 'the' prose nums
    gd "color $opts ctx" ctx $opts -e two ctx
done
for gc in 'ms=01;32' 'mt=01;34' 'sl=1' 'cx=2' 'sl=1:cx=2' 'sl=1:cx=2:rv' 'fn=34:ln=33:bn=31:se=35' 'ne' 'ms=:mc=' 'mt=' 'bogus' 'ms=01;32:bogus=1:fn=1' 'ms' 'fn' 'sl=7:ms=4' 'rv:sl=1:cx=2'; do
    export GREP_COLORS="$gc"
    for opts in "-n" "-Hn" "-v -n" "-o" "-C1 -n" "-vC1 -n" "-c" "-l"; do
        gd "GREP_COLORS=$gc color $opts" ctx --color=always $opts two ctx nums
    done
done
unset GREP_COLORS
export GREP_COLOR='4;33'
gd 'GREP_COLOR deprecated' prose --color=always o prose
unset GREP_COLOR

# ---- several files, names, counts
gd '2 files' nums two nums text
gd '2 files -c' nums -c two nums text prose
gd '2 files -h' nums -h two nums text
gd '2 files -l' nums -l o nums text empty
gd '2 files -L' nums -L o nums text empty
gd '2 files -q' nums -q two nums text
gd '2 files -s missing' nums -s two nosuch nums
gd 'missing + ok' nums two nosuch nums
gd 'missing only -q' nums -q two nosuch nums
gd 'missing -q no match' nums -q zzz nosuch nums
gd 'match then missing -q' nums -q two nums nosuch
gd 'stdin -' nums two -
gd 'stdin - and file' nums two - nums
gd 'stdin label' nums --label=NAME -H two
gd 'stdin label -' nums --label=NAME -H two -
gd 'stdin -c' nums -c two
gd 'stdin -H' nums -H two
gd 'no file operand' nums two
gd 'dir operand' nums two d
gd 'dir operand with file' nums two d nums
gd 'dir -s' nums -s two d
gd 'dir -d read' nums -d read two d
gd 'dir -d skip' nums -d skip two d
gd 'dir -d recurse' nums -d recurse two d
gd 'dir -d bogus' nums -d bogus two d
gd 'dir -d re (prefix)' nums -d rec two d
gd 'dir -d r (ambiguous)' nums -d r two d
gd '-D skip' nums -D skip two nums
gd '-D read' nums -D read two nums
gd '-D bogus' nums -D bogus two nums
gd 'same file twice' nums -c two nums nums
gd '-Z names' nums -Z two nums text
gd '-Z -c' nums -Z -c two nums text
gd '-Z -n' nums -Z -n two nums text
gd '-Z -o' nums -Z -o two nums text
gd 'null in name -L' nums -LZ zzz nums text
gd 'output is input' nums two nums
gd 'unreadable file' nums two unreadable

# ---- recursion
gd '-r' nums -r two d
gd '-r no operand' nums -r two
gd '-r .' nums -r two .
gd '-r d/' nums -r two d/
gd '-r d//' nums -r two d//
gd '-R' nums -R two d
gd '-r -h' nums -rh two d
gd '-r -c' nums -rc two d
gd '-r -l' nums -rl two d
gd '-r -L' nums -rL two d
gd '-r -n' nums -rn two d
gd '-r file operand' nums -r two nums
gd '-r file and dir' nums -r two nums d
gd '-r symlink operand' nums -r two d/link
gd '-R symlink' nums -R two d/link
gd '--include' nums -r --include='*.txt' two d
gd '--include two' nums -r --include='*.txt' --include='*.c' two d
gd '--exclude' nums -r --exclude='*.txt' two d
gd '--exclude-dir' nums -r --exclude-dir=sub two d
gd '--exclude-dir glob' nums -r --exclude-dir='s*' two d
gd '--exclude-dir skip' nums -r --exclude-dir=skip two d
gd '--exclude-dir with operand' nums -r --exclude-dir=d two d
gd '--exclude-from' nums -r --exclude-from=pat1 two d
gd '--include no recursion' nums --include='*.txt' two nums text
gd '--exclude no recursion' nums --exclude='n*' two nums text
gd '--exclude path' nums -r --exclude='d/x.txt' two d
gd '--include hidden' nums -r --include='.*' two d
gd '-r --color' nums -r --color=always two d
gd '-r -o' nums -ro two d
gd '-r binary' nums -r match .
gd '-r -a binary' nums -ra match .
gd '-r -I binary' nums -rI match .

# ---- binary and encoding
for f in b.bin n1 n2 n3 crlf; do
    for opts in "" "-c" "-n" "-a" "-I" "-l" "-L" "-q" "-o" "-v" "-vc" "-A1" "-z" "-zc" "-Hc" "--binary-files=text" "--binary-files=without-match" "--binary-files=binary" "-U" "-ab" "-an" "-ac" "-av" "-ao"; do
        for pat in match two line . b a; do
            gd "bin $opts '$pat' $f" $f $opts -- "$pat" $f
        done
    done
done
gd 'bin bogus type' b.bin --binary-files=bogus two b.bin
gd 'bin -I count' b.bin -Ic two b.bin
gd 'bin two files' b.bin two b.bin nums
gd 'bin stdin' b.bin two
gd 'bin -z' n2 -z match n2
gd 'bin -z -o' n2 -zo 'match.' n2
gd 'bin -z ^' n2 -z '^m' n2
gd 'bin -z $' n2 -z 'z$' n2
gd 'bin -z dot' n2 -z 'h.z' n2
gd 'crlf $' crlf 'b$' crlf
gd 'crlf -U $' crlf -U 'b$' crlf
gd 'crlf color' crlf --color=always 'b' crlf

# ---- UTF-8 locale
CMP_LOCALE=C.UTF-8
for opts in "" "-n" "-c" "-o" "-v" "-i" "-w" "-x" "-a" "-l" "-b" "--color=always" "-on"; do
    for pat in 'match' 'caf.' '.' 'é' 'É' 'ß' 'straße' '[[:alpha:]]\+' '\w\+' 'α' '日' '[^a-z]' 'é\+' '^.$' '.\{3\}'; do
        gd "utf8 $opts '$pat'" u8 $opts -- "$pat" u8
        gd "utf8 -E $opts '$pat'" u8 -E $opts -- "$pat" u8
    done
done
gd 'utf8 -i É' u8 -i 'É' u8
gd 'utf8 -io' u8 -io 'É' u8
gd 'utf8 -F -i' u8 -Fi 'É' u8
gd 'utf8 -w' u8 -w 'caf' u8
gd 'utf8 -wo' u8 -wo '\w*' u8
gd 'utf8 -P .' u8 -Po '.' u8
gd 'utf8 binary bad' u8 '' u8
gd 'utf8 binary bad -c' u8 -c '' u8
gd 'utf8 binary bad -a' u8 -a match u8
gd 'utf8 binary bad -o' u8 -o match u8
gd 'utf8 binary bad -v' u8 -v zzz u8
gd 'utf8 binary bad -A' u8 -A1 caf u8
unset CMP_LOCALE
gd 'C locale bytes' u8 -o 'caf.' u8
gd 'C locale dot' u8 -c '^.$' u8
gd 'C locale -i' u8 -i 'É' u8

# ---- misc
gd 'no args' nums
gd 'only option' nums -i
gd 'bad option' nums -Q two nums
gd 'bad long option' nums --bogus two nums
gd 'ambiguous long' nums --no two nums
gd 'missing arg' nums -e
gd 'missing arg long' nums --regexp
gd '--regexp=' nums --regexp=two nums
gd '--file=' nums --file=pat2 nums
gd '--max-count=' nums --max-count=1 o nums
gd '--context=' nums --context=1 two nums
gd '--after-context' nums --after-context=1 two nums
gd '--before-context' nums --before-context=1 two nums
gd '--only-matching' nums --only-matching o nums
gd '--count' nums --count o nums
gd '--invert-match' nums --invert-match o nums
gd '--ignore-case' nums --ignore-case TWO nums
gd '--word-regexp' nums --word-regexp two nums
gd '--line-regexp' nums --line-regexp two nums
gd '--no-messages' nums --no-messages two nosuch
gd '--quiet' nums --quiet two nums
gd '--silent' nums --silent two nums
gd '--with-filename' nums --with-filename two nums
gd '--no-filename' nums --no-filename two nums text
gd '--line-number' nums --line-number two nums
gd '--byte-offset' nums --byte-offset two nums
gd '--initial-tab' nums --initial-tab -n two nums
gd '--null' nums --null -l two nums
gd '--null-data' nums --null-data two nums
gd '--files-with-matches' nums --files-with-matches two nums
gd '--files-without-match' nums --files-without-match two nums
gd '--text' b.bin --text two b.bin
gd '--line-buffered' nums --line-buffered two nums
gd '--basic-regexp' abc --basic-regexp 'a\+' abc
gd '--extended-regexp' abc --extended-regexp 'a+' abc
gd '--fixed-strings' abc --fixed-strings 'a+' abc
gd '--perl-regexp' abc --perl-regexp 'a+' abc
gd '--recursive' nums --recursive two d
gd '--dereference-recursive' nums --dereference-recursive two d
gd '--directories=skip' nums --directories=skip two d
gd '--devices=skip' nums --devices=skip two nums
gd '--unix-byte-offsets' nums -u -b two nums
gd '-X grep' nums -X grep 'a\+' abc
gd '-X egrep' nums -X egrep 'a+' abc
gd '-X bogus' nums -X bogus 'a+' abc
gd '-- pattern starts with dash' nums -e -- -- nums
gd '-e -x' nums -e -x nums
gd 'combined -ie' nums -ie TWO nums
gd 'combined -nie' nums -nie TWO nums
gd 'options after files' nums two nums -n
gd 'POSIXLY_CORRECT' nums two nums -n
gd '-E -e with newline' nums -E -e 'one|' nums
gd 'exit status 1' nums zzz nums
gd 'exit status 2 error + match' nums two nums nosuch
gd 'exit status -q error' nums -q zzz nosuch
gd 'long line' longline x longline
help_cmp
cd /; print_summary
