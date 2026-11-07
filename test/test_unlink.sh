#!/bin/sh
# unlink: differential tests against GNU unlink 9.7 (C locale).
UTIL="unlink"
. "$(dirname "$0")/testlib.sh"
run_tree "regular file"            'touch a b' a
run_tree "missing"                 : nofile
run_tree "directory"               'mkdir d' d
run_tree "symlink"                 'touch t; ln -s t l' l
run_tree "dangling symlink"        'ln -s nowhere l' l
run_tree "hard link"               'touch a; ln a b' a
run_tree "no permission dir"       'mkdir d; touch d/f; chmod 500 d' d/f
run_tree "name with space"         'touch "a b"' "a b"
run_tree "name needing quotes"     'touch "a*b"' nofile*
run_tree "no operand"              : 
run_tree "two operands"            'touch a b' a b
run_tree "--"                      'touch -- -x' -- -x
run_tree "-x"                      : -x
run_tree "--bogus"                 : --bogus
run_tree "trailing slash on file"  'touch a' a/
run_tree "empty name"              : ''
print_summary
