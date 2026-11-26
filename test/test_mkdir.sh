#!/bin/sh
# mkdir: differential tests against GNU mkdir. References: GNU manual "mkdir
# invocation"; POSIX.1-2024 mkdir. Known difference (documented): GNU 9.7
# yields 1755 for `-m +t` (and o+t, a+t); we yield 1777.
UTIL="mkdir"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic ]\n"
run_tree "one directory"            : a
run_tree "several directories"      : a b c
run_tree "trailing slash"           : a/
run_tree "existing directory"       'mkdir a' a
run_tree "existing among new"       'mkdir b' a b c
run_tree "existing file"            'touch f' f
run_tree "missing parent"           : a/b
run_tree "parent is a file"         'touch f' f/x
run_tree "-v"                       : -v a b
run_tree "--verbose"                : --verbose a
run_tree "-- then dash name"        : -- -d
run_tree "no operand"               :
run_tree "invalid option"           : -x a
run_tree "unrecognized long"        : --nope a

printf "\n[ -p parents ]\n"
run_tree "-p nested"                : -p a/b/c
run_tree "-p existing"              'mkdir -p a/b' -p a/b
run_tree "-p partly existing"       'mkdir a' -p a/b/c
run_tree "-pv"                      : -pv a/b/c
run_tree "-pv existing parent"      'mkdir a' -pv a/b
run_tree "-pv trailing slash"       : -pv a/b/
run_tree "-p repeated slashes"      : -p a//b///c
run_tree "-p absolute-style ./"     : -p ./a/./b
run_tree "-p file in the way"       'touch f' -p f
run_tree "-p file in path"          'touch f' -p f/z
run_tree "--parents"                : --parents a/b
run_tree "-p ..-component"          'mkdir a' -p a/../b/c
run_tree "-p umask 077 parent mode" : -p a/b
TREE_UMASK=077 run_tree "-p umask 077"  : -p a/b/c
TREE_UMASK=000 run_tree "-p umask 000"  : -p a/b/c
TREE_UMASK=277 run_tree "-p umask 277 (u needs wx)" : -p a/b/c

printf "\n[ -m mode ]\n"
for m in 755 700 0 777 7777 1777 2755 4755 u=rwx,g=rx,o= u=r a-x go-rx -w +x u+s g+s u+s,g+s,o+t =rx =t a= = g=u ug=o a+rx,go-w g-w,-x 'u=rwx,go=' 'a=r,u+w'; do
    run_tree "-m $m (umask 022)" : -m "$m" d
done
for um in 077 000 027; do
    TREE_UMASK=$um run_tree "-m 755 umask $um" : -m 755 d
    TREE_UMASK=$um run_tree "-m -w umask $um" : -m -w d
    TREE_UMASK=$um run_tree "-m =rx umask $um" : -m =rx d
done
run_tree "--mode=700"                : --mode=700 d
run_tree "-m700 attached"            : -m700 d
run_tree "--mode 700 separate"       : --mode 700 d
run_tree "-m with -p (parents unaffected)" : -p -m 700 a/b/c
run_tree "-m applies to every operand" : -m 711 a b
run_tree "-m invalid"                : -m zz d
run_tree "-m 8"                      : -m 8 d
run_tree "-m 10000"                  : -m 10000 d
run_tree "-m empty"                  : -m '' d
run_tree "-m missing arg"            : -m
run_tree "-m on existing dir fails"  'mkdir d' -m 700 d
run_tree "-pm on existing dir"       'mkdir -m 755 d' -p -m 700 d

printf "\n[ -Z accepted ]\n"
run_tree "-Z"                        : -Z d

# The new file is replaced by a link to "victim" before mkdir sets its mode;
# strace holds mkdir after the call that creates it.
d=$(mktemp -d)
if can_inject; then
    mkdir "$d/victim"
    chmod 700 "$d/victim"
    (cd "$d" && exec timeout 30 strace -o /dev/null -e trace=mkdirat -e inject=mkdirat:delay_exit=1500000:when=1 "$BIN_DIR/mkdir" -m 777 node > out 2>&1) & race_pid=$!
    tries=0
    while [ ! -e "$d/node" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
    mv "$d/node" "$d/moved" && ln -s victim "$d/node"
    wait "$race_pid"; rc=$?
    mode=$(stat -c %a "$d/victim")
    if [ "$rc" -eq 1 ] && [ "$mode" = 700 ]; then
        PASS=$((PASS + 1)); echo "PASS mkdir -m 777 node does not change the target of a swapped-in link"
    else
        FAIL=$((FAIL + 1)); echo "FAIL mkdir -m 777 node does not change the target of a swapped-in link (rc=$rc, victim $mode)"; cat "$d/out"
    fi
else
    skip_test "mkdir -m 777 node link race (needs strace)"
fi
chmod -R u+rwx "$d"; rm -rf "$d"
# The same for a parent made by -p, which is given u+wx under a strict umask.
d=$(mktemp -d)
if can_inject; then
    mkdir "$d/victim"; chmod 500 "$d/victim"
    (cd "$d" && umask 277 && exec timeout 30 strace -o /dev/null -e trace=mkdirat -e inject=mkdirat:delay_exit=1500000:when=1 "$BIN_DIR/mkdir" -p node/child > out 2>&1) & race_pid=$!
    tries=0
    while [ ! -e "$d/node" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
    mv "$d/node" "$d/moved" && ln -s victim "$d/node"
    wait "$race_pid"
    mode=$(stat -c %a "$d/victim")
    if [ "$mode" = 500 ]; then
        PASS=$((PASS + 1)); echo "PASS mkdir -p does not change the target of a swapped-in parent link"
    else
        FAIL=$((FAIL + 1)); echo "FAIL mkdir -p does not change the target of a swapped-in parent link (victim $mode)"; cat "$d/out"
    fi
else
    skip_test "mkdir -p link race (needs strace)"
fi
chmod -R u+rwx "$d"; rm -rf "$d"

# In a set-group-ID directory a new directory inherits the bit, and it stays
# unless the mode mentions it.
SG='mkdir g; chmod 2775 g'
for m in 755 0755 00755 700 0 2755 4755 1777 6000 u=rwx u=rwx,g=rx,o= g=rx g=s g-s g+s u+s +s a-s ug=rwx,g-s g+s,g=rx a= = =rwx -w g=u o=g go=; do
    run_tree "setgid parent -m $m"      "$SG" -m "$m" g/new
    run_tree "setgid parent -p -m $m"   "$SG" -p -m "$m" g/p/new
    run_tree "plain parent -m $m"       'mkdir g' -m "$m" g/new
done
# (0777 would also make run_tree's own capture files unreadable.)
for u in 022 077 0277 0377; do
    TREE_UMASK=$u run_tree "setgid parent umask $u"    "$SG" g/new
    TREE_UMASK=$u run_tree "setgid parent -p umask $u" "$SG" -p g/p1/p2/p3
    TREE_UMASK=$u run_tree "setgid parent -p -m 750 umask $u" "$SG" -p -m 750 g/p1/p2
done
print_summary
