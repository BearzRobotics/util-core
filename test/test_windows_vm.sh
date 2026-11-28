#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the Windows (x86_64-windows) builds on a real Windows machine over SSH and
# compare standard output and exit status with the Linux build of the same
# command. Wine (test_windows_wine.sh) does not show everything real Windows
# does.
#
# Build both sets first:
#
#   zig build -Doptimize=ReleaseSafe -Dman=false --prefix zig-out-linux
#   zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dman=false --prefix zig-out-win
#
# Environment:
#   WIN_HOST   user@host of a Windows machine running OpenSSH (required; the
#              suite is skipped without it)
#   WIN_SSH    the ssh command (default "ssh"). Log in with a key, or have ssh
#              ask through SSH_ASKPASS; no password belongs in this repository.
#   LINUX_BIN  Linux binaries    (default <repo>/zig-out-linux/bin)
#   WIN_BIN    NAME.exe files    (default <repo>/zig-out-win/bin)
#   WIN_SHELL  the shell the cases run in: "cmd" (default), "powershell"
#              (Windows PowerShell 5.1) or the full path of a pwsh.exe
#   ONLY       an extended regular expression: run the cases whose name matches
#   KEEP       a directory that receives the raw outputs
#
# Everything on the Windows side happens below %TEMP%\ucvm-test, which is
# removed first and left behind for inspection. The programs go there too, so
# nothing has to be installed.
#
# In PowerShell the lines are typed as a user would type them there, with each
# program as NAME.exe (several names are PowerShell aliases): "&&" becomes a
# test of $LASTEXITCODE, which 5.1 needs, and "> nul" becomes "> $null". The
# Linux side runs with wildcards off, because util-core does not expand them for
# PowerShell. Standard error is only collected from cmd.exe: redirecting it
# changes how PowerShell treats a program. Some failures are PowerShell's own
# doing (see docs/portability.md).
#
# Exit status 0 when every comparison passed or the suite was skipped.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINUX_BIN=${LINUX_BIN:-$ROOT/zig-out-linux/bin}
WIN_BIN=${WIN_BIN:-$ROOT/zig-out-win/bin}
WIN_SSH=${WIN_SSH:-ssh}
WIN_SHELL=${WIN_SHELL:-cmd}
GLOB=+f
[ "$WIN_SHELL" = cmd ] || GLOB=-f

if [ -z "${WIN_HOST:-}" ]; then
    echo "SKIP: WIN_HOST is not set (see the header of this script)"
    exit 0
fi
if [ ! -f "$WIN_BIN/cat.exe" ] || [ ! -x "$LINUX_BIN/cat" ]; then
    echo "SKIP: no builds in $WIN_BIN and $LINUX_BIN (see the header of this script)"
    exit 0
fi

vm() {
    # shellcheck disable=SC2086
    timeout 900 $WIN_SSH -o LogLevel=ERROR "$WIN_HOST" "$@"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ucvm.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

. "$ROOT/test/windows_cases.sh"
. "$ROOT/test/windows_cases_all.sh"

# Keep the cases asked for. Windows PowerShell 5.1 never ends a pipeline whose
# first program writes for ever (it collects the output until memory runs
# out), so those cases stay out of the PowerShell runs.
SKIP='^$'
[ "$WIN_SHELL" = cmd ] || SKIP='^yes head$'
if [ -n "${ONLY:-}" ] || [ "$WIN_SHELL" != cmd ]; then
    sep=$(printf '\001')
    paste -d "$sep" "$TMP/names" "$TMP/tests" |
        awk -F "$sep" -v re="${ONLY:-.}" -v skip="$SKIP" '$1 ~ re && $1 !~ skip' > "$TMP/picked"
    cut -d "$sep" -f 1 "$TMP/picked" > "$TMP/names"
    cut -d "$sep" -f 2- "$TMP/picked" > "$TMP/tests"
    NTESTS=$(wc -l < "$TMP/tests")
fi

# ---- Linux side
mkfixture "$TMP/lin-fix"
LOUT="$TMP/linux.out"
: > "$LOUT"
i=0
while IFS= read -r line; do
    i=$((i + 1))
    rm -rf "$TMP/lw"
    cp -a "$TMP/lin-fix" "$TMP/lw"
    printf '===T %d\n' "$i" >> "$LOUT"
    # echo, printf and test are built into the shell, which PATH does not
    # override.
    (cd "$TMP/lw" && PATH="$LINUX_BIN:$PATH" LINUX_BIN="$LINUX_BIN" LC_ALL=C TZ=UTC0 timeout 20 sh "$GLOB" -c 'echo() { "$LINUX_BIN/echo" "$@"; }; printf() { "$LINUX_BIN/printf" "$@"; }; test() { "$LINUX_BIN/test" "$@"; }
'"$line" 2>/dev/null </dev/null; echo "status=$?") >> "$LOUT"
done < "$TMP/tests"

# ---- Windows side: one batch file for the real cmd.exe
# (The outer cmd.exe of the ssh server leaves a quote behind.)
RTEMP=$(vm 'cmd /c echo %TEMP%' | tr -d '\r"' | sed 's/ *$//')
[ -n "$RTEMP" ] || { echo "cannot reach $WIN_HOST" >&2; exit 1; }
RBASE="$RTEMP\\ucvm-test"
mkfixture "$TMP/send/win-fix"
mkdir "$TMP/send/bin" "$TMP/send/err"
cp "$WIN_BIN"/*.exe "$TMP/send/bin/"
# A PowerShell script for each case, so that one it cannot parse fails alone,
# and one that runs them all.
ps_cases() {
    mkdir "$TMP/send/case"
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        printf '%s\n' "$line" |
            sed -E -e 's/(^|\| |&& )([a-z0-9_]+)( |$)/\1\2.exe\3/g' -e 's/> nul( |$)/> $null\1/g' |
            awk '{
                n = split($0, part, / && /)
                out = part[1]
                close_braces = ""
                for (k = 2; k <= n; k++) {
                    out = out "; if ($LASTEXITCODE -eq 0) { " part[k]
                    close_braces = close_braces " }"
                }
                # A byte order mark: 5.1 reads UTF-8 only with one.
                printf "\357\273\277%s%s\r\n", out, close_braces
            }' > "$TMP/send/case/$i.ps1"
    done < "$TMP/tests"
    {
        printf '$base = $PSScriptRoot\r\n'
        printf '$env:Path = "$base\\bin;" + $env:Path\r\n'
        printf '$env:TZ = "UTC0"\r\n'
        printf 'for ($i = 1; $i -le %d; $i++) {\r\n' "$NTESTS"
        printf '  [Console]::Out.Write("===T $i`n"); [Console]::Out.Flush()\r\n'
        printf '  Set-Location $base\r\n'
        printf '  cmd /c "if exist w rd /s /q w"\r\n'
        printf '  cmd /c "xcopy /e /i /q /y /h /k win-fix w >nul"\r\n'
        printf '  Set-Location "$base\\w"\r\n'
        printf '  $global:LASTEXITCODE = $null\r\n'
        printf '  try { & "$base\\case\\$i.ps1" } catch { $global:LASTEXITCODE = "shell-error: $_" }\r\n'
        printf '  [Console]::Out.Write("status=$LASTEXITCODE`n"); [Console]::Out.Flush()\r\n'
        printf '}\r\n'
    } > "$TMP/send/run.ps1"
}

if [ "$WIN_SHELL" = cmd ]; then
    {
        printf '@echo off\r\n'
        printf 'set "B=%s\\bin"\r\n' "$RBASE"
        printf 'set "PATH=%%B%%;%%PATH%%"\r\n'
        printf 'set TZ=UTC0\r\n'
        printf 'chcp 65001 >nul\r\n'
        i=0
        while IFS= read -r line; do
            i=$((i + 1))
            # Every program by its full path: cmd.exe takes even "mkdir.exe" and
            # "date.exe" for its own commands.
            esc=$(printf '%s' "$line" | sed -e 's/%/%%/g' |
                sed -E 's/(^|\| |&& )([a-z0-9_]+)( |$)/\1%B%\\\2.exe\3/g')
            printf 'echo ===T %d\r\n' "$i"
            printf 'cd /d "%s"\r\n' "$RBASE"
            printf 'if exist w rd /s /q w\r\n'
            printf 'xcopy /e /i /q /y /h /k win-fix w >nul\r\n'
            printf 'cd /d "%s\\w" || exit /b 1\r\n' "$RBASE"
            printf '(%s) 2>"%s\\err\\%d.txt" <nul\r\n' "$esc" "$RBASE" "$i"
            printf 'echo status=%%errorlevel%%\r\n'
        done < "$TMP/tests"
    } > "$TMP/send/run.bat"
else
    ps_cases
fi

vm "cmd /c if exist \"$RBASE\" rd /s /q \"$RBASE\"" || exit 1
vm "cmd /c mkdir \"$RBASE\"" || exit 1
tar -C "$TMP/send" -cf - . | vm "tar -x -f - -C \"$RBASE\"" || exit 1
if [ "$WIN_SHELL" = cmd ]; then
    RUN="cmd /c \"$RBASE\\run.bat\""
else
    RUN="\"$WIN_SHELL\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$RBASE\\run.ps1\""
fi
vm "$RUN" < /dev/null | sed -E -e '/^===T/s/\r$//' -e 's/(status=-?[0-9]+)\r$/\1/' > "$TMP/windows.out"
mkdir "$TMP/err"
vm "tar -c -f - -C \"$RBASE\\err\" ." | tar -x -f - -C "$TMP/err"
if [ -n "${KEEP:-}" ]; then
    cp "$TMP/linux.out" "$TMP/windows.out" "$KEEP/"
    cp "$TMP"/send/run.* "$KEEP/"
    cp -r "$TMP/err" "$KEEP/"
fi

# ---- compare section by section
section() { awk -v want="===T $2" '$0 == want { on = 1; next } /^===T / { on = 0 } on' "$1"; }
PASS=0
FAIL=0
i=0
while [ "$i" -lt "$NTESTS" ]; do
    i=$((i + 1))
    name=$(sed -n "${i}p" "$TMP/names")
    section "$TMP/linux.out" "$i" > "$TMP/l"
    section "$TMP/windows.out" "$i" > "$TMP/w"
    if cmp -s "$TMP/l" "$TMP/w"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  case:    %s\n' "$name" "$(sed -n "${i}p" "$TMP/tests")"
        printf '  linux:   %s\n' "$(head -n 12 "$TMP/l" | tr '\n' '|' | head -c 300)"
        printf '  windows: %s\n' "$(head -n 12 "$TMP/w" | tr '\n' '|' | tr -d '\r' | head -c 300)"
        [ -s "$TMP/err/$i.txt" ] && printf '  stderr:  %s\n' "$(head -n 4 "$TMP/err/$i.txt" | tr -d '\r' | tr '\n' '|' | head -c 300)"
    fi
done
printf '\n%d passed, %d failed of %d (Windows build on real Windows, from %s)\n' "$PASS" "$FAIL" "$NTESTS" "$WIN_SHELL"
[ "$FAIL" -eq 0 ]
