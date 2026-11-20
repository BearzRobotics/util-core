#!/bin/sh
# ls --json (also dir and vdir): GNU ls has no --json, so
#  - the entries and their ORDER are compared with `ls -1 --quoting-style=literal`
#    for the same options (GNU coreutils 9.7, C locale), including -R and
#    several operands, and
#  - every metadata field is compared with what GNU stat prints for the path.
# Needs python3 and GNU ls/stat.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
export LC_ALL=C TZ=UTC
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1

mkdir -p top/sub/deeper top/.hid top/emptydir "top/we ird" other
head -c 100000 /dev/zero > top/big; printf hello > top/file.txt; printf a > top/a.c; printf b > top/b.h; : > top/empty
printf x > top/.dot; printf x > "top/q'uote"; printf x > top/backup~; printf x > top/sub/inner.txt; printf x > top/sub/deeper/leaf
ln -s file.txt top/lnk; ln -s nowhere top/dangling; ln -s sub top/dlnk; ln top/a.c top/hard; mkfifo top/fifo
printf x > other/o1; printf yy > other/o2
touch -d @1000000000 top/big; touch -d @1100000000 top/file.txt; touch -d @1200000000 top/a.c; touch -d @1300000000 top/b.h
touch -d @1400000000 top/empty; touch -h -d @1500000000 top/lnk
chmod 4755 top/big; chmod 600 "top/q'uote"; chmod 1777 top/emptydir

# names in order: JSON vs GNU, flattened to "dir<TAB>name" lines
flat_gnu() { # ls options..., operands...
    ls -1 --quoting-style=literal "$@" | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
if lines and lines[-1] == "": lines.pop()
cur = None; out = []
multi = any(l.endswith(":") and i == 0 for i, l in enumerate(lines)) or "-R" in sys.argv[1:]
for l in lines:
    if l == "": continue
    if multi and l.endswith(":") : cur = l[:-1]; continue
    out.append("%s\t%s" % (cur if cur is not None else "-", l))
print("\n".join(out))' "$@"
}
flat_ours() {
    "$BIN/ls" --json "$@" | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    print("%s\t%s" % (e["dir"] if e["dir"] is not None else "-", e["name"]))'
}
cmp_order() { # name, then ls options/operands
    name=$1; shift
    g=$(flat_gnu "$@" 2>/dev/null)
    o=$(flat_ours "$@" 2>/dev/null)
    [ -n "$g" ] && [ "$g" = "$o" ] && ok || { bad "order: $name"; echo "--- GNU"; echo "$g" | head -5; echo "--- OURS"; echo "$o" | head -5; }
}
# Directory operands are listed under a header in GNU only when there are
# several operands or -R, so compare single-directory listings without dirs.
strip() { sed 's/^[^	]*	//'; }
cmp_names() {
    name=$1; shift
    g=$(ls -1 --quoting-style=literal "$@" 2>/dev/null)
    o=$("$BIN/ls" --json "$@" 2>/dev/null | python3 -c '
import json, sys
for e in json.load(sys.stdin): print(e["name"])')
    [ -n "$g" ] && [ "$g" = "$o" ] && ok || { bad "names: $name"; echo "--- GNU"; echo "$g" | head -5; echo "--- OURS"; echo "$o" | head -5; }
}
# Layout, quoting, colour and indicator options change GNU's text but must not
# change the JSON at all.
cmp_same() {
    name=$1; shift
    a=$("$BIN/ls" --json top 2>/dev/null | md5sum); b=$("$BIN/ls" --json "$@" 2>/dev/null | md5sum)
    [ "$a" = "$b" ] && ok || bad "same output: $name"
}
cmp_names "default"            top
cmp_names "-a"                 -a top
cmp_names "-A"                 -A top
cmp_names "-r"                 -r top
cmp_names "-S"                 -S top
cmp_names "-t"                 -t top
cmp_names "-tr"                -t -r top
cmp_names "-U"                 -U top
cmp_names "-X"                 -X top
cmp_names "-v"                 -v top
cmp_names "-S -r"              -S -r top
cmp_names "-t -u"              -t -u top
cmp_names "-t -c"              -t -c top
cmp_names "--group-dirs-first" --group-directories-first top
cmp_names "-B"                 -B top
cmp_names "-I"                 -I '*.c' top
cmp_names "--hide"             --hide='*.h' top
cmp_names "-d dir"             -d top
cmp_names "-d many"            -d top/sub top/emptydir top/big
cmp_names "files and links (-d)"  -d top/big top/lnk top/dlnk   # --json lists a symlink to a directory itself, like ls -l
cmp_names "-L"                 -L top
cmp_names "-H on link to dir"  -H top/dlnk
cmp_same "-l ignored"            -l top
cmp_same "-1 ignored"            -1 top
cmp_same "-C ignored"            -C top
cmp_same "-F ignored"            -F top
cmp_same "-Q ignored"            -Q top
cmp_same "--color ignored"            --color=always top
cmp_order "several dirs"       top other
cmp_order "-R"                 -R top
cmp_order "-Ra"                -R -a top
cmp_order "-RS"                -R -S top
cmp_order "-R operand+dirs"    -R top/sub top/big

# Metadata: every field against GNU stat for the listed path.
python3 - "$BIN" <<'PY' || bad "metadata"
import json, os, subprocess, sys
bin_ = sys.argv[1]
out = subprocess.run([bin_ + "/ls", "--json", "-a", "top"], capture_output=True, text=True).stdout
entries = json.loads(out)
assert len(entries) >= 15, len(entries)
keys = [("size","%s"),("blocks","%b"),("block_size","%o"),("nlink","%h"),("inode","%i"),("uid","%u"),("gid","%g"),
        ("user","%U"),("group","%G"),("mode_string","%A"),("mode_octal","%04a"),("type_desc","%F"),
        ("dev","%d"),("atime","%X"),("mtime","%Y"),("ctime","%Z")]
bad = 0
for e in entries:
    path = "top/" + e["name"]
    for k, f in keys:
        want = subprocess.run(["stat", "-c", f, "--", path], capture_output=True, text=True).stdout.strip()
        if str(e[k]) != want:
            print("FAIL %s %s: GNU=[%s] OURS=[%s]" % (path, k, want, e[k])); bad += 1
    if e["type"] == "symlink":
        assert e["link_target"] == os.readlink(path), (path, e["link_target"])
    else:
        assert e["link_target"] is None, path
    assert e["dir"] == "top", e["dir"]
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] && ok

# dir and vdir are the same listing
t "dir --json equals ls --json" sh -c "[ \"\$('$BIN/dir' --json top | md5sum)\" = \"\$('$BIN/ls' --json top | md5sum)\" ]"
t "vdir --json equals ls --json" sh -c "[ \"\$('$BIN/vdir' --json top | md5sum)\" = \"\$('$BIN/ls' --json top | md5sum)\" ]"
t "symlink is not followed by default" sh -c "'$BIN/ls' --json top | python3 -c 'import json,sys;d={e[\"name\"]:e for e in json.load(sys.stdin)};assert d[\"lnk\"][\"type\"]==\"symlink\" and d[\"dlnk\"][\"type\"]==\"symlink\" and d[\"lnk\"][\"link_target\"]==\"file.txt\"'"
t "-L follows" sh -c "'$BIN/ls' --json -L top | python3 -c 'import json,sys;d={e[\"name\"]:e for e in json.load(sys.stdin)};assert d[\"dlnk\"][\"type\"]==\"directory\" and d[\"lnk\"][\"type\"]==\"file\"'"
t "operand dir is null for files" sh -c "'$BIN/ls' --json top/big | python3 -c 'import json,sys;e=json.load(sys.stdin);assert len(e)==1 and e[0][\"dir\"] is None'"
t "empty directory is []" sh -c "[ \"\$('$BIN/ls' --json top/emptydir)\" = '[]' ]"
t "missing operand: status 2, others listed" sh -c "out=\$('$BIN/ls' --json nofile top/big 2>/dev/null); rc=\$?; [ \$rc = 2 ] && echo \"\$out\" | python3 -c 'import json,sys;assert len(json.load(sys.stdin))==1'"
t "valid JSON for a name with a quote and space" sh -c "'$BIN/ls' --json top | python3 -c 'import json,sys;n=[e[\"name\"] for e in json.load(sys.stdin)];assert \"q\x27uote\" in n and \"we ird\" in n'"
t "--json is listed in --help as a non-GNU line" sh -c "'$BIN/ls' --help | grep -q -e '--json .*not in GNU' -e '-json .*JSON'"
t "no --json: text output unchanged (no brackets)" sh -c "! '$BIN/ls' top | grep -q '^\\['"

echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
