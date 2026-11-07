#!/bin/sh
# tr: differential tests against GNU tr (C locale). References: GNU manual "tr
# invocation"; POSIX.1-2024 tr. Multibyte locales are not implemented.
UTIL="tr"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'hello world 123 ABC  aa--bb\n\tTabs\there\nlast line no newline' > text
printf 'aaabbbcccdddeee\n\n\n\nxyz  \t  \t z\n' > runs
head -c 4000 /dev/urandom > bin
printf 'The Quick Brown Fox.\n' > mixed
CMP_STDIN="$W/text"

printf "\n[ Translate ]\n"
for a in 'a-z A-Z' 'A-Z a-z' 'abc xyz' 'abc xy' 'abc x' 'a-c x-z' 'lo 01' 'aa xy' 'abcabc xyzuvw' 'a-e [x*]' 'a-e [x*3]' 'a-e [x*2]yz' 'a-e [x*3]yz' 'a-e v[x*010]' \
         'abc [x*]' '[a-c] [A-C]' 'a-c-e xyz' 'a- b-' '\- x' 'a\-c xyz' 'a-a b' 'a-z a-z' '0-9 a-j' ' - _:' '\n x' '\t x' '\\\\ /' '\150 H' '\150-\152 XYZ' '[:lower:] [:upper:]' '[:upper:] [:lower:]' \
         '[:lower:] X' '[:digit:] #' '[:space:] _' '[:blank:] _' '[:punct:] .' '[:alpha:] x' '[:alnum:] x' 'a[:lower:] A[:upper:]' '[:lower:]a [:upper:]A' '[:lower:][:upper:] [:upper:][:lower:]' \
         '[=l=] L' '[=a=][=b=] xy' '[a-c] x' 'a[b c' '[:alpha x' '[=a x' '[a* x' '\077 x' '\1 x' '\18 x'; do
    run_cmp "tr $a"          $a text
done
run_cmp "binary a-z"          a-z A-Z
CMP_STDIN="$W/bin"
run_cmp "binary \\000-\\377 shift"  '\000-\177' '\200-\377'
run_cmp "binary [:upper:]->lower"   '[:upper:]' '[:lower:]'
CMP_STDIN="$W/text"
run_cmp "-t abc xy"           -t abc xy
run_cmp "-t abc x"            -t abc x
run_cmp "-t longer string2"   -t ab xyz
run_cmp "--truncate-set1"     --truncate-set1 abc xy
run_cmp "-t with classes"     -t '[:lower:]' 'ab'

printf "\n[ Complement ]\n"
for a in '-c a-z _' '-cd a-z' '-cs a-z \n' '-C a-z X' '-c a-z AB' '-cd 0-9' '-c [:alpha:] x' '-cs [:alpha:] x' '-Cd [:alnum:]' '-cd [:print:]' '-ct a-z AB' '-c abc ""'; do
    run_cmp "tr $a"          $a text
done
run_cmp "--complement"        --complement -d a-z text
run_cmp "-c with no string2 (delete)" -cd 'a-z\n' text

printf "\n[ Delete ]\n"
for a in 'l' 'a-z' 'lo' '[:space:]' '[:digit:]' '[:upper:]' '[:punct:]' '\n' '\t' '[=l=]' 'a-c-e' '[a-c]' '\150' '' '[:alpha:]-z' '-' 'a\-c'; do
    run_cmp "tr -d $a"       -d "$a" text
done
run_cmp "--delete"            --delete l text
run_cmp "-d binary"           -d '\000-\100'

printf "\n[ Squeeze ]\n"
for a in 'l' 'a-z' '[:space:]' '[:alpha:]' ' ' '\n' 'abc' '' 'xyz'; do
    run_cmp "tr -s $a"       -s "$a" runs
done
run_cmp "-s a-c A-C"          -s a-c A-C runs
run_cmp "-s l o"              -s l o text
run_cmp "-s [:space:] ' '"    -s '[:space:]' ' ' runs
run_cmp "-s a-z A-Z"          -s a-z A-Z runs
run_cmp "--squeeze-repeats"   --squeeze-repeats l text
run_cmp "-sc a-z \\n"         -sc 'a-z' '\n' runs
run_cmp "-s empty input"      -s a < /dev/null

printf "\n[ Delete + squeeze ]\n"
run_cmp "-ds l o"             -ds l o text
run_cmp "-ds a-b c"           -ds a-b c runs
run_cmp "-ds [:digit:] [:alpha:]" -ds '[:digit:]' '[:alpha:]' text
run_cmp "-cds l \\n"          -cds l '\n' text
run_cmp "-dsc a b"            -dsc a b text
run_cmp "-ds [x*]"            -ds a '[x*]' runs
run_cmp "-ds with [=b=]"      -ds a '[=b=]' runs
run_cmp "-ds with fill"       -ds ab '[c*3]' runs

printf "\n[ Errors ]\n"
run_cmp "no operands"
run_cmp "-d no operand"       -d
run_cmp "one operand"         a
run_cmp "three operands"      a b c
run_cmp "-d two operands"     -d a b
run_cmp "-ds one operand"     -ds a
run_cmp "-d three operands"   -d a b c
run_cmp "empty string2"       abc ''
run_cmp "a to empty"          a ''
run_cmp "-t abc empty"        -t abc ''
run_cmp "reverse range"       z-a b
run_cmp "-d reverse range"    -d z-a
run_cmp "reverse in string2"  a-c z-a
run_cmp "invalid class"       '[:foo:]' x
run_cmp "invalid class -d"    -d '[:foo:]'
run_cmp "equiv multi"         '[=ll=]' L
run_cmp "equiv in string2"    a '[=b=]'
run_cmp "repeat in string1"   '[x*3]' y
run_cmp "repeat fill in string1" '[x*]' y
run_cmp "repeat in -d"        -d '[x*]'
run_cmp "two fills"           a '[x*][y*]'
run_cmp "bad repeat count"    a '[x*08]'
run_cmp "class in string2"    a-z '[:digit:]'
run_cmp "misaligned"          a-z '[:lower:]'
run_cmp "misaligned 2"        '[:alpha:]' '[:upper:]'
run_cmp "[:upper:] to X ok"   '[:upper:]' X
run_cmp "string2 ends in class" -c a-z '[:upper:]'
run_cmp "string2 ends in class 2" a-z 'x[:upper:]'
run_cmp "trailing backslash"  'a\' x
run_cmp "trailing backslash -d" -d 'a\'
run_cmp "ambiguous octal"     '\400' x
run_cmp "ambiguous octal 2"   '\777' x
run_cmp "invalid option"      -x a b
run_cmp "unrecognized long"   --nope a b
run_cmp "-- then operands"    -- -a b
run_cmp "dash operand"        - x

cd /; rm -rf "$W"
printf "\n[ Large inputs: chunk boundaries (64 KiB reads) ]\n"
# Runs of one byte placed to straddle each 65536-byte read boundary, so a
# squeeze run is split across two chunks.
awk 'BEGIN { srand(31); for (i = 0; i < 25000; i++) { n = 1 + int(rand() * 8); s = ""; for (j = 0; j < n; j++) s = s "ab 12 " ; print s "xx\t\t" i } }' > "$W/big"
{ head -c 65535 /dev/zero | tr '\0' 'q'; head -c 3 /dev/zero | tr '\0' 'a'; head -c 65534 /dev/zero | tr '\0' 'z'; printf 'aaaa\n'; } > "$W/runs65"
{ head -c 65536 /dev/zero | tr '\0' 'a'; head -c 65536 /dev/zero | tr '\0' 'a'; printf 'b'; } > "$W/oneletter"
head -c 300000 /dev/urandom > "$W/rnd"
for f in big runs65 oneletter rnd; do
    CMP_STDIN="$W/$f"
    for a in 'a-z A-Z' '-d a' '-d a-z' '-d [:digit:]' '-s a' '-s [:space:]' '-s ab' '-ds a b' '-ds 1 a' '-s a-z A-Z' '-d -c a-z' '-s -c a-z' '-c a-z _' '-cd a-z' '-cs a-z \n' '-s q' '-s z' '-d q' '-s a b' '[:lower:] [:upper:]' '-s [:lower:] [:upper:]' '-t abc x'; do
        run_cmp "$f tr $a"   $a
    done
done
CMP_STDIN="$W/text"

print_summary
