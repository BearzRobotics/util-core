#!/bin/sh
# diff --json: the JSON hunks are turned back into unified text with jq and
# compared with GNU diff -u (header lines dropped).
UTIL="diff"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"
if ! have_jq; then echo "SKIP: jq not installed"; exit 0; fi

W="$(mktemp -d)"; cd "$W"
JQ_UNI='def rng(s;c): if c==1 then "\(s)" else "\(s),\(c)" end;
  .hunks[] | "@@ -\(rng(.old_start;.old_count)) +\(rng(.new_start;.new_count)) @@",
  (.lines[] | (if .kind=="context" then " " elif .kind=="removed" then "-" else "+" end) + .text, (if .no_newline then "\\ No newline at end of file" else empty end))'

cmp_json() {
    d="$1"; shift
    exp=$(LC_ALL=C /usr/bin/diff -u "$@" 2>/dev/null | tail -n +3)
    got=$(ours --json "$@" | jq -r "$JQ_UNI" 2>&1)
    if [ "$exp" = "$got" ]; then PASS=$((PASS + 1)); echo "PASS $d"; else FAIL=$((FAIL + 1)); echo "FAIL $d"; printf '  want: %s\n  got : %s\n' "$exp" "$got"; fi
}

printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n' > o
printf '1\n2\nx\n4\n5\n6\n7\n8\n9\n10\ny\nz\n12\n' > n
printf 'a\nb' > e1; printf 'a\nc' > e2; : > empty; printf 'x\n' > one
printf 'a  b\n' > w1; printf 'a b\n' > w2

printf "\n[ Hunks against GNU diff -u ]\n"
cmp_json "o n" o n
cmp_json "e1 e2 (no newline)" e1 e2
cmp_json "empty one" empty one
cmp_json "one empty" one empty
cmp_json "identical" o o
exp=$(LC_ALL=C /usr/bin/diff -U1 o n | tail -n +3); got=$(ours --json -U 1 o n | jq -r "$JQ_UNI"); check "-U 1 hunks" "$exp" "$got"
check "-U 1 hunk count follows -U" "$(LC_ALL=C /usr/bin/diff -U1 o n | grep -c '^@@')" "$(ours --json -U 1 o n | jq '.hunks | length')"
check "-w equal" true "$(ours --json -w w1 w2 | jq -r .equal)"
cmp_json "-b" -b w1 w2

printf "\n[ Fields ]\n"
out=$(ours --json o n); rc=$?
check "status 1" 1 "$rc"
check "kind" diff "$(echo "$out" | jq -r .kind)"
check "old/new" 'o n' "$(echo "$out" | jq -r '.old + " " + .new')"
check "equal false" false "$(echo "$out" | jq -r .equal)"
check "binary false" false "$(echo "$out" | jq -r .binary)"
out=$(ours --json o o); rc=$?
check "identical status" 0 "$rc"
check "identical equal" true "$(echo "$out" | jq -r .equal)"
printf 'x\0y\n' > bin1; printf 'x\0z\n' > bin2
out=$(ours --json bin1 bin2)
check "binary flag" true "$(echo "$out" | jq -r .binary)"
out=$(ours --json -a bin1 bin2)
check "-a makes text" false "$(echo "$out" | jq -r .binary)"
ours --json -y o n >/dev/null 2>&1; check "--json -y refused" 2 $?
ours --json -T o n >/dev/null 2>&1; check "--json -T refused" 2 $?
check "--help lists --json" 1 "$(ours --help | grep -c -e '--json.*(not in GNU)')"
out=$(ours --j o n); check "--j abbreviation" diff "$(echo "$out" | jq -r .kind)"

printf "\n[ Directories ]\n"
mkdir -p d1/sub d1/only1 d2/sub d2/same
printf 'x\n' > d1/a; printf 'y\n' > d2/a; printf 's\n' > d1/sub/f; printf 't\n' > d2/sub/f
printf '1\n' > d1/o1; printf '2\n' > d2/o2; printf 'q\n' > d1/same.txt; printf 'q\n' > d2/same.txt
mkdir d1/dd; printf 'q\n' > d2/dd
out=$(ours --json -r d1 d2); rc=$?
check "dir status" 1 "$rc"
check "dir is a list" array "$(echo "$out" | jq -r 'type')"
gnu_only=$(LC_ALL=C /usr/bin/diff -r d1 d2 2>/dev/null | grep '^Only in' | sort)
ours_only=$(echo "$out" | jq -r '.[] | select(.kind=="only_in") | "Only in " + (if .side=="old" then "d1" else "d2" end) + ": " + .name' | sort)
check "only_in entries match GNU" "$gnu_only" "$ours_only"
check "diff entries" "d1/a d2/a
d1/sub/f d2/sub/f" "$(echo "$out" | jq -r '.[] | select(.kind=="diff" and (.equal | not)) | .old + " " + .new')"
check "type mismatch" "directory regular file" "$(echo "$out" | jq -r '.[] | select(.kind=="type_mismatch") | .old_type + " " + .new_type')"
out=$(ours --json d1 d2)
check "non-recursive: common subdirectory" "d1/sub d2/sub" "$(echo "$out" | jq -r '.[] | select(.kind=="common_subdirectory") | .old + " " + .new')"
out=$(ours --json -rs d1 d2)
check "-s lists identical" "d1/same.txt" "$(echo "$out" | jq -r '.[] | select(.kind=="diff" and .equal) | .old')"
check "empty array when equal" "[]" "$(ours --json -r d2/same d2/same | jq -c '.')" 2>/dev/null || true

print_summary
[ "$FAIL" -eq 0 ]
