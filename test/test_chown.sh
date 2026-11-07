#!/bin/sh
# chown: differential tests against GNU chown 9.7 (C locale). Run without
# privileges: only changes that an ordinary user may make (own uid, own
# groups) succeed; everything else produces the same errors in both programs.
# References: GNU manual "chown invocation", POSIX chown.
UTIL="chown"
. "$(dirname "$0")/testlib.sh"
help_cmp
export TREE_OWNER=1
ME=$(id -un); MYUID=$(id -u); MYGID=$(id -g); MYGRP=$(id -gn)
OTHER=$(id -G | tr ' ' '\n' | grep -v "^$MYGID\$" | head -1); OTHERNAME=$(getent group "$OTHER" | cut -d: -f1)
SETUP='mkdir -p d/sub/deep e; touch f d/a d/sub/b d/sub/deep/c; ln -s f lnk; ln -s d dlnk; ln -s nothing dang; ln -s ../d e/up; mkdir noperm; touch noperm/x; chmod 000 noperm'
[ -z "$OTHER" ] && OTHER=$MYGID && OTHERNAME=$MYGRP

printf "\n[ Specs ]\n"
for spec in "$ME" "$MYUID" "$ME:" "$ME:$MYGRP" "$ME:$MYGID" "$MYUID:$MYGID" "$ME.$MYGRP" ":$MYGRP" ":$MYGID" ":" "" "$ME:$OTHERNAME" ":$OTHERNAME" ":$OTHER" "root" "0" "root:" "root:root" ":root" "nosuchuser" "nosuchuser:" "$ME:nosuchgroup" ":nosuchgroup" "+$MYUID" "+$MYUID:+$MYGID" "4294967295" "4294967294" "-1" "$ME:$MYGRP:x" "a:b:c" ".$MYGRP" "$ME." "$ME.nosuch" "1.2.3" " $MYUID" "0x10" "010" "$MYUID " "99999999999999999999" ":99999999999999999999"; do
    run_tree "spec '$spec'" "$SETUP" "$spec" f
    run_tree "spec '$spec' -v" "$SETUP" -v "$spec" f
done

printf "\n[ Options ]\n"
for o in -c -v -f -h -R -Rh -RH -RL -RP -Rc -Rv -Rf -RhH -RhL -RHv -RLv -RPv -cv -vc -fv --changes --verbose --quiet --silent --dereference --no-dereference --recursive --preserve-root --no-preserve-root "-R --preserve-root" "-R --no-preserve-root" "-R --dereference" "-R -H --dereference" "-R -L --dereference" "-h --dereference" "--dereference -h"; do
    run_tree "$o file" "$SETUP" $o "$ME:$MYGRP" f lnk dlnk dang d
    run_tree "$o group other" "$SETUP" $o ":$OTHER" f lnk dlnk dang d e
    run_tree "$o dirs" "$SETUP" $o "$ME" d e noperm
done
run_tree "--from user" "$SETUP" -v --from="$ME" "$ME:$OTHER" f d/a
run_tree "--from user:group" "$SETUP" -v --from="$ME:$MYGRP" ":$OTHER" f d/a
run_tree "--from :group" "$SETUP" -v --from=":$MYGRP" ":$OTHER" f d/a
run_tree "--from nomatch" "$SETUP" -v --from=root ":$OTHER" f d/a
run_tree "--from nomatch grp" "$SETUP" -v --from=":root" ":$OTHER" f d/a
run_tree "--from numeric" "$SETUP" -v --from="$MYUID:$MYGID" ":$OTHER" f
run_tree "--from bad" "$SETUP" --from=nosuchuser ":$OTHER" f
run_tree "--from bad group" "$SETUP" --from=":nosuchgroup" ":$OTHER" f
run_tree "--from -R" "$SETUP" -R -v --from=":$MYGRP" ":$OTHER" d
run_tree "--from -R none" "$SETUP" -R -v --from=":root" ":$OTHER" d
run_tree "--from -h lnk" "$SETUP" -h -v --from="$ME" ":$OTHER" lnk dlnk
run_tree "--reference" "$SETUP; chgrp $OTHER d/a" --reference=d/a f
run_tree "--reference -v" "$SETUP; chgrp $OTHER d/a" -v --reference=d/a f d
run_tree "--reference lnk" "$SETUP" -v --reference=lnk f
run_tree "--reference dang" "$SETUP" --reference=dang f
run_tree "--reference none" "$SETUP" --reference=nosuch f
run_tree "--reference no files" "$SETUP" --reference=f
run_tree "--reference with spec" "$SETUP" --reference=f "$ME" d/a

printf "\n[ Recursion order and errors ]\n"
run_tree "-R tree" "$SETUP" -Rv ":$OTHER" d
run_tree "-R tree changes" "$SETUP" -Rc ":$OTHER" d e
run_tree "-R unreadable" "$SETUP" -R ":$OTHER" noperm
run_tree "-R unreadable v" "$SETUP" -Rv ":$OTHER" noperm
run_tree "-R unreadable f" "$SETUP" -Rf ":$OTHER" noperm
run_tree "-R missing" "$SETUP" -R ":$OTHER" nosuch d
run_tree "missing" "$SETUP" ":$OTHER" nosuch
run_tree "missing -f" "$SETUP" -f ":$OTHER" nosuch
run_tree "missing -v" "$SETUP" -v ":$OTHER" nosuch
run_tree "dangling" "$SETUP" -v ":$OTHER" dang
run_tree "dangling -h" "$SETUP" -hv ":$OTHER" dang
run_tree "dangling -R" "$SETUP" -Rv ":$OTHER" dang
run_tree "-RL up" "$SETUP; ln -s .. d/sub/loop" -RLv ":$OTHER" d
run_tree "-RH cycle" "$SETUP; ln -s .. d/sub/loop" -RHv ":$OTHER" d d/sub/loop
run_tree "-RP cycle" "$SETUP; ln -s .. d/sub/loop" -RPv ":$OTHER" d
run_tree "-RL dlnk" "$SETUP" -RLv ":$OTHER" dlnk
run_tree "-RH dlnk" "$SETUP" -RHv ":$OTHER" dlnk
run_tree "-RP dlnk" "$SETUP" -RPv ":$OTHER" dlnk
run_tree "-R dlnk/" "$SETUP" -Rv ":$OTHER" dlnk/
run_tree "-Rh dlnk" "$SETUP" -Rhv ":$OTHER" dlnk
run_tree "multiple" "$SETUP" -v ":$OTHER" f d/a d/sub/b nosuch lnk
run_tree "same file twice" "$SETUP" -v ":$OTHER" f f
run_tree "slash" "$SETUP" -v ":$OTHER" d/
run_tree "dot" "$SETUP" -Rv ":$OTHER" .
run_tree "-R preserve-root" "$SETUP" -R --preserve-root ":$OTHER" /
run_tree "-R preserve-root lnk" "$SETUP; ln -s / rootlnk" -RH --preserve-root ":$OTHER" rootlnk
run_tree "-RL preserve-root lnk" "$SETUP; ln -s / rootlnk" -RL --preserve-root ":$OTHER" rootlnk
run_tree "-R preserve-root //" "$SETUP" -R --preserve-root ":$OTHER" //
run_tree "--preserve-root not recursive" "$SETUP" --preserve-root ":$OTHER" f
run_tree "permission denied other user" "$SETUP" root f
run_tree "permission denied -v" "$SETUP" -v root f
run_tree "permission denied -c" "$SETUP" -c root:root f d
run_tree "permission denied -f" "$SETUP" -f root f
run_tree "permission denied group" "$SETUP" -v :root f
run_tree "permission denied -R" "$SETUP" -Rv root d
run_tree "permission denied -h" "$SETUP" -hv root lnk

printf "\n[ Usage ]\n"
run_tree "no args" ""
run_tree "one arg" "" "$ME"
run_tree "one arg --reference=f" "$SETUP" --reference=f
run_tree "bad option" "" -z
run_tree "bad long option" "" --bogus
run_tree "amb option" "" --re "$ME" f
run_tree "--from missing" "" --from
run_tree "-- args" "$SETUP" -- "$ME" f
run_tree "-- before spec" "$SETUP" -v -- ":$OTHER" f
run_tree "dash file" "$SETUP; touch ./-x" "$ME" -- -x
run_tree "empty file name" "$SETUP" "$ME" ""
run_tree "spec empty" "$SETUP" "" f
run_tree "-R -h -H" "$SETUP" -R -h -H ":$OTHER" d

cd /; print_summary
