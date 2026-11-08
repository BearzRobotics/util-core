#!/bin/sh
# tree: differential tests against tree 2.3.1 (C locale and C.UTF-8).
UTIL="tree"
ORACLE_OK=1  # tree is not a GNU program; the reference is Steve Baker's tree 2.3.1
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
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

for loc in C C.UTF-8; do
  CMP_LOCALE=$loc
  for o in "" "-a" "-d" "-f" "-i" "-q" "-N" "-Q" "-QN" "-p" "-u" "-g" "-s" "-h" "--si" "-D" "-F" "--inodes" "--device" "-l" "-L 1" "-L 2" "-L 3" "-x" "-t" "-r" "-v" "-U" "-c" "--dirsfirst" "--filesfirst" "--dirsfirst -r" "--noreport" "-A" "-S" "-n" "-C" "--charset=utf-8" "--charset=ascii" "--charset=iso-8859-1" "--du" "-pugsD" "-pugsDF" "-P *.c" "-P *.c|*.md" "-P f*" "-P F*" "--ignore-case -P F*" "-I *.c" "-I dir1" "-I dir1|d2" "-I f* -a" "--matchdirs -P dir*" "--matchdirs -P d*" "--matchdirs -P sub" "--prune" "--prune -P *.c" "-d --prune" "-X" "-J" "-J -a" "-X -s" "-J -s -p" "-X -D -u -g" "-J -d" "-X -d" "-J --noreport" "-X --noreport" "-a -p" "--sort=size" "--sort=size -r" "--sort=name" "--sort=version" "--sort=mtime" "--sort=ctime" "--sort=none" "--sort=bogus" "-hD" "--timefmt %Y-%m-%d -D" "--timefmt %c -D" "--filelimit 2" "--filelimit 5" "--filelimit 0" "-L 2 -d" "-C -F" "-C -a" "-C -l" "-t -r" "-d --prune" "-P *.c --prune" "-l -L 2" "-d -l" "-f -i" "-h --du" "-a --du -s" "--du -d" "--du -L 1" "--du -P *.c" "--du --prune" "--du -I dir1" "--dirsfirst --sort=size" "-tr --dirsfirst" "-f -L 1" "-f -d" "-fi" "-Qi" "-qf" "-pQ" "-sF" "-ph" "-L 0" "-L x" "-L" "-P" "-I" "--bogus" "-Z" "--filelimit x" "--timefmt" "-lL 1" "-xl" "-axl" "--inodes --device -p" "-Cp" "-CD" "-Cs"; do
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
  td "$loc -o out" -o out.txt dir1
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
help_cmp_tree() {
    exp=$(LC_ALL=C /usr/bin/tree --help 2>&1)
    act=$(ours --help 2>&1)
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); printf "PASS --help text\n"
    else FAIL=$((FAIL + 1)); printf "FAIL --help text\n"; fi
}
help_cmp_tree
cd /; print_summary
