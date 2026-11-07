#!/bin/sh
# mktemp: differential tests against GNU mktemp 9.7 (C locale). References: GNU
# manual "mktemp invocation". The random characters differ per run, so output
# and the resulting tree are compared after every letter and digit is masked
# to 'x' (shape: length, separators, fixed text positions); literal prefixes
# and suffixes are checked separately below.
UTIL="mktemp"
. "$(dirname "$0")/testlib.sh"
help_cmp
mask() { sed 's/[A-Za-z0-9]/x/g'; }
# run_mask DESC SETUP ARGS... : like run_tree with masked names.
run_mask() {
    description="$1"; setup="$2"; shift 2
    base="$TEST_TMP/mk"; chmod -R u+rwx "$base" 2>/dev/null; rm -rf "$base"; mkdir -p "$base/g" "$base/o"
    for x in g o; do (cd "$base/$x" && eval "$setup"); done
    (cd "$base/g" && TMPDIR="$base/g" LC_ALL=C gnu "$@" > "$base/g.out" 2> "$base/g.err"; echo $? > "$base/g.rc")
    (cd "$base/o" && TMPDIR="$base/o" ours "$@" > "$base/o.out" 2> "$base/o.err"; echo $? > "$base/o.rc")
    for x in g o; do
        (cd "$base/$x" && find . -printf '%p %y %m\n' | mask | sort > "$base/$x.tree")
        sed "s#$base/$x#BASE#g" "$base/$x.out" | mask > "$base/$x.out2"
        sed "s#$base/$x#BASE#g" "$base/$x.err" | norm_err > "$base/$x.err2"
    done
    if cmp -s "$base/g.out2" "$base/o.out2" && cmp -s "$base/g.err2" "$base/o.err2" && cmp -s "$base/g.rc" "$base/o.rc" && cmp -s "$base/g.tree" "$base/o.tree"; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU  rc=%s out=%s err=%s\n     OURS rc=%s out=%s err=%s\n" "$description" "$(cat "$base/g.rc")" "$(cat "$base/g.out2")" "$(cat -A "$base/g.err2")" "$(cat "$base/o.rc")" "$(cat "$base/o.out2")" "$(cat -A "$base/o.err2")"
        diff "$base/g.tree" "$base/o.tree" | head -6
    fi
}
S='mkdir d; touch exists'
run_mask "default"               "$S"
run_mask "-d"                    "$S" -d
run_mask "-u"                    "$S" -u
run_mask "-d -u"                 "$S" -d -u
run_mask "-q default"            "$S" -q
run_mask "template"              "$S" fooXXXX
run_mask "template 3 X"          "$S" fooXXX
run_mask "template 2 X"          "$S" fooXX
run_mask "template 2 X quiet"    "$S" -q fooXX
run_mask "no X"                  "$S" foo
run_mask "only X"                "$S" XXXXXX
run_mask "empty template"        "$S" ''
run_mask "slash"                 "$S" /
run_mask "suffix implied"        "$S" fooXXXXbar
run_mask "suffix implied dot"    "$S" fooXXXX.txt
run_mask "X after suffix start"  "$S" fooXXXXbarXX
run_mask "X in middle"           "$S" fooXXXbarXXXbaz
run_mask "--suffix"              "$S" --suffix=.txt fooXXXX
run_mask "--suffix no X end"     "$S" --suffix=.txt fooXXXXbar
run_mask "--suffix empty"        "$S" --suffix= fooXXXX
run_mask "--suffix slash"        "$S" --suffix=/x fooXXXX
run_mask "--suffix separate"     "$S" --suffix .c fooXXXX
run_mask "--suffix default tmpl" "$S" --suffix=.log
run_mask "implied suffix slash"  "$S" fooXXXX/bar
run_mask "subdir template"       "$S" d/fooXXXX
run_mask "missing subdir"        "$S" nodir/fooXXXX
run_mask "missing subdir quiet"  "$S" -q nodir/fooXXXX
run_mask "-d subdir"             "$S" -d d/fooXXXX
run_mask "-p dir"                "$S" -p d
run_mask "-p dir template"       "$S" -p d fooXXXX
run_mask "-p . template"         "$S" -p . fooXXXX
run_mask "-p dir/ template"      "$S" -p d/ fooXXXX
run_mask "-p absolute template"  "$S" -p d /abs/XXXX
run_mask "-p missing"            "$S" -p nodir
run_mask "-p missing quiet"      "$S" -q -p nodir
run_mask "-p file"               "$S" -p exists
run_mask "-p slash template"     "$S" -p d sub/fooXXXX
run_mask "-p ./template"         "$S" -p . ./XXXX
run_mask "-p needs arg"          "$S" -p
run_mask "--tmpdir=d"            "$S" --tmpdir=d
run_mask "--tmpdir=d tmpl"       "$S" --tmpdir=d fooXXXX
run_mask "--tmpdir tmpl"         "$S" --tmpdir fooXXXX
run_mask "--tmpdir alone"        "$S" --tmpdir
run_mask "--tmpdir abs tmpl"     "$S" --tmpdir /x/fooXXXX
run_mask "-t"                    "$S" -t
run_mask "-t template"           "$S" -t fooXXXX
run_mask "-t slash"              "$S" -t d/fooXXXX
run_mask "-t -p"                 "$S" -t -p d fooXXXX
run_mask "-p -t"                 "$S" -p d -t fooXXXX
run_mask "-td"                   "$S" -td fooXXXX
run_mask "-d -p"                 "$S" -d -p d fooXXXX
run_mask "-u -p"                 "$S" -u -p d fooXXXX
run_mask "two templates"         "$S" fooXXXX barXXXX
run_mask "dash template"         "$S" -- -XXXX
run_mask "space template"        "$S" 'a bXXXX'
run_mask "long template"         "$S" XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
run_mask "-V"                    "$S" --bogus
run_mask "bad option"            "$S" -x
run_mask "long abbrev"           "$S" --dir
run_mask "--dry-run"             "$S" --dry-run fooXXXX
run_mask "--quiet"               "$S" --quiet nodir/XXXX
run_mask "--directory"           "$S" --directory fooXXXX

# Literal parts and permissions (GNU and ours must agree on these exactly).
D="$TEST_TMP/lit"; mkdir -p "$D"; cd "$D"
chk() { desc="$1"; shift; if "$@"; then PASS=$((PASS + 1)); printf "PASS %s\n" "$desc"; else FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$desc"; fi; }
chk "prefix kept"      sh -c "$BIN_DIR/mktemp -u zzpre-XXXXXXXX | grep -q '^zzpre-[A-Za-z0-9]\{8\}\$'"
chk "suffix kept"      sh -c "$BIN_DIR/mktemp -u zzXXXXXX-suf | grep -q '^zz[A-Za-z0-9]\{6\}-suf\$'"
chk "--suffix kept"    sh -c "$BIN_DIR/mktemp -u --suffix=.sfx zzXXXXXX | grep -q '^zz[A-Za-z0-9]\{6\}\.sfx\$'"
chk "default name"     sh -c "TMPDIR=$D $BIN_DIR/mktemp -u | grep -q '^$D/tmp\.[A-Za-z0-9]\{10\}\$'"
chk "file mode 600"    sh -c "f=\$($BIN_DIR/mktemp zzmodeXXXX) && [ \"\$(stat -c %a \$f)\" = 600 ] && [ -f \$f ]"
chk "dir mode 700"     sh -c "f=\$($BIN_DIR/mktemp -d zzdirXXXX) && [ \"\$(stat -c %a \$f)\" = 700 ] && [ -d \$f ]"
chk "umask 077 file"   sh -c "umask 277; f=\$($BIN_DIR/mktemp zzumXXXX) && [ \"\$(stat -c %a \$f)\" = 400 ]"
chk "dry run absent"   sh -c "f=\$($BIN_DIR/mktemp -u zzdryXXXX) && [ ! -e \$f ]"
chk "names differ"     sh -c "[ \"\$($BIN_DIR/mktemp -u XXXXXXXXXX)\" != \"\$($BIN_DIR/mktemp -u XXXXXXXXXX)\" ]"
chk "all chars used"   sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do $BIN_DIR/mktemp -u XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX; done | fold -w1 | sort -u | wc -l | grep -qx 62"
chk "no X left"        sh -c "! $BIN_DIR/mktemp -u fooXXXXXX | grep -q X"
print_summary
[ "$FAIL" -eq 0 ]
