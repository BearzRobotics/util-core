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
shred_cmp "dev full" /dev/full
shred_cmp "dash" - 
cd /; print_summary
