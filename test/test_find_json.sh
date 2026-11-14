#!/bin/sh
# find -json (an extension action, like -print but one JSON object per file):
#  - the files matched, and their order, are compared with GNU find -print for
#    the same expression (GNU findutils 4.10), and
#  - size, mode, owner, group, type, link count, inode and target are compared
#    with GNU find -printf for every file.
# Needs python3 and GNU find.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
export LC_ALL=C TZ=UTC
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
mkdir -p top/sub/deeper top/.hid top/emptydir "top/we ird" other
head -c 100000 /dev/zero > top/big; printf hello > top/file.txt; printf a > top/a.c; printf b > top/b.h; : > top/empty
printf x > top/.dot; printf x > "top/q'uote"; printf x > top/sub/inner.txt; printf x > top/sub/deeper/leaf.c
ln -s file.txt top/lnk; ln -s nowhere top/dangling; ln -s sub top/dlnk; ln top/a.c top/hard; mkfifo top/fifo
printf x > other/o1; touch -d @1000000000 top/big; touch -d @1300000000 top/b.h
chmod 4755 top/big; chmod 600 "top/q'uote"; chmod 1777 top/emptydir

# JSON entries reassembled to the path GNU find prints.
paths_ours() {
    "$BIN/find" "$@" -json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    e = json.loads(line)
    d, n = e["dir"], e["name"]
    print(n if d is None else (d + n if d.endswith("/") else d + "/" + n))'
}
cmp_paths() { # name, find args (before the action)
    name=$1; shift
    g=$(find "$@" -print 2>/dev/null)
    o=$(paths_ours "$@")
    [ -n "$g" ] && [ "$g" = "$o" ] && ok || { bad "paths: $name"; echo "--- GNU"; echo "$g" | head -4; echo "--- OURS"; echo "$o" | head -4; }
}
cmp_paths "tree"                top
cmp_paths "two roots"           top other
cmp_paths "-type f"             top -type f
cmp_paths "-type d"             top -type d
cmp_paths "-type l"             top -type l
cmp_paths "-name"               top -name '*.c'
cmp_paths "-iname"              top -iname 'FILE*'
cmp_paths "-maxdepth 1"         top -maxdepth 1
cmp_paths "-mindepth 2"         top -mindepth 2
cmp_paths "-depth"              top -depth
cmp_paths "-prune"              top \( -name sub -prune \) -o -true
cmp_paths "-size"               top -type f -size +1k
cmp_paths "-newer"              top -newer top/file.txt
cmp_paths "-perm"               top -perm -4000
cmp_paths "-empty"              top -empty
cmp_paths "-L"                  -L top
cmp_paths "-H"                  -H top/dlnk
cmp_paths "-P"                  -P top/dlnk
cmp_paths "-xtype"              top -xtype l
cmp_paths "-not"                top -not -name '*.c'
cmp_paths "-o"                  top -name '*.c' -o -name '*.h'
cmp_paths "file operand"        top/big
cmp_paths "-path"               top -path '*/sub/*'
cmp_paths "-links"              top -links +1 -type f
cmp_paths "dot"                 .

# Metadata for every file, against find -printf.
python3 - "$BIN" <<'PY' || bad "metadata"
import json, subprocess, sys
bin_ = sys.argv[1]
for opts in ([], ["-L"]):
    ours = [json.loads(l) for l in subprocess.run([bin_ + "/find"] + opts + ["top", "-json"], capture_output=True, text=True).stdout.splitlines()]
    fmt = "%p\t%s\t%m\t%u\t%g\t%y\t%n\t%i\t%l\t%U\t%G\t%T@\n"
    gnu = [l.split("\t") for l in subprocess.run(["find"] + opts + ["top", "-printf", fmt], capture_output=True, text=True).stdout.split("\n") if l]
    assert len(ours) == len(gnu) >= 15, (len(ours), len(gnu))
    tmap = {"f": "file", "d": "directory", "l": "symlink", "p": "fifo", "s": "socket", "c": "char_device", "b": "block_device"}
    bad = 0
    for e, g in zip(ours, gnu):
        path, size, mode, user, group, typ, nlink, ino, link, uid, gid, mt = g
        d, n = e["dir"], e["name"]
        mine = n if d is None else d + "/" + n
        def chk(k, a, b):
            global bad
            if str(a) != str(b):
                print("FAIL %s %s %s: GNU=[%s] OURS=[%s]" % (opts, path, k, b, a)); bad += 1
        chk("path", mine, path)
        chk("size", e["size"], size)
        chk("mode_octal", e["mode_octal"].lstrip("0") or "0", mode)
        chk("type", e["type"], tmap.get(typ, typ))
        chk("nlink", e["nlink"], nlink)
        chk("inode", e["inode"], ino)
        chk("uid", e["uid"], uid)
        chk("gid", e["gid"], gid)
        if e["type"] == "symlink":
            chk("link_target", e["link_target"], link)
        else:
            chk("link_target", e["link_target"], "None")
        chk("mtime", e["mtime"], int(float(mt)))
    if bad: sys.exit(1)
PY
[ $? = 0 ] && ok

t "-json is an action: no implicit -print" sh -c "[ \"\$('$BIN/find' top -name file.txt -json | wc -l)\" = 1 ]"
t "-json with -print prints both" sh -c "[ \"\$('$BIN/find' top -name file.txt -print -json | wc -l)\" = 2 ]"
t "-json valid for odd names" sh -c "'$BIN/find' top -json | python3 -c 'import json,sys;n=[json.loads(l)[\"name\"] for l in sys.stdin];assert \"q\x27uote\" in n and \"we ird\" in n'"
t "one object per line" sh -c "[ \"\$('$BIN/find' top -json | wc -l)\" = \"\$(find top | wc -l)\" ]"
t "root path has a null dir" sh -c "'$BIN/find' top -maxdepth 0 -json | python3 -c 'import json,sys;e=json.loads(sys.stdin.readline());assert e[\"dir\"] is None and e[\"name\"]==\"top\"'"
t "dangling link is listed with its target" sh -c "'$BIN/find' top -name dangling -json | python3 -c 'import json,sys;e=json.loads(sys.stdin.readline());assert e[\"type\"]==\"symlink\" and e[\"link_target\"]==\"nowhere\"'"
t "-L follows links (dlnk is a directory)" sh -c "'$BIN/find' -L top -name dlnk -json | python3 -c 'import json,sys;assert json.loads(sys.stdin.readline())[\"type\"]==\"directory\"'"
t "missing root: status 1, others listed" sh -c "out=\$('$BIN/find' nofile top/b.h -json 2>/dev/null); rc=\$?; [ \$rc = 1 ] && [ \$(echo \"\$out\" | wc -l) = 1 ]"
t "-prune with -json" sh -c "[ \"\$('$BIN/find' top -name sub -prune -o -json | wc -l)\" = \"\$(find top -name sub -prune -o -print | wc -l)\" ]"
t "-json is not in --help" sh -c "! '$BIN/find' --help | grep -q json"
t "text output is unchanged" sh -c "[ \"\$('$BIN/find' top -type f | sort)\" = \"\$(find top -type f | sort)\" ]"
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
