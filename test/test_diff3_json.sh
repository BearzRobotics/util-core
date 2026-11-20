#!/bin/sh
# diff3 --json: block kinds and ranges are checked against GNU diff3's own
# normal-format report.
UTIL="diff3"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"
if ! have_jq; then echo "SKIP: jq not installed"; exit 0; fi

W="$(mktemp -d)"; cd "$W"
printf 'a\nM\nc\nd\ne\nf\nmm\n' > mine; printf 'a\nb\nc\nd\ne\nf\n' > old; printf 'a\nb\nc\nY\ne\nf\n' > your
printf 'a\nM\nc\nd\nZ\nf\n' > mine2; printf 'a\nQ\nc\nd\nZ\nf\n' > your2

# Kinds in order, from GNU's "====", "====1", ... headers.
gnu_kinds() { LC_ALL=C /usr/bin/diff3 "$@" | awk '/^====/ { k = substr($0, 5); print (k == "1" ? "only-first" : k == "2" ? "only-second" : k == "3" ? "only-third" : "overlap") }'; }
ours_kinds() { ours --json "$@" | jq -r '.blocks[] | select(.kind != "unchanged") | .kind'; }
for t in "mine old your" "mine2 old your2" "old old old" "mine old old" "old old your"; do
    check "kinds: $t" "$(gnu_kinds $t)" "$(ours_kinds $t)"
done

# Ranges: "1:2c" lines of GNU's report against start/count.
gnu_ranges() { LC_ALL=C /usr/bin/diff3 "$@" | grep -E '^[123]:' | tr '\n' ' '; }
ours_ranges() { ours --json "$@" | jq -r '.blocks[] | select(.kind != "unchanged") | .sides | to_entries[] | "\(.key + 1):" + (if .value.count == 0 then "\(.value.start - 1)a" elif .value.count == 1 then "\(.value.start)c" else "\(.value.start),\(.value.start + .value.count - 1)c" end)' | tr '\n' ' '; }
check "ranges: mine old your" "$(gnu_ranges mine old your | sed 's/1:/1:/g')" "$(ours_ranges mine old your)"

out=$(ours --json mine2 old your2); rc=$?
check "status 0" 0 "$rc"
check "files" 'mine2 old your2' "$(echo "$out" | jq -r '.files | join(" ")')"
check "conflicts counted" 1 "$(echo "$out" | jq -r .conflicts)"
check "overlap text" 'M b Q' "$(echo "$out" | jq -r '[.blocks[] | select(.kind=="overlap") | .sides[] | .lines[0]] | join(" ")')"
check "unchanged blocks present" true "$(echo "$out" | jq '[.blocks[] | .kind] | index("unchanged") != null')"
ours --json -e mine old your >/dev/null 2>&1; check "--json -e refused" 2 $?
ours --json -m mine old your >/dev/null 2>&1; check "--json -m refused" 2 $?
check "--help lists --json" 1 "$(ours --help | grep -c -e '--json.*(not in GNU)')"
print_summary
[ "$FAIL" -eq 0 ]
