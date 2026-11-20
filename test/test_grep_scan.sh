#!/bin/sh
# grep buffer-wide pre-filter (literal scan, DFA scan, bulk -v counting):
# differential tests against GNU grep 3.12 on multi-megabyte inputs, so lines
# cross the read-buffer boundaries. Output and exit status must be identical.
UTIL="grep"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
export TZ=UTC LC_ALL=C

python3 -I - <<'EOF'
import random
r = random.Random(5)
vocab = ["the", "two", "and", "zqxjv", "Foo", "foo", "foobar", "a.b", "x_y", "k", "ss", "café", "ÉTÉ", "12", "007", "end"]
def line():
    n = r.choice([0, 1, 3, 8, 8, 8, 20])
    return " ".join(r.choice(vocab) for _ in range(n))
with open("text", "w", encoding="utf-8", newline="") as f:
    size = 0
    while size < 1500000:
        l = line()
        f.write(l + "\n")
        size += len(l) + 1
    f.write(" ".join(r.choice(vocab) for _ in range(5)))  # no final newline
with open("long", "w") as f:  # lines longer than the read buffer
    for i in range(6):
        f.write(("x" * 300000) + (" zqxjv " if i % 2 else " the ") + ("y" * 270000) + "\n")
    f.write("zqxjv")
EOF
printf 'zqxjv\nthe\nfoo\n' > pats3
printf 'the\ntwo\nand\nzqxjv\nfoo\nend\nk\n' > pats7
printf 'zqxjv\n^the\n' > patsanch

run() {
    desc=$1; shift
    gnu "$@" > g.out 2> g.err; grc=$?
    ours "$@" > o.out 2> o.err; orc=$?
    TOTAL=$((TOTAL + 1))
    if [ $grc = $orc ] && cmp -s g.out o.out && cmp -s g.err o.err; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL $desc (rc gnu=$grc ours=$orc)"
    fi
}
TOTAL=0 PASS=0 FAIL=0
for f in text long; do
    for pat in zqxjv the two foo 'fo*' 'foo\|zqxjv' 'the$' '^the' '^foo' '^the$' 'end$' '^Foo$' '^foo\|end$' '^$' 'a.b' 'x_y' 'k' 'ss' 'end' '[0-9][0-9]*' '007' 'zq.*v' 'e\{2\}' 'o\+' 'x*' '' 'xx*y' 'Foo\|foo'; do
        for opts in "" -n -c -v -vc -vn -i -ic -w -wc -x -xc -o -on -b -bo -m3 -nm3 -A1 -B1 -C1 -nA2 -l -L -q -z -zc -Fc; do
            case $f$opts in long*-[AoBCbn]*|long*-i|long*-z*) continue ;; esac
            run "$opts '$pat' $f" $opts -e "$pat" $f
        done
    done
    for pat in 'the\|two' 'the\|two\|and' 'zqxjv\|^the' '(the|two)s?' 'ca.é' 'fo+|ba+r'; do
        for opts in -E -Ec -Ev -Evc -Ei -Eic -Ew -Ewc -En -Eo -Ex; do
            case $f in long) continue ;; esac
            run "$opts '$pat' $f" $opts -e "$pat" $f
        done
    done
done
for pf in pats3 pats7 patsanch; do
    for opts in "-F" "-Fc" "-Fn" "-Fv" "-Fvc" "-Fi" "-Fic" "-Fw" "-Fx" "-Fo" "-Fob" "-G" "-Gc" "-Gv" "-Gn" "-Gvc"; do
        run "$opts -f $pf text" $opts -f $pf text
    done
done
# a pattern list with a pattern spanning nothing special, many files, stdin
run "multi file" -c the text long pats3
for o in -c -vc -n -ov; do
    sh -c "/usr/bin/grep $o the < text" > g.out 2>&1; sh -c "\"$BIN_DIR/grep\" $o the < text" > o.out 2>&1
    TOTAL=$((TOTAL + 1)); if cmp -s g.out o.out; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL stdin $o"; fi
done
cat text | gnu -n zqxjv > g.out; cat text | ours -n zqxjv > o.out
TOTAL=$((TOTAL + 1)); if cmp -s g.out o.out; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL pipe"; fi
# UTF-8 locale
export LC_ALL=C.UTF-8
for pat in 'café' 'ÉTÉ' 'k' 'ss' 'the' 'c.fé'; do
    for opts in "" -i -ic -c -w -x -o -n -vc; do
        run "utf8 $opts '$pat'" $opts -e "$pat" text
    done
done

echo
echo "======================================"
echo " grep scan: $PASS/$TOTAL passed"
[ $FAIL = 0 ] && echo " All tests passed!"
echo "======================================"
[ $FAIL = 0 ]
