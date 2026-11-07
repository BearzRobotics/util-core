#!/bin/sh
# dd: differential tests against GNU dd 9.7 (C locale). References: GNU manual
# "dd invocation", POSIX dd. The timing/rate line of the statistics is masked.
UTIL="dd"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
printf 'hello world\nsecond line  \nthird\n' > text
head -c 5000 /dev/urandom > rnd; : > empty; printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' > alnum
printf 'abc\ndefgh\n\nij\n' > lines; printf 'abc  def  \nxy  \n' > blank
head -c 70000 /dev/zero > zeros

mask() { sed -E 's/^([0-9]+ bytes?( \([^)]*\))?) copied, .*/\1 copied, TIME/'; }
# dd_cmp DESC ARGS... (stdin from $DD_IN or /dev/null, output compared as a file too)
dd_cmp() {
    description="$1"; shift
    in="${DD_IN:-/dev/null}"
    rm -f out.g out.o out.pre
    [ -f out ] && cp -p out out.pre
    (cd "$W" && LC_ALL=C /usr/bin/dd "$@" < "$in" > o.g 2> e.g; echo $? > r.g)
    [ -f out.g ] && mv out.g outfile.g; [ -f out ] && mv out outfile.g
    [ -f out.pre ] && cp -p out.pre out
    (cd "$W" && "$BIN_DIR/dd" "$@" < "$in" > o.o 2> e.o; echo $? > r.o)
    [ -f out ] && mv out outfile.o
    norm_err < e.g | mask > e.g2; norm_err < e.o | mask > e.o2
    if cmp -s o.g o.o && cmp -s e.g2 e.o2 && cmp -s r.g r.o && { [ ! -f outfile.g ] && [ ! -f outfile.o ] || cmp -s outfile.g outfile.o; }; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$description"
        printf "     GNU  rc=%s out=%s err=%s\n" "$(cat r.g)" "$(head -c 200 o.g | cat -A)" "$(cat -A e.g2)"
        printf "     OURS rc=%s out=%s err=%s\n" "$(cat r.o)" "$(head -c 200 o.o | cat -A)" "$(cat -A e.o2)"
    fi
    rm -f outfile.g outfile.o out out.pre
}

for f in text rnd empty alnum lines blank zeros; do
    DD_IN=$f dd_cmp "copy $f"
    DD_IN=$f dd_cmp "of=out $f" of=out
    DD_IN=$f dd_cmp "if=$f" if=$f
    for bs in 1 7 100 512 4096 1K 1KiB 1kB 2b 1M; do
        DD_IN=$f dd_cmp "bs=$bs $f" bs=$bs
        DD_IN=$f dd_cmp "bs=$bs of=out $f" bs=$bs of=out
    done
    DD_IN=$f dd_cmp "ibs=3 $f" ibs=3
    DD_IN=$f dd_cmp "obs=3 $f" obs=3
    DD_IN=$f dd_cmp "ibs=3 obs=5 $f" ibs=3 obs=5
    DD_IN=$f dd_cmp "ibs=5 obs=3 $f" ibs=5 obs=3
    DD_IN=$f dd_cmp "count=1 $f" count=1
    DD_IN=$f dd_cmp "count=0 $f" count=0
    DD_IN=$f dd_cmp "skip=1 $f" skip=1
    DD_IN=$f dd_cmp "skip=1 count=1 bs=7 $f" skip=1 count=1 bs=7
    DD_IN=$f dd_cmp "iseek=1 $f" iseek=1
    DD_IN=$f dd_cmp "seek=1 of=out $f" seek=1 of=out
    DD_IN=$f dd_cmp "oseek=2 bs=3 of=out $f" oseek=2 bs=3 of=out
    DD_IN=$f dd_cmp "skip=1 seek=1 bs=9 of=out $f" skip=1 seek=1 bs=9 of=out
    DD_IN=$f dd_cmp "skip=99999 $f" skip=99999
    DD_IN=$f dd_cmp "skip=3 bs=1 count=4 iflag=count_bytes $f" skip=3 bs=1 count=4 iflag=count_bytes
    DD_IN=$f dd_cmp "iflag=skip_bytes skip=5 $f" iflag=skip_bytes skip=5 bs=4
    DD_IN=$f dd_cmp "iflag=count_bytes count=10 bs=4 $f" iflag=count_bytes count=10 bs=4
    DD_IN=$f dd_cmp "oflag=seek_bytes seek=5 bs=4 of=out $f" oflag=seek_bytes seek=5 bs=4 of=out
    DD_IN=$f dd_cmp "iflag=fullblock bs=4 $f" iflag=fullblock bs=4
    DD_IN=$f dd_cmp "status=none $f" status=none
    DD_IN=$f dd_cmp "status=noxfer $f" status=noxfer
    DD_IN=$f dd_cmp "status=progress $f" status=progress
done
for c in ucase lcase swab sync block unblock ascii ebcdic ibm "ucase,swab" "sync,swab" noerror notrunc sparse "sync,noerror" "block,sync" "unblock,sync" "ascii,ucase" "ebcdic,lcase" "ibm,ucase" fsync fdatasync "sparse,notrunc" excl nocreat; do
    for f in text lines blank alnum zeros; do
        DD_IN=$f dd_cmp "conv=$c $f" conv=$c
        DD_IN=$f dd_cmp "conv=$c cbs=8 $f" conv=$c cbs=8
        DD_IN=$f dd_cmp "conv=$c cbs=4 bs=7 $f" conv=$c cbs=4 bs=7
        DD_IN=$f dd_cmp "conv=$c bs=3 of=out $f" conv=$c bs=3 of=out
        DD_IN=$f dd_cmp "conv=$c ibs=3 obs=8 $f" conv=$c ibs=3 obs=8
    done
done
DD_IN=zeros dd_cmp "conv=sparse of=out" conv=sparse of=out bs=512
DD_IN=zeros dd_cmp "conv=sparse seek" conv=sparse of=out bs=512 seek=3
printf 'old content here' > "$W/pre"
cp pre out; DD_IN=text dd_cmp "overwrite" of=out
cp pre out; DD_IN=text dd_cmp "conv=notrunc" of=out conv=notrunc
cp pre out; DD_IN=text dd_cmp "seek=1 bs=4 conv=notrunc" of=out seek=1 bs=4 conv=notrunc
cp pre out; DD_IN=text dd_cmp "conv=excl existing" of=out conv=excl
cp pre out; DD_IN=text dd_cmp "conv=nocreat existing" of=out conv=nocreat
DD_IN=text dd_cmp "conv=nocreat missing" of=nosuch conv=nocreat
cp pre out; DD_IN=text dd_cmp "oflag=append" of=out oflag=append
cp pre out; DD_IN=text dd_cmp "oflag=append notrunc" of=out oflag=append conv=notrunc
cp pre out; DD_IN=text dd_cmp "seek beyond" of=out seek=100 bs=1
cp pre out; DD_IN=text dd_cmp "seek small trunc" of=out seek=1 bs=4
dd_cmp "of=/dev/null" if=rnd of=/dev/null
dd_cmp "if=/dev/zero count" if=/dev/zero count=3 bs=100 of=out
dd_cmp "if=/dev/zero bs=0" if=/dev/zero bs=0
dd_cmp "if=/dev/zero count=0" if=/dev/zero count=0
dd_cmp "of=/dev/full" if=text of=/dev/full
dd_cmp "if=dir" if=/
dd_cmp "if=missing" if=nosuch
dd_cmp "of=dir" if=text of=/
dd_cmp "of=missing dir" if=text of=nosuch/x
dd_cmp "if=text of=text" if=text of=text conv=notrunc
for a in "bs=0" "bs=-1" "bs=x" "bs=" "bs=1x" "bs=1xx" "bs=2x3" "bs=2x3x4" "bs=0x5" "bs=00x5" "bs=1k" "bs=1kB" "bs=1KB" "bs=1KiB" "bs=1c" "bs=1w" "bs=1b" "bs=1M" "bs=1G" "bs=1T" "bs=99999999999999999999" "bs=0x10" "bs=1B" "bs=1BB" "bs=1kB2" "ibs=0" "obs=0" "cbs=0" "cbs=x" "count=x" "count=-1" "count=1k" "count=99999999999999999999" "skip=x" "seek=x" "skip=-1" "seek=-1" "count=" "skip=" "if=" "of=" "conv" "conv=bogus" "conv=" "conv=,sync" "conv=sync," "conv=ucase,bogus" "conv=ucase,lcase" "conv=block,unblock" "conv=ascii,ibm" "conv=ebcdic,ibm" "conv=excl,nocreat" "iflag=bogus" "oflag=bogus" "iflag=" "oflag=fullblock" "iflag=direct,nocache" "status=bogus" "status=" "status=progress,none" "x" "x=1" "=" "==" "-x" "--bogus" "--help=1" "if=text of=out bs=4 junk" "IF=text" "if =text" "iF=text" "if=text if=nosuch" "of=out of=nosuch/x" "bs=3 bs=5" "conv=ucase conv=lcase" "status=none status=noxfer" "iflag=append" "oflag=sync" "iflag=nofollow" "iflag=noctty" "oflag=direct" "iflag=dsync" "iflag=sync,dsync" "iflag=nonblock" "iflag=noatime" "iflag=directory"; do
    DD_IN=text dd_cmp "arg '$a'" $a
done
DD_IN=text dd_cmp "no args"
DD_IN=text dd_cmp "-- args" -- bs=4
DD_IN=text dd_cmp "conv=sync partial"  conv=sync bs=7
DD_IN=text dd_cmp "iflag=skip_bytes count" iflag=skip_bytes skip=3 count=2
printf 'a\0b\0' > nul; DD_IN=nul dd_cmp "conv=sparse nul" conv=sparse of=out bs=1
DD_IN=alnum dd_cmp "swab odd" conv=swab bs=5
DD_IN=alnum dd_cmp "swab odd 1" conv=swab bs=1
DD_IN=alnum dd_cmp "swab ibs obs" conv=swab ibs=7 obs=3
DD_IN=alnum dd_cmp "swab count" conv=swab bs=3 count=2
DD_IN=lines dd_cmp "block short cbs" conv=block cbs=2
DD_IN=lines dd_cmp "unblock short cbs" conv=unblock cbs=2
DD_IN=lines dd_cmp "block cbs=1" conv=block cbs=1
DD_IN=lines dd_cmp "ebcdic cbs=0" conv=ebcdic cbs=0
cd /; print_summary
