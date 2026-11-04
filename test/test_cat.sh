#!/bin/sh
UTIL="cat"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_cat1.txt
printf "line1\nline2\nline3\n" > /tmp/test_cat2.txt
printf "line with\ttabs\n" > /tmp/test_cat3.txt
printf "\n\n\nblank lines\n" > /tmp/test_cat4.txt

printf "\n[ Basic output ]\n"
run_test_file "single file"          /tmp/test_cat1.txt
run_test "multiple files"            /tmp/test_cat1.txt /tmp/test_cat2.txt

printf "\n[ Flags ]\n"
run_test_file "-n number lines"      /tmp/test_cat2.txt -n
run_test_file "-b number nonblank"   /tmp/test_cat4.txt -b
run_test_file "-s squeeze blank"     /tmp/test_cat4.txt -s
run_test_file "-A show all"          /tmp/test_cat3.txt -A
run_test_file "-E show line ends"    /tmp/test_cat2.txt -E
run_test_file "-T show tabs"         /tmp/test_cat3.txt -T
run_test_file "-v show nonprint"     /tmp/test_cat3.txt -v

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
   3 line3" --decorations=always --color=never --style=numbers /tmp/test_cat2.txt
check_ours "-p is raw" "$(cat /tmp/test_cat2.txt)" --decorations=always -p /tmp/test_cat2.txt
check_ours "pipe stays GNU" "$(cat /tmp/test_cat2.txt)" /tmp/test_cat2.txt
check_ours "GNU flag beats bat view" "$(gnu -n /tmp/test_cat2.txt)" --decorations=always -n /tmp/test_cat2.txt
check_ours "bad --style rejected" "cat: invalid argument 'x' for '--style'" --style=x /tmp/test_cat2.txt

printf "\n[ syntax highlighting (toy grammar) ]\n"
mkdir -p /tmp/test_cat_syn
cat > /tmp/test_cat_syn/Toy.sublime-syntax <<'GRAMMAR'
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
printf 'if "a\nb" else\n' > /tmp/test_cat5.toy
ESC=$(printf '\033')
SYN="--syntax-dir=/tmp/test_cat_syn --decorations=always --color=always -p"
check_ours "highlight by extension" "${ESC}[35mif${ESC}[0m ${ESC}[32m\"${ESC}[0m${ESC}[32ma${ESC}[0m
${ESC}[32mb${ESC}[0m${ESC}[32m\"${ESC}[0m ${ESC}[35melse${ESC}[0m" $SYN /tmp/test_cat5.toy
actual=$(printf 'if\n' | ours $SYN -l toy 2>&1)
if [ "$actual" = "${ESC}[35mif${ESC}[0m" ]; then PASS=$((PASS + 1)); printf "PASS highlight stdin with -l\n"; else FAIL=$((FAIL + 1)); printf "FAIL highlight stdin with -l\n"; fi
check_ours "no color, no escapes" "if \"a
b\" else" --syntax-dir=/tmp/test_cat_syn --decorations=always --color=never -p /tmp/test_cat5.toy
check_ours "unknown language" "cat: unknown language 'zzz' (see --list-languages)" $SYN -l zzz /tmp/test_cat5.toy
check_ours "list languages" "Toy	toy" --syntax-dir=/tmp/test_cat_syn --list-languages
check_ours "pipe ignores highlighting" "$(cat /tmp/test_cat5.toy)" --syntax-dir=/tmp/test_cat_syn /tmp/test_cat5.toy
# NO_COLOR (SPEC 5.4) needs a terminal on stdout, so run under script(1).
if command -v script >/dev/null 2>&1; then
    tty_run() { # "ENV=val ...", then extra cat options; prints output with CRs removed
        envs="$1"; shift
        script -qec "env $envs $BIN_DIR/cat --syntax-dir=/tmp/test_cat_syn $* /tmp/test_cat5.toy" /dev/null | tr -d '\r'
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
rm -rf /tmp/test_cat_syn /tmp/test_cat5.toy

rm -f /tmp/test_cat1.txt /tmp/test_cat2.txt /tmp/test_cat3.txt /tmp/test_cat4.txt
print_summary
