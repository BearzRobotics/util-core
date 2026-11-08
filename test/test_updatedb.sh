#!/bin/sh
# updatedb: differential tests against GNU findutils 4.10 updatedb/frcode,
# built from source (tools/build-gnu-findutils.sh). The databases produced by
# both programs are compared byte for byte.
UTIL="updatedb"
FU="${GNU_BIN:-$HOME/.cache/util-core/findutils/bin}"
if [ ! -x "$FU/updatedb" ]; then
    echo "SKIP: GNU findutils not built; run tools/build-gnu-findutils.sh" >&2
    exit 0
fi
GNU_BIN="$FU"; export GNU_BIN
ORACLE_OK=1  # updatedb --version starts with a blank line
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
export TZ=UTC LC_ALL=C
set -f
mkdir -p tree/a/b tree/c "tree/sp ace" tree/d/e/f tree/skip tree/other.d tree/m
for f in a/one.txt a/b/Two.TXT a/b/three.c c/four.sh "sp ace/five six" top.md d/e/f/deep.dat d/e/UPPER LOWER skip/x skip/y other.d/z m/q; do : > "tree/$f"; done
: > "tree/new
line"; : > "tree/$(printf 'caf\303\251')"; ln -s one.txt tree/a/link; ln -s nowhere tree/dangling
i=0; while [ $i -lt 300 ]; do : > "tree/m/file_with_a_rather_long_name_to_force_prefix_differences_$i"; i=$((i+1)); done
mkdir -p tree/deepdir; p=tree/deepdir; i=0; while [ $i -lt 40 ]; do p="$p/level$i"; i=$((i+1)); done; mkdir -p "$p"; : > "$p/end"
mkdir -p tree/private && : > tree/private/p && chmod 000 tree/private
trap 'chmod -R u+rwx "$W" 2>/dev/null; chmod -R u+rwx "$TEST_TMP" 2>/dev/null; rm -rf "$TEST_TMP"' EXIT

# ud DESC ARGS...: run both updatedbs, compare output, status and database
ud() {
    d="$1"; shift
    rm -f "$W/g.db" "$W/g.db.n" "$W/o.db" "$W/o.db.n"
    "$FU/updatedb" "$@" --output="$W/g.db" > "$W/g.out" 2> "$W/g.err"; gx=$?
    "$BIN_DIR/updatedb" "$@" --output="$W/o.db" > "$W/o.out" 2> "$W/o.err"; ox=$?
    sed -e "s#$W/g.db#DB#g; s#$FU/updatedb#updatedb#g" "$W/g.out" > "$W/g.out2"; sed -e "s#$W/o.db#DB#g; s#$BIN_DIR/updatedb#updatedb#g" "$W/o.out" > "$W/o.out2"
    sed -e "s#$W/g.db#DB#g; s#$FU/updatedb#updatedb#g; s#$FU/find#find#g" "$W/g.err" > "$W/g.err2"; sed -e "s#$W/o.db#DB#g; s#$BIN_DIR/updatedb#updatedb#g" "$W/o.err" > "$W/o.err2"
    ok=1
    cmp -s "$W/g.out2" "$W/o.out2" || ok=0
    cmp -s "$W/g.err2" "$W/o.err2" || ok=0
    [ "$gx" = "$ox" ] || ok=0
    if [ -e "$W/g.db" ] || [ -e "$W/o.db" ]; then cmp -s "$W/g.db" "$W/o.db" || ok=0; fi
    if [ "$ok" = 1 ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$d"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU  (rc=%s) out: %s err: %s\n     OURS (rc=%s) out: %s err: %s\n" "$d" "$gx" "$(cat -A "$W/g.out2" | head -5)" "$(cat -A "$W/g.err2" | head -5)" "$ox" "$(cat -A "$W/o.out2" | head -5)" "$(cat -A "$W/o.err2" | head -5)"
    fi
}
P="--prunepaths=/nonexistent"
ud 'tree' --localpaths="$W/tree" $P
ud 'tree two paths' --localpaths="$W/tree/a $W/tree/c" $P
ud 'tree two paths reversed' --localpaths="$W/tree/c $W/tree/a" $P
ud 'tree dup paths' --localpaths="$W/tree/a $W/tree/a" $P
ud 'tree nested paths' --localpaths="$W/tree $W/tree/a" $P
ud 'single file' --localpaths="$W/tree/top.md" $P
ud 'missing path' --localpaths="$W/nosuch" $P
ud 'missing path + ok' --localpaths="$W/nosuch $W/tree/c" $P
ud 'empty paths' --localpaths="" $P
ud 'netpaths' --localpaths="$W/tree/a" --netpaths="$W/tree/c" $P
ud 'netpaths only' --localpaths="" --netpaths="$W/tree/c" $P
ud 'prunepaths' --localpaths="$W/tree" --prunepaths="$W/tree/skip $W/tree/a/b"
ud 'prunepaths regex dot' --localpaths="$W/tree" --prunepaths="$W/tree/other.d"
ud 'prunepaths regex dot 2' --localpaths="$W/tree" --prunepaths="$W/tree/other.d $W/tree/oth.r"
ud 'prunepaths trailing slash' --localpaths="$W/tree" --prunepaths="$W/tree/skip/"
ud 'prunepaths start itself' --localpaths="$W/tree/skip" --prunepaths="$W/tree/skip"
ud 'prunepaths file' --localpaths="$W/tree" --prunepaths="$W/tree/top.md"
ud 'prunepaths star' --localpaths="$W/tree" --prunepaths="$W/tree/*"
ud 'prunepaths bracket' --localpaths="$W/tree" --prunepaths="$W/tree/[ab]"
ud 'prunefs ext4' --localpaths="$W/tree" $P --prunefs="ext4"
ud 'prunefs bogus' --localpaths="$W/tree" $P --prunefs="nosuchfs"
ud 'prunefs empty' --localpaths="$W/tree" $P --prunefs=""
ud 'prunefs many' --localpaths="$W/tree" $P --prunefs="nfs ext4 xfs"
ud 'findoptions -xdev' --localpaths="$W/tree" $P --findoptions='-xdev'
ud 'findoptions -mount' --localpaths="$W/tree" $P --findoptions='-mount'
ud 'findoptions -maxdepth' --localpaths="$W/tree" $P --findoptions='-maxdepth 2'
ud 'findoptions -mindepth' --localpaths="$W/tree" $P --findoptions='-mindepth 2'
ud 'findoptions -depth' --localpaths="$W/tree" $P --findoptions='-depth'
ud 'findoptions -noleaf' --localpaths="$W/tree" $P --findoptions='-noleaf'
ud 'findoptions bogus' --localpaths="$W/tree" $P --findoptions='-bogus'
ud 'findoptions maxdepth bad' --localpaths="$W/tree" $P --findoptions='-maxdepth x'
ud 'findoptions maxdepth missing' --localpaths="$W/tree" $P --findoptions='-maxdepth'
ud 'dbformat LOCATE02' --localpaths="$W/tree" $P --dbformat=LOCATE02
ud 'dbformat slocate' --localpaths="$W/tree" $P --dbformat=slocate
ud 'dbformat bogus' --localpaths="$W/tree" $P --dbformat=bogus
ud 'changecwd' --localpaths="tree" $P --changecwd="$W"
ud 'relative path' --localpaths="$W/tree/../tree/a" $P
ud 'dot path' --localpaths="$W/tree/./a" $P
ud 'trailing slash path' --localpaths="$W/tree/a/" $P
ud 'double slash path' --localpaths="$W/tree/a//" $P
ud 'root only prune all' --localpaths="/" --prunepaths="/ /" --prunefs=""
ud 'long db many entries' --localpaths="$W/tree/m" $P
ud 'deep paths' --localpaths="$W/tree/deepdir" $P
ud 'bad option' --bogus --localpaths="$W/tree/c"
ud 'bad option 2' --output --localpaths="$W/tree/c"
ud 'bad option 3' -x --localpaths="$W/tree/c"
ud 'version' --version
ud 'help' --help
ud 'netuser' --localpaths="$W/tree/c" --netuser=nobody $P
ud 'localuser' --localpaths="$W/tree/c" --localuser="" $P
export PRUNEPATHS="$W/tree/skip"; ud 'env PRUNEPATHS' --localpaths="$W/tree"; unset PRUNEPATHS
export SEARCHPATHS="$W/tree/c"; ud 'env SEARCHPATHS' $P; unset SEARCHPATHS
export FINDOPTIONS='-maxdepth 1'; ud 'env FINDOPTIONS' --localpaths="$W/tree" $P; unset FINDOPTIONS
export PRUNEFS='ext4'; ud 'env PRUNEFS' --localpaths="$W/tree" $P; unset PRUNEFS
ud 'order of options' $P --localpaths="$W/tree/c" --prunepaths="$W/tree/c/four.sh"
ud 'option twice' --localpaths="$W/tree/a" --localpaths="$W/tree/c" $P
ud 'option with space value' "--localpaths=$W/tree/sp ace" $P
ud 'output dir missing' --localpaths="$W/tree/c" $P --output="$W/nodir/db"
cd /; print_summary
