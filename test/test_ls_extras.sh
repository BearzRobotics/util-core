#!/bin/sh
# ls extras that GNU ls does not have or cannot be compared on (decision 0005):
#  - the "memory exhausted" diagnostic (GNU dies with the same status; ours also
#    says the listing is incomplete),
#  - capability colouring (`ca=`): the reference GNU ls on the development
#    machine is built without libcap, so this is checked against the
#    documented rule, not against GNU,
#  - the terminal colour is reset when a signal ends a coloured listing.
# Checks that need a facility the machine lacks are skipped (and counted).
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
export LC_ALL=C TZ=UTC
pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }
skp()  { skip=$((skip + 1)); echo "SKIP $1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1

# ---- out of memory: status 2 and a clear message, no crash --------------------
mkdir many
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "f%06d\n", i }' | (cd many && xargs touch)
( ulimit -v 6000 2>/dev/null || exit 77
  "$BIN/ls" many >out.txt 2>err.txt; echo $? >rc.txt )
if [ "$(cat rc.txt 2>/dev/null)" = 77 ] || [ ! -s rc.txt ]; then
    skp "memory exhausted (cannot limit address space)"
else
    if [ "$(cat rc.txt)" = 2 ]; then ok; else bad "memory exhausted: status $(cat rc.txt), want 2"; fi
    if grep -q '^ls: memory exhausted: the listing is incomplete$' err.txt; then ok; else bad "memory exhausted: message: $(head -c 200 err.txt)"; fi
    if [ "$(wc -l <out.txt)" -lt 40000 ]; then ok; else bad "memory exhausted: listing was not cut short"; fi
fi
# with enough memory the same directory lists completely
"$BIN/ls" many >out.txt 2>err.txt; rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l <out.txt)" = 40000 ] && [ ! -s err.txt ]; then ok; else bad "full listing"; fi

# ---- capability colouring -----------------------------------------------------
printf x >capf; printf x >plain
if command -v setcap >/dev/null 2>&1 && command -v unshare >/dev/null 2>&1 &&
   unshare -rm setcap cap_net_raw+ep capf 2>/dev/null; then
    out=$(LS_COLORS='ca=30;41:fi=0' unshare -rm "$BIN/ls" --color=always -1 capf plain | od -c | tr -s ' ' | tr -d '\n')
    case $out in *"033 [ 3 0 ; 4 1 m c a p f"*) ok ;; *) bad "ca= colours a file with capabilities: $out" ;; esac
    case $out in *"p l a i n"*"033 [ 3 0 ; 4 1 m"*) bad "ca= colours a file without capabilities" ;; *) ok ;; esac
    # without ca= in LS_COLORS the capability does not change the colour
    out=$(LS_COLORS='fi=0' unshare -rm "$BIN/ls" --color=always -1 capf | od -c | tr -s ' ' | tr -d '\n')
    case $out in *"3 0 ; 4 1 m"*) bad "capability colour without ca=" ;; *) ok ;; esac
    # long format too
    out=$(LS_COLORS='ca=30;41:fi=0' unshare -rm "$BIN/ls" --color=always -l capf | grep -c '30;41m')
    if [ "$out" = 1 ]; then ok; else bad "ca= with -l"; fi
else
    skp "capability colouring (setcap or unshare -rm unavailable)"
fi

# ---- a signal resets the colour ----------------------------------------------
mkdir bigc
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "file%06d.c\n", i }' | (cd bigc && xargs touch)
rm -f pid out
{ LS_COLORS='di=01;34:*.c=31' sh -c "echo \$\$ > pid; exec '$BIN/ls' --color=always -1 bigc" 2>/dev/null | { sleep 2; cat > out; }; } &
bgjob=$!
sleep 1
kill -TERM "$(cat pid)" 2>/dev/null
wait "$bgjob" 2>/dev/null
tail=$(tail -c 3 out | od -An -c | tr -d ' ')
if [ "$tail" = '033[m' ]; then ok; else bad "signal: output ends with '$tail', want the colour reset"; fi
if [ "$(wc -c <out)" -lt 440004 ]; then ok; else bad "signal: listing was not interrupted"; fi
# the colour is not reset when no colour was used
rm -f pid out
{ sh -c "echo \$\$ > pid; exec '$BIN/ls' -1 bigc" 2>/dev/null | { sleep 2; cat > out; }; } &
bgjob=$!
sleep 1
kill -TERM "$(cat pid)" 2>/dev/null
wait "$bgjob" 2>/dev/null
if ! grep -q "$(printf '\033')" out; then ok; else bad "signal: escape bytes without --color"; fi

echo "ls extras: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
