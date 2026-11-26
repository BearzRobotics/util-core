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
# An output name that is the input: refuse and leave the input as it was.
run_tree "input is first output" 'seq 1 9 > xaa' -l 1 xaa
run_tree "input is later output" 'seq 1 9 > xac' -l 1 xac
run_tree "output links to input" 'seq 1 9 > in; ln in xaa' -l 1 in
run_tree "output symlink to input" 'seq 1 9 > in; ln -s in xab' -b 4 in
run_tree "-n input is output"   'seq 1 9 > xab' -n 3 xab
run_tree "-n l/ input is output" 'seq 1 9 > xab' -n l/3 xab
run_tree "existing outputs are replaced" 'seq 1 9 > in; seq 1 99 > xaa' -l 3 in
TREE_STDIN=xab run_tree "stdin is an output" 'seq 1 9 > xab' -b 6
run_tree "-n r/ input is first output" 'seq 1 9 > xaa' -n r/2 xaa
run_tree "-n r/ empty input is output" ': > xab' -n r/3 xab
# Here GNU has written part of the earlier pieces when it stops and we have
# not, so only the status, the diagnostic and the input are compared.
# keeps_input DESC REDIRECT ARGS...: xab is the input and the second output.
keeps_input() {
    description="$1"; redirect="$2"; shift 2
    d="$TEST_TMP/keep"; rm -rf "$d"; mkdir "$d"
    seq 1 9 > "$d/xab"; seq 1 9 > "$TEST_TMP/keep.want"
    (cd "$d" && ours "$@" < "$redirect" > /dev/null 2> "$TEST_TMP/keep.err"); rc=$?
    if [ "$rc" -eq 1 ] && grep -q "'xab' would overwrite input; aborting" "$TEST_TMP/keep.err" && cmp -s "$d/xab" "$TEST_TMP/keep.want"; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s (rc=%s)\n" "$description" "$rc"
    fi
}
keeps_input "-n r/ stdin is an output"    xab       -n r/3
keeps_input "-n r/ input is later output" /dev/null -n r/3 xab
keeps_input "-n r/ -e input is output"    /dev/null -e -n r/3 xab
run_tree "output is /dev/null"  'seq 1 9 > in; ln -s /dev/null xaa' -l 3 in
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
# Round robin runs one filter per chunk too, all open at once.
for nn in 1 2 3 10; do
    run_tree "filter r/$nn"     "$S" --filter='tr a-z A-Z > $FILE.up' -n r/$nn words
done
# (only output made after end of input has a defined order)
run_tree "filter r/ output order" "$S" --filter='x=$(cat); echo "$FILE: $x"' -n r/3 seven
run_tree "filter r/ -u"         "$S" -u --filter='cat > $FILE.out' -n r/3 words
run_tree "filter r/ empty input" "$S" --filter='cat > $FILE.out' -n r/3 empty
run_tree "filter r/ empty input -e" "$S" -e --filter='cat > $FILE.out' -n r/3 empty
run_tree "filter r/ -e few lines" "$S" -e --filter='cat > $FILE.out' -n r/30 words
run_tree "filter r/ fails"      "$S" --filter='cat >/dev/null; [ $FILE != xab ] || exit 4; [ $FILE != xac ] || exit 5' -n r/3 words
# A write that fails, at the end or on the way, is reported with status 1.
if [ -e /dev/full ]; then
    for c in "-n 1/2" "-n l/1/2" "-n r/1/2"; do
        (cd "$TEST_TMP" && seq 100 > kn && ours $c kn > /dev/full 2> kn.err); rc=$?
        if [ "$rc" = 1 ] && [ "$(cat "$TEST_TMP/kn.err")" = "split: write error: No space left on device" ]; then
            PASS=$((PASS + 1)); echo "PASS $c to a full device"
        else
            FAIL=$((FAIL + 1)); echo "FAIL $c to a full device (rc=$rc $(cat "$TEST_TMP/kn.err"))"
        fi
    done
    run_tree "-l write error"       'seq 1 100 > in; ln -s /dev/full xab' -l 60 in
    run_tree "-n write error"       'seq 1 100 > in; ln -s /dev/full xab' -n 2 in
    run_tree "-n r/ write error at the end" 'seq 1 100 > in; ln -s /dev/full xab' -n r/2 in
    # (mid-way, GNU has created fewer of the other files than we have)
    for how in "-n r/2" "-u -n r/2"; do
        m="$TEST_TMP/midway"; rm -rf "$m"; mkdir "$m"; seq 1 20000 > "$m/in"; ln -s /dev/full "$m/xaa"
        (cd "$m" && ours $how in 2> "$TEST_TMP/midway.err"); rc=$?
        if [ "$rc" = 1 ] && [ "$(cat "$TEST_TMP/midway.err")" = "split: xaa: No space left on device" ]; then
            PASS=$((PASS + 1)); echo "PASS write error mid-way $how"
        else
            FAIL=$((FAIL + 1)); echo "FAIL write error mid-way $how (rc=$rc $(cat "$TEST_TMP/midway.err"))"
        fi
    done
fi
# Pieces cut short by a file size limit: ours must say so (how much of the
# other pieces GNU has written by then differs, so the trees are not compared).
d="$TEST_TMP/limit"; mkdir -p "$d"; seq 3000 > "$d/in"
for how in "-n r/2" "-n 2" "-b 8000"; do
    (cd "$d" && rm -f x?? && trap '' XFSZ && ulimit -f 4 && ours $how in 2> "$TEST_TMP/limit.err"); rc=$?
    if [ "$rc" = 1 ] && [ "$(cat "$TEST_TMP/limit.err")" = "split: xaa: File too large" ]; then
        PASS=$((PASS + 1)); echo "PASS file size limit $how"
    else
        FAIL=$((FAIL + 1)); echo "FAIL file size limit $how (rc=$rc $(cat "$TEST_TMP/limit.err"))"
    fi
done
if can_inject; then
    for how in "-n r/1" "-l 5000"; do
        (cd "$d" && rm -f x?? && strace -y -o "$TEST_TMP/trace" -e trace=close "$BIN_DIR/split" $how in)
        n=$(grep '^close' "$TEST_TMP/trace" | grep -n '/xaa>' | cut -d: -f1)
        (cd "$d" && rm -f x?? && strace -o /dev/null -e trace=close -e inject=close:error=EIO:when="$n" "$BIN_DIR/split" $how in 2> "$TEST_TMP/limit.err"); rc=$?
        if [ "$rc" = 1 ] && [ "$(cat "$TEST_TMP/limit.err")" = "split: xaa: Input/output error" ]; then
            PASS=$((PASS + 1)); echo "PASS close error $how"
        else
            FAIL=$((FAIL + 1)); echo "FAIL close error $how (n=$n rc=$rc $(cat "$TEST_TMP/limit.err"))"
        fi
    done
else
    skip_test "close errors (no strace)"
fi
print_summary
[ "$FAIL" -eq 0 ]
