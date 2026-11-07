#!/bin/sh
# dir: shares its implementation with ls; test/test_ls.sh holds the extensive
# comparison. This suite checks the dir entry point against GNU dir.
UTIL="dir"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
export TZ=UTC
mkdir -p t/sub; printf x > t/a; printf x > "t/b c"; printf x > t/.h; ln -s a t/l; mkfifo t/f; touch -d '2001-02-03 04:05:06' t/a t/sub
for o in "" -a -A -l -1 -C -x -m -R -F -s -i -b -Q -N -r -t -S -X -d -h --si --color=always --quoting-style=shell --format=commas -w 30 -T 4 --time-style=long-iso --full-time -n -g -o -G; do
    run_cmp "dir $o" $o t
done
run_cmp "missing" nosuch
run_cmp "bad option" -z
print_summary
