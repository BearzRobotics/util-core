#!/bin/sh
# printf: differential tests against GNU printf 9.7 (C locale).
UTIL="printf"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
pf() { run_cmp "printf $(printf '%s ' "$@" | cut -c1-60)" "$@"; }

printf "\n[ Literal text and escapes ]\n"
pf 'hello'
pf 'hello\n'
pf 'a\tb\\c\n'
pf '\a\b\f\r\v\e|' 
pf '\"q\"\n'
pf '\101\102\103\n'
pf '\1\12\123\1234\n'
pf '\0\00\000|\n'
pf '\x41\x4a\x4A\x414\n'
pf '\x\n'
pf '\xg\n'
pf 'é\n'
pf 'A\n'
pf '$@`\n'
pf '\U0001F600\n'
pf '\U00000041\n'
pf '\u12\n'
pf '\u\n'
pf '\ud800\n'
pf '\U00110000\n'
pf 'a\cb\n'
pf 'ab\c'
pf '\c'
pf '\q\n'
pf 'trailing backslash \'
pf '%%\n'
pf '100%%\n'
pf 'no newline'
pf ''
pf '\n\n\n'

printf "\n[ Strings and characters ]\n"
pf '%s\n' abc
pf '%s|%s\n' a b
pf '%10s|\n' abc
pf '%-10s|\n' abc
pf '%.2s|\n' abcdef
pf '%10.2s|\n' abcdef
pf '%-10.2s|\n' abcdef
pf '%.0s|\n' abc
pf '%s\n' ''
pf '%s\n'
pf '%s %s\n' a
pf '%5s|%-5s|\n' toolongvalue toolongvalue
pf '%c\n' abc
pf '%c%c%c\n' a b c
pf '%c|\n' ''
pf '%c\n'
pf '%5c|%-5c|\n' x y
pf '%b\n' 'a\tb'
pf '%b\n' 'a\\b'
pf '%b\n' '\0101'
pf '%b\n' '\101'
pf '%b\n' '\x41'
pf '%b\n' 'a\cb'
pf '%b|%b\n' 'x\cy' 'z'
pf '%b\n' 'é'
pf '%b\n' 'bad\xzz'
pf '%10b|\n' 'a\tb'
pf '%q\n' 'a b'
pf '%q\n' abc
pf '%q\n' ''
pf "%q\n" "it's"
pf '%q\n' 'a"b'
pf '%q\n' 'a$b'
pf '%q\n' 'a\b'
pf '%q|%q\n' '~x' '#x'
pf '%q\n' "$(printf 'a\nb')"
pf '%q\n' "$(printf 'a\tb')"
pf '%q\n' "$(printf '\303\251')"
pf '%q\n' 'a*b?c[d]'
pf '%q\n' '{x}'
pf '%20q|\n' 'a b'
pf '%s\n' 'a\nb'
pf 'abc%sdef\n' X
pf '%s%s%s\n' 1 2 3 4 5

printf "\n[ Integers ]\n"
for v in 0 1 -1 42 -42 +5 007 08 0x1f 0X1F 0x -0x10 010 -010 ' 5' '5 ' '  -3' 1e3 1.5 abc '' ' ' '--5' '+-5' 9223372036854775807 9223372036854775808 -9223372036854775808 -9223372036854775809 18446744073709551615 18446744073709551616 99999999999999999999 0x7fffffffffffffff 0xffffffffffffffff 0x10000000000000000 "'A" '"B' "'" '"' "'AB" "'é"; do
    pf '%d\n' "$v"
    pf '%i|%u|%o|%x|%X\n' "$v" "$v" "$v" "$v" "$v"
done
pf '%d %d %d\n' 1 2 3
pf '%d %d\n' 1 2 3
pf '%d %d\n' 1
pf '%d\n'
pf '%5d|%-5d|%05d|%+d|% d\n' 42 42 42 42 42
pf '%5d|%-5d|%05d|%+d|% d\n' -42 -42 -42 -42 -42
pf '%.3d|%.0d|%.0d|%5.3d|%-5.3d|%05.3d\n' 5 0 1 5 5 5
pf '%+.3d|% .3d|%+5.3d\n' 5 5 5
pf '%#x|%#X|%#o|%#x|%#o\n' 255 255 8 0 0
pf '%#10x|%#-10x|%#010x|%#.5x\n' 255 255 255 255
pf '%10o|%-10o|%010o|%.5o\n' 8 8 8 8
pf '%x|%X|%o\n' -1 -255 -8
pf '%u\n' -1
pf '%ld|%lld|%hd|%hhd|%jd|%zd|%td\n' 1 2 3 4 5 6 7
pf '%lu|%llx|%hu\n' 1 255 3
pf '%*d|\n' 6 7
pf '%-*d|\n' 6 7
pf '%*d|\n' -6 7
pf '%.*d|\n' 4 7
pf '%*.*d|\n' 8 4 7
pf '%*d\n' 5
pf '%*d\n'
pf '%.*d\n' -1 5
pf "%'d\n" 1234567
pf '%5%|\n'
pf '%-5%|\n'
pf '%d%%\n' 50
pf '%1$d\n' 5
pf '%y\n' 1
pf '%z\n'
pf '%\n'
pf '%'
pf '%5'
pf '%.\n'
pf '%-\n'
pf '%l\n'
pf '%ll\n'

printf "\n[ Floating point ]\n"
for v in 0 1 -1 0.5 1.5 2.5 3.14159265358979 -3.14159 1e10 1e-10 123456789.123456789 0.1 0.30000000000000004 1e100 1e-100 255 .5 5. 1e3 1E3 -0 -0.0 +1.5 ' 1.5' '1.5 ' abc '' inf -inf nan -nan INF NaN infinity 0x1p3 0x1.8p1 0x10 0x.8 1e 1e+ '1e+5' 100000 1000000 10000000 0.0001 0.00001 0.000001 123456789012345678 1.7976931348623157e308 5e-324 "'a"; do
    pf '%f|%F|%e|%E|%g|%G\n' "$v" "$v" "$v" "$v" "$v" "$v"
done
pf '%.0f|%.1f|%.2f|%.10f\n' 2.5 2.25 2.675 0.1
pf '%.0e|%.1e|%.3e|%.10e\n' 12345.678 12345.678 12345.678 12345.678
pf '%.0g|%.1g|%.3g|%.10g\n' 12345.678 12345.678 12345.678 12345.678
pf '%10.3f|%-10.3f|%010.3f|%+10.3f|% 10.3f\n' 3.14159 3.14159 3.14159 3.14159 3.14159
pf '%10.3e|%-10.3e|%010.3e\n' 3.14159 3.14159 3.14159
pf '%#f|%#.0f|%#g|%#.0e\n' 3 3 3 3
pf '%10g|%-10g|%010g\n' 3.5 3.5 3.5
pf '%G|%E\n' 1e-10 1e-10
pf '%5.1f%%\n' 99.44
pf '%*.*f|\n' 10 3 3.14159
pf '%f %f\n' 1.5
pf '%f\n'
pf '%.30f\n' 0.1
pf '%.20e\n' 0.1
pf '%.17g\n' 0.1
pf '%lf|%Lf\n' 1.5 2.5
pf '%a|%A\n' 1 1
for v in 0 1 2 0.5 0.1 -1 3.5 255 1024 1e10 1e-10 0.3 inf nan; do pf '%a|%A\n' "$v" "$v"; done
pf '%.0a|%.1a|%.3a|%.20a\n' 1.999 1.999 1.999 1.999
pf '%20a|%-20a|%020a|%+a|% a\n' 1.5 1.5 1.5 1.5 1.5
pf '%#a|%#.0a\n' 1 1

printf "\n[ Argument reuse and counting ]\n"
pf '%s\n' a b c
pf '%s %s\n' a b c
pf '%s=%d\n' x 1 y 2 z 3
pf '[%s]\n' a b c d
pf 'x\n' a b c
pf '%%\n' a b
pf '%d %s\n' 1 a 2
pf '%b%b\n' 'a\n' 'b\n' 'c\n'
pf '%s\n' 'a b' 'c d'
pf '%d\n' 1 2 3 x
pf '%s %c\n' ab cd ef gh
pf '\n%s' a b

printf "\n[ Randomised conversion specifications ]\n"
awk 'BEGIN {
    srand(81)
    split("- + space # 0", fl, " ")
    split("d i u o x X c s e E f F g G a A", cv, " ")
    split("0 1 -1 7 42 -42 255 65536 3.14159 -2.5 0.5 1e5 1e-5 123456.789 abc 0x1f 1e100 inf nan", vals, " ")
    nv = 19; nc = 16
    for (i = 0; i < 1800; i++) {
        spec = "%"
        for (j = 1; j <= 5; j++) if (rand() < 0.25) { f = fl[j]; spec = spec (f == "space" ? " " : f) }
        if (rand() < 0.5) spec = spec int(rand() * 14)
        if (rand() < 0.4) spec = spec "." int(rand() * 8)
        spec = spec cv[1 + int(rand() * nc)]
        v = vals[1 + int(rand() * nv)]
        printf "pf \047%s|\\n\047 \047%s\047\n", spec, v
    } }' > pf_rnd.sh
. ./pf_rnd.sh
printf "\n[ Exit status and messages ]\n"
pf
pf --
pf -- '%s\n' x
pf --bogus
pf -x
pf '-%s\n' x
pf '--%s\n' x
pf '%s\n' --
pf '%d\n' abc
pf '%d\n' 12abc
pf '%f\n' 1.5.5
pf '%d %d\n' x y
print_summary
