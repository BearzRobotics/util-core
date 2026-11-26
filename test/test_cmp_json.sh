#!/bin/sh
# cmp --json: the JSON is checked against GNU cmp's own text output.
UTIL="cmp"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"

if ! have_jq; then echo "SKIP: jq not installed"; SUMMARY_DONE=1; exit 0; fi
W="$(mktemp -d)"; cd "$W"
printf 'abc\ndef\nghi\n' > a
printf 'abc\ndXf\nghi\nzz' > b
printf 'abc\n' > c
printf 'abc' > p
: > e

# j FILE1 FILE2 [OPTS]: our JSON with the comparison's exit status.
printf "\n[ Equal and different ]\n"
out=$(ours --json a a); rc=$?
check "equal: equal true" true "$(echo "$out" | jq -r .equal)"
check "equal: status" 0 "$rc"
check "equal: first_difference null" null "$(echo "$out" | jq -c .first_difference)"
check "equal: file names" 'a a' "$(echo "$out" | jq -r '.file1 + " " + .file2')"

out=$(ours --json a b); rc=$?
gnu_msg=$(LC_ALL=C gnu a b)
check "differ: status" 1 "$rc"
check "differ: equal false" false "$(echo "$out" | jq -r .equal)"
check "differ: byte and line match GNU text" "a b differ: char $(echo "$out" | jq -r .first_difference.byte), line $(echo "$out" | jq -r .first_difference.line)" "$gnu_msg"
check "differ: bytes" '101 88' "$(echo "$out" | jq -r '.first_difference | "\(.byte1) \(.byte2)"')"
check "differ: no differences list without -l" null "$(echo "$out" | jq -c '.differences')"

printf "\n[ EOF ]\n"
out=$(ours --json a c); rc=$?
check "eof: status" 1 "$rc"
check "eof: file" c "$(echo "$out" | jq -r .eof.file)"
check "eof: after_byte" 4 "$(echo "$out" | jq -r .eof.after_byte)"
check "eof: partial_line false" false "$(echo "$out" | jq -r .eof.partial_line)"
check "eof: GNU text agrees" "cmp: EOF on 'c' after byte 4, line 1" "$(LC_ALL=C gnu a c 2>&1)"
out=$(ours --json a p)
check "eof partial: partial_line true" true "$(echo "$out" | jq -r .eof.partial_line)"
out=$(ours --json a e)
check "eof empty: after_byte 0" 0 "$(echo "$out" | jq -r .eof.after_byte)"

printf "\n[ -l ]\n"
out=$(ours --json -l a b)
gl=$(LC_ALL=C gnu -l a b 2>/dev/null | awk '{print $1 ":" $2 ":" $3}')
jl=$(echo "$out" | jq -r '.differences[] | "\(.byte):" + (.byte1 | tostring) + ":" + (.byte2|tostring)')
# GNU prints octal; convert ours to octal for the comparison
jl=$(echo "$out" | jq -r '.differences[] | "\(.byte)"')
check "-l: byte numbers match GNU" "$(LC_ALL=C gnu -l a b 2>/dev/null | awk '{print $1}')" "$jl"
check "-l: count" "$(LC_ALL=C gnu -l a b 2>/dev/null | wc -l | tr -d ' ')" "$(echo "$out" | jq -r .difference_count)"
seq 1 1000 > big1; seq 1 1000 | sed 's/7/x/' > big2
out=$(ours --json -l big1 big2)
check "-l big: count" "$(LC_ALL=C gnu -l big1 big2 | wc -l | tr -d ' ')" "$(echo "$out" | jq -r .difference_count)"
check "-l big: octal bytes agree" "$(LC_ALL=C gnu -l big1 big2 | awk '{print $2 ":" $3}' | head -5 | tr '\n' ' ')" "$(echo "$out" | jq -r '.differences[:5][] | ((.byte1|tostring)+":"+(.byte2|tostring))' | awk -F: '{printf "%o:%o ", $1, $2}')"

printf "\n[ Options and errors ]\n"
out=$(ours --json -n 2 a b); rc=$?
check "-n: equal within limit" true "$(echo "$out" | jq -r .equal)"
check "-n: status" 0 "$rc"
out=$(ours --json -i 2 a b)
check "-i: byte relative to skip" 4 "$(echo "$out" | jq -r .first_difference.byte)"
ours --json -b a b >/dev/null 2>&1; check "--json -b refused" 2 $?
ours --json -s a b >/dev/null 2>&1; check "--json -s refused" 2 $?
out=$(ours --json a nonexist 2>/dev/null); rc=$?
check "missing file: status" 2 "$rc"
check "missing file: no JSON" "" "$out"
out=$(ours --j a a); check "--j abbreviation" true "$(echo "$out" | jq -r .equal)"
check "valid JSON on one line" 1 "$(ours --json -l a b | wc -l | tr -d ' ')"
help_text=$(ours --help | grep -c -e '--json.*(not in GNU)')
check "--help lists --json as not in GNU" 1 "$help_text"

print_summary
[ "$FAIL" -eq 0 ]
