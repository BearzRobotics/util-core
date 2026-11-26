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

# The elapsed time must be a number as %g writes it; its value and the rate vary.
mask() { sed -E 's/^([0-9]+ bytes?( \([^)]*\))?) copied, [0-9]+(\.[0-9]+)?(e-[0-9]+)? s, .*/\1 copied, TIME/'; }
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

# Offsets that do not fit in a file offset are diagnosed, not computed.
cp pre out; dd_cmp "skip= overflow" if=text skip=18014398509481984 bs=1024
dd_cmp "skip= largest count" if=text skip=9223372036854775807
dd_cmp "skip= largest count bs=1" if=text skip=9223372036854775807 bs=1
cp pre out; dd_cmp "skip= overflow of=out" if=text of=out skip=18014398509481984 bs=1024
DD_IN=text dd_cmp "skip= overflow stdin" skip=18014398509481984 bs=1024
dd_cmp "skip= overflow /dev/zero" if=/dev/zero of=/dev/null skip=18014398509481984 bs=1024 count=2
cp pre out; dd_cmp "seek= overflow" if=text of=out seek=18014398509481984 bs=1024
cp pre out; dd_cmp "seek= largest count" if=text of=out seek=9223372036854775807
dd_cmp "seek= overflow new file" if=text of=newfile seek=9223372036854775807
[ ! -e newfile ] && { PASS=$((PASS + 1)); echo "PASS seek= overflow creates nothing"; } || { FAIL=$((FAIL + 1)); echo "FAIL seek= overflow creates nothing"; }
cp pre out; dd_cmp "seek= overflow notrunc" if=text of=out seek=18014398509481984 bs=1024 conv=notrunc
cp pre out; dd_cmp "seek= overflow stdout" if=text seek=18014398509481984 bs=1024
for a in skip=18014398509481984 skip=9223372036854775807; do
    printf abc | LC_ALL=C /usr/bin/dd $a bs=1024 > o.g 2> e.g; rg=$?
    printf abc | "$BIN_DIR/dd" $a bs=1024 > o.o 2> e.o; ro=$?
    if [ "$rg" = "$ro" ] && cmp -s o.g o.o && [ "$(norm_err < e.g | mask)" = "$(norm_err < e.o | mask)" ]; then
        PASS=$((PASS + 1)); echo "PASS pipe $a"
    else FAIL=$((FAIL + 1)); echo "FAIL pipe $a"; cat e.o; fi
done

# The elapsed time is the real one. The writer holds the pipe open for 0.3 s.
{ printf a; timeout 0.3 tail -f /dev/null; } | "$BIN_DIR/dd" 2>e.o >/dev/null
secs=$(sed -n 's/^1 byte copied, \([0-9.]*\) s, .*/\1/p' e.o)
if awk -v t="$secs" 'BEGIN { exit !(t >= 0.25 && t < 60) }'; then PASS=$((PASS + 1)); echo "PASS elapsed time is reported"
else FAIL=$((FAIL + 1)); echo "FAIL elapsed time is reported"; cat e.o; fi

# Signals. dd reads a FIFO that the test feeds, so each step waits for the one
# before it. (A shell starts background jobs with SIGINT ignored; env undoes it.)
wait_for() { # wait_for COMMAND...: poll for up to 5 s
    tries=0
    until "$@" 2>/dev/null; do
        tries=$((tries + 1)); [ "$tries" -lt 100 ] || return 1
        timeout 0.05 tail -f /dev/null
    done
}
trap '' PIPE # a dd that has died must fail its case, not end the suite
rm -f fifo sigout sigerr; mkfifo fifo
"$BIN_DIR/dd" if=fifo of=sigout bs=3 2> sigerr & pid=$!
exec 3> fifo
printf abc >&3; wait_for grep -q abc sigout
kill -USR1 "$pid"; wait_for grep -q 'records out' sigerr
asked=$(head -n 2 sigerr)
printf def >&3; exec 3>&-
wait "$pid"; rc=$?
if [ "$rc" = 0 ] && [ "$(cat sigout)" = abcdef ] && [ "$asked" = "$(printf '1+0 records in\n1+0 records out')" ] && [ "$(grep -c 'records in' sigerr)" = 2 ]; then
    PASS=$((PASS + 1)); echo "PASS SIGUSR1 prints statistics and the copy goes on"
else
    FAIL=$((FAIL + 1)); echo "FAIL SIGUSR1 prints statistics and the copy goes on (rc=$rc) $(cat sigerr)"
fi
rm -f fifo sigout sigerr; mkfifo fifo
env --default-signal=INT "$BIN_DIR/dd" if=fifo of=sigout bs=3 2> sigerr & pid=$!
exec 3> fifo
printf abc >&3; wait_for grep -q abc sigout
kill -INT "$pid"; wait_for grep -q 'records out' sigerr
# Should the signal be lost, the end of input still ends dd.
exec 3>&-
wait "$pid"; rc=$?
if [ "$rc" = 130 ] && [ "$(grep -c 'records in' sigerr)" = 1 ] && grep -q '^3 bytes copied' sigerr; then
    PASS=$((PASS + 1)); echo "PASS SIGINT prints statistics and ends dd"
else
    FAIL=$((FAIL + 1)); echo "FAIL SIGINT prints statistics and ends dd (rc=$rc) $(cat sigerr)"
fi
rm -f fifo sigout sigerr
trap - PIPE
cd /; print_summary
