#!/bin/sh
# dircolors tests. Expected values come from the GNU coreutils manual
# (dircolors invocation) and src/dircolors.c / dircolors.hin (master,
# consulted 2026-11-04). /usr/bin/dircolors must be GNU coreutils (9.7 when
# written); testlib.sh refuses to run otherwise.
# The built-in database follows GNU master, so default-database output is not
# compared with 9.7 here (extension lists differ; see
# docs/compatibility/dircolors.md).
UTIL="dircolors"
. "$(dirname "$0")/testlib.sh"

T=/tmp/test_dircolors.$$
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
export SHELL=/bin/bash TERM=xterm
unset COLORTERM

# check DESCRIPTION EXPECTED_STDOUT EXPECTED_RC ARGS... (stderr discarded)
check() {
    description="$1"; expected="$2"; want_rc="$3"; shift 3
    actual=$(ours "$@" 2>/dev/null); rc=$?
    if [ "$actual" = "$expected" ] && [ "$rc" -eq "$want_rc" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s (rc=%s)\n   got:      %s\n   expected: %s\n" "$description" "$rc" "$actual" "$expected"
    fi
}
# check_msg DESCRIPTION NEEDLE ARGS...: fails with rc!=0, stderr contains NEEDLE
check_msg() {
    description="$1"; needle="$2"; shift 2
    msg=$(ours "$@" 2>&1 >/dev/null); rc=$?
    case "$msg" in
        *"$needle"*) [ "$rc" -ne 0 ] && { PASS=$((PASS + 1)); printf "PASS %s\n" "$description"; } || { FAIL=$((FAIL + 1)); printf "FAIL %s (rc 0)\n" "$description"; } ;;
        *) FAIL=$((FAIL + 1)); printf "FAIL %s\n   message: %s\n   wanted:  %s\n" "$description" "$msg" "$needle" ;;
    esac
}

printf "\n[ Built-in database ]\n"
out=$(ours -b)
case "$out" in "LS_COLORS='rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=00:tw=30;42:ow=34;42:st=37;44:ex=01;32:"*"*.tar=01;31:"*"';
export LS_COLORS") PASS=$((PASS + 1)); echo "PASS xterm gets colors, in the standard order";; *) FAIL=$((FAIL + 1)); echo "FAIL xterm output";; esac
a=$(TERM=foo "$BIN_DIR/dircolors" -b); [ "$a" = "LS_COLORS='';
export LS_COLORS" ] && { PASS=$((PASS + 1)); echo "PASS TERM=foo: empty LS_COLORS"; } || { FAIL=$((FAIL + 1)); echo "FAIL TERM=foo"; }
a=$(TERM=foo COLORTERM=truecolor "$BIN_DIR/dircolors" -b | head -c 16); [ "$a" = "LS_COLORS='rs=0:" ] && { PASS=$((PASS + 1)); echo "PASS COLORTERM=truecolor enables colors for any TERM"; } || { FAIL=$((FAIL + 1)); echo "FAIL COLORTERM"; }
a=$(env -u TERM "$BIN_DIR/dircolors" -b); [ "$a" = "LS_COLORS='';
export LS_COLORS" ] && { PASS=$((PASS + 1)); echo "PASS unset TERM is treated as 'none'"; } || { FAIL=$((FAIL + 1)); echo "FAIL unset TERM"; }
a=$(TERM=xterm "$BIN_DIR/dircolors" -c | head -c 40); [ "$a" = "setenv LS_COLORS 'rs=0:di=01;34:ln=01;36" ] && { PASS=$((PASS + 1)); echo "PASS -c prints setenv"; } || { FAIL=$((FAIL + 1)); echo "FAIL -c"; }
for s in /bin/csh /usr/bin/tcsh; do
    a=$(SHELL=$s "$BIN_DIR/dircolors" | head -c 16); [ "$a" = "setenv LS_COLORS" ] && { PASS=$((PASS + 1)); echo "PASS SHELL=$s selects C shell"; } || { FAIL=$((FAIL + 1)); echo "FAIL SHELL=$s"; }
done
for s in /bin/zsh /bin/bash /usr/bin/mycsh; do
    a=$(SHELL=$s "$BIN_DIR/dircolors" | head -c 11); [ "$a" = "LS_COLORS='" ] && { PASS=$((PASS + 1)); echo "PASS SHELL=$s selects Bourne (basename must be exactly csh/tcsh)"; } || { FAIL=$((FAIL + 1)); echo "FAIL SHELL=$s"; }
done
msg=$(SHELL= "$BIN_DIR/dircolors" 2>&1 >/dev/null); case "$msg" in *"no SHELL environment variable, and no shell type option given"*) PASS=$((PASS + 1)); echo "PASS empty SHELL is treated as unset";; *) FAIL=$((FAIL + 1)); echo "FAIL empty SHELL";; esac

printf "\n[ Custom files: GNU semantics ]\n"
printf '# c\r\ndir 01;34  # note\n.tar 1\n*~ 2\nLNK 3\nOPTIONS x\nEIGHTBIT 1\nCOLOR tty\nNORMAL 5\nENDCODE 7\n' > "$T/a"
check "keywords, aliases, comments, CRLF" "LS_COLORS='di=01;34:*.tar=1:*~=2:ln=3:no=5:ec=7:';
export LS_COLORS" 0 -b "$T/a"
printf 'DIR 1 2\n.x  a b c\n' > "$T/multi"
check "values keep inner white space" "LS_COLORS='di=1 2:*.x=a b c:';
export LS_COLORS" 0 -b "$T/multi"
printf 'DIR a#b\nFILE 2\n' > "$T/hash"
check "'#' ends the value even inside a word" "LS_COLORS='di=a:fi=2:';
export LS_COLORS" 0 -b "$T/hash"
printf '.a:b 1\nDIR x=y\nFILE it'"'"'s\n.t \\e[1m\nLNK a\\:b\n' > "$T/esc"
check "escaping of : = ' and protected : (entries keep file order)" "LS_COLORS='*.a\\:b=1:di=x\\=y:fi=it'\\''s:*.t=\\e[1m:ln=a\\:b:';
export LS_COLORS" 0 -b "$T/esc"
printf 'FILE a!b\n' > "$T/bang"
check "! is escaped only for C shell (Bourne)" "LS_COLORS='fi=a!b:';
export LS_COLORS" 0 -b "$T/bang"
check "! is escaped only for C shell (C)" "setenv LS_COLORS 'fi=a\\!b:'" 0 -c "$T/bang"
: > "$T/empty"
check "empty file" "LS_COLORS='';
export LS_COLORS" 0 -b "$T/empty"
printf 'DIR 7' > "$T/nonl"
check "no trailing newline" "LS_COLORS='di=7:';
export LS_COLORS" 0 -b "$T/nonl"
a=$(printf 'FILE 9\n' | ours -b -); [ "$a" = "LS_COLORS='fi=9:';
export LS_COLORS" ] && { PASS=$((PASS + 1)); echo "PASS read from stdin (-)"; } || { FAIL=$((FAIL + 1)); echo "FAIL stdin"; }
printf 'FOO 1\nDIR 2\n' > "$T/globalunk"
check "unknown keyword outside TERM blocks is ignored" "LS_COLORS='di=2:';
export LS_COLORS" 0 -b "$T/globalunk"

printf "\n[ TERM / COLORTERM state machine ]\n"
printf 'TERM vt*\nDIR 1\nTERM xterm*\nFILE 2\n' > "$T/t1"
printf 'TERM xterm*\nDIR 1\nTERM vt*\nFILE 2\n' > "$T/t2"
printf 'COLORTERM ?*\nDIR 5\n' > "$T/t3"
printf 'TERM nomatch*\nFOO 1\nDIR 2\n' > "$T/t4"
check "later matching TERM enables entries"        "LS_COLORS='fi=2:';
export LS_COLORS" 0 -b "$T/t1"
check "a later non-matching TERM cancels entries"  "LS_COLORS='di=1:';
export LS_COLORS" 0 -b "$T/t2"
check "COLORTERM unset never matches ?*"           "LS_COLORS='';
export LS_COLORS" 0 -b "$T/t3"
a=$(COLORTERM=1 "$BIN_DIR/dircolors" -b "$T/t3"); [ "$a" = "LS_COLORS='di=5:';
export LS_COLORS" ] && { PASS=$((PASS + 1)); echo "PASS COLORTERM set matches ?*"; } || { FAIL=$((FAIL + 1)); echo "FAIL COLORTERM set"; }
check "unknown keyword under non-matching TERM is ignored" "LS_COLORS='';
export LS_COLORS" 0 -b "$T/t4"
# Differential comparison against /usr/bin/dircolors (GNU).
for f in t3 t4 multi nonl empty; do
    for e in "TERM=xterm" "TERM=vt100" "TERM=zzz COLORTERM=1"; do
        x=$(env -u COLORTERM $e $BIN_DIR/dircolors -b "$T/$f" 2>&1); y=$(env -u COLORTERM $e /usr/bin/dircolors -b "$T/$f" 2>&1)
        [ "$x" = "$y" ] && { PASS=$((PASS + 1)); printf "PASS agrees with GNU: %s [%s]\n" "$f" "$e"; } || { FAIL=$((FAIL + 1)); printf "FAIL agrees with GNU: %s [%s]\n" "$f" "$e"; }
    done
done

printf "\n[ --print-ls-colors and --print-database ]\n"
printf 'DIR 01;35\n.gz 01;31\nFILE a:b\n' > "$T/p"
ESC=$(printf '\033')
check "--print-ls-colors is raw, one line per entry" "${ESC}[01;35mdi	01;35${ESC}[0m
${ESC}[01;31m*.gz	01;31${ESC}[0m
${ESC}[a:bmfi	a:b${ESC}[0m" 0 --print-ls-colors "$T/p"
db=$(ours -p)
n=$(printf '%s\n' "$db" | grep -c '^[A-Za-z.*]')
[ "$n" -gt 150 ] && { PASS=$((PASS + 1)); echo "PASS -p prints the database ($n lines of data)"; } || { FAIL=$((FAIL + 1)); echo "FAIL -p"; }
printf '%s\n' "$db" > "$T/roundtrip"
[ "$(ours -b "$T/roundtrip")" = "$(ours -b)" ] && { PASS=$((PASS + 1)); echo "PASS -p output is a valid database (round trip)"; } || { FAIL=$((FAIL + 1)); echo "FAIL round trip"; }
[ "$(ours -p)" = "$(ours --print-d)" ] && { PASS=$((PASS + 1)); echo "PASS long options may be abbreviated"; } || { FAIL=$((FAIL + 1)); echo "FAIL abbreviation"; }

printf "\n[ Errors (exit status 1, nothing on stdout) ]\n"
printf 'TERM xterm*\nFOO 1\nDIR\nBAR 2\n' > "$T/bad"
check_msg "unknown keyword is quoted and located"  "$T/bad:2: unrecognized keyword 'FOO'" -b "$T/bad"
check_msg "all problems are reported"              "$T/bad:4: unrecognized keyword 'BAR'" -b "$T/bad"
check_msg "missing second token"                   "$T/bad:3: invalid line;  missing second token" -b "$T/bad"
out=$(ours -b "$T/bad" 2>/dev/null); [ -z "$out" ] && { PASS=$((PASS + 1)); echo "PASS no output when the file has errors"; } || { FAIL=$((FAIL + 1)); echo "FAIL output on error"; }
check_msg "missing file"                           "nonexistent" -b "$T/nonexistent"
check_msg "-p with -b"                             "mutually exclusive" -p -b
check_msg "--print-ls-colors with -c"              "mutually exclusive" --print-ls-colors -c
check_msg "-p with --print-ls-colors"              "options --print-database and --print-ls-colors are mutually exclusive" -p --print-ls-colors
check_msg "-p with a file operand"                 "file operands cannot be combined with --print-database (-p)" -p "$T/a"
check_msg "extra operand"                          "extra operand '$T/a'" -b "$T/a" "$T/a"
check_msg "invalid option"                         "invalid option" --bogus
check_msg "ambiguous abbreviation"                 "invalid option" --print

print_summary
