#!/bin/sh
# realpath: differential tests against GNU realpath 9.7 (C locale).
UTIL="realpath"
. "$(dirname "$0")/testlib.sh"
S='echo A > a; mkdir d d/e; echo C > d/c; ln -s a sl; ln -s sl sl2; ln -s d sd; ln -s nowhere dang; ln -s d/c slc; ln -s /etc/passwd abs; ln -s ../a d/up; ln -s loop2 loop1; ln -s loop1 loop2; ln -s a/b nodir; ln -s ../d/e d/e2'
FILES="a sl sl2 sd dang slc abs d d/c d/up d/e d/e2 nodir nofile nofile/x nofile/../a sd/c sl/x loop1 . .. ./a d/../a d/./c a/ sl/ d/ d//c //d / /etc/../etc"
for o in "" -e -m -s -L -P -eL -mL -sL -q -eq -mq -z; do
    for f in $FILES; do
        run_tree "realpath $o $f"   "$S" $o -- "$f"
    done
done
run_tree "empty name"              "$S" ''
run_tree "empty name -m"           "$S" -m ''
run_tree "empty name -e"           "$S" -e ''
for o in "--relative-to=d" "--relative-to=sd" "--relative-to=d/e" "--relative-to=." "--relative-to=nofile" "--relative-to=/" "--relative-to=a" "--relative-base=d" "--relative-base=/" "--relative-base=/nonexistent" "--relative-to=d --relative-base=d" "--relative-to=d/e --relative-base=d" "--relative-to=d --relative-base=d/e"; do
    for f in a d d/c d/e sl nofile d/nofile /etc/passwd .; do
        run_tree "realpath $o $f"   "$S" $o -- "$f"
    done
    run_tree "realpath -m $o"       "$S" -m $o -- a d/nofile nofile/x
done
run_tree "several"                 "$S" a d sl nofile d/c
run_tree "several -e"              "$S" -e a nofile d
run_tree "several -z"              "$S" -z a d
run_tree "no operand"              "$S"
run_tree "-x"                      "$S" -x a
run_tree "--canonicalize-existing" "$S" --canonicalize-existing a
run_tree "--canonicalize-missing"  "$S" --canonicalize-missing nofile
run_tree "--logical"               "$S" --logical sd/..
run_tree "--physical"              "$S" --physical sd/..
run_tree "--quiet"                 "$S" --quiet nofile/x
run_tree "--strip"                 "$S" --strip sl
run_tree "--no-symlinks"           "$S" --no-symlinks sl
run_tree "--zero"                  "$S" --zero a
run_tree "--relative-to missing arg" "$S" a --relative-to
run_tree "--bogus"                 "$S" --bogus a
# A name that cannot be examined (no search permission, a component too long)
# is an error except with -m, never a canonical name.
d="$TEST_TMP/denied"; mkdir -p "$d"; cd "$d" || exit 1
mkdir locked dir noexec; : > f; : > locked/x; : > noexec/y; ln -s locked/x tolocked; ln -s locked tolockeddir; ln -s nowhere dang
chmod 000 locked; chmod 444 noexec
long=$(printf 'a%.0s' $(seq 300))
if [ -r locked/x ]; then
    skip_test "realpath on names without search permission (running as root)"
    names=
else
    names="locked/x locked/a/b locked/./x locked/x/ tolocked tolocked/ tolockeddir/x tolocked/.. noexec/y noexec/.. locked locked/ locked/.."
fi
for o in "" -e -m -s -L -q; do
    for n in $names "$long" "$long/x" "dir/$long" f/. f/.. f/ nosuch/ nosuch/. nosuch/x nosuch/x/.. dir/nosuch/ dang/ dang/x; do
        run_cmp "realpath $o $(printf '%.30s' "$n")" $o "$n"
    done
done
# -L applies ".." to the name before following links; -s, -L and -P override
# one another, apart from -e and -m.
mkdir -p logical/a/b logical/t && (cd logical && ln -s a/b l)
cd logical
for o in -L -s -P "-s -L" "-L -s" "-s -P" "-s -e" "-L -e" "-L -m" "--relative-to=l/.. -L" "--relative-base=l -s"; do
    for n in l/.. l/../t l/../a nosuch/.. l/nosuch nosuch/x; do
        run_cmp "links $o $n" $o "$n"
    done
done
cd ..
chmod 755 locked noexec; cd /
print_summary
