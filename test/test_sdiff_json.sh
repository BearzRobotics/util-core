#!/bin/sh
# sdiff --json: the rows are checked against GNU sdiff's text (-w 3 prints
# only the markers, so the marker column of GNU's output is compared).
UTIL="sdiff"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"
if ! have_jq; then echo "SKIP: jq not installed"; exit 0; fi

W="$(mktemp -d)"; cd "$W"
printf 'a\nb\nc\nd\ne\n' > i1; printf 'a\nX\nc\nf\ne\ng\n' > i2
: > empty

# GNU marker column: with width 3 each row is "<marker>" surrounded by blanks.
gnu_markers() { LC_ALL=C /usr/bin/sdiff -w 3 "$@" | sed 's/^ *//; s/ *$//; s/^$/=/' | tr '\n' ' '; }
ours_markers() { ours --json "$@" | jq -r '.rows[] | (if .marker=="equal" then "=" elif .marker=="changed" then "|" elif .marker=="left_only" then "<" else ">" end)' | tr '\n' ' '; }
for p in "i1 i2" "i1 i1" "empty i1" "i1 empty"; do
    check "markers: $p" "$(gnu_markers $p)" "$(ours_markers $p)"
done
out=$(ours --json i1 i2); rc=$?
check "status 1" 1 "$rc"
check "files" 'i1 i2' "$(echo "$out" | jq -r '.files | join(" ")')"
check "changed row" 'b X 2 2' "$(echo "$out" | jq -r '.rows[] | select(.marker=="changed") | select(.left=="b") | "\(.left) \(.right) \(.left_line) \(.right_line)"')"
check "left_only row" 'd' "$(echo "$out" | jq -r '.rows[] | select(.marker=="left_only") | .left')"
check "left_only has null right" null "$(echo "$out" | jq -c '.rows[] | select(.marker=="left_only") | .right')"
check "right_only row" 'g' "$(echo "$out" | jq -r '.rows[] | select(.marker=="right_only") | .right')"
ours --json i1 i1 >/dev/null; check "identical status" 0 $?
ours --json -o out i1 i2 >/dev/null 2>&1; check "--json -o refused" 2 $?
ours --json -t i1 i2 >/dev/null 2>&1; check "--json -t refused" 2 $?
check "--help lists --json" 1 "$(ours --help | grep -c -e '--json.*(not in GNU)')"
print_summary
[ "$FAIL" -eq 0 ]
