#!/bin/sh
# diff: differential tests against GNU diff 3.12 (C locale). References: GNU
# diffutils manual "Comparing and Merging Files"; POSIX.1-2024 diff.
# NPAIRS (default 150) sets how many generated pairs are run per format.
UTIL="diff"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"
export TZ="${TZ:-America/New_York}"

W="$(mktemp -d)"; cd "$W"
printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n' > o
printf '1\n2\nx\n4\n5\n6\n7\n8\n9\n10\ny\nz\n12\n' > n
touch -d '2024-01-02 03:04:05.123456789 +0000' o
touch -d '2024-05-06 07:08:09 +0000' n
printf 'a\nb\nc\nd\ne\n' > i1; printf 'a\nX\nc\ne\nf\n' > i2
printf 'a\n.\nb' > m1; printf 'a\n.\nc\n.' > m2
printf 'a\nb' > e1; printf 'a\nc' > e2; printf 'a\nb\n' > e3
printf 'a\n\nb\n\n' > s1; printf 'a\n\nc\nd\n\n' > s3
printf 'a\r\nb\r\nc\n' > cr1; printf 'a\nB\nc\n' > cr2
printf 'a\tb\nlonglonglonglonglonglong\n' > t1; printf 'a\tc\nlonglonglonglonglongXXXXXXXXXX\n' > t2
printf 'a  b\nc d\n' > w1; printf 'a b\nc   d\n' > w2
printf 'Hello\nWORLD\n' > c1; printf 'hello\nworld\n' > c2
printf 'int f(void)\n{\n  a;\n  b;\n  c;\n  d;\n  e;\n  f;\n  g;\n}\nint g(void)\n{\n  h;\n}\n' > f1
printf 'int f(void)\n{\n  a;\n  b;\n  c;\n  d;\n  e;\n  f;\n  X;\n}\nint g(void)\n{\n  Y;\n}\n' > f2
printf 'x\0y\n' > bin1; printf 'x\0z\n' > bin2; printf 'text\n' > txt
: > empty
printf 'one\n' > one
printf 'x\n' > oneline
mkdir -p d1/sub d1/only1 d2/sub d2/same
printf 'x\n' > d1/a; printf 'y\n' > d2/a
printf 's\n' > d1/sub/f; printf 't\n' > d2/sub/f
printf '1\n' > d1/o1; printf '2\n' > d2/o2
printf 'q\n' > d1/same.txt; printf 'q\n' > d2/same.txt
mkdir d1/dd; printf 'q\n' > d2/dd
ln -s a d1/lnk; ln -s b d2/lnk
touch -d '2024-01-01 00:00:00 +0000' d1/a d2/a d1/sub/f d2/sub/f d1/o1 d2/o2 d1/same.txt d2/same.txt

printf "\n[ Formats on fixed pairs ]\n"
PAIRS="o,n i1,i2 m1,m2 e1,e2 e1,e3 e3,e1 e3,e2 e1,e1 s1,s3 cr1,cr2 t1,t2 w1,w2 c1,c2 f1,f2 empty,o o,empty empty,empty one,oneline bin1,bin2 bin1,txt txt,txt"
for p in $PAIRS; do
    a=${p%,*}; b=${p#*,}
    for f in "" -c -u -e -f -n "-C 1" "-U 0" "-U 1" "-c -L X -L Y" "-u -L X -L Y" -q -s "-u -T" "-c -T" "-u -t" "-u --suppress-blank-empty" "-c --suppress-blank-empty" "-i" "-w" "-b" "-B" "-Z" "-E" "--strip-trailing-cr" "-a" "-ia -u" "-d" "-H" "--horizon-lines=5" "-p -u" "-p -c" "-F 'int' -u"; do
        eval run_cmp \"diff $f $a $b\" $f $a $b
    done
done

printf "\n[ Side by side ]\n"
for p in o,n i1,i2 s1,s3 t1,t2 empty,o one,oneline m1,m2; do
    a=${p%,*}; b=${p#*,}
    for f in -y "-y -W 40" "-y -W 20" "-y -W 31" "-y -W 130 -t" "-y -t -W 41" "-y --left-column" "-y --suppress-common-lines" "-y -T -W 60" "-y --tabsize=4 -W 50" "-y --tabsize=3 -W 41" "-y -W 11" "-y -W 5" "-y -W 3" "-y -W 2" "-y -W 1" "-y -i" "-y --suppress-blank-empty"; do
        eval run_cmp \"diff $f $a $b\" $f $a $b
    done
done
for w in 8 9 10 12 15 16 17 18 19 20 21 22 23 24 25 28 30 33 36 37 40 45 50 62 64 65 69 70 77 80 100 128 129 130 131 132 133 134 140 200; do
    run_cmp "side-by-side W=$w" -y -W $w t1 t2
    run_cmp "side-by-side W=$w -t" -y -t -W $w t1 t2
done

printf "\n[ Line formats ]\n"
for f in "-D FOO" "-D FOO -i" "--line-format=%L" "--line-format=[%l]" "--line-format=%dn:%L" "--old-line-format=-%l
 --new-line-format=+%l
 --unchanged-line-format= %l
" "--changed-group-format=<<%<==%>>>
 --unchanged-group-format=" "--old-group-format=%dn,%df,%dl,%de,%dm|%< --new-group-format=%(F=L?one:many)%dN:%dF:%dL:%dE:%dM|%>" "--new-group-format=%c'\\101'%%%c'x'%>" "--line-format=%5dn|%-5dn|%05.3dn|%xn|%on|%Xn %L"; do
    for p in i1,i2 o,n e1,e2 empty,o o,empty m1,m2; do
        a=${p%,*}; b=${p#*,}
        run_cmp "format [$f] $a $b" $f $a $b
    done
done

printf "\n[ Option handling and errors ]\n"
for args in "-c -u o n" "-u -c o n" "-e -n o n" "-C x o n" "-U -1 o n" "-W 0 o n" "-W x o n" "--tabsize=0 o n" "--tabsize=x o n" "-L a -L b -L c o n" "o" "o n x" "-D" "-I \\( o n" "-x" "-3 o n" "-12 o n" "-u3 o n" "--context=2 o n" "--unified o n" "--unified=1 o n" "-C 2 -c o n" "-U2 -C1 o n" "-ey o n" "--line-format=x -c o n" "-D X -y o n" "-y -c o n" "-q -c o n" "-N -c o n" "--horizon-lines=x o n" "--color=bad o n" "--normal -c o n" "-f -e o n" "-fn o n" "--binary o n" "-h o n" "--palette=x o n" "--bogus" "--nor o n" "--ignore-c o n" "nonex n" "o nonex" "o o" "-s o o" "-q o o" "-s o n" "--brief o n" "--report-identical-files o o" "-r o n" "-i -s w1 w2" "-ws w1 w2" "-bs w1 w2" "-Bs s1 s3" "-I 1 -s o o" "-I x o n" "-I '^[0-9]*$' o n" "-I 3 o n" "-I '[xyz]' o n" "-I '[xyz]' -u o n" "-I '1' -I x -u o n" "-B -u s1 s3" "-B -c s1 s3" "-B -y s1 s3" "-B o n" "-w -B s1 s3"; do
    eval run_cmp \"diff $args\" $args
done

printf "\n[ Control characters, -t, -T, pagination, same file ]\n"
printf 'a\tb\r\fc\bd\ve\n\a\t\n\n' > cc1; printf 'a\tb\r\fc\bd\ve\n\a\t\x01\x80\n\n\n' > cc2
printf '\x07\n\t\x1b\xff\r\r\bx\n' > cc3; printf '\x0c\n\t\x1b\xfe\r\bx\r\n' > cc4
for p in cc1,cc2 cc3,cc4 s1,s3; do
    a=${p%,*}; b=${p#*,}
    for f in "-y -W 15" "-y -t -W 15" "-y -t -W 20" "-y -W 30" "-u -t" "-c -t" "-u -T" "-u -T --suppress-blank-empty" "-t -D X" "-n -t" "-t" "-t -e"; do
        eval run_cmp \"diff $f $a $b\" $f $a $b
    done
done
for f in "-l" "-lu" "-l -y" "-l -D X" "-l -e" "-l -c -L A -L B"; do
    run_cmp "diff $f o n" $f o n
done
for f in -y "-y --suppress-common-lines" "-D X" "--line-format=%L" "-u" ""; do
    run_cmp "same file $f" $f o o
done

printf "\n[ Standard input ]\n"
CMP_STDIN="$W/o"
run_cmp "stdin vs n"       - n
run_cmp "n vs stdin"       n -
run_cmp "stdin vs stdin"   - -
run_cmp "-u stdin label"   -u -L stdin -L n - n
run_cmp "stdin vs dir"     - d1
run_cmp "dir vs stdin"     d1 -
CMP_STDIN="$W/e"
unset CMP_STDIN

printf "\n[ Directories ]\n"
for f in "" -r "-r -u" "-ru" "-r -q" "-r -s" "-rN" "-rNu" "-r -c -x a" "-r --exclude=a" "-rq -x sub" "-r -y -W 40" "-r -e" "-r -n" "-r -D X" "-l" "-r --no-dereference" "-r -L x" "-r -N -u -L x -L y" "-r -t" "-r -T -u" "-r -I 1" "-rs --brief" "-r -x a -x lnk -x dd" "-r -x 'o*'" "-r -S o2" "-rP" "-r --unidirectional-new-file -u" "-r --ignore-file-name-case" "-r --strip-trailing-cr" "-r -i" "-r -q -N"; do
    run_tree "dirs $f" "mkdir -p d1/sub d1/only1 d2/sub d2/same d1/dd; printf 'x\n' > d1/a; printf 'y\n' > d2/a; printf 's\n' > d1/sub/f; printf 't\n' > d2/sub/f; printf '1\n' > d1/o1; printf '2\n' > d2/o2; printf 'q\n' > d1/same.txt; printf 'q\n' > d2/same.txt; printf 'q\n' > d2/dd; ln -s a d1/lnk; ln -s b d2/lnk; touch -d 2024-01-01 d1/a d2/a d1/sub/f d2/sub/f d1/o1 d2/o2 d1/same.txt d2/same.txt" $f d1 d2
done
run_tree "file vs dir"  "mkdir d; printf 'x\n' > d/f; printf 'y\n' > f; touch -d 2024-01-01 d/f f" -u f d
run_tree "dir vs file"  "mkdir d; printf 'x\n' > d/f; printf 'y\n' > f; touch -d 2024-01-01 d/f f" d f
run_tree "file vs dir missing"  "mkdir d; printf 'y\n' > f" f d
run_tree "dir vs dir same"  "mkdir -p d1 d2; printf 'y\n' > d1/f; printf 'y\n' > d2/f" -s d1 d2
run_tree "trailing slash"  "mkdir -p d1 d2; printf 'x\n' > d1/f; printf 'y\n' > d2/f; touch -d 2024-01-01 d1/f d2/f" -u d1/ d2/
run_tree "from-file"  "printf 'x\n' > a; printf 'y\n' > b; printf 'x\n' > c" --from-file=a b c
run_tree "to-file"  "printf 'x\n' > a; printf 'y\n' > b; printf 'x\n' > c" --to-file=a b c
run_tree "from-file dir"  "mkdir d; printf 'x\n' > d/b; printf 'y\n' > b" --from-file=d b

printf "\n[ Help ]\n"
help_cmp_diffutils

printf "\n[ Generated pairs ]\n"
NPAIRS="${NPAIRS:-150}"
GENSTART=$PASS; GENFAIL0=$FAIL
i=0
while [ $i -lt "$NPAIRS" ]; do
    i=$((i + 1))
    awk -v seed=$i 'BEGIN { srand(seed);
        nvocab = 2 + int(rand() * 12); n = int(rand() * 70);
        if (rand() < 0.1) n = 100 + int(rand() * 400);
        rep = rand() < 0.15;
        for (k = 0; k < n; k++) {
            if (rep && rand() < 0.5 && k > 0) a[k] = a[k - 1]; else a[k] = "line" int(rand() * nvocab);
            if (rand() < 0.05) a[k] = "";
            if (rand() < 0.04) a[k] = "  " a[k] "\t ";
            if (rand() < 0.03) a[k] = toupper(a[k]);
        }
        pe = 0.02 + rand() * 0.2;
        m = 0;
        for (k = 0; k < n; k++) {
            r = rand();
            if (r < pe / 3) continue;
            if (r < 2 * pe / 3) { b[m++] = "new" int(rand() * 6); }
            if (r < pe) { b[m++] = "chg" int(rand() * 6); continue; }
            b[m++] = a[k];
        }
        if (rand() < 0.1) { for (k = 0; k < 8; k++) b[m++] = "tail" k; }
        crlf = rand() < 0.07; nonl0 = rand() < 0.1; nonl1 = rand() < 0.1;
        for (k = 0; k < n; k++) printf "%s%s%s", a[k], crlf ? "\r" : "", (k == n - 1 && nonl0) ? "" : "\n" > "g1";
        for (k = 0; k < m; k++) printf "%s%s%s", b[k], crlf ? "\r" : "", (k == m - 1 && nonl1) ? "" : "\n" > "g2";
        printf "" >> "g1"; printf "" >> "g2" }'
    [ -f g1 ] || : > g1
    [ -f g2 ] || : > g2
    for f in "" -c -u -e -n -f -y "-y -W 60" "-U 0" "-C 1" "-U 8" "-i -u" "-w -u" "-b -c" "-B -u" "-Z" "-E" "-d" "-H -u" "--strip-trailing-cr -u" "-D X" "--line-format=%dn:%L" "-y --suppress-common-lines" "-y --left-column -W 41" "-p -u" "-u --horizon-lines=20"; do
        run_cmp "gen $i diff $f" $f g1 g2
    done
    rm -f g1 g2
done
GENPASS=$((PASS - GENSTART)); GENFAILS=$((FAIL - GENFAIL0)); GENTOTAL=$((GENPASS + GENFAILS))
printf "\nGenerated pairs: %d/%d agree with GNU diff\n" "$GENPASS" "$GENTOTAL"

CMP_STDIN=/dev/null
# Two files with the same inode number, size and time on different file systems
# are not the same file. bwrap gives each its own tmpfs, where the first file
# gets the same number.
d="$TEST_TMP/twofs"; mkdir -p "$d/m1" "$d/m2"
TWO='echo AAAA > "$1/m1/f"; echo BBBB > "$1/m2/f"; touch -d @1000000000 "$1/m1/f" "$1/m2/f"'
two_fs() { # SHELL-SCRIPT, with the directory as $1 and the program as $2
    timeout 20 bwrap --ro-bind / / --tmpfs "$d/m1" --tmpfs "$d/m2" /bin/sh -c "$TWO; $1" sh "$d" "$2"
}
if command -v bwrap > /dev/null && [ "$(two_fs 'stat -c %i "$1/m1/f" "$1/m2/f" | uniq | wc -l' '' 2>/dev/null)" = 1 ]; then
    for args in "m1/f m2/f" "-r m1 m2" "-q m1/f m2/f" "-rs m1 m2"; do
        exp=$(LC_ALL=C two_fs "cd \"\$1\" && \"\$2\" $args; echo status \$?" "${GNU_BIN:-/usr/bin}/$UTIL" 2>&1)
        act=$(LC_ALL=C two_fs "cd \"\$1\" && \"\$2\" $args; echo status \$?" "$BIN_DIR/$UTIL" 2>&1)
        if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS equal inodes on two file systems: $UTIL $args"
        else FAIL=$((FAIL + 1)); echo "FAIL equal inodes on two file systems: $UTIL $args"; printf '%s\n---\n%s\n' "$exp" "$act"; fi
    done
else
    skip_test "equal inodes on two file systems (needs bwrap and matching inode numbers)"
fi
# -q must not go by sizes that files do not have (VIEW-010).
for f in /proc/version /proc/filesystems /sys/kernel/mm/transparent_hugepage/enabled; do
    [ -r "$f" ] || continue
    cat "$f" > "$TEST_TMP/copy"; { cat "$f"; echo more; } > "$TEST_TMP/longer"; head -c 5 "$f" > "$TEST_TMP/shorter"
    for other in copy longer shorter; do
        run_cmp "-q $f $other" -q "$f" "$TEST_TMP/$other"
        run_cmp "-q $other $f" -q "$TEST_TMP/$other" "$f"
        run_cmp "-qs $f $other" -qs "$f" "$TEST_TMP/$other"
    done
done
: > "$TEST_TMP/empty"; printf 'x\n' > "$TEST_TMP/one"; head -c 4096 /dev/zero > "$TEST_TMP/page"; { cat "$TEST_TMP/page"; echo; } > "$TEST_TMP/page1"
for a in "empty one" "one empty" "page page1" "page1 page" "page page" "empty empty"; do
    run_cmp "-q sizes $a" -q "$TEST_TMP/${a% *}" "$TEST_TMP/${a#* }"
done

# Standard input that is the other file, partly read already (VIEW-009): its
# contents differ from the file's. (The last case also skips back into step.)
printf 'xx\nabc\n' > "$TEST_TMP/pos"
for args in '- pos' 'pos -' '- -' '-s - pos'; do
    case $args in -s*) [ diff = cmp ] || continue ;; esac
    for start in 0 3; do
        exp=$( cd "$TEST_TMP" && { [ $start = 0 ] || dd bs=1 count=$start of=/dev/null status=none; LC_ALL=C gnu $args 2>&1; echo "status $?"; } < pos )
        act=$( cd "$TEST_TMP" && { [ $start = 0 ] || dd bs=1 count=$start of=/dev/null status=none; LC_ALL=C ours $args 2>&1; echo "status $?"; } < pos )
        if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS stdin from $start: $args"
        else FAIL=$((FAIL + 1)); echo "FAIL stdin from $start: $args"; echo "     GNU : $exp"; echo "     OURS: $act"; fi
    done
done

print_summary
[ "$FAIL" -eq 0 ]
