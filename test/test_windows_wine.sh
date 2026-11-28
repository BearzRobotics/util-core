#!/bin/sh
# Run a representative set of the Windows (x86_64-windows) builds under wine
# and compare their standard output and exit status with the Linux build of
# the same command. Wine is a quick check, not proof of behaviour on Windows
# (see docs/portability.md).
#
# Build both sets first (standalone binaries):
#
#   CMDS=cat,wc,sort,ls,cp,rm,mkdir,date,find,grep,sed,printf,test,env,seq,md5sum,tr,cut,uniq,tee,head,tail,du,stat,basename,readlink
#   zig build -Doptimize=ReleaseSafe -Dcommands=$CMDS -Dmode=standalone -Dman=false --prefix zig-out-linux
#   zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dcommands=$CMDS -Dmode=standalone -Dman=false --prefix zig-out-win
#
# Environment:
#   LINUX_BIN  Linux binaries   (default <repo>/zig-out-linux/bin)
#   WIN_BIN    NAME.exe files   (default <repo>/zig-out-win/bin)
#   WINE       wine launcher    (default wine64, then wine)
#
# All tests of one run go in one batch file run by wine's cmd.exe, in a
# private wine prefix and a temporary directory. Standard error is not
# compared. Output is compared byte for byte; the only carriage returns
# removed are those cmd.exe adds to its own "echo" marker lines.
#
# Exit status 0 when every comparison passed or when the test was skipped
# (no wine, or no build).

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINUX_BIN=${LINUX_BIN:-$ROOT/zig-out-linux/bin}
WIN_BIN=${WIN_BIN:-$ROOT/zig-out-win/bin}

WINE=${WINE:-}
if [ -z "$WINE" ]; then
    if command -v wine64 >/dev/null 2>&1; then WINE=wine64
    elif command -v wine >/dev/null 2>&1; then WINE=wine
    fi
fi
if [ -z "$WINE" ] || ! command -v "$WINE" >/dev/null 2>&1; then
    echo "SKIP: wine is not installed"
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

export WINEDEBUG=-all
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ucwine.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export WINEPREFIX=${WINEPREFIX:-$TMP/prefix}

. "$ROOT/test/windows_cases.sh"

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
    # printf and test are built into the shell, which PATH does not override:
    # name the Linux builds of those, which are what Windows is compared with.
    (cd "$TMP/lw" && PATH="$LINUX_BIN:$PATH" LINUX_BIN="$LINUX_BIN" sh -c 'printf() { "$LINUX_BIN/printf" "$@"; }; test() { "$LINUX_BIN/test" "$@"; }
'"$line" 2>/dev/null </dev/null; echo "status=$?") >> "$LOUT"
done < "$TMP/tests"

# ---- Windows side (wine): one batch file
WBIN=$("$WINE" winepath -w "$WIN_BIN" 2>/dev/null | tr -d '\r')
mkfixture "$TMP/win-fix"
WFIX=$("$WINE" winepath -w "$TMP/win-fix" | tr -d '\r')
WWORK=$("$WINE" winepath -w "$TMP" | tr -d '\r')'\w'
BAT="$TMP/run.bat"
{
    printf '@echo off\r\n'
    printf 'set PATH=%s;%%PATH%%\r\n' "$WBIN"
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        # cmd.exe has internal date and mkdir (and would run its own sort/find
        # first on a real Windows PATH): name the programs explicitly.
        esc=$(printf '%s' "$line" | sed -e 's/%/%%/g' -E -e 's/(^|\| |&& )([a-z0-9]+) /\1\2.exe /g')
        printf 'echo ===T %d\r\n' "$i"
        printf 'rd /s /q %s 2>nul\r\n' "$WWORK"
        printf 'xcopy /e /i /q /y %s %s >nul\r\n' "$WFIX" "$WWORK"
        printf 'cd /d %s\r\n' "$WWORK"
        printf '%s\r\n' "$esc"
        printf 'echo status=%%errorlevel%%\r\n'
    done < "$TMP/tests"
} > "$BAT"
"$WINE" cmd /c "$("$WINE" winepath -w "$BAT" | tr -d '\r')" 2>/dev/null </dev/null | sed -E '/^(===T|status=)/s/\r$//' > "$TMP/windows.out"

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
printf '\n%d passed, %d failed (Windows build under wine)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
