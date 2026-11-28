#!/bin/sh
# grep extensions (decision 0006): ripgrep-derived options are compared with
# the real `rg`, ugrep-derived ones with `ugrep`, FreeBSD ones with the Chimera
# sysroot's FreeBSD grep (tools/bsdrun.sh), better diagnostics with the
# documented text. The GNU path is compared with GNU grep. Missing oracles skip
# their tests. Run from anywhere after building grep.
UTIL="grep"
. "$(dirname "$0")/testlib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BSD="$ROOT/tools/bsdrun.sh"
W="$(mktemp -d)"; cd "$W"
OURS="$BIN_DIR/grep"
export TZ=UTC LC_ALL=C

HAVE_RG=0; command -v rg >/dev/null 2>&1 && HAVE_RG=1
HAVE_UG=0; [ -x /usr/bin/ugrep ] && HAVE_UG=1
HAVE_BSD=0; sh "$BSD" grep --help >/dev/null 2>&1; [ $? -ne 125 ] && HAVE_BSD=1
UGREP=/usr/bin/ugrep

pass() { PASS=$((PASS + 1)); printf "PASS %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$1"; printf "     REF : %s\n" "$(printf '%s' "$2" | cat -A | head -c 1500)"; printf "     OURS: %s\n" "$(printf '%s' "$3" | cat -A | head -c 1500)"; }

# cmp DESC REFCMD OURSCMD [NORMALISER]: both are shell snippets run in $W; the
# text and exit status are compared after the optional filter (a command).
# In OURSCMD, $G is our grep. SORT is a normaliser that sorts the lines.
cmp() {
    desc=$1; ref=$2; mine=$3; norm=${4:-cat}
    G=$OURS
    e=$( (eval "$ref") 2>&1 </dev/null; echo "rc=$?")
    a=$( (eval "$mine") 2>&1 </dev/null; echo "rc=$?")
    e=$(printf '%s\n' "$e" | eval "$norm"); a=$(printf '%s\n' "$a" | eval "$norm")
    if [ "$e" = "$a" ]; then pass "$desc"; else fail "$desc" "$e" "$a"; fi
}
SORT=sort
# JSON from rg and from us differ only in timings
JNORM="sed -e 's/\"nanos\":[0-9]*/\"nanos\":0/g' -e 's/\"secs\":[0-9]*/\"secs\":0/g' -e 's/\"human\":\"[0-9.]*s\"/\"human\":\"0s\"/g'"
SNORM="sed -e 's/^[0-9.]* seconds/N seconds/'"

rgcmp() { # DESC "rg args" "our args" [norm]
    if [ $HAVE_RG = 1 ]; then cmp "rg: $1" "rg $2" "\$G $3" "$4"; else skip_test "rg: $1 (no rg)"; fi
}
# differential test of a path that must behave as GNU grep does
gnucmp() { cmp "gnu: $1" "/usr/bin/grep $2" "\$G $2" "sed -e 's#/usr/bin/grep:#grep:#'"; }

printf 'one two\nthree two\nfour\nTwo again\n' > a.txt
printf 'x\ntwo two\n' > b.c
printf 'cafe \377 two\n' > bad.txt
printf 'aaa bbb aaa\n' > l.txt
printf 'ab12 cd34\nxy\n' > g.txt
printf 'abcdefghij two klm\nshort two\n' > wide.txt
printf 'A B\nA C\nB\nA\nC D\nA D B\n' > q.txt
printf 'nothing here\n' > none.txt

# ---------------------------------------------------------------- GNU path
gnucmp 'plain search unchanged' "two a.txt"
gnucmp '-c still prints zero' "-c nothing a.txt b.c"
gnucmp '-o -n' "-on two a.txt"
gnucmp 'abbreviation --cou is --count' "--cou two a.txt"
gnucmp 'abbreviation --no-i is --no-ignore-case' "--no-i two a.txt"
gnucmp 'abbreviation --ign is --ignore-case' "--ign two a.txt"
gnucmp 'abbreviation --inc exact include' "--inc=*.c two a.txt b.c"
gnucmp 'abbreviation --col' "--col=always two a.txt"
gnucmp 'abbreviation --no-f is --no-filename' "--no-f two a.txt b.c"
gnucmp 'abbreviation --w' "--w two a.txt"
gnucmp 'abbreviation --line-n' "--line-n two a.txt"
gnucmp 'abbreviation --max' "--max=1 two a.txt"
gnucmp 'recursive hidden files are searched' "-r two ."
gnucmp 'recursive ignore files are not honoured' "-r two ."
gnucmp '-s on missing file' "-s two nosuch a.txt"

# ------------------------------------------------------------- ripgrep: json
rgcmp 'json basic' "--json two a.txt" "--json two a.txt" "$JNORM"
rgcmp 'json context' "--json -C1 four a.txt" "--json -C1 four a.txt" "$JNORM"
rgcmp 'json before context' "--json -B2 four a.txt" "--json -B2 four a.txt" "$JNORM"
rgcmp 'json two submatches' "--json aaa l.txt" "--json aaa l.txt" "$JNORM"
rgcmp 'json no match' "--json zzz a.txt" "--json zzz a.txt" "$JNORM"
rgcmp 'json non-utf8 bytes' "--json two bad.txt" "--json two bad.txt" "$JNORM"
rgcmp 'json ignore case' "--json -i two a.txt" "--json -i two a.txt" "$JNORM"
rgcmp 'json invert' "--json -v two a.txt" "--json -v two a.txt" "$JNORM"
rgcmp 'json max-count' "--json -m1 two a.txt" "--json -m1 two a.txt" "$JNORM"
rgcmp 'json two files sorted' "--json --sort path two a.txt b.c" "--json two a.txt b.c" "$JNORM"
rgcmp 'json stdin' "--json two < a.txt" "--json two < a.txt" "$JNORM"
printf 'q"uo\\te\ttab\001\n' > esc.txt
rgcmp 'json escapes' "--json 'uo' esc.txt" "--json uo esc.txt" "$JNORM"
printf 'no newline two' > nonl.txt
rgcmp 'json no trailing newline' "--json two nonl.txt" "--json two nonl.txt" "$JNORM"

# Nothing but JSON may reach standard output.
all_json() { # DESC ARGS...
    desc=$1; shift
    out=$("$OURS" "$@" 2>&1); rc=$?
    if [ "$rc" -le 1 ] && [ -n "$out" ] && printf '%s\n' "$out" |
        python3 -I -c 'import json, sys; [json.loads(l)["type"] for l in sys.stdin]' 2>/dev/null; then pass "$desc"
    else fail "$desc" "only JSON lines" "rc=$rc $out"; fi
}
if command -v python3 > /dev/null; then
    printf 'two\nx\ny\nz\ntwo\n' > apart.txt
    all_json 'json: no separator between context groups' --json -A1 two apart.txt
    all_json 'json: no separator between files' --json -C1 two a.txt b.c
    all_json 'json with --stats' --json --stats two a.txt
    all_json 'json with --group-separator' --json -C1 --group-separator=== two apart.txt
    all_json 'json with context after -m' --json -m1 -A2 two a.txt apart.txt
    all_json 'json with non-UTF-8 and control bytes' --json -C1 two bad.txt a.txt
    all_json 'json with no match' --json zzz a.txt
    all_json 'json with -q' --json -q two a.txt
else
    skip_test 'json: every line is JSON (no python3)'
fi
for opt in -c -l -L --count-matches; do
    cmp "json refuses $opt" "echo 1; echo 2" "\$G --json $opt two a.txt 2>&1 >/dev/null | /usr/bin/grep -c -e '--json cannot be used with'; \$G --json $opt two a.txt >/dev/null 2>&1; echo \$?" ""
    cmp "json refuses $opt: nothing on stdout" "exit 2" "\$G $opt --json two a.txt 2>/dev/null" ""
done

# ------------------------------------------------- ripgrep: counts and stats
rgcmp 'count-matches one file' "--count-matches two a.txt" "--count-matches two a.txt"
rgcmp 'count-matches two files' "--count-matches two a.txt b.c" "--count-matches two a.txt b.c" "$SORT"
rgcmp 'count-matches several per line' "--count-matches a l.txt" "--count-matches a l.txt"
rgcmp 'count-matches no match' "--count-matches zzz a.txt" "--count-matches zzz a.txt"
rgcmp 'count-matches -i' "--count-matches -i two a.txt" "--count-matches -i two a.txt"
rgcmp 'stats' "--stats two a.txt" "--stats two a.txt" "$SNORM"
rgcmp 'stats two files' "--stats --sort path two a.txt b.c" "--stats two a.txt b.c" "$SNORM"
rgcmp 'stats no match' "--stats zzz a.txt" "--stats zzz a.txt" "$SNORM"

# Ignore files come with the tree: only regular files of a sane size are read,
# and a .gitignore may not be a link. Nothing here may hang or use up memory.
# The trees are kept out of $W: later cases run other programs over all of it.
IG=$(mktemp -d)
# ig DESC DIR WANT-STDOUT+STDERR
ig() {
    got=$( (cd "$IG" && ulimit -v 400000 && timeout 20 "$OURS" -r --sort=path --ignore-vcs foo "$2") 2>&1 </dev/null; echo "rc=$?")
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "$3" "$got"; fi
}
(
    cd "$IG" || exit 1
    mkdir ig_zero ig_fifo ig_big ig_link ig_dot
    for d in ig_zero ig_fifo ig_big ig_link ig_dot; do echo foo > $d/a; done
    ln -s /dev/zero ig_zero/.gitignore
    mkfifo ig_fifo/.gitignore
    { echo a; head -c 5000000 /dev/zero | tr '\0' '\n'; } > ig_big/.gitignore
    echo a > rules; ln -s ../rules ig_link/.gitignore; ln -s ../rules ig_dot/.ignore
)
ig 'ignore-vcs: .gitignore link to /dev/zero' ig_zero "grep: ig_zero/.gitignore: ignore file not used: it is a symbolic link
ig_zero/a:foo
rc=0"
ig 'ignore-vcs: .gitignore that is a FIFO' ig_fifo "grep: ig_fifo/.gitignore: ignore file not used: it is not a regular file
ig_fifo/a:foo
rc=0"
ig 'ignore-vcs: a huge .gitignore' ig_big "grep: ig_big/.gitignore: ignore file not used: it is larger than 4 MiB
ig_big/a:foo
rc=0"
ig 'ignore-vcs: .gitignore symlink is not followed' ig_link "grep: ig_link/.gitignore: ignore file not used: it is a symbolic link
ig_link/a:foo
rc=0"
ig 'ignore-vcs: .ignore symlink to a file is followed' ig_dot "rc=1"

# Many "**" in a pattern take no longer than one (the limit stops a matcher
# that tries every position for every one of them).
deep=$IG/stars/t; for i in $(seq 40); do deep=$deep/x; done; mkdir -p "$deep"; echo foo > "$deep/f"
printf '**/x/**/x/**/x/**/x/**/x/**/x/**/x/**/x/**/nomatch\n' > "$IG/stars/t/.gitignore"
ig 'ignore-vcs: many ** segments' stars/t "stars/t/$(printf 'x/%.0s' $(seq 40))f:foo
rc=0"
printf 'a/**/b/**/c\n**/y/**\n!keep\n' > rules2
mkdir -p dstar/a/q/b/r dstar/a/b dstar/m/y/n
for f in dstar/a/q/b/r/c dstar/a/b/c dstar/a/b/d dstar/m/y/n/f dstar/m/f; do echo two > $f; done
cp rules2 dstar/.gitignore
rgcmp 'ignore-vcs with several **' "--no-require-git --hidden --sort path two dstar" "-r --sort=path --ignore-vcs two dstar" ""

# --------------------------------------------------- ripgrep: smart case
for pat in two Two tWo 'o' 'T' '\\Sw' 'w\\w'; do
    rgcmp "smart-case $pat" "--smart-case '$pat' a.txt" "--smart-case '$pat' a.txt"
done
rgcmp 'smart-case with -i' "--smart-case -i Two a.txt" "--smart-case -i Two a.txt"
rgcmp 'smart-case -o' "--smart-case -o two a.txt" "--smart-case -o two a.txt"

# ------------------------------------------------------ ripgrep: replace
rgcmp 'replace plain' "-r X aaa l.txt" "--replace=X aaa l.txt"
rgcmp 'replace -o group' "-o -r '[\$1]' 'a(a)' l.txt" "-o --replace='[\$1]' -E 'a(a)' l.txt"
rgcmp 'replace named group' "-o -r '\${n}z' 'a(?P<n>a)' l.txt" "-o --replace='\${n}z' -P 'a(?<n>a)' l.txt"
rgcmp 'replace $0' "-o -r '<\$0>' 'b+' l.txt" "-o --replace='<\$0>' -E 'b+' l.txt"
rgcmp 'replace $$' "-r '\$\$' bbb l.txt" "--replace='\$\$' bbb l.txt"
rgcmp 'replace unknown group is empty' "-r '[\$9]' bbb l.txt" "--replace='[\$9]' bbb l.txt"
rgcmp 'replace word group name' "-o -r '\$1x' '(b)bb' l.txt" "-o --replace='\$1x' -E '(b)bb' l.txt"
rgcmp 'replace with -n' "-n -r X two a.txt" "-n --replace=X two a.txt"
rgcmp 'replace multiple matches per line' "-r '<\$0>' a l.txt" "--replace='<\$0>' a l.txt"

# -------------------------------------------------- ripgrep: max columns
rgcmp 'max-columns omits' "--max-columns=5 two a.txt" "--max-columns=5 two a.txt"
rgcmp 'max-columns exact length kept' "--max-columns=4 four a.txt" "--max-columns=4 four a.txt"
rgcmp 'max-columns context' "--max-columns=5 -C1 four a.txt" "--max-columns=5 -C1 four a.txt"
rgcmp 'max-columns preview' "--max-columns=5 --max-columns-preview two a.txt" "--max-columns=5 --max-columns-preview two a.txt"
rgcmp 'max-columns -o' "-o --max-columns=2 aaa l.txt" "-o --max-columns=2 aaa l.txt"
rgcmp 'max-columns wide file' "--max-columns=10 two wide.txt" "--max-columns=10 two wide.txt"

# ------------------------------------------- ripgrep: files, types, ignores
mkdir -p tree/.hid tree/d2 tree/src tree/build
echo 'two h' > tree/.hid/f; echo 'two dot' > tree/.dot; echo 'two ok' > tree/ok.txt
echo 'two log' > tree/ig.log; echo 'two d2' > tree/d2/x.log; echo 'two c' > tree/src/m.c
echo 'two py' > tree/src/s.py; echo 'two h' > tree/src/m.h; echo 'two build' > tree/build/o.txt
echo 'two rs' > tree/src/r.rs; echo 'two Make' > tree/Makefile; echo 'two zig' > tree/src/z.zig
printf '*.log\n!x.log\nbuild/\n' > tree/.gitignore
printf 'ok.txt\n' > tree/src/.ignore
RGB='rg --no-ignore --hidden --sort path'
OPT='-r --sort=path'
rgcmp 'recursive default = rg --hidden --no-ignore' "--no-ignore --hidden --sort path two tree" "-r --sort=path two tree"
rgcmp 'recursive --no-hidden' "--no-ignore --sort path two tree" "-r --sort=path --no-hidden two tree"
rgcmp 'recursive --hidden is accepted' "--no-ignore --hidden --sort path two tree" "-r --sort=path --hidden two tree"
rgcmp 'ignore-vcs + no-hidden = rg default' "--no-require-git --sort path two tree" "-r --sort=path --no-hidden --ignore-vcs two tree"
rgcmp 'ignore-vcs keeps hidden' "--no-require-git --hidden --sort path two tree" "-r --sort=path --ignore-vcs two tree"
rgcmp 'no-ignore after ignore-vcs' "--no-ignore --hidden --sort path two tree" "-r --sort=path --ignore-vcs --no-ignore two tree"
rgcmp 'ignore-vcs from the directory' "--no-require-git --hidden --sort path two ." "-r --sort=path --ignore-vcs two ." ""
(cd tree && true)
cmp 'ignore-vcs in the current directory' "cd tree && rg --no-require-git --hidden --sort path two ." "cd tree && \$G -r --sort=path --ignore-vcs two ." ""
rgcmp 'glob include' "$(echo "--no-ignore --hidden --sort path -g '*.c' two tree")" "-r --sort=path --glob='*.c' two tree"
rgcmp 'glob exclude' "--no-ignore --hidden --sort path -g '!*.c' two tree" "-r --sort=path --glob='!*.c' two tree"
rgcmp 'glob two includes' "--no-ignore --hidden --sort path -g '*.c' -g '*.py' two tree" "-r --sort=path --glob='*.c' --glob='*.py' two tree"
rgcmp 'glob include then exclude' "--no-ignore --hidden --sort path -g '*.txt' -g '!ok.txt' two tree" "-r --sort=path --glob='*.txt' --glob='!ok.txt' two tree"
rgcmp 'glob exclude directory' "--no-ignore --hidden --sort path -g '!src' two tree" "-r --sort=path --glob='!src' two tree"
rgcmp 'glob anchored path' "--no-ignore --hidden --sort path -g 'tree/src/*.c' two tree" "-r --sort=path --glob='tree/src/*.c' two tree"
rgcmp 'glob doublestar' "--no-ignore --hidden --sort path -g 'tree/**/*.log' two tree" "-r --sort=path --glob='tree/**/*.log' two tree"
rgcmp 'type c' "--no-ignore --hidden --sort path -t c two tree" "-r --sort=path --type=c two tree"
rgcmp 'type cpp' "--no-ignore --hidden --sort path -t cpp two tree" "-r --sort=path --type=cpp two tree"
rgcmp 'type py and rust' "--no-ignore --hidden --sort path -t py -t rust two tree" "-r --sort=path --type=py --type=rust two tree"
rgcmp 'type-not c' "--no-ignore --hidden --sort path -T c two tree" "-r --sort=path --type-not=c two tree"
rgcmp 'type make' "--no-ignore --hidden --sort path -t make two tree" "-r --sort=path --type=make two tree"
rgcmp 'type zig' "--no-ignore --hidden --sort path -t zig two tree" "-r --sort=path --type=zig two tree"
rgcmp 'type unknown' "-t nosuchtype two tree 2>&1 | tail -n 1 | sed 's/.*unrecognized/unrecognized/;s/ (.*//'" "--type=nosuchtype two tree 2>&1 | tail -n 1 | sed 's/.*unrecognized/unrecognized/;s/ (.*//'"
if [ $HAVE_RG = 1 ]; then
    missing=0
    $OURS --type-list | while IFS= read -r line; do
        rg --type-list | /usr/bin/grep -qxF -- "$line" || echo "type line differs: $line"
    done > typelist.out
    if [ ! -s typelist.out ]; then pass "rg: type-list lines all equal rg's"; else fail "rg: type-list" "" "$(cat typelist.out)"; fi
else skip_test "rg: type-list"; fi
mkdir -p ts; for i in 3 1 2; do echo "two $i" > ts/f$i; touch -d "2020-01-0$i" ts/f$i; done
rgcmp 'sort path' "--sort path two ts" "-r --sort=path two ts"
rgcmp 'sortr path' "--sortr path two ts" "-r --sortr=path two ts"
rgcmp 'sort modified' "--sort modified two ts" "-r --sort=modified two ts"
rgcmp 'sortr modified' "--sortr modified two ts" "-r --sortr=modified two ts"
rgcmp 'sort none accepted' "--sort path two ts" "-r --sort=none two ts" "$SORT"
rgcmp 'explicit files bypass glob and type' "-g '*.c' two a.txt b.c" "--glob='*.c' two a.txt b.c" "$SORT"

# ---------------------------------------------------------- ugrep: boolean
ugcmp() { # DESC "ugrep args" "our args" [norm]
    if [ $HAVE_UG = 1 ]; then cmp "ugrep: $1" "$UGREP -F $2" "\$G -F $3" "$4"; else skip_test "ugrep: $1 (no ugrep)"; fi
}
ugcmp 'and' "-e A --and B q.txt" "-e A --and B q.txt"
ugcmp 'and with alternatives' "-e A -e C --and B q.txt" "-e A -e C --and B q.txt"
ugcmp 'and three' "-e A --and B --and D q.txt" "-e A --and B --and D q.txt"
ugcmp 'not' "-e A --not B q.txt" "-e A --not B q.txt"
ugcmp 'not only' "--not B q.txt" "--not B q.txt"
ugcmp 'andnot' "-e A --andnot B q.txt" "-e A --andnot B q.txt"
ugcmp 'groups of alternatives' "-e A -e B --and -e C -e D q.txt" "-e A -e B --and -e C -e D q.txt"
ugcmp 'and with -n' "-n -e A --and B q.txt" "-n -e A --and B q.txt"
ugcmp 'and with -c' "-c -e A --and B q.txt" "-c -e A --and B q.txt"
ugcmp 'and with -v' "-v -e A --and B q.txt" "-v -e A --and B q.txt"
ugcmp 'and with -o' "-o -e A --and B q.txt" "-o -e A --and B q.txt"
ugcmp 'bool and' "--bool 'A B' q.txt" "--bool 'A B' q.txt"
ugcmp 'bool or' "--bool 'C|D' q.txt" "--bool 'C|D' q.txt"
ugcmp 'bool not' "--bool 'A -B' q.txt" "--bool 'A -B' q.txt"
ugcmp 'bool words' "--bool 'A AND NOT B' q.txt" "--bool 'A AND NOT B' q.txt"
ugcmp 'bool OR word' "--bool 'A OR C' q.txt" "--bool 'A OR C' q.txt"
ugcmp 'bool parentheses' "--bool '(A B)|C' q.txt" "--bool '(A B)|C' q.txt"
ugcmp 'bool precedence' "--bool 'A|B C|D' q.txt" "--bool 'A|B C|D' q.txt"
ugcmp 'bool quoted' "--bool 'A \"B\"' q.txt" "--bool 'A \"B\"' q.txt"
ugcmp 'bool -n' "-n --bool 'A -B' q.txt" "-n --bool 'A -B' q.txt"
ugcmp 'bool no match' "--bool 'A Z' q.txt" "--bool 'A Z' q.txt"
cmp 'bool syntax error message' "echo 'grep: invalid Boolean query: syntax error'; exit 2" "\$G --bool '(A B' q.txt" "sed -e 's/ at offset.*//'"

# ------------------------------------------------------------------ FreeBSD
mkdir -p sl/d sl/e; echo needle > sl/d/f; echo needle > sl/e/g
ln -s ../e sl/d/lnk; ln -s f sl/d/flnk; ln -s d sl/dl
bsdcmp() { # DESC "bsd args" "our args"
    if [ $HAVE_BSD = 1 ]; then cmp "bsd: $1" "sh $BSD grep $2" "\$G $3" "$SORT"; else skip_test "bsd: $1 (no chimera sysroot)"; fi
}
bsdcmp '-RO command-line links only' "-RO needle sl/d sl/dl" "-rO needle sl/d sl/dl"
bsdcmp '-Rp no links' "-Rp needle sl/d sl/dl" "-rp needle sl/d sl/dl"
bsdcmp '-RS all links' "-RS needle sl/d sl/dl" "-rS needle sl/d sl/dl"
bsdcmp '-S alone reads a file link' "-S needle sl/d/flnk" "-S needle sl/d/flnk"
bsdcmp '-p alone reads a file link' "-p needle sl/d/flnk" "-p needle sl/d/flnk"
bsdcmp '--mmap ignored' "--mmap needle sl/d/f" "--mmap needle sl/d/f"
bsdcmp '--mmap with -n' "--mmap -n two a.txt" "--mmap -n two a.txt"
bsdcmp '--include-dir' "-R --include-dir=d needle sl" "-r -S --include-dir=d needle sl"
bsdcmp '--include-dir none match' "-R --include-dir=zz needle sl" "-r -S --include-dir=zz needle sl"
cmp 'gnu: -r still skips links in walk' "/usr/bin/grep -r needle sl/d | sort" "\$G -r needle sl/d | sort" ""
cmp 'gnu: -R follows links' "/usr/bin/grep -R needle sl/d | sort" "\$G -R needle sl/d | sort" ""

# decompression: compared with ugrep -z (which reads the same formats)
printf 'alpha needle\nbeta\ngamma needle\n' > plain.txt
gzip -k -c plain.txt > p.gz; xz -k -c plain.txt > p.xz; zstd -q -c plain.txt > p.zst
zlib() { python3 -c 'import sys,zlib;sys.stdout.buffer.write(zlib.compress(open(sys.argv[1],"rb").read()))' "$1"; }
bzip2 -k -c plain.txt > p.bz2
for f in p.gz p.xz p.zst; do
    if [ $HAVE_UG = 1 ]; then cmp "ugrep: --decompress $f" "$UGREP -F -z needle $f" "\$G -F --decompress needle $f"; else skip_test "ugrep: --decompress $f"; fi
    cmp "decompress $f -c" "echo 2" "\$G --decompress -c needle $f"
done
# Every gzip member and xz stream is searched, and anything else is reported.
(gzip -c plain.txt; gzip -c plain.txt) > two.gz
(xz -c plain.txt; xz -c plain.txt) > two.xz
(xz -c plain.txt; head -c 8 /dev/zero; xz -c plain.txt; head -c 4 /dev/zero) > pad.xz
(zstd -q -c plain.txt; zstd -q -c plain.txt) > two.zst
(gzip -c plain.txt; head -c 512 /dev/zero) > zeros.gz
for f in two.gz two.xz pad.xz two.zst; do
    cmp "decompress all of $f" "echo 4" "\$G --decompress -c needle $f"
done
cmp 'decompress gzip padded with zeros' "echo 2" "\$G --decompress -c needle zeros.gz"
(gzip -c plain.txt; echo junk) > junk.gz
(xz -c plain.txt; echo junk) > junk.xz
(xz -c plain.txt; head -c 3 /dev/zero) > badpad.xz
(zlib plain.txt; echo junk) > junk.zlib 2>/dev/null
for f in junk.gz junk.xz badpad.xz junk.zlib; do
    if [ $f = junk.zlib ] && ! command -v python3 > /dev/null; then skip_test "decompress $f (no python3)"; continue; fi
    cmp "decompress reports what follows the data: $f" "echo 'grep: $f: --decompress: what follows the compressed data was not searched'; echo 2; exit 2" "\$G --decompress -c needle $f 2>err >out; rc=\$?; cat err; \$G --decompress -c needle $f 2>/dev/null; exit \$rc"
done
cmp 'decompress plain file untouched' "/usr/bin/grep needle plain.txt" "\$G --decompress needle plain.txt"
cmp 'without --decompress gzip is binary (GNU)' "/usr/bin/grep needle p.gz" "\$G needle p.gz"
cmp 'decompress stdin is not decompressed' "/usr/bin/grep -c needle < p.gz" "\$G --decompress -c needle < p.gz"
cmp 'decompress bzip2 warns and searches the bytes' "echo 'grep: p.bz2: bzip2 compression is not supported by --decompress; searching the compressed bytes'; /usr/bin/grep -c needle p.bz2" "\$G --decompress -c needle p.bz2"
head -c 40 p.gz > trunc.gz
cmp 'decompress damaged data is an error' "echo 'grep: trunc.gz: cannot decompress: the compressed data is damaged or truncated'; exit 2" "\$G --decompress needle trunc.gz"
# Data that still decodes but fails its checksum (REGX-033). `bad IN OUT N`
# flips one bit of the byte N from the end; for xz the text is stored as it is,
# so a changed letter decodes without complaint.
bad() { cp "$1" "$2"; at=$(($(wc -c < "$1") - $3)); byte=$(od -An -tu1 -j "$at" -N1 "$1"); printf "\\$(printf '%o' $((byte ^ 1)))" | dd of="$2" bs=1 seek="$at" conv=notrunc status=none; }
printf 'needle\n' > one.txt
gzip -n -c one.txt > one.gz; zstd -q -c one.txt > one.zst
bad one.gz crc.gz 8; bad one.gz length.gz 4; bad one.zst sum.zst 1
cat one.gz crc.gz > second.gz; cat one.zst sum.zst > second.zst
damaged() { cmp "decompress checksum: $1" "echo 'grep: $1: cannot decompress: the compressed data is damaged or truncated'; exit 2" "\$G --decompress needle $1"; }
for f in crc.gz length.gz second.gz sum.zst second.zst; do damaged $f; done
for check in crc32 crc64 sha256; do
    xz --check=$check -c one.txt > one-$check.xz
    cmp "decompress intact xz $check" "echo 1" "\$G --decompress -c needle one-$check.xz"
    at=$(grep -abo needle one-$check.xz | cut -d: -f1)
    bad one-$check.xz text-$check.xz $(($(wc -c < one-$check.xz) - at)); damaged text-$check.xz
done
seq 20000 | sed 's/^/needle /' > many.txt; xz --block-size=20000 -c many.txt > blocks.xz
cmp 'decompress xz with many blocks' "echo 20000" "\$G --decompress -c needle blocks.xz"
zlib plain.txt > p.zlib 2>/dev/null
if [ -s p.zlib ] && python3 -c 'import zlib' 2>/dev/null; then
    cmp 'decompress zlib' "echo 2" "\$G --decompress -c needle p.zlib"
fi

# Data that decodes to more than 32 MB is not held whole (REGX-019): it is
# decoded once to be checked and again as it is searched.
yes 'a line with nothing in it' | head -c 200000000 | gzip -1 > bomb.gz
cmp 'decompress a large file in bounded memory' "echo 0; exit 1" "(ulimit -v 150000; \$G --decompress -c needle bomb.gz)"
(yes 'a line with nothing in it' | head -c 39999986; echo needle) > large.txt
gzip -1 -c large.txt > large.gz; zstd -q -1 -c large.txt > large.zst
for f in large.gz large.zst; do
    cmp "decompress large $f" "echo 1538462:needle" "\$G --decompress -n needle $f"
done
bad large.gz large-crc.gz 8; damaged large-crc.gz
rm -f bomb.gz large.txt large.gz large.zst large-crc.gz

# ------------------------------------------------------------- diagnostics
cmp 'diag: invalid -P pattern, stdout and status as GNU' "/usr/bin/grep -P '(' a.txt 2>/dev/null; echo rc=\$?" "\$G -P '(' a.txt 2>/dev/null; echo rc=\$?" ""
cmp 'diag: invalid -P pattern names the pattern and offset' "echo yes" "\$G -P '(' a.txt 2>&1 >/dev/null | /usr/bin/grep -c \"invalid Perl regular expression: .* (at offset [0-9]* in '(')\" | sed 's/1/yes/'; true" ""
cmp 'diag: -P with unmatched bracket' "/usr/bin/grep -P '[a' a.txt 2>/dev/null; echo rc=\$?" "\$G -P '[a' a.txt 2>/dev/null; echo rc=\$?" ""
cmp 'diag: bool syntax error status' "exit 2" "\$G --bool '(A' q.txt >/dev/null 2>&1" ""
cmp 'diag: type error status' "exit 2" "\$G --type=nope x a.txt >/dev/null 2>&1" ""
cmp 'diag: sort key error' "echo 'invalid sort key'; exit 2" "\$G -r --sort=bogus x a.txt 2>&1 | sed 's/.*: bogus: \(invalid sort key\).*/\1/'; \$G -r --sort=bogus x a.txt >/dev/null 2>&1" ""
# a pattern that exceeds the backtracking limit is reported, not silently skipped
awk 'BEGIN { for (i = 0; i < 40; i++) printf "a"; print "c" }' > evil.txt
cmp 'diag: search limit reported with status 2' "echo 2" "\$G -P '(a+)+\\1\$' evil.txt >/dev/null 2>&1; echo \$?" ""

# the help text lists every extension as "(not in GNU)"
cmp 'help marks extensions' "echo 0" "\$G --help | /usr/bin/grep -c -e '--smart-case' -e '--json' -e '--glob' -e '--decompress' -e '--bool' -e '--sort' | sed 's/^[1-9][0-9]*\$/0/'" ""
cmp 'help extension lines all say not in GNU' "echo 0; exit 1" "\$G --help | /usr/bin/grep -e '--json ' -e '--smart-case ' -e '--glob=' -e '--decompress ' -e '--bool ' -e '--sort=' -e '--stats ' | /usr/bin/grep -vc '(not in GNU)\$'" ""

cd /; print_summary
