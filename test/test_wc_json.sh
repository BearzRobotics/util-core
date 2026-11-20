#!/bin/sh
# wc --json: GNU wc has no --json, so every count is compared with GNU wc's
# output for the same input (GNU coreutils 9.7), and the JSON must parse.
# Needs python3 and GNU wc.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
export LC_ALL=C
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
printf 'hello world\nsecond line here\n\nlast' > a; : > empty; head -c 100000 /dev/urandom > rnd; printf 'tab\there\r\nx\fy\n' > odd
printf 'caf\303\251 na\303\257ve\n' > utf8; printf 'no newline' > nonl; mkdir dir; printf 'q"uote' > 'we"ird name'

# opts, files: compare each selected count with GNU `wc <opt> file`
cmp() { # json key, wc option, files...
    key=$1; opt=$2; shift 2
    for f in "$@"; do
        want=$(wc $opt "$f" 2>/dev/null | awk '{print $1}')
        got=$("$BIN/wc" --json $opt "$f" 2>/dev/null | python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['$key'])" 2>/dev/null)
        [ -n "$want" ] && [ "$want" = "$got" ] && ok || bad "$key $opt $f: GNU=[$want] OURS=[$got]"
    done
}
# GNU comparison. wc's documented deviation (src/commands/wc.zig): -m counts UTF-8
# code points and words are split on ASCII whitespace only, whatever the locale,
# while GNU in the C locale counts bytes; so -m and -w are compared with GNU only
# for ASCII text, and for binary and UTF-8 input with this wc's own text output.
for f in a empty odd nonl "we\"ird name"; do
    cmp lines -l "$f"; cmp words -w "$f"; cmp bytes -c "$f"; cmp chars -m "$f"; cmp max_line_length -L "$f"
done
for f in rnd utf8; do
    cmp lines -l "$f"; cmp bytes -c "$f"; cmp max_line_length -L "$f"
done
cmp_self() { # json key, wc option, file: the JSON count equals this wc's text count
    key=$1; opt=$2; f=$3
    want=$("$BIN/wc" $opt "$f" | awk '{print $1}')
    got=$("$BIN/wc" --json $opt "$f" | python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['$key'])")
    [ -n "$want" ] && [ "$want" = "$got" ] && ok || bad "self $key $opt $f: text=[$want] json=[$got]"
}
for f in rnd utf8; do cmp_self words -w "$f"; cmp_self chars -m "$f"; done
# Default selection (lines, words, bytes) and exactly those keys.
t "default keys" sh -c "'$BIN/wc' --json a | python3 -c 'import json,sys;d=json.load(sys.stdin);assert sorted(k for k in d if k not in (\"file\",\"total\"))==[\"bytes\",\"lines\",\"words\"]'"
t "-l only has only lines" sh -c "'$BIN/wc' --json -l a | python3 -c 'import json,sys;d=json.load(sys.stdin);assert sorted(k for k in d if k not in (\"file\",\"total\"))==[\"lines\"]'"
t "file name is reported" sh -c "'$BIN/wc' --json a | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"file\"]==\"a\"'"
t "stdin without operand: file is null" sh -c "'$BIN/wc' --json < a | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"file\"] is None and d[\"lines\"]==3'"
t "several files: one line each plus a total" sh -c "[ \"\$('$BIN/wc' --json a empty utf8 | wc -l)\" = 4 ]"
t "total equals GNU total" sh -c "[ \"\$('$BIN/wc' --json -lwc a empty utf8 | tail -1 | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"lines\"],d[\"words\"],d[\"bytes\"],d[\"total\"])')\" = \"\$(wc -lwc a empty utf8 | tail -1 | awk '{print \$1,\$2,\$3}') True\" ]"
t "total max_line_length is the maximum" sh -c "'$BIN/wc' --json -L a odd | tail -1 | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"total\"] and d[\"max_line_length\"]==max($(wc -L < a),$(wc -L < odd))'"
t "missing file: others counted, status 1" sh -c "out=\$('$BIN/wc' --json nofile a 2>/dev/null); rc=\$?; [ \$rc = 1 ] && echo \"\$out\" | head -1 | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"file\"]==\"a\"'"
t "directory: zero counts like GNU" sh -c "'$BIN/wc' --json -c dir 2>/dev/null | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"bytes\"]==0'"
t "--json is listed in --help as a non-GNU line" sh -c "'$BIN/wc' --help | grep -q -e '--json .*not in GNU' -e '-json .*JSON'"
t "text output is unchanged" sh -c "[ \"\$('$BIN/wc' a utf8)\" = \"\$(wc a utf8)\" ]"
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
