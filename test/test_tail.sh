#!/bin/sh
# tail: differential tests against GNU tail. References: GNU manual "tail
# invocation"; POSIX.1-2024 tail. --max-unchanged-stats is not implemented.
UTIL="tail"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"
seq 1 25 > "$W/n25"
printf 'a\nb\nc' > "$W/nonl"
printf 'a\0b\0c\0d\0' > "$W/nul"
: > "$W/empty"
head -c 300000 /dev/urandom > "$W/bin"
mkdir "$W/dir"
cd "$W"
# stdin variants: regular file and pipe use different code paths.
via_pipe() { # DESC ARGS...: stdin is a pipe fed from n25
    d="$1"; shift
    e=$(cat n25 | LC_ALL=C gnu "$@" 2>&1); a=$(cat n25 | ours "$@" 2>&1)
    [ "$e" = "$a" ] && { PASS=$((PASS + 1)); printf "PASS %s\n" "$d"; } || { FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU : %s\n     OURS: %s\n" "$d" "$e" "$a"; }
}

printf "\n[ Defaults and -n (named file: seekable path) ]\n"
CMP_STDIN="$W/n25"
run_cmp "default (10 lines) from stdin"
run_cmp "file operand"           n25
run_cmp "-n 3"                   -n 3 n25
run_cmp "-n3"                    -n3 n25
run_cmp "-n 0"                   -n 0 n25
run_cmp "-n 100"                 -n 100 n25
run_cmp "--lines=4"              --lines=4 n25
run_cmp "--lines 4"              --lines 4 n25
run_cmp "no trailing newline"    -n 2 nonl
run_cmp "no trailing nl default" nonl
run_cmp "empty file"             empty
run_cmp "-n 1K"                  -n 1K n25
run_cmp "-n 99999999999999999999999" n25 -n 99999999999999999999999
run_cmp "last of -n/-c wins"     -c 3 -n 2 n25
run_cmp "-n 5000 binary"         -n 5000 bin
run_cmp "-n 1 binary"            -n 1 bin
run_cmp "-n 100000 binary"       -n 100000 bin

printf "\n[ +NUM ]\n"
run_cmp "-n +3"                  -n +3 n25
run_cmp "-n +1"                  -n +1 n25
run_cmp "-n +0"                  -n +0 n25
run_cmp "-n +100"                -n +100 n25
run_cmp "-n +2 no trailing nl"   -n +2 nonl
run_cmp "-n +1000 binary"        -n +1000 bin
run_cmp "-c +5"                  -c +5 n25
run_cmp "-c +100000 binary"      -c +100000 bin

printf "\n[ Bytes ]\n"
run_cmp "-c 7"                   -c 7 n25
run_cmp "-c 0"                   -c 0 n25
run_cmp "-c 1b"                  -c 1b bin
run_cmp "-c 2K"                  -c 2K bin
run_cmp "-c 1M"                  -c 1M bin
run_cmp "-c 299999"              -c 299999 bin
run_cmp "--bytes=3"              --bytes=3 n25

printf "\n[ Pipe (streaming path) ]\n"
via_pipe "pipe default"
via_pipe "pipe -n 3"             -n 3
via_pipe "pipe -n 0"             -n 0
via_pipe "pipe -n +3"            -n +3
via_pipe "pipe -c 7"             -c 7
via_pipe "pipe -c +7"            -c +7
via_pipe "pipe -n 100"           -n 100
via_pipe "pipe stdin as -"       -n 2 -
e=$(cat nonl | gnu -n 2); a=$(cat nonl | ours -n 2)
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS pipe no trailing newline"; } || { FAIL=$((FAIL + 1)); echo "FAIL pipe no trailing newline"; }
e=$(cat bin | gnu -n 300 | od -c); a=$(cat bin | ours -n 300 | od -c)
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS pipe binary -n 300"; } || { FAIL=$((FAIL + 1)); echo "FAIL pipe binary -n 300"; }
e=$(cat bin | gnu -c 70000 | od -c); a=$(cat bin | ours -c 70000 | od -c)
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS pipe binary -c 70000"; } || { FAIL=$((FAIL + 1)); echo "FAIL pipe binary -c 70000"; }

printf "\n[ Headers ]\n"
run_cmp "two files"              -n 2 n25 nonl
run_cmp "-q two files"           -q -n 2 n25 nonl
run_cmp "--quiet"                --quiet -n 2 n25 nonl
run_cmp "-v one file"            -v -n 2 n25
run_cmp "--verbose"              --verbose -n 2 n25
run_cmp "stdin among files"      -n 1 n25 - nonl

printf "\n[ -z ]\n"
run_cmp "-z -n 2"                -z -n 2 nul
run_cmp "-z -n +2"               -z -n +2 nul
run_cmp "--zero-terminated"      --zero-terminated -n 3 nul

printf "\n[ Obsolete -NUM ]\n"
run_cmp "-3"                     -3 n25
run_cmp "-3q rejected like GNU"  -3q n25 nonl
run_cmp "-2k rejected like GNU"  -2k n25
run_cmp "-2l"                    -2l n25
run_cmp "-1b"                    -1b n25
run_cmp "-5c"                    -5c n25
run_cmp "-2v rejected like GNU"  -2v n25

printf "\n[ Errors ]\n"
run_cmp "missing file"           nonexistent
run_cmp "missing among files"    -n 1 n25 nonexistent nonl
run_cmp "directory"              dir
run_cmp "invalid -n"             -n abc n25
run_cmp "invalid -c"             -c 1x n25
run_cmp "invalid option"         -x
run_cmp "unrecognized long"      --nope
run_cmp "-- ends options"        -- -n

printf "\n[ -f follow (descriptor) ]\n"
follow_case() { # DESC ARGS...: append lines while following; compare to GNU
    d="$1"; shift
    for t in gnu ours; do
        seq 1 3 > ff; : > "$t.out"
        if [ $t = gnu ]; then timeout 3 /usr/bin/tail "$@" ff > "$t.out" 2>&1 & else timeout 3 "$BIN_DIR/tail" "$@" ff > "$t.out" 2>&1 & fi
        sleep 0.5; echo four >> ff; sleep 0.5; echo five >> ff; sleep 0.8; kill $! 2>/dev/null; wait $! 2>/dev/null
    done
    cmp -s gnu.out ours.out && { PASS=$((PASS + 1)); printf "PASS %s\n" "$d"; } || { FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU : %s\n     OURS: %s\n" "$d" "$(cat gnu.out)" "$(cat ours.out)"; }
}
follow_case "-f sees appended lines" -n 2 -s 0.1 -f
follow_case "--follow=descriptor"    -n 1 -s 0.1 --follow=descriptor
follow_case "-n +1 -f"               -n +1 -s 0.1 -f
seq 1 5 > ff; (sleep 0.3; : > ff; sleep 0.3; echo new >> ff) &
timeout 2 "$BIN_DIR/tail" -n 0 -s 0.1 -f ff > ours.trunc 2>&1; wait
grep -q "ff: file truncated" ours.trunc && grep -q "^new$" ours.trunc && { PASS=$((PASS + 1)); echo "PASS truncation is reported and followed"; } || { FAIL=$((FAIL + 1)); echo "FAIL truncation: $(cat ours.trunc)"; }
# Standard input redirected from a file, possibly not at its start: only what
# is appended afterwards may follow the initial output.
for a in "-n0" "-c0" "-n1" "" "-n +2" "-c +2" "-c3"; do
    for skip in 0 1; do
        for t in gnu ours; do
            if [ $t = gnu ]; then bin=/usr/bin/tail; else bin="$BIN_DIR/tail"; fi
            printf 'a\nb\nc\nd\n' > sf
            { [ $skip = 0 ] || read -r _; timeout 1.2 $bin $a -s 0.1 -f > $t.out 2>&1; } < sf &
            sleep 0.5; echo e >> sf; wait
        done
        cmp -s gnu.out ours.out && { PASS=$((PASS + 1)); echo "PASS -f on redirected stdin: '$a', $skip line(s) already read"; } || { FAIL=$((FAIL + 1)); printf "FAIL -f on redirected stdin: '%s' skip %s\n     GNU : %s\n     OURS: %s\n" "$a" $skip "$(cat gnu.out)" "$(cat ours.out)"; }
    done
done
sleep 30 & spid=$!
echo x > pf; timeout 5 "$BIN_DIR/tail" --pid=$spid -s 0.1 -f pf > /dev/null & tpid=$!
sleep 0.5; kill $spid; wait $spid 2>/dev/null; sleep 0.5
kill -0 $tpid 2>/dev/null && { FAIL=$((FAIL + 1)); echo "FAIL --pid did not end tail"; kill $tpid; } || { PASS=$((PASS + 1)); echo "PASS --pid ends tail after the process dies"; }
wait 2>/dev/null

printf "\n[ -F / --follow=name / --retry ]\n"
# scen DESC "tail args" "driver commands": run GNU and ours in fresh dirs with the same
# background driver, compare stdout, normalised stderr and exit status.
scen() {
    d="$1"; a="$2"; drv="$3"
    for t in gnu ours; do
        D="$W/sc.$t"; rm -rf "$D"; mkdir "$D"; (cd "$D" && printf 'a1\na2\na3\n' > f && printf 'b1\n' > g)
        if [ $t = gnu ]; then bin=/usr/bin/tail; else bin="$BIN_DIR/tail"; fi
        ( cd "$D" && { ( eval "$drv" ) & LC_ALL=C timeout 2.5 $bin $a > out 2> err; echo "rc=$?" >> out; wait; } )
        sed "s#$bin#tail#g; s#^tail: #E: #" "$D/err" > "$D/err2"
    done
    if cmp -s "$W/sc.gnu/out" "$W/sc.ours/out" && cmp -s "$W/sc.gnu/err2" "$W/sc.ours/err2"; then PASS=$((PASS + 1)); echo "PASS $d"
    else FAIL=$((FAIL + 1)); echo "FAIL $d"; diff "$W/sc.gnu/out" "$W/sc.ours/out"; diff "$W/sc.gnu/err2" "$W/sc.ours/err2"; fi
}
scen "-F appends, remove, re-create" "-F -s 0.2 f" "sleep 0.5; echo a4 >> f; sleep 0.5; rm f; sleep 0.5; echo n1 > f; sleep 0.5; echo n2 >> f"
scen "-F replaced and truncated" "-F -s 0.2 f" "sleep 0.5; echo r1 > f.new; mv f.new f; sleep 0.5; : > f; sleep 0.5; echo t >> f"
scen "--follow=name removal ends" "--follow=name -s 0.2 f" "sleep 0.5; rm f"
scen "-f missing file" "-f -s 0.2 nofile" "sleep 0.3"
scen "-F two files, headers" "-F -s 0.2 f g" "sleep 0.5; echo a4 >> f; sleep 0.4; echo b2 >> g; sleep 0.4; echo a5 >> f"
scen "-F two files, -q" "-F -s 0.2 -q f g" "sleep 0.5; echo a4 >> f; sleep 0.4; echo b2 >> g"
scen "--follow=name --retry" "--follow=name --retry -s 0.2 f" "sleep 0.5; echo x >> f"
scen "-f --retry warns" "-f --retry -s 0.2 f" "sleep 0.5; echo x >> f"
scen "--follow=name on stdin" "--follow=name -s 0.2 -" "sleep 0.3"
scen "--retry without -f" "--retry f" "sleep 0.1"
scen "--pid without -f" "--pid=1 f" "sleep 0.1"
scen "--pid and --retry without -f" "--pid=1 --retry f" "sleep 0.1"
scen "-F existing and missing" "-F -s 0.2 f nofile" "sleep 0.5; echo z > nofile"
scen "-F -n0" "-F -n0 -s 0.2 f" "sleep 0.4; echo q >> f"
scen "-f then removal keeps following" "-f -s 0.2 f" "sleep 0.5; echo q >> f; sleep 0.4; rm f; sleep 0.3"
# Lines appended just before a rename or removal, with no poll in between, can
# only be read from the old descriptor. The expected text is what GNU prints;
# it is not run, because when its checks fall depends on inotify.
# rotated DESC "tail args" "driver commands" STDOUT STDERR
rotated() {
    D="$W/rot"; rm -rf "$D"; mkdir "$D"; (cd "$D" && printf 'a1\na2\na3\n' > f && printf 'b1\n' > g)
    ( cd "$D" && { ( eval "$3" ) & LC_ALL=C timeout 2.5 "$BIN_DIR/tail" $2 > out 2> err; wait; } )
    printf "$4" > "$W/rot.out"; printf "$5" > "$W/rot.err"
    sed "s#$BIN_DIR/tail#tail#g" "$D/err" > "$D/err2"
    if cmp -s "$D/out" "$W/rot.out" && cmp -s "$D/err2" "$W/rot.err"; then PASS=$((PASS + 1)); echo "PASS $1"
    else FAIL=$((FAIL + 1)); echo "FAIL $1"; diff "$W/rot.out" "$D/out"; diff "$W/rot.err" "$D/err2"; fi
}
rotated "-F lines written just before a rotation" "-F -s 1 f" "sleep 0.5; echo last >> f; mv f f.1; echo new > f" \
    'a1\na2\na3\nlast\nnew\n' "tail: 'f' has been replaced;  following new file\n"
rotated "-F lines written just before removal" "-F -s 1 f" "sleep 0.5; echo last >> f; rm f" \
    'a1\na2\na3\nlast\n' "tail: 'f' has become inaccessible: No such file or directory\n"
rotated "--follow=name lines before removal" "--follow=name -s 1 f" "sleep 0.5; echo last >> f; rm f" \
    'a1\na2\na3\nlast\n' "tail: f: No such file or directory\ntail: no files remaining\n"
rotated "-F two files, rotation with pending lines" "-F -s 1 f g" "sleep 0.5; echo last >> f; mv f f.1; echo new > f; echo b2 >> g" \
    '==> f <==\na1\na2\na3\n\n==> g <==\nb1\n\n==> f <==\nlast\nnew\n\n==> g <==\nb2\n' "tail: 'f' has been replaced;  following new file\n"

cd /
rm -rf "$W"
printf "\n[ Backward scan across read windows ]\n"
W="$(mktemp -d)"
awk 'BEGIN { srand(21); for (i = 0; i < 60000; i++) { n = int(rand() * 25); s = ""; for (j = 0; j < n; j++) s = s "z"; print i s } }' > "$W/lines"
head -c 65536 "$W/lines" > "$W/w1"
head -c 65537 "$W/lines" > "$W/w1p"
head -c 131072 "$W/lines" > "$W/w2"
head -c 131073 "$W/lines" > "$W/w2p"
{ head -c 200000 /dev/zero | tr '\0' 'q'; } > "$W/oneline"
head -c 100000 /dev/zero | tr '\0' '\n' > "$W/onlynl"
printf 'a\0b\0c\0' > "$W/nul"
for f in lines w1 w1p w2 w2p oneline onlynl nul; do
    for n in 0 1 2 10 100 1000 5000 20000 100000; do
        run_cmp "$f -n $n"       -n $n "$W/$f"
    done
    for c in 1 100 65535 65536 65537 150000; do
        run_cmp "$f -c $c"       -c $c "$W/$f"
    done
    run_cmp "$f -z -n 2"         -z -n 2 "$W/$f"
    run_cmp "$f +3 lines"        -n +3 "$W/$f"
done
CMP_STDIN="$W/lines" run_cmp "stdin -n 50"     -n 50
CMP_STDIN="$W/lines" run_cmp "stdin -c 5000"   -c 5000
rm -rf "$W"

CMP_STDIN=/dev/null
# Files whose size says nothing: procfs reports 0 and sysfs 4096 for a few
# bytes. (Only files that do not change while the test runs.)
for f in /proc/version /proc/filesystems /sys/kernel/mm/transparent_hugepage/enabled /sys/devices/system/cpu/online /sys/class/net/lo/mtu; do
    if [ ! -r "$f" ]; then skip_test "$f not readable"; continue; fi
    for o in "-n 1" "-n 3" "-n 0" "-c 1" "-c 5" "-c 100000" "-n +2" "-c +3"; do
        run_cmp "$o $f" $o "$f"
    done
done
# Real files around the size from which the end is sought.
S="$TEST_TMP/sizes"; mkdir -p "$S"
for size in 4095 4096 4097 8192 8193; do
    seq 3000 | head -c $size > "$S/$size"
    for o in "-n 3" "-n 100000" "-c 7" "-c 4096"; do
        run_cmp "$o of $size bytes" $o "$S/$size"
    done
done

print_summary
