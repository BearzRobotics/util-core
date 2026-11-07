#!/bin/sh
# chgrp: differential tests against GNU chgrp 9.7 (C locale), run without
# privileges (only the user's own groups can be set). test/test_chown.sh holds
# the traversal and option matrix; this suite covers the chgrp entry point.
UTIL="chgrp"
. "$(dirname "$0")/testlib.sh"
help_cmp
export TREE_OWNER=1
MYGID=$(id -g); MYGRP=$(id -gn)
OTHER=$(id -G | tr ' ' '\n' | grep -v "^$MYGID\$" | head -1); [ -z "$OTHER" ] && OTHER=$MYGID
OTHERNAME=$(getent group "$OTHER" | cut -d: -f1)
SETUP='mkdir -p d/sub e; touch f d/a d/sub/b; ln -s f lnk; ln -s d dlnk; ln -s nothing dang; mkdir noperm; touch noperm/x; chmod 000 noperm'

for g in "$MYGRP" "$MYGID" "$OTHERNAME" "$OTHER" "root" "0" "nosuchgroup" "+$MYGID" "4294967295" "-1" "" ":" "a:b" "$MYGRP:x" ".$MYGRP" "99999999999999999999"; do
    run_tree "group '$g'" "$SETUP" "$g" f
    run_tree "group '$g' -v" "$SETUP" -v "$g" f d lnk
done
for o in -c -v -f -h -R -Rh -RH -RL -RP -Rc -Rv -Rf --changes --verbose --quiet --silent --dereference --no-dereference --recursive "-R --preserve-root" "-R --dereference" "-R -L --dereference"; do
    run_tree "$o" "$SETUP" $o "$OTHERNAME" f lnk dlnk dang d e
    run_tree "$o same" "$SETUP" $o "$MYGRP" f lnk d noperm
done
run_tree "--from" "$SETUP" -v --from=":$MYGRP" "$OTHERNAME" f d
run_tree "--from nomatch" "$SETUP" -v --from=root "$OTHERNAME" f d
run_tree "--reference" "$SETUP; chgrp $OTHER d/a" -v --reference=d/a f d
run_tree "--reference none" "$SETUP" --reference=nosuch f
run_tree "-R order" "$SETUP" -Rv "$OTHERNAME" d
run_tree "-R unreadable" "$SETUP" -Rv "$OTHERNAME" noperm
run_tree "missing" "$SETUP" -v "$OTHERNAME" nosuch
run_tree "root group" "$SETUP" -v root f
run_tree "no args" ""
run_tree "one arg" "" "$OTHERNAME"
run_tree "bad option" "" -z
run_tree "-R preserve-root" "$SETUP" -R --preserve-root "$OTHERNAME" /
cd /; print_summary
