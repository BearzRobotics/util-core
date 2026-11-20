#!/bin/sh
# difflib.sh - helpers shared by the diffutils suites (cmp, diff, diff3, sdiff).
# Source after testlib.sh.

# help_cmp_diffutils: ours --help must equal GNU's --help minus the trailing
# "Report bugs to:" block, which names the GNU project; our lines that end
# with "(not in GNU)" (the --json option) are dropped first.
help_cmp_diffutils() {
    exp=$(PATH="${GNU_BIN:-/usr/bin}:/usr/bin" LC_ALL=C "$UTIL" --help | awk '/^Report bugs to:/ { exit } { lines[n++] = $0 } END { while (n > 0 && lines[n-1] == "") n--; for (i = 0; i < n; i++) print lines[i] }')
    act=$(ours --help | grep -v -e '^ *--json ' -e '(not in GNU)$')
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); printf "PASS --help text\n"
    else FAIL=$((FAIL + 1)); printf "FAIL --help text\n"; fi
}

# jq may be absent; JSON checks use it when present.
have_jq() { command -v jq >/dev/null 2>&1; }

# check DESC EXPECTED ACTUAL: plain string comparison helper.
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf "PASS %s\n" "$1"
    else FAIL=$((FAIL + 1)); printf "FAIL %s\n     want: %s\n     got : %s\n" "$1" "$2" "$3"; fi
}
