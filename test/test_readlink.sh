#!/bin/sh
# readlink: differential tests against GNU readlink 9.7 (C locale). Paths in
# the output are masked (run_tree) so the two working directories compare equal.
UTIL="readlink"
. "$(dirname "$0")/testlib.sh"
S='echo A > a; mkdir d; echo C > d/c; ln -s a sl; ln -s sl sl2; ln -s d sd; ln -s nowhere dang; ln -s d/c slc; ln -s /etc/passwd abs; ln -s ../a d/up; ln -s loop2 loop1; ln -s loop1 loop2; ln -s a/b nodir'
for o in "" -f -e -m -n -v -q -s -z -fn -en -mn -fv -ev -mv -fz -ez -mz; do
    for f in a sl sl2 sd dang slc abs d d/c d/up nodir nofile nofile/x sd/c sl/x loop1 . .. ./a d/../a a/ sl/ d/ ''; do
        run_tree "readlink $o '$f'"   "$S" $o "$f"
    done
done
run_tree "several"                 "$S" sl sd abs a
run_tree "several -f"              "$S" -f sl sd nofile a
run_tree "several -n"              "$S" -n sl sd
run_tree "several -nf"             "$S" -nf sl sd
run_tree "several -e"              "$S" -e sl nofile sd
run_tree "several -z"              "$S" -z sl sd
run_tree "no operand"              "$S"
run_tree "-x"                      "$S" -x sl
run_tree "--canonicalize"          "$S" --canonicalize sl
run_tree "--canonicalize-existing" "$S" --canonicalize-existing sl
run_tree "--canonicalize-missing"  "$S" --canonicalize-missing nofile
run_tree "--no-newline"            "$S" --no-newline sl
run_tree "--verbose"               "$S" --verbose a
run_tree "--quiet"                 "$S" --quiet a
run_tree "--silent"                "$S" --silent a
run_tree "--zero"                  "$S" --zero sl
run_tree "--bogus"                 "$S" --bogus sl
run_tree "--"                      "$S" -- sl
print_summary
