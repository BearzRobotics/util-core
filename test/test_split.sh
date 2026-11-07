#!/bin/sh
# split: differential tests against GNU split 9.7 (C locale). References: GNU
# manual "split invocation"; POSIX.1-2024 split (-a -b -l and alphabetic
# suffixes). --filter and -u need processes; they are tested through a file.
UTIL="split"
. "$(dirname "$0")/testlib.sh"
TREE_CONTENT=1
help_cmp
S='seq 1 25 > in; seq 1 105 > in105; printf "no newline at end" > nonl; : > empty; printf "aaaa\nbb\ncccccc\nd\neeeeeeeeee\nf\n" > words; printf "a\0b\0cc\0ddd\0" > nul; printf "one\ntwo\nthree\nfour\nfive\nsix\nseven\n" > seven; awk "BEGIN{srand(7); for(i=0;i<300;i++){n=int(rand()*30); s=\"\"; for(j=0;j<n;j++) s=s sprintf(\"%c\",97+int(rand()*26)); print s}}" > rnd; awk "BEGIN{srand(3); for(i=0;i<5000;i++) printf \"%c\", 1+int(rand()*254)}" | tr "\n" "x" > bin; echo >> bin'
run_tree "default"              "$S" in
run_tree "stdin"                "$S" < /dev/null
TREE_STDIN=/dev/null run_tree "stdin dash empty" "$S" -
run_tree "no newline"           "$S" nonl
run_tree "empty"                "$S" empty
run_tree "prefix"               "$S" in pre-
run_tree "prefix in dir"        "$S; mkdir d" in d/pre
run_tree "prefix missing dir"   "$S" in nodir/pre
for l in 1 2 3 5 10 25 26 100; do
    run_tree "-l $l"            "$S" -l $l in
    run_tree "-$l obsolete"     "$S" -$l in
done
run_tree "-l 1 105 lines"       "$S" -l 1 in105
run_tree "-l 1 -d 105 lines"    "$S" -l 1 -d in105
run_tree "-l 1 -a 1 overflow"   "$S" -l 1 -a 1 in
run_tree "-l 1 -a 3"            "$S" -l 1 -a 3 in
run_tree "-a 0"                 "$S" -a 0 in
run_tree "-a x"                 "$S" -a x in
run_tree "-d"                   "$S" -d -l 4 in
run_tree "-x"                   "$S" -x -l 1 in
run_tree "-x 300"               "$S" -x -l 1 rnd
run_tree "-d -a 3"              "$S" -d -a 3 -l 5 in
run_tree "--numeric-suffixes"   "$S" --numeric-suffixes -l 5 in
run_tree "--numeric-suffixes=5" "$S" --numeric-suffixes=5 -l 5 in
run_tree "--numeric-suffixes=98" "$S" --numeric-suffixes=98 -l 1 in
run_tree "--numeric-suffixes=x" "$S" --numeric-suffixes=x -l 5 in
run_tree "--numeric-suffixes=123 -a2" "$S" --numeric-suffixes=123 -a 2 -l 5 in
run_tree "--hex-suffixes"       "$S" --hex-suffixes -l 10 in
run_tree "-d -x"                "$S" -d -x -l 5 in
run_tree "alpha exhaust 676+"   "$S" -l 1 rnd
run_tree "additional suffix"    "$S" --additional-suffix=.txt -l 5 in
run_tree "additional suffix /"  "$S" --additional-suffix=a/b -l 5 in
run_tree "additional + numeric" "$S" -d --additional-suffix=.log -l 5 in
for b in 1 2 3 7 10 100 1K 1KB 4096 1M; do
    run_tree "-b $b"            "$S" -b $b bin
    run_tree "-b $b words"      "$S" -b $b words
done
run_tree "-b 0"                 "$S" -b 0 in
run_tree "-b x"                 "$S" -b x in
run_tree "-b 1x"                "$S" -b 1x in
run_tree "-b -1"                "$S" -b -1 in
run_tree "-b 1b"                "$S" -b 1b in
run_tree "-b 99999999999999999999999" "$S" -b 99999999999999999999999 in
run_tree "--bytes=7"            "$S" --bytes=7 words
for c in 1 3 5 7 10 11 12 20 100 1000; do
    run_tree "-C $c"            "$S" -C $c words
    run_tree "-C $c rnd"        "$S" -C $c rnd
    run_tree "-C $c nonl"       "$S" -C $c nonl
done
run_tree "--line-bytes=20"      "$S" --line-bytes=20 words
run_tree "-C 0"                 "$S" -C 0 in
run_tree "-t sep"               "$S" -t , -l 2 words
run_tree "-t nul"               "$S" -t '\0' -l 2 nul
run_tree "-t multi"             "$S" -t ab -l 2 words
run_tree "-t a -t b"            "$S" -t a -t b words
run_tree "-t a -t a"            "$S" -t a -t a -l 1 words
run_tree "-t x -C"              "$S" -t x -C 8 rnd
run_tree "-l 0"                 "$S" -l 0 in
run_tree "-l x"                 "$S" -l x in
run_tree "-l 1 -b 1"            "$S" -l 1 -b 1 in
run_tree "-l 1 -n 2"            "$S" -l 1 -n 2 in
run_tree "-b 1 -C 1"            "$S" -b 1 -C 1 in
run_tree "missing input"        "$S" nofile
run_tree "directory input"      "$S; mkdir dd" dd
run_tree "extra operand"        "$S" in p extra
run_tree "bad option"           "$S" -z in
run_tree "long abbrev"          "$S" --line=5 in
run_tree "overwrite input"      "$S" -l 5 xaa xa
run_tree "verbose"              "$S" --verbose -l 10 in
run_tree "verbose -b"           "$S" --verbose -b 20 in
run_tree "-e"                   "$S" -e -l 10 in
for nn in 1 2 3 4 5 7 10 25 26 30; do
    run_tree "-n $nn"           "$S" -n $nn in
    run_tree "-n $nn bin"       "$S" -n $nn bin
    run_tree "-n l/$nn"         "$S" -n l/$nn rnd
    run_tree "-n l/$nn words"   "$S" -n l/$nn words
    run_tree "-n r/$nn"         "$S" -n r/$nn rnd
    run_tree "-n r/$nn words"   "$S" -n r/$nn words
done
run_tree "-n -e"                "$S" -e -n 30 in
run_tree "-n l/ -e"             "$S" -e -n l/30 words
run_tree "-n r/ -e"             "$S" -e -n r/30 words
run_tree "-n 0"                 "$S" -n 0 in
run_tree "-n x"                 "$S" -n x in
run_tree "-n 2/3 stdout"        "$S" -n 2/3 in
run_tree "-n 1/3 stdout"        "$S" -n 1/3 bin
run_tree "-n 3/3 stdout"        "$S" -n 3/3 in
run_tree "-n 4/3"               "$S" -n 4/3 in
run_tree "-n 0/3"               "$S" -n 0/3 in
run_tree "-n l/2/3 stdout"      "$S" -n l/2/3 words
run_tree "-n r/2/3 stdout"      "$S" -n r/2/3 words
run_tree "-n l/1/1 stdout"      "$S" -n l/1/1 words
run_tree "-n a/b/c/d"           "$S" -n 1/2/3/4 in
run_tree "-n stdin"             "$S" -n 3 -
run_tree "-n r/ stdin"          "$S" -n r/3
run_tree "-n 5 -a 1"            "$S" -n 5 -a 1 in
run_tree "-n 30 -a 1"           "$S" -n 30 -a 1 in
run_tree "-n 30 -d"             "$S" -n 30 -d in
run_tree "-n 100 -d"            "$S" -n 100 -d in
run_tree "-n 1000"              "$S" -n 1000 in
run_tree "-n nonl"              "$S" -n 4 nonl
run_tree "-n empty"             "$S" -n 3 empty
run_tree "-n l/ empty"          "$S" -n l/3 empty
run_tree "--number=3"           "$S" --number=3 in
run_tree "filter cat"           "$S" --filter='cat > $FILE.out' -l 10 in
run_tree "filter gzip-less"     "$S" --filter='tr a-z A-Z > $FILE' -l 10 words
run_tree "filter fails"         "$S" --filter='exit 3' -l 10 in
run_tree "filter and stdout chunk" "$S" --filter=cat -n 1/3 in
run_tree "-u"                   "$S" -u -n r/3 words
print_summary
[ "$FAIL" -eq 0 ]
