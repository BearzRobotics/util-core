#!/bin/sh
# link: differential tests against GNU link 9.7 (C locale).
UTIL="link"
. "$(dirname "$0")/testlib.sh"
run_tree "simple"                  'echo hi > a' a b
run_tree "target exists"           'touch a b' a b
run_tree "source missing"          : nofile b
run_tree "source is directory"     'mkdir d' d e
run_tree "dest in missing dir"     'touch a' a nodir/b
run_tree "dest is directory"       'touch a; mkdir d' a d
run_tree "source symlink"          'touch t; ln -s t l' l m
run_tree "one operand"             'touch a' a
run_tree "three operands"          'touch a' a b c
run_tree "no operand"              :
run_tree "same file"               'touch a' a a
run_tree "name with space"         'touch "a b"' "a b" "c d"
run_tree "unreadable dir"          'mkdir d; touch d/f; chmod 500 d' d/f d/g
run_tree "--"                      'touch -- -x' -- -x y
run_tree "-x"                      : -x
print_summary
