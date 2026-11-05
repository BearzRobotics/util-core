#!/bin/sh
# rmdir: differential tests against GNU rmdir. References: GNU manual "rmdir
# invocation"; POSIX.1-2024 rmdir.
UTIL="rmdir"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic ]\n"
run_tree "one empty directory"     'mkdir a' a
run_tree "several"                 'mkdir a b c' a b c
run_tree "trailing slash"          'mkdir a' a/
run_tree "-v"                      'mkdir a b' -v a b
run_tree "--verbose"               'mkdir a' --verbose a
run_tree "non-empty"               'mkdir a; touch a/f' a
run_tree "non-empty among others"  'mkdir a b; touch a/f' a b
run_tree "missing"                 : nope
run_tree "a file"                  'touch f' f
run_tree "file path component"     'touch f' f/x
run_tree "no operand"              :
run_tree "invalid option"          'mkdir a' -x a
run_tree "unrecognized long"       : --nope a
run_tree "-- then dash name"       'mkdir ./-d' -- -d
run_tree "symlink to directory"    'mkdir t; ln -s t l' l
run_tree "dot"                     'mkdir a' .
run_tree "parent then child order" 'mkdir -p a/b' a a/b
run_tree "child then parent order" 'mkdir -p a/b' a/b a

printf "\n[ -p ]\n"
run_tree "-p nested"               'mkdir -p a/b/c' -p a/b/c
run_tree "-pv nested"              'mkdir -p a/b/c' -pv a/b/c
run_tree "-p stops at non-empty"   'mkdir -p a/b/c; touch a/b/f' -p a/b/c
run_tree "-pv stops at non-empty"  'mkdir -p a/b/c; touch a/b/f' -pv a/b/c
run_tree "-p missing"              : -p nope/zz
run_tree "-p trailing slashes"     'mkdir -p s/t' -pv s/t//
run_tree "-p ./ prefix"            'mkdir -p ab/cd' -pv ./ab/cd
run_tree "-p single component"     'mkdir a' -p a
run_tree "-p several operands"     'mkdir -p a/b c/d' -p a/b c/d
run_tree "--parents"               'mkdir -p a/b' --parents a/b
run_tree "-p with .."              'mkdir -p a/b' -p a/b/../b

printf "\n[ --ignore-fail-on-non-empty ]\n"
run_tree "ignore non-empty"        'mkdir a; touch a/f' --ignore-fail-on-non-empty a
run_tree "ignore with -pv"         'mkdir -p a/b; touch a/f' --ignore-fail-on-non-empty -pv a/b
run_tree "ignore does not hide missing" : --ignore-fail-on-non-empty nope
run_tree "abbreviated --ignore"    'mkdir a; touch a/f' --ignore a

print_summary
