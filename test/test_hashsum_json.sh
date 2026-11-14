#!/bin/sh
# md5sum/sha*sum/b2sum/cksum --json: digests and numbers are compared with
# what GNU's own tools print for the same input (GNU coreutils 9.7).
# Needs python3 and the GNU tools.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
printf 'hello\n' > a; : > empty; head -c 300000 /dev/urandom > rnd; printf 'x' > 'we"ird name'

for tool in md5sum sha1sum sha224sum sha256sum sha384sum sha512sum b2sum; do
    for f in a empty rnd "we\"ird name"; do
        want=$($tool "$f" | awk '{print $1}')
        got=$("$BIN/$tool" --json "$f" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['digest']); assert d['file']==sys.argv[1]" "$f")
        [ -n "$want" ] && [ "$want" = "$got" ] && ok || bad "$tool $f: GNU=[$want] OURS=[$got]"
    done
done
for f in a empty rnd; do
    want=$(cksum "$f" | awk '{print $1, $2}')
    got=$("$BIN/cksum" --json "$f" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['checksum'], d['size']); assert d['algorithm']=='crc'")
    [ "$want" = "$got" ] && ok || bad "cksum $f: GNU=[$want] OURS=[$got]"
    for alg in crc32b bsd sysv; do
        want=$(cksum -a $alg "$f" | awk '{print $1 + 0}')   # bsd is zero-padded in text; JSON has the number
        got=$("$BIN/cksum" --json -a $alg "$f" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['checksum']); assert d['algorithm']=='$alg'")
        [ "$want" = "$got" ] && ok || bad "cksum -a $alg $f: GNU=[$want] OURS=[$got]"
    done
    for alg in bsd sysv; do
        want=$(cksum -a $alg "$f" | awk '{print $2}')
        got=$("$BIN/cksum" --json -a $alg "$f" | python3 -c "import json,sys; print(json.load(sys.stdin)['blocks'])")
        [ "$want" = "$got" ] && ok || bad "cksum -a $alg $f blocks: GNU=[$want] OURS=[$got]"
    done
done
for alg in md5 sha1 sha224 sha256 sha384 sha512 blake2b sm3; do
    want=$(cksum -a $alg --untagged a | awk '{print $1}')
    got=$("$BIN/cksum" --json -a $alg a | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['digest']); assert d['algorithm']=='$alg'")
    [ "$want" = "$got" ] && ok || bad "cksum -a $alg: GNU=[$want] OURS=[$got]"
done
want=$(b2sum -l 256 a | awk '{print $1}')
got=$("$BIN/b2sum" --json -l 256 a | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
[ "$want" = "$got" ] && ok || bad "b2sum -l 256"

t "stdin without operand: file is null" sh -c "'$BIN/sha256sum' --json < a | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"file\"] is None'"
t "several files: one object per line" sh -c "[ \"\$('$BIN/md5sum' --json a empty rnd | wc -l)\" = 3 ]"
t "missing file: others still printed, status 1" sh -c "out=\$('$BIN/md5sum' --json nofile a 2>/dev/null); rc=\$?; [ \$rc = 1 ] && [ \$(echo \"\$out\" | wc -l) = 1 ]"
t "digest is lowercase hex of the right length" sh -c "'$BIN/sha256sum' --json a | python3 -c 'import json,sys,re;assert re.fullmatch(\"[0-9a-f]{64}\", json.load(sys.stdin)[\"digest\"])'"
for o in -c --check --raw --base64 --tag -z --zero; do
    t "--json with $o is refused" sh -c "! '$BIN/sha256sum' --json $o a 2>/dev/null"
done
t "--json --untagged refused for cksum" sh -c "! '$BIN/cksum' --json --untagged a"
t "--json is not in --help" sh -c "! '$BIN/md5sum' --help | grep -q json"
t "text output is unchanged" sh -c "[ \"\$('$BIN/sha256sum' a rnd)\" = \"\$(sha256sum a rnd)\" ]"
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
