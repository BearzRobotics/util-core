#!/bin/sh
# Run a representative set of the Windows (x86_64-windows) builds natively on a
# Windows machine reached over SSH, and compare their standard output and exit
# status with the Linux build of the same command.
#
# Build both sets first (standalone binaries):
#
#   CMDS=cat,wc,sort,ls,cp,rm,mkdir,date,find,grep,sed,printf,test,env,seq,md5sum,tr,cut,uniq,tee,head,tail,du,stat,basename,readlink
#   zig build -Doptimize=ReleaseSafe -Dcommands=$CMDS -Dmode=standalone -Dman=false --prefix zig-out-linux
#   zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dcommands=$CMDS -Dmode=standalone -Dman=false --prefix zig-out-win
#
# Environment (no credentials live in the repository):
#   WIN_VM_HOST   host name or address of the Windows machine   (default 192.168.122.202)
#   WIN_VM_USER   account on it                                  (default aimgr)
#   SSH_ASKPASS   executable that prints the account password; required
#                 (SSH_ASKPASS_REQUIRE=force and DISPLAY are set here)
#   LINUX_BIN     Linux binaries   (default <repo>/zig-out-linux/bin)
#   WIN_BIN       NAME.exe files   (default <repo>/zig-out-win/bin)
#
# Everything is copied to and run in %USERPROFILE%\utilcore on the machine; no
# setting of the machine is changed. All tests of one run go in a single batch
# file, so there is one copy and one ssh session. Standard error is not
# compared (program names and Windows error texts differ legitimately).
# Output is compared byte for byte; the only carriage returns removed are those
# cmd.exe adds to its own "echo" marker lines.
#
# Exit status 0 when every comparison passed or when the test was skipped.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINUX_BIN=${LINUX_BIN:-$ROOT/zig-out-linux/bin}
WIN_BIN=${WIN_BIN:-$ROOT/zig-out-win/bin}
HOST=${WIN_VM_HOST:-192.168.122.202}
USER_=${WIN_VM_USER:-aimgr}

if [ -z "$SSH_ASKPASS" ] || [ ! -x "$SSH_ASKPASS" ]; then
    echo "SKIP: SSH_ASKPASS is not set to an executable password helper"
    exit 0
fi
if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    echo "SKIP: ssh/scp not installed"
    exit 0
fi
if [ ! -f "$WIN_BIN/cat.exe" ]; then
    echo "SKIP: no Windows build in $WIN_BIN (see the header of this script)"
    exit 0
fi
if [ ! -x "$LINUX_BIN/cat" ]; then
    echo "SKIP: no Linux build in $LINUX_BIN to compare against (see the header of this script)"
    exit 0
fi

export SSH_ASKPASS SSH_ASKPASS_REQUIRE=force
export DISPLAY=${DISPLAY:-:0}
SSHOPTS="-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=15"
vm() { ssh $SSHOPTS "$USER_@$HOST" "$@"; }

if [ "$(vm 'echo reachable' 2>/dev/null | tr -d '\r')" != "reachable" ]; then
    echo "SKIP: cannot reach $USER_@$HOST over ssh"
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ucvm.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

mkfixture() {
    rm -rf "$1"
    mkdir -p "$1/dir/sub"
    printf 'banana\napple\ncherry\napple\n10\n9\n' > "$1/a.txt"
    printf 'one two three\nfour five\n\nsix\n' > "$1/b.txt"
    printf 'x,y,z\n1,2,3\n4,5,6\n' > "$1/c.csv"
    printf 'nested\n' > "$1/dir/sub/n.txt"
    printf 'top\n' > "$1/dir/t.txt"
}

# Test lines run unchanged by sh on Linux and by cmd.exe on Windows, so they use
# only double quotes, && chaining and |.
: > "$TMP/tests"
: > "$TMP/names"
NTESTS=0
t() {
    NTESTS=$((NTESTS + 1))
    printf '%s\n' "$1" >> "$TMP/names"
    printf '%s\n' "$2" >> "$TMP/tests"
}

t "cat file" 'cat a.txt'
t "cat -n two files" 'cat -n a.txt b.txt'
t "cat -A" 'cat -A b.txt'
t "cat missing" 'cat nosuchfile'
t "wc" 'wc a.txt'
t "wc -l -w -c" 'wc -l -w -c b.txt'
t "wc -L" 'wc -L b.txt'
t "sort" 'sort a.txt'
t "sort -n" 'sort -n a.txt'
t "sort -ru" 'sort -ru a.txt'
t "sort -t, -k2n" 'sort -t, -k2n c.csv'
t "ls -1" 'ls -1'
t "ls -1a dir" 'ls -1a dir'
t "ls -R" 'ls -R dir'
t "ls -1S" 'ls -1S'
t "ls missing" 'ls nosuchfile'
t "cp file" 'cp a.txt copy.txt && cat copy.txt'
t "cp -r tree" 'cp -r dir dir2 && find dir2 -type f | sort'
t "cp into dir" 'cp a.txt dir && ls -1 dir'
t "cp missing" 'cp nosuchfile x'
t "rm file" 'rm a.txt && ls -1'
t "rm -r dir" 'rm -r dir && ls -1'
t "rm -f missing" 'rm -f nosuchfile'
t "rm missing" 'rm nosuchfile'
t "mkdir -p" 'mkdir -p x/y/z && find x | sort'
t "mkdir" 'mkdir newdir && ls -1'
t "mkdir existing" 'mkdir dir'
t "date @0" 'date -u -d @0 "+%Y-%m-%dT%H:%M:%S %A %j"'
t "date text" 'date -u -d "2024-02-29 12:34:56" "+%s %a %b %e %U"'
t "date iso" 'date -u -d @86400 --iso-8601=seconds'
t "find -name" 'find . -name "*.txt" -print | sort'
t "find -type d" 'find . -type d | sort'
t "find -maxdepth" 'find . -maxdepth 1 -type f -print | sort'
t "find -size" 'find . -type f -size -2c'
t "grep" 'grep apple a.txt'
t "grep -c" 'grep -c a a.txt'
t "grep -n -i" 'grep -n -i APPLE a.txt'
t "grep -r" 'grep -r nested .'
t "grep -E" 'grep -E "^(a|b)" a.txt'
t "grep no match" 'grep zzz a.txt'
t "sed s///" 'sed "s/apple/APPLE/" a.txt'
t "sed -n p" 'sed -n "2,3p" a.txt'
t "sed -E" 'sed -E "s/([a-z]+) ([a-z]+)/\2 \1/" b.txt'
t "sed -i" 'sed -i "s/a/A/g" a.txt && cat a.txt'
t "sed d" 'sed "/apple/d" a.txt'
t "printf" 'printf "%s %d %5.2f|%-5s|%x\n" hello 42 3.14159 ab 255'
t "printf escapes" 'printf "a\tb\101\n"'
t "test -f" 'test -f a.txt'
t "test -d" 'test -d dir'
t "test -e missing" 'test -e nosuch'
t "test -s" 'test -s a.txt'
t "test strings" 'test abc = abc -a 3 -lt 5'
t "test -w" 'test -w a.txt'
t "env -i" 'env -i FOO=bar BAZ=qux'
t "env -i two" 'env -i FOO=1 BAR=2'
t "seq" 'seq 5'
t "seq range" 'seq 2 3 14'
t "seq -s" 'seq -s, 1 5'
t "seq -w float" 'seq -w 0.5 0.5 3'
t "md5sum" 'md5sum a.txt b.txt'
t "md5sum -c" 'md5sum a.txt > sums.txt && md5sum -c sums.txt'
t "tr" 'cat a.txt | tr a-z A-Z'
t "tr -d" 'cat a.txt | tr -d a'
t "cut -d -f" 'cut -d, -f1,3 c.csv'
t "cut -c" 'cut -c1-3 a.txt'
t "uniq" 'uniq a.txt'
t "uniq -c" 'sort a.txt | uniq -c'
t "uniq -d" 'sort a.txt | uniq -d'
t "tee" 'cat a.txt | tee out.txt && cat out.txt'
t "tee -a" 'cat a.txt | tee -a b.txt > nul && cat b.txt'
t "head -n" 'head -n 2 a.txt'
t "head -c" 'head -c 7 a.txt'
t "tail -n" 'tail -n 2 a.txt'
t "tail -c" 'tail -c 5 a.txt'
t "du -b files" 'du -b a.txt b.txt'
t "stat -c" 'stat -c "%s %F %n" a.txt'
t "stat dir" 'stat -c "%F" dir'
t "basename" 'basename dir/sub/n.txt .txt'
t "readlink non-link" 'readlink a.txt'

# ---- Linux side
mkfixture "$TMP/lin-fix"
LOUT="$TMP/linux.out"
: > "$LOUT"
i=0
while IFS= read -r line; do
    i=$((i + 1))
    rm -rf "$TMP/lw"
    cp -r "$TMP/lin-fix" "$TMP/lw"
    printf '===T %d\n' "$i" >> "$LOUT"
    (cd "$TMP/lw" && PATH="$LINUX_BIN:$PATH" sh -c "$line" 2>/dev/null </dev/null; echo "status=$?") >> "$LOUT"
done < "$TMP/tests"

# ---- Windows side: one batch file
BAT="$TMP/run.bat"
{
    printf '@echo off\r\n'
    printf 'set PATH=%%USERPROFILE%%\\utilcore\\bin;%%PATH%%\r\n'
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        esc=$(printf '%s' "$line" | sed 's/%/%%/g')
        printf 'echo ===T %d\r\n' "$i"
        printf 'rd /s /q %%USERPROFILE%%\\utilcore\\w 2>nul\r\n'
        printf 'xcopy /e /i /q /y %%USERPROFILE%%\\utilcore\\fix %%USERPROFILE%%\\utilcore\\w >nul\r\n'
        printf 'cd /d %%USERPROFILE%%\\utilcore\\w\r\n'
        printf '%s 2>nul <nul\r\n' "$esc"
        printf 'echo status=%%errorlevel%%\r\n'
    done < "$TMP/tests"
} > "$BAT"

vm 'mkdir utilcore\bin' >/dev/null 2>&1
vm 'rd /s /q utilcore\fix' >/dev/null 2>&1
if ! scp $SSHOPTS -q "$WIN_BIN"/*.exe "$USER_@$HOST:utilcore/bin/" ||
    ! scp $SSHOPTS -q -r "$TMP/lin-fix" "$USER_@$HOST:utilcore/fix" ||
    ! scp $SSHOPTS -q "$BAT" "$USER_@$HOST:utilcore/run.bat"; then
    echo "SKIP: copying to $USER_@$HOST failed"
    exit 0
fi
vm 'utilcore\run.bat' 2>/dev/null | sed -E '/^(===T|status=)/s/\r$//' > "$TMP/windows.out"

# ---- compare section by section
PASS=0
FAIL=0
i=0
while [ "$i" -lt "$NTESTS" ]; do
    i=$((i + 1))
    name=$(sed -n "${i}p" "$TMP/names")
    awk -v n="$i" '$0=="===T " n {f=1; next} /^===T / {f=0} f' "$LOUT" > "$TMP/l.sec"
    awk -v n="$i" '$0=="===T " n {f=1; next} /^===T / {f=0} f' "$TMP/windows.out" > "$TMP/w.sec"
    if cmp -s "$TMP/l.sec" "$TMP/w.sec"; then
        PASS=$((PASS + 1))
        printf 'PASS %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n' "$name"
        printf '  linux:   %s\n' "$(head -c 300 "$TMP/l.sec" | tr '\n' '|')"
        printf '  windows: %s\n' "$(head -c 300 "$TMP/w.sec" | tr '\n' '|' | tr '\r' '~')"
    fi
done
printf '\n%d passed, %d failed (native Windows via %s)\n' "$PASS" "$FAIL" "$HOST"
[ "$FAIL" -eq 0 ]
