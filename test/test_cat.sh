#!/bin/sh
UTIL="cat"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > $TEST_TMP/test_cat1.txt
printf "line1\nline2\nline3\n" > $TEST_TMP/test_cat2.txt
printf "line with\ttabs\n" > $TEST_TMP/test_cat3.txt
printf "\n\n\nblank lines\n" > $TEST_TMP/test_cat4.txt
# Without its inputs a comparison would compare two "no such file" messages.
for f in 1 2 3 4; do [ -s "$TEST_TMP/test_cat$f.txt" ] || { echo "test_cat: cannot create the inputs" >&2; exit 2; }; done

printf "\n[ Basic output ]\n"
run_test_file "single file"          $TEST_TMP/test_cat1.txt
run_test "multiple files"            $TEST_TMP/test_cat1.txt $TEST_TMP/test_cat2.txt

printf "\n[ Flags ]\n"
run_test_file "-n number lines"      $TEST_TMP/test_cat2.txt -n
run_test_file "-b number nonblank"   $TEST_TMP/test_cat4.txt -b
run_test_file "-s squeeze blank"     $TEST_TMP/test_cat4.txt -s
run_test_file "-A show all"          $TEST_TMP/test_cat3.txt -A
run_test_file "-E show line ends"    $TEST_TMP/test_cat2.txt -E
run_test_file "-T show tabs"         $TEST_TMP/test_cat3.txt -T
run_test_file "-v show nonprint"     $TEST_TMP/test_cat3.txt -v

printf "\n[ bat view (no GNU equivalent; compared to fixed output) ]\n"
check_ours() {
    description="$1"; expected="$2"; shift 2
    actual=$(ours "$@" 2>&1)
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$description"
    fi
}
check_ours "--style=numbers" "   1 line1
   2 line2
   3 line3" --decorations=always --color=never --style=numbers $TEST_TMP/test_cat2.txt
check_ours "-p is raw" "$(cat $TEST_TMP/test_cat2.txt)" --decorations=always -p $TEST_TMP/test_cat2.txt
check_ours "pipe stays GNU" "$(cat $TEST_TMP/test_cat2.txt)" $TEST_TMP/test_cat2.txt
check_ours "GNU flag beats bat view" "$(gnu -n $TEST_TMP/test_cat2.txt)" --decorations=always -n $TEST_TMP/test_cat2.txt
check_ours "bad --style rejected" "cat: invalid argument 'x' for '--style'" --style=x $TEST_TMP/test_cat2.txt

printf "\n[ syntax highlighting (toy grammar) ]\n"
mkdir -p $TEST_TMP/test_cat_syn
cat > $TEST_TMP/test_cat_syn/Toy.sublime-syntax <<'GRAMMAR'
%YAML 1.2
---
name: Toy
scope: source.toy
file_extensions: [toy]
contexts:
  main:
    - match: '\b(if|else)\b'
      scope: keyword.control
    - match: '"'
      scope: punctuation.begin
      push: string
  string:
    - meta_scope: string.quoted
    - match: '"'
      scope: punctuation.end
      pop: true
GRAMMAR
printf 'if "a\nb" else\n' > $TEST_TMP/test_cat5.toy
ESC=$(printf '\033')
SYN="--syntax-dir=$TEST_TMP/test_cat_syn --decorations=always --color=always --theme=ansi -p"
check_ours "highlight by extension" "${ESC}[35mif${ESC}[0m ${ESC}[32m\"${ESC}[0m${ESC}[32ma${ESC}[0m
${ESC}[32mb${ESC}[0m${ESC}[32m\"${ESC}[0m ${ESC}[35melse${ESC}[0m" $SYN $TEST_TMP/test_cat5.toy
actual=$(printf 'if\n' | ours $SYN -l toy 2>&1)
if [ "$actual" = "${ESC}[35mif${ESC}[0m" ]; then PASS=$((PASS + 1)); printf "PASS highlight stdin with -l\n"; else FAIL=$((FAIL + 1)); printf "FAIL highlight stdin with -l\n"; fi
check_ours "no color, no escapes" "if \"a
b\" else" --syntax-dir=$TEST_TMP/test_cat_syn --decorations=always --color=never -p $TEST_TMP/test_cat5.toy
check_ours "unknown language" "cat: unknown language 'zzz' (see --list-languages)" $SYN -l zzz $TEST_TMP/test_cat5.toy
# The built-in grammars are listed too; the user's toy grammar must be among them.
if [ "$(ours --syntax-dir=$TEST_TMP/test_cat_syn --list-languages 2>&1 | grep '^Toy')" = "Toy	toy" ]; then
    PASS=$((PASS + 1)); printf "PASS list languages\n"
else
    FAIL=$((FAIL + 1)); printf "FAIL list languages\n"
fi
check_ours "pipe ignores highlighting" "$(cat $TEST_TMP/test_cat5.toy)" --syntax-dir=$TEST_TMP/test_cat_syn $TEST_TMP/test_cat5.toy
# NO_COLOR (SPEC 5.4) needs a terminal on stdout, so run under script(1).
if command -v script >/dev/null 2>&1; then
    tty_run() { # "ENV=val ...", then extra cat options; prints output with CRs removed
        envs="$1"; shift
        script -qec "env $envs $BIN_DIR/cat --syntax-dir=$TEST_TMP/test_cat_syn $* $TEST_TMP/test_cat5.toy" /dev/null | tr -d '\r'
    }
    has_esc() { printf '%s' "$1" | grep -q "$ESC"; }
    # SGR parameters that set a foreground/background color.
    has_color() { printf '%s' "$1" | grep -Eq "${ESC}\\[(3[0-9]|4[0-9]|9[0-7]|10[0-7])(;[0-9;]*)?m|${ESC}\\[[0-9;]*;(3[0-9]|4[0-9]|9[0-7])m"; }
    expect() { # description, ok(0/1)
        if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$1"; else FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$1"; fi
    }
    out=$(tty_run TERM=xterm);                       has_color "$out"; expect "tty: color by default" $?
    out=$(tty_run "TERM=xterm NO_COLOR=1");          has_color "$out"; r=$?; has_esc "$out"; expect "tty: NO_COLOR=1 removes color, keeps styles" $(( (r == 1 && $? == 0) ? 0 : 1 ))
    out=$(tty_run "TERM=xterm NO_COLOR=0");          has_color "$out"; expect "tty: NO_COLOR=0 also removes color" $(( $? == 1 ? 0 : 1 ))
    out=$(tty_run "TERM=xterm NO_COLOR=");           has_color "$out"; expect "tty: empty NO_COLOR is ignored" $?
    out=$(tty_run TERM=dumb);                        has_esc "$out";   expect "tty: TERM=dumb emits no escapes" $(( $? == 1 ? 0 : 1 ))
    out=$(tty_run "TERM=xterm NO_COLOR=1" --color=always); has_color "$out"; expect "tty: --color=always beats NO_COLOR" $?
    out=$(tty_run TERM=xterm --color=never);         has_esc "$out";   expect "tty: --color=never emits no escapes" $(( $? == 1 ? 0 : 1 ))
else
    SKIP=$((SKIP + 7)); printf "SKIP NO_COLOR tests (script(1) not found)\n"
fi
rm -rf $TEST_TMP/test_cat_syn $TEST_TMP/test_cat5.toy

rm -f $TEST_TMP/test_cat1.txt $TEST_TMP/test_cat2.txt $TEST_TMP/test_cat3.txt $TEST_TMP/test_cat4.txt
# What has been read is written before cat waits for more.
for o in -u -n -A; do
    got=$( { printf 'early\n'; sleep 3; } | { timeout 2 "$BIN_DIR/cat" $o > "$TEST_TMP/stream"; true; }; cat "$TEST_TMP/stream" )
    want=$( { printf 'early\n'; sleep 3; } | { timeout 2 "${GNU_BIN:-/usr/bin}/cat" $o > "$TEST_TMP/stream.gnu"; true; }; cat "$TEST_TMP/stream.gnu" )
    if [ -n "$got" ] && [ "$got" = "$want" ]; then PASS=$((PASS + 1)); printf "PASS output keeps up with a slow input %s\n" "$o"
    else FAIL=$((FAIL + 1)); printf "FAIL output keeps up with a slow input %s (%s)\n" "$o" "$got"; fi
done

printf "\n[ Formatting options, differential ]\n"
W="$(mktemp -d)"
printf 'a\n\n\n\nb\n\nc' > "$W/blanks"
printf '\n\n\nx\n' > "$W/leadblank"
printf 'tab\there\n\t\nend  \n\xe9\x01\x7f\xff\x00z\n' > "$W/ctl"
printf 'one\r\ntwo\r\n\r\n' > "$W/crlf"
awk 'BEGIN { for (i = 0; i < 30000; i++) { if (i % 7 == 0) print ""; else print "line " i " of the text" } }' > "$W/big"
: > "$W/empty"
printf 'no newline' > "$W/nonl"
for f in blanks leadblank ctl crlf big empty nonl; do
    for o in -n -b -s -E -T -v -A -e -t -ns -bs -nE -nsE -bE -nET -nv -sT -nbs "-n -b" --number --number-nonblank --squeeze-blank --show-ends; do
        run_cmp "$f $o"       $o "$W/$f"
    done
done
run_cmp "-n two files continue numbering"  -n "$W/blanks" "$W/big"
run_cmp "-b two files"                     -b "$W/blanks" "$W/leadblank"
run_cmp "-s across file boundary"          -s "$W/leadblank" "$W/leadblank"
run_cmp "-n file without newline then file" -n "$W/nonl" "$W/blanks"
run_cmp "-E file without newline then file" -E "$W/nonl" "$W/nonl"
CMP_STDIN="$W/big" run_cmp "-n stdin"      -n
CMP_STDIN="$W/blanks" run_cmp "-ns stdin"  -ns -
# A carriage return before a newline under -E, split across read chunks and files.
{ head -c 65535 /dev/zero | tr '\0' 'x'; printf '\r\nafter\n'; } > "$W/crsplit"
{ head -c 65534 /dev/zero | tr '\0' 'x'; printf '\r\r\nafter\n'; } > "$W/crsplit2"
printf 'tail\r' > "$W/crend"
printf '\nstart\n' > "$W/lfstart"
printf '\rjust cr\n\r\n\r' > "$W/crmix"
for o in -E -nE -A -ET -bE -sE; do
    run_cmp "cr at chunk boundary $o"  $o "$W/crsplit"
    run_cmp "cr then cr lf $o"         $o "$W/crsplit2"
    run_cmp "cr at eof $o"             $o "$W/crend"
    run_cmp "cr eof then lf file $o"   $o "$W/crend" "$W/lfstart"
    run_cmp "cr eof then cr eof $o"    $o "$W/crend" "$W/crend"
    run_cmp "cr mix $o"                $o "$W/crmix"
done
# Numbers wider than the 6-column field.
awk 'BEGIN { for (i = 0; i < 1000050; i++) print "x" }' > "$W/million"
r=$(ours -n "$W/million" | md5sum); g=$(gnu -n "$W/million" | md5sum)
[ "$r" = "$g" ] && { PASS=$((PASS+1)); echo "PASS -n past 999999 lines"; } || { FAIL=$((FAIL+1)); echo "FAIL -n past 999999 lines"; }
rm -rf "$W"

printf "\n[ themes and git markers ]\n"
check_ours "list themes" "ansi	follows the terminal palette
night	dark
ember	dark
day	light
paper	light" --list-themes
actual=$(printf 'return\n' | COLORTERM=truecolor ours --decorations=always --color=always --theme=night -p -l lua 2>&1)
if [ "$actual" = "${ESC}[38;2;247;118;142mreturn${ESC}[0m" ]; then PASS=$((PASS + 1)); printf "PASS truecolor theme\n"; else FAIL=$((FAIL + 1)); printf "FAIL truecolor theme\n"; fi
actual=$(printf 'return\n' | env -u COLORTERM TERM=xterm-256color "$BIN_DIR/$UTIL" --decorations=always --color=always --theme=night -p -l lua 2>&1)
if [ "$actual" = "${ESC}[38;5;210mreturn${ESC}[0m" ]; then PASS=$((PASS + 1)); printf "PASS 256-color theme\n"; else FAIL=$((FAIL + 1)); printf "FAIL 256-color theme\n"; fi
check_ours "unknown theme" "cat: unknown theme 'nope' (see --list-themes)" --syntax-dir=$TEST_TMP/test_cat_syn --decorations=always --color=always --theme=nope -p $TEST_TMP/test_cat5.toy
if command -v git >/dev/null 2>&1; then
    G=$(mktemp -d)
    ( cd "$G" && git init -q . && printf 'one\ntwo\nthree\nfour\n' > f.txt && git add f.txt &&
      git -c user.name=t -c user.email=t@t commit -qm i && printf 'one\nTWO\nthree\nnew\n' > f.txt )
    actual=$(cd "$G" && ours --decorations=always --color=never f.txt 2>&1 | sed -n 4,7p)
    expected="   1   │ one
   2 ~ │ TWO
   3   │ three
   4 ~ │ new"
    if [ "$actual" = "$expected" ]; then PASS=$((PASS + 1)); printf "PASS git change markers\n"; else FAIL=$((FAIL + 1)); printf "FAIL git change markers\n"; fi
    printf 'x\n' > "$G/u.txt"
    actual=$(cd "$G" && ours --decorations=always --color=never u.txt 2>&1 | sed -n 4p)
    if [ "$actual" = "   1 │ x" ]; then PASS=$((PASS + 1)); printf "PASS no markers for untracked file\n"; else FAIL=$((FAIL + 1)); printf "FAIL no markers for untracked file\n"; fi
    printf 'one\r\nTWO\r\nthree\r\nfour\r\n' > "$G/f.txt"
    git -C "$G" config core.autocrlf true
    actual=$(cd "$G" && ours --decorations=always --color=never f.txt 2>&1 | sed -n 4,7p | tr -d '\r')
    expected="   1   │ one
   2 ~ │ TWO
   3   │ three
   4   │ four"
    if [ "$actual" = "$expected" ]; then PASS=$((PASS + 1)); printf "PASS markers ignore a CRLF checkout\n"; else FAIL=$((FAIL + 1)); printf "FAIL markers ignore a CRLF checkout\n"; fi
    rm -rf "$G"

    # A repository that came with the files must not get to run anything.
    # Every program it can name leaves a file in $H/ran.
    H=$(mktemp -d)
    mkdir "$H/ran" "$H/repo" "$H/repo/.rel"
    trap_prog() { # NAME: a program that records that it ran
        printf '#!/bin/sh\necho "$@" >> "%s/ran/%s"\n%s\n' "$H" "$1" "$2" > "$H/$1"
        chmod +x "$H/$1"
    }
    # A filter passes the text through; the others only fail.
    trap_prog clean 'exec cat'
    trap_prog smudge 'exec cat'
    for p in fsmonitor process textconv external pager hook ssh uploadpack ext; do trap_prog "$p" 'exit 1'; done
    cp "$H/hook" "$H/repo/.rel/git"
    (
        cd "$H/repo" && git init -q . && printf 'one\ntwo\n' > f.txt && cp f.txt g.txt && printf 'lazy\n' > l.txt &&
        printf 'f.txt diff=y\ng.txt filter=x\n' > .gitattributes && git add . &&
        git -c user.name=t -c user.email=t@t commit -qm i &&
        printf 'one\nTWO\n' > f.txt && cp f.txt g.txt && printf 'more\n' >> l.txt
    ) </dev/null
    gc() { git -C "$H/repo" config "$1" "$2"; }
    gc core.fsmonitor "$H/fsmonitor"
    gc filter.x.clean "$H/clean"
    gc filter.x.smudge "$H/smudge"
    gc filter.x.process "$H/process"
    gc diff.y.textconv "$H/textconv"
    gc diff.external "$H/external"
    gc core.pager "$H/pager"
    gc pager.cat-file "$H/pager"
    mkdir -p "$H/repo/.git/hooks"
    cp "$H/hook" "$H/repo/.git/hooks/post-index-change"
    untouched() { # NAME FILE: view FILE; nothing of the repository's ran
        ( cd "$H/repo" && timeout 60 "$BIN_DIR/$UTIL" --decorations=always --color=never --paging=never "$2" ) >"$H/out" 2>&1
        if [ -z "$(ls "$H/ran")" ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$1"; else FAIL=$((FAIL + 1)); printf "FAIL %s: ran %s\n" "$1" "$(ls "$H/ran" | tr '\n' ' ')"; fi
        rm -f "$H"/ran/*
    }
    untouched "hostile repository: modified file" f.txt
    if grep -q '^   2 ~ ' "$H/out"; then PASS=$((PASS + 1)); printf "PASS hostile repository still shows markers\n"; else FAIL=$((FAIL + 1)); printf "FAIL hostile repository still shows markers\n"; fi
    untouched "hostile repository: filtered file" g.txt
    # A "git" that a relative PATH entry would find next to the files.
    saved_path=$PATH
    PATH=".rel:$PATH"
    untouched "hostile repository: git from a relative PATH entry" f.txt
    PATH=$saved_path
    # A partial clone fetches a missing object through a program the
    # repository chooses. Remove the blob of l.txt to force that.
    blob=$(git -C "$H/repo" -c core.fsmonitor= rev-parse :l.txt)
    rm -f "$H/repo/.git/objects/$(printf %s "$blob" | cut -c1-2)/$(printf %s "$blob" | cut -c3-)"
    rm -f "$H"/ran/*
    gc core.repositoryformatversion 1
    gc extensions.partialClone origin
    gc remote.origin.promisor true
    gc core.sshCommand "$H/ssh"
    gc remote.origin.url ssh://host.invalid/repo
    untouched "hostile repository: lazy fetch over ssh" l.txt
    gc protocol.ext.allow always
    gc remote.origin.url "ext::$H/ext"
    untouched "hostile repository: lazy fetch through ext::" l.txt
    gc remote.origin.url "$H/repo"
    gc remote.origin.uploadpack "$H/uploadpack"
    untouched "hostile repository: lazy fetch with uploadpack" l.txt
    rm -rf "$H"
fi

# Grammars and themes never come from the current directory (VIEW-021).
mkdir -p "$TEST_TMP/cwd/cat/syntaxes" "$TEST_TMP/cwd/.config/cat/syntaxes" "$TEST_TMP/cwd/rel/cat/syntaxes"
for d in cat .config/cat rel/cat; do
    printf '%%YAML 1.2\n---\nname: FromCwd\nfile_extensions: [cwdx]\nscope: source.cwd\ncontexts:\n  main: []\n' > "$TEST_TMP/cwd/$d/syntaxes/c.sublime-syntax"
done
for e in "XDG_CONFIG_HOME= HOME=" "HOME=" "XDG_CONFIG_HOME=. HOME=." "XDG_CONFIG_HOME=rel HOME=rel" "XDG_CONFIG_HOME= HOME=/nonexistent APPDATA="; do
    if ( cd "$TEST_TMP/cwd" && env -u XDG_CONFIG_HOME -u APPDATA $e "$BIN_DIR/cat" --list-languages ) | grep -q FromCwd; then
        FAIL=$((FAIL + 1)); echo "FAIL a grammar of the current directory is loaded: $e"
    else PASS=$((PASS + 1)); echo "PASS no grammar from the current directory: $e"; fi
done
if ( cd / && XDG_CONFIG_HOME="$TEST_TMP/cwd" "$BIN_DIR/cat" --list-languages ) | grep -q FromCwd; then
    PASS=$((PASS + 1)); echo "PASS an absolute XDG_CONFIG_HOME is used"
else FAIL=$((FAIL + 1)); echo "FAIL an absolute XDG_CONFIG_HOME is not used"; fi

# A message longer than any buffer is still printed (INFRA-010).
run_cmp "a 9000 byte name" "$(head -c 9000 /dev/zero | tr '\0' x)"

# Names in messages are quoted, as GNU does, so that none reaches the terminal
# as it is (VIEW-007).
for name in "$(printf 'n\033]0;T\007x')" "$(printf 'a\nb')" "$(printf 'c1\302\233z')" "$(printf 'bad\233')" "$(printf 'caf\303\251 x')" "it's" 'sp ace' 'a:b'; do
    CMP_LOCALE=C run_cmp "missing name, C" "./$name"
    CMP_LOCALE=C.UTF-8 run_cmp "missing name, UTF-8" "./$name"
done

# A capture index past any group, and a theme of more rules than 16 bits count,
# used to crash the highlighted view (VIEW-019).
mkdir -p "$TEST_TMP/vgr" "$TEST_TMP/vcfg/cat/themes"
printf '%%YAML 1.2\n---\nname: Bad\nfile_extensions: [bad]\nscope: source.bad\ncontexts:\n  main:\n    - match: a\n      captures:\n        2147483648: keyword\n        4294967295: string\n' > "$TEST_TMP/vgr/Bad.sublime-syntax"
printf 'aaa\n' > "$TEST_TMP/v.bad"; printf '# hi\n' > "$TEST_TMP/v.sh"
check_ours "huge capture index" "aaa" --syntax-dir="$TEST_TMP/vgr" --decorations=always --color=always --theme=ansi -p "$TEST_TMP/v.bad"
awk 'BEGIN { for (i = 0; i < 65540; i++) printf "a%d=1\n", i; print "comment=2" }' > "$TEST_TMP/vcfg/cat/themes/big.theme"
got=$(XDG_CONFIG_HOME="$TEST_TMP/vcfg" "$BIN_DIR/cat" --decorations=always --color=always --theme=big -p "$TEST_TMP/v.sh" 2>&1; echo "status $?")
if [ "$got" = "$(printf '\033[32m# hi\033[0m\nstatus 0')" ]; then PASS=$((PASS + 1)); echo "PASS a theme of 65541 rules"
else FAIL=$((FAIL + 1)); echo "FAIL a theme of 65541 rules: $got"; fi

# A name containing "writ" does not stand for a report of the write error (INFRA-013).
if [ -c /dev/full ]; then
    printf 'x\n' > "$TEST_TMP/some"
    exp=$(cd "$TEST_TMP" && LC_ALL=C gnu nonexistent-rewrite some 2>&1 >/dev/full | sed 's|/usr/bin/||'; echo end)
    act=$(cd "$TEST_TMP" && LC_ALL=C ours nonexistent-rewrite some 2>&1 >/dev/full; echo end)
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS write error after a name with writ"
    else FAIL=$((FAIL + 1)); echo "FAIL write error after a name with writ: $act"; fi
fi

# A small grammar cannot unfold without end: contexts that include each other
# repeatedly, and variables made of each other (VIEW-020).
bomb="$TEST_TMP/bomb"; mkdir -p "$bomb/inc" "$bomb/var"
bomb_head='%%%%YAML 1.2\n---\nname: Bomb\nfile_extensions: [bomb]\nscope: source.bomb\n'
# shellcheck disable=SC2059
{ printf "${bomb_head}contexts:\n"; printf '  main:\n    - include: main\n    - include: other\n    - include: other\n    - match: a\n      scope: keyword\n  other:\n    - include: main\n    - include: main\n'; } > "$bomb/inc/b.sublime-syntax"
# shellcheck disable=SC2059
{ printf "${bomb_head}variables:\n"
    i=0; while [ $i -lt 14 ]; do j=$((i + 1)); printf "  v$i: '{{v$j}}{{v$j}}{{v$j}}{{v$j}}{{v$j}}{{v$j}}{{v$j}}{{v$j}}'\n"; i=$j; done
    printf "  v14: ''\ncontexts:\n  main:\n    - match: '{{v0}}'\n      scope: keyword\n    - match: a\n      scope: keyword\n"; } > "$bomb/var/b.sublime-syntax"
printf 'a b a\n' > "$bomb/f.bomb"
for kind in inc var; do
    out=$( (ulimit -v 600000; timeout 30 "$BIN_DIR/cat" --syntax-dir="$bomb/$kind" --decorations=always --color=always --theme=ansi -p "$bomb/f.bomb") 2>&1 | cat -v)
    if [ "$out" = '^[[35ma^[[0m b ^[[35ma^[[0m' ]; then PASS=$((PASS + 1)); echo "PASS grammar bomb: $kind"
    else FAIL=$((FAIL + 1)); echo "FAIL grammar bomb: $kind: $out"; fi
done

print_summary
