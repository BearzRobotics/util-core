#!/bin/sh
# tree: differential tests against tree 2.3.1 (C locale and C.UTF-8).
UTIL="tree"
ORACLE_OK=1  # tree is not a GNU program; the reference is Steve Baker's tree 2.3.1
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
# The colour variables would otherwise be whatever this machine has.
export TERM=xterm
unset LS_COLORS TREE_COLORS NO_COLOR CLICOLOR CLICOLOR_FORCE
set -f
mkdir t && cd t
mkdir -p dir1/sub .hid emptyd d2/x/y/z deep/a/b/c/d/e
printf 'abc\n' > f1.txt; printf 'x' > "sp ace"; printf 'q' > "tab	name"; printf 'q' > 'quo"te'
printf 'q' > "new
line"; printf 'q' > 'back\slash'; printf 'q' > "$(printf 'hi\351x')"; printf 'q' > "caf$(printf '\303\251').txt"
printf 'z' > dir1/sub/deep.c; printf 'y' > dir1/a.sh; chmod +x dir1/a.sh; printf 'h' > .hid/h.txt; printf 'w' > .dot
printf 'x' > d2/x/y/z/file.md; printf 'x' > d2/x/top.md; printf 'e' > deep/a/b/c/d/e/end.txt
printf '1' > A; printf '2' > B; printf 'file10' > file10; printf 'file2' > file2; printf 'file1' > file1
ln -s f1.txt lnk; ln -s nowhere dang; ln -s dir1 dlink; ln -s . self; ln -s dir1/sub sublink; mkfifo fifo
head -c 3000 /dev/zero > big; head -c 100 /dev/zero > small; head -c 100000 /dev/zero > huge
touch -d '2020-03-04 05:06:07' f1.txt; touch -d '2000-01-01' big; touch -d '2010-06-15 12:00:00' small file1 file2 file10 A B
touch -d '2001-02-03 04:05:06' huge dir1 d2; chmod 4755 dir1/a.sh 2>/dev/null; chmod 640 f1.txt; chmod 1777 d2
mkdir private && printf 'p' > private/p.txt && chmod 000 private
cd "$W/t"
trap 'chmod -R u+rwx "$W" 2>/dev/null; chmod -R u+rwx "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT
ln -s dir1 d2/loopback 2>/dev/null

td() { d="$1"; shift; CMP_STDIN=/dev/null run_cmp "$d" "$@"; }
# tree_o DESC ARG...: with -o, each writes a file of its own; the two files,
# what is printed besides, and the status must agree.
tree_o() {
    d="$1"; shift
    rm -f "$W/o.gnu" "$W/o.ours"
    exp=$(LC_ALL="$CMP_LOCALE" gnu -o "$W/o.gnu" "$@" 2>&1; echo "status $?")
    act=$(LC_ALL="$CMP_LOCALE" ours -o "$W/o.ours" "$@" 2>&1; echo "status $?")
    if [ "$exp" = "$act" ] && [ -s "$W/o.gnu" ] && cmp -s "$W/o.gnu" "$W/o.ours"; then PASS=$((PASS + 1)); printf "PASS %s\n" "$d"
    else FAIL=$((FAIL + 1)); printf "FAIL %s (%s / %s)\n" "$d" "$exp" "$act"; diff "$W/o.gnu" "$W/o.ours" | head -6; fi
}

for loc in C C.UTF-8; do
  CMP_LOCALE=$loc
  for o in "" "-a" "-d" "-f" "-i" "-q" "-N" "-Q" "-QN" "-p" "-u" "-g" "-s" "-h" "--si" "-D" "-F" "--inodes" "--device" "-l" "-L 1" "-L 2" "-L 3" "-x" "-t" "-r" "-v" "-U" "-c" "--dirsfirst" "--filesfirst" "--dirsfirst -r" "--noreport" "-A" "-S" "-n" "-C" "--charset=utf-8" "--charset=ascii" "--charset=iso-8859-1" "--du" "-pugsD" "-pugsDF" "-P *.c" "-P *.c|*.md" "-P f*" "-P F*" "--ignore-case -P F*" "-I *.c" "-I dir1" "-I dir1|d2" "-I f* -a" "--matchdirs -P dir*" "--matchdirs -P d*" "--matchdirs -P sub" "--prune" "--prune -P *.c" "-d --prune" "-X" "-J" "-J -a" "-X -s" "-J -s -p" "-X -D -u -g" "-J -d" "-X -d" "-J --noreport" "-X --noreport" "-J -f" "-X -f" "-J -f -p" "-J -f -d" "-J -s -h" "-J -h" "-J --si -s" "-J -D" "-X -D" "-J -D --timefmt %Y-%m-%d" "-X -D --timefmt %Y-%m-%d" "-J -D --timefmt %s" "-J -pugsD" "-X -pugsD" "-J -f -s -h" "-J --du -s" "-X --du -s" "-J --du -h" "-J --du -s -d" "-J -f dir1 d2" "-J -h dir1 d2" "-a -p" "--sort=size" "--sort=size -r" "--sort=name" "--sort=version" "--sort=mtime" "--sort=ctime" "--sort=none" "--sort=bogus" "-hD" "--timefmt %Y-%m-%d -D" "--timefmt %c -D" "--filelimit 2" "--filelimit 5" "--filelimit 0" "-L 2 -d" "-C -F" "-C -a" "-C -l" "-t -r" "-d --prune" "-P *.c --prune" "-l -L 2" "-d -l" "-f -i" "-h --du" "-a --du -s" "--du -d" "--du -L 1" "--du -P *.c" "--du --prune" "--du -I dir1" "--dirsfirst --sort=size" "-tr --dirsfirst" "-f -L 1" "-f -d" "-fi" "-Qi" "-qf" "-pQ" "-sF" "-ph" "-L 0" "-L x" "-L" "-P" "-I" "--bogus" "-Z" "--filelimit x" "--timefmt" "-lL 1" "-xl" "-axl" "--inodes --device -p" "-Cp" "-CD" "-Cs"; do
    td "$loc tree $o" $o .
    td "$loc tree $o dir1 d2" $o dir1 d2
  done
  td "$loc file arg" f1.txt
  td "$loc file arg -p" -p f1.txt
  td "$loc link arg" lnk
  td "$loc link arg -l" -l dlink
  td "$loc link arg dir" dlink
  td "$loc missing" nosuch
  td "$loc missing + ok" nosuch dir1
  td "$loc unreadable" private
  td "$loc unreadable in tree" .
  td "$loc unreadable -a" -a private
  td "$loc empty dir" emptyd
  td "$loc empty dir -d" -d emptyd
  td "$loc hidden dir" .hid
  td "$loc hidden dir -a" -a .hid
  td "$loc trailing slash" dir1/
  td "$loc double slash" dir1//
  td "$loc dot slash" ./
  td "$loc dotdot" dir1/..
  td "$loc deep" deep
  td "$loc deep -L 3" -L 3 deep
  td "$loc deep -f" -f deep
  td "$loc deep -pugsD" -pugsD deep
  tree_o "$loc -o out" dir1
  td "$loc -o out missing dir" -o /nonexistent/out dir1
  td "$loc -- args" -- dir1
  td "$loc --version" --version
  td "$loc multiple roots -J" -J dir1 d2 emptyd
  td "$loc multiple roots -X" -X dir1 d2 emptyd
  td "$loc multiple roots" dir1 d2 emptyd f1.txt
  td "$loc -J file" -J f1.txt
  td "$loc -X file" -X f1.txt
  td "$loc -J missing" -J nosuch
  td "$loc -J private" -J private
  td "$loc -l loop" -l self
  td "$loc -l loop 2" -l -L 3 d2
  td "$loc -l dlink" -l -d
  td "$loc -L1 -Q -F" -L 1 -Q -F
  td "$loc --dirsfirst -a" --dirsfirst -a
  td "$loc --filesfirst -a" --filesfirst -a
done
for lc in 'rs=0:di=01;34:ln=01;36:ex=01;32' 'di=1;31' 'ln=target' 'or=01;31:mi=00' '*.txt=01;33:*.c=32' 'ex=' 'di=' 'fi=0' 'pi=33:so=35:bd=34:cd=33' 'su=37;41:sg=30;43:tw=30;42:ow=34;42:st=37;44' 'garbage' ''; do
  export LS_COLORS="$lc"
  for loc in C C.UTF-8; do
    CMP_LOCALE=$loc td "colors '$lc' $loc" -C
    CMP_LOCALE=$loc td "colors '$lc' $loc -F" -CF -a
    CMP_LOCALE=$loc td "colors '$lc' $loc -p" -Cpa d2
  done
done
unset LS_COLORS
CMP_LOCALE=C td 'LS_COLORS unset -C' tree -C -a
CMP_LOCALE=C td 'NO_COLOR' tree -C -n
# Short inode and device numbers are padded; sysfs has them everywhere.
if [ -d /sys/kernel ]; then
    CMP_LOCALE=C td 'short inode numbers' --inodes --device -d -L 1 /sys
    CMP_LOCALE=C td 'short inode numbers, -p' --inodes -p -d -L 1 /sys
fi

# Whether to colour and with which table, from the environment.
mkdir "$W/ext"; for e in tar gz zip jpg mp3 wav exe bat txt Tar 7z; do : > "$W/ext/f.$e"; done
ln -s nowhere "$W/ext/orphan"
for spec in '' TERM= CLICOLOR=1 CLICOLOR_FORCE=1 CLICOLOR_FORCE= 'NO_COLOR=1 CLICOLOR_FORCE=1' LS_COLORS= LS_COLORS=di=33 \
    'LS_COLORS=di=33 TREE_COLORS=di=32' 'LS_COLORS=di=33 TREE_COLORS=' LS_COLORS=no=36 LS_COLORS=no=36:mi=31; do
    for v in $spec; do export "$v"; done
    for o in -C -a '-n -C' '-C -n' -n; do CMP_LOCALE=C td "color env '$spec' $o" $o "$W/ext"; done
    unset LS_COLORS TREE_COLORS NO_COLOR CLICOLOR CLICOLOR_FORCE; export TERM=xterm
done
unset TERM
CMP_LOCALE=C td 'no TERM, -C' -C "$W/ext"
export TERM=xterm
help_cmp_tree() {
    exp=$(LC_ALL=C /usr/bin/tree --help 2>&1)
    act=$(ours --help 2>&1)
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); printf "PASS --help text\n"
    else FAIL=$((FAIL + 1)); printf "FAIL --help text\n"; fi
}
help_cmp_tree
# Any time the file system can hold: no crash, the seconds are shown where there
# is no calendar form. (tree 2.3.1 crashes, so there is nothing to compare with.
# Skipped where the file system clamps such times.)
mkdir "$W/times"
for secs in -9223372036854775808 -100000000000000000 100000000000000000 9223372036854775807; do
    : > "$W/times/f"; touch -m -d "@$secs" "$W/times/f"
    if [ "$(stat -c %Y "$W/times/f")" != "$secs" ]; then SKIP=$((SKIP + 1)); echo "SKIP mtime $secs not stored here"; continue; fi
    for o in "-D" "-J -D" "-X -D" "-D --timefmt %Y"; do
        out=$(cd "$W" && ours $o times 2>&1); rc=$?
        if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q -e "\\[$secs\\]" -e "\"$secs\"" -e ">$secs<"; then PASS=$((PASS + 1)); echo "PASS mtime $secs: tree $o"
        else FAIL=$((FAIL + 1)); echo "FAIL mtime $secs: tree $o (rc=$rc)"; printf '%s\n' "$out" | head -8; fi
    done
done
# Past PATH_MAX the listing stops where tree's does. The tree is walked a
# directory at a time from open descriptors, which could go further.
mkdir "$W/deep" && ( cd "$W/deep" && i=0; while [ $i -lt 2100 ]; do mkdir a && cd -P a || exit 1; i=$((i + 1)); done ) 2>/dev/null
for o in -d -J; do
    exp=$(cd "$W" && ulimit -s 8192 && LC_ALL=C gnu $o deep 2>&1 | cksum; echo)
    act=$(cd "$W" && ulimit -s 8192 && LC_ALL=C timeout 120 "$BIN_DIR/tree" $o deep 2>&1 | cksum; echo)
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS past PATH_MAX $o"
    else FAIL=$((FAIL + 1)); echo "FAIL past PATH_MAX $o: GNU $exp, ours $act"; fi
done
/usr/bin/rm -rf "$W/deep"

# Link loops end in every output mode, not only in the text listing. (With a
# timeout: without loop detection these never finish.)
mkdir -p "$W/loops/two/d" "$W/loops/up/a/b/c" "$W/loops/cross/one" "$W/loops/cross/other"
ln -s . "$W/loops/two/d/s1"; ln -s . "$W/loops/two/d/s2"
ln -s ../.. "$W/loops/up/a/b/c/back"; ln -s a "$W/loops/up/q"; echo z > "$W/loops/up/a/b/c/z"
ln -s ../other "$W/loops/cross/one/over"; ln -s ../one "$W/loops/cross/other/back"; echo y > "$W/loops/cross/other/y"
cd "$W/loops"
ours() { timeout 20 "$BIN_DIR/$UTIL" "$@"; }
for o in "-l" "-J -l" "-X -l" "--du -l" "--du -l -h" "-J --du -l" "-X --du -l" "-J -l -s" "-X -l -s" "-J --du -l -s" "-J -l --noreport" "-J -l -d" "-J -l -a"; do
    for t in two up cross; do
        case $o in
        *--du*)
            # Under --du tree walks in the order the file system returns the
            # names, and that decides which link of a loop it follows. Ours
            # walks in sorted order; compare where the two are the same.
            if [ "$t" != two ] && [ "$(/usr/bin/ls -U "$t")" != "$(LC_ALL=C /usr/bin/ls "$t")" ]; then
                if ours $o $t > /dev/null 2>&1; then PASS=$((PASS + 1)); echo "PASS loop $o $t ends"
                else FAIL=$((FAIL + 1)); echo "FAIL loop $o $t ends"; fi
                continue
            fi ;;
        esac
        td "loop $o $t" $o $t
    done
done
td "loop -J -l two roots" -J -l two cross
ours() { "$BIN_DIR/$UTIL" "$@"; }
# Characters that are not printable are escaped in a UTF-8 locale too, the C1
# controls (U+009B starts a control sequence) among them.
mkdir -p "$W/c1/d"; cd "$W/c1"
: > "d/$(printf 'a\302\2332Jb')"; : > "d/$(printf 'b\302\200\302\205\302\237')"; : > "d/$(printf 'c\315\270\342\200\250\357\277\276')"
: > "d/$(printf 'd\303\251\302\240\342\200\213\360\237\230\200\356\200\200')"; ln -s "$(printf 't\302\233q')" d/link
for o in "" "-q" "-N" "-Q" "-f" "-F" "-p" "-qQ"; do
    CMP_LOCALE=C.UTF-8 td "unprintable characters $o" $o --noreport d
    CMP_LOCALE=C td "unprintable characters, C locale $o" $o --noreport d
done
# Entries that cannot be examined leave nothing behind on standard error (FIND-031).
mkdir -p "$W/nostat/sub" && touch "$W/nostat/sub/a" "$W/nostat/sub/b" && chmod 600 "$W/nostat/sub"
CMP_LOCALE=C td 'a directory without search permission' "$W/nostat"
chmod 700 "$W/nostat/sub"

cd /; print_summary
