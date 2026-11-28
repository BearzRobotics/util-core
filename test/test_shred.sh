#!/bin/sh
# shred: differential tests against GNU shred 9.7 (C locale). The pass order of
# the fixed patterns and the random bytes are random in both programs, so the
# hexadecimal pattern names are masked; sizes, removal, messages and exit
# status are compared.
UTIL="shred"
. "$(dirname "$0")/testlib.sh"
help_cmp
SETUP='printf "hello world\n" > a; head -c 10000 /dev/zero | tr "\0" x > big; : > empty; printf q > tiny; mkdir d; printf z > d/f; ln -s a lnk; chmod 400 ro 2>/dev/null; printf r > ro; chmod 400 ro; mkfifo ff; head -c 5000 /dev/zero | tr "\0" y > blk'
mask() { sed -E 's/\(([0-9a-f]{6})\)/(PAT)/g; s#/[0-9]+ [0-9]+%#/N P%#' ; }
shred_cmp() {
    description="$1"; shift
    base="$TEST_TMP/sh"; rm -rf "$base"; mkdir -p "$base/g" "$base/o"
    for x in g o; do (cd "$base/$x" && eval "$SETUP_CMD"); done
    (cd "$base/g" && LC_ALL=C gnu "$@" > ../g.out 2> ../g.err; echo $? > ../g.rc)
    (cd "$base/o" && ours "$@" > ../o.out 2> ../o.err; echo $? > ../o.rc)
    for x in g o; do (cd "$base/$x" && find . -printf '%p %y %m %s\n' | sort) > "$base/$x.tree"; norm_err < "$base/$x.err" | mask > "$base/$x.err2"; done
    if cmp -s "$base/g.out" "$base/o.out" && cmp -s "$base/g.err2" "$base/o.err2" && cmp -s "$base/g.rc" "$base/o.rc" && cmp -s "$base/g.tree" "$base/o.tree"; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU  rc=%s err=%s\n     OURS rc=%s err=%s\n" "$description" "$(cat "$base/g.rc")" "$(cat -A "$base/g.err2" | head -12)" "$(cat "$base/o.rc")" "$(cat -A "$base/o.err2" | head -12)"
        diff "$base/g.tree" "$base/o.tree" | head -6
    fi
}
SETUP_CMD="$SETUP"
for f in a big empty tiny d/f lnk ro blk; do
    for o in "" -v -u -uv -vz -z -x -vx "-n 1" "-n 0" "-n 5 -v" "-n 7 -vz" "-n 25 -v" "-n 30 -v" "-n 2 -vu" "-s 3 -v" "-s 20000 -v" "-s 1K -v" "-s 0 -v" -f -fu -fvu "--remove=unlink" "--remove=wipe" "--remove=wipesync" "--remove=wipe -v" "--remove=unlink -v" "--remove=bogus" "-x -z -u -v" "-s 100 -x -v" "-n 3 -s 5000 -zv"; do
        shred_cmp "shred $o $f" $o $f
    done
done
shred_cmp "multiple" -v a big tiny
shred_cmp "multiple missing" -v a nosuch tiny
shred_cmp "missing" nosuch
shred_cmp "missing -f" -f nosuch
shred_cmp "directory" d
shred_cmp "directory -u" -u d
shred_cmp "dir -v" -v d
shred_cmp "no operand"
shred_cmp "bad option" -z2 a
shred_cmp "bad -n" -n x a
shred_cmp "bad -n neg" -n -1 a
shred_cmp "bad -n huge" -n 99999999999999999999 a
shred_cmp "bad -s" -s x a
shred_cmp "bad -s neg" -s -1 a
shred_cmp "-s suffix" -s 1c a
shred_cmp "-s KB" -s 1KB a
shred_cmp "-s bad suffix" -s 1q a
shred_cmp "random-source missing" --random-source=nosuch a
shred_cmp "random-source empty" --random-source=empty -v a
shred_cmp "random-source two" --random-source=big --random-source=tiny a
shred_cmp "random-source same" --random-source=big --random-source=big a
shred_cmp "-- args" -- a
shred_cmp "ro without -f" -v ro
shred_cmp "ro with -f" -fv ro
shred_cmp "ro -fu" -fu ro
shred_cmp "-u names" -uv big
shred_cmp "-uz names" -uvz tiny
# shred fsyncs its target, and fsync on /dev/full waits for the machine's pending disk
# writeback (the process sits uninterruptible in sync_inodes_sb, GNU's as well as ours, and
# cannot be killed). Opt in with SHRED_DEVFULL=1 on an idle machine.
[ -n "${SHRED_DEVFULL:-}" ] && shred_cmp "dev full" /dev/full
shred_cmp "dash" - 
# A file system without RENAME_NOREPLACE (NFS, CIFS, many FUSE ones) fails the
# renameat2 call; the name must still be wiped.
if strace -o /dev/null -e inject=renameat2:error=EINVAL true 2>/dev/null; then
    base="$TEST_TMP/noreplace"; mkdir -p "$base"
    for err in EINVAL ENOSYS; do
        (cd "$base" && printf secret > longsecretname &&
            strace -f -o "$base.tr" -e trace=renameat2 -e inject=renameat2:error=$err "$BIN_DIR/shred" -uv longsecretname 2> "$base.err")
        rc=$?
        if [ "$rc" = 0 ] && grep -q 'renamed to 0$' "$base.err" && [ -z "$(ls -A "$base")" ]; then
            PASS=$((PASS + 1)); echo "PASS the name is wiped when renameat2 gives $err"
        else
            FAIL=$((FAIL + 1)); echo "FAIL the name is wiped when renameat2 gives $err (rc=$rc)"; tail -4 "$base.err"
        fi
    done
    # When no rename works at all, say so.
    (cd "$base" && printf secret > longsecretname &&
        strace -f -o "$base.tr" -e trace=renameat2 -e inject=renameat2:error=EPERM "$BIN_DIR/shred" -u longsecretname 2> "$base.err")
    rc=$?
    if [ "$rc" = 0 ] && [ "$(grep -c 'not fully wiped' "$base.err")" = 1 ] && [ -z "$(ls -A "$base")" ]; then
        PASS=$((PASS + 1)); echo "PASS a name that cannot be wiped is reported once"
    else
        FAIL=$((FAIL + 1)); echo "FAIL a name that cannot be wiped is reported once (rc=$rc)"; tail -4 "$base.err"
    fi
else
    skip_test "renameat2 without RENAME_NOREPLACE (no usable strace)"
fi
# Running out of memory is said, and nothing is overwritten (DISK-009).
printf secret > "$TEST_TMP/sf"
out=$( (ulimit -v 1000000; "$BIN_DIR/shred" -n 100000000000 "$TEST_TMP/sf") </dev/null 2>&1 >/dev/null; echo "status $?")
case $out in
*"memory exhausted"*"status 1") PASS=$((PASS + 1)); echo "PASS shred -n too large" ;;
*) FAIL=$((FAIL + 1)); echo "FAIL shred -n too large: $out" ;;
esac

cd /; print_summary
