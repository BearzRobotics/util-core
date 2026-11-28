# SPDX-License-Identifier: GPL-2.0-or-later
# windows/init.ps1, run on Windows in either PowerShell:
#
#     pwsh -File windows_init_test.ps1 -Portable DIR
#
# DIR holds init.ps1 and a bin folder with the Windows build. Each line is
# rewritten as the prompt's hook would rewrite it, then run. This does not type
# at a prompt, so the hook itself is not covered.
param([Parameter(Mandatory)][string]$Portable)

. (Join-Path $Portable 'init.ps1')

$script:passed = 0
$script:failed = 0
function Check([string]$label, $want, $got) {
    if (($want -join '|') -ceq ($got -join '|')) { $script:passed++ }
    else {
        $script:failed++
        [Console]::Out.WriteLine("FAIL $label`n  want: $($want -join '|')`n  got:  $($got -join '|')")
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) 'uc-init-test'
if (Test-Path $work) { Remove-Item -Recurse -Force -Path $work }
function Reset-Fixture {
    Set-Location ([IO.Path]::GetTempPath())
    if (Test-Path $work) { cmd /c "rd /s /q `"$work`"" }
    New-Item -ItemType Directory (Join-Path $work 'sub') | Out-Null
    foreach ($f in 'a.txt', 'b c.txt', 'x.c', '.hidden', '[q].dat', 'sub\n.txt', 'sub\M.TXT') {
        [IO.File]::WriteAllText((Join-Path $work $f), "$f`n")
    }
    Set-Location $work
}

# What a typed line prints after the hook has had it.
function Run([string]$line) {
    Reset-Fixture
    $converted = ConvertTo-UtilCoreLine $line
    @(Invoke-Expression $converted)
}

foreach ($name in 'cat', 'cp', 'diff', 'dir', 'echo', 'ls', 'mkdir', 'mv', 'pwd', 'rm', 'rmdir', 'sleep', 'sort', 'tee') {
    $found = Get-Command $name | Select-Object -First 1
    Check "$name is util-core's" (Join-Path $global:UtilCoreBin "$name.exe") $found.Source
}
Check 'PATH has the folder once, first' @($global:UtilCoreBin, 1) @(($env:Path -split ';')[0], @($env:Path -split ';' | Where-Object { $_ -eq $global:UtilCoreBin }).Count)

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    Check 'no wildcard hook before 7.4' $false ([bool](Get-Command ConvertTo-UtilCoreLine -ErrorAction SilentlyContinue))
    [Console]::Out.WriteLine("$script:passed passed, $script:failed failed (PowerShell $($PSVersionTable.PSVersion))")
    return
}

Check 'a pattern' 'a.txt b c.txt' (Run 'echo *.txt')
Check 'with the extension typed' 'a.txt b c.txt' (Run 'echo.exe *.txt')
Check 'each name is one argument' @('a.txt', 'b c.txt') (Run 'printf "%s\n" *.txt')
Check 'single quotes' '*.txt' (Run "echo '*.txt'")
Check 'double quotes' '*.txt' (Run 'echo "*.txt"')
Check 'partly quoted word' '*.txt' (Run 'echo *".txt"')
Check 'no match stays' '*.zip' (Run 'echo *.zip')
Check 'forward slash' 'sub/M.TXT sub/n.txt' (Run 'echo sub/*.txt')
Check 'backslash' 'sub\M.TXT sub\n.txt' (Run 'echo sub\*.txt')
Check 'pattern directory' 'sub/M.TXT sub/n.txt' (Run 'echo s*/*.txt')
Check 'directories only' 'sub/' (Run 'echo s*/')
Check 'leading dot' '.hidden' (Run 'echo .h*')
Check 'no leading dot' '[q].dat a.txt b c.txt sub x.c' (Run 'echo *')
Check 'brackets are ordinary' '[q].dat' (Run 'echo [q].*')
Check 'question mark' 'x.c' (Run 'echo ?.c')
Check 'tilde and no match' "$HOME/nosuch*" (Run 'echo ~/nosuch*')
Check 'full path' "$work\x.c" (Run "echo $work\*.c")
Check 'variable and pattern' "$work/x.c" (Run 'echo $work/*.c')
Check 'quoted variable' "$work/*.c" (Run 'echo "$work/*.c"')
Check 'option with a pattern' '--include=*.zz' (Run 'echo --include=*.zz')
Check 'stop-parsing' '*.txt' (Run 'echo --% *.txt')
Check 'nested command' 'got a.txt b c.txt' (Run 'echo got $(echo *.txt)')
Check 'find keeps its quoted pattern' @('./a.txt', './b c.txt', './sub/M.TXT', './sub/n.txt') (Run "find . -iname '*.txt' | sort")
Check 'grep keeps its quoted pattern' 'a.txt:a.txt' (Run "grep -H 'a.*t' a.txt")
Check 'pipe' '2' (Run 'cat *.txt | wc -l')
Check 'two commands' @('x.c', 'a.txt b c.txt') (Run 'echo *.c; echo *.txt')
Check 'ls' @('a.txt', 'b c.txt') (Run 'ls -1 *.txt')
Check 'rm' @('[q].dat', 'sub', 'x.c') (Run 'rm *.txt; ls -1')
Check 'cp' @('a.txt', 'b c.txt', 'M.TXT', 'n.txt') (Run 'cp *.txt sub; ls -1 sub' | Sort-Object { $_ -cne 'a.txt' }, { $_ -cne 'b c.txt' }, { $_ -cne 'M.TXT' })
Check 'rm -f with no match' '0' (Run 'rm -f *.zip; echo $LASTEXITCODE')

Check 'PowerShell commands are left alone' 'Get-ChildItem *.txt' (ConvertTo-UtilCoreLine 'Get-ChildItem *.txt')
Check 'other programs are left alone' 'cmd /c dir *.txt' (ConvertTo-UtilCoreLine 'cmd /c dir *.txt')
Check 'a line that does not parse is left alone' 'echo *.txt "' (ConvertTo-UtilCoreLine 'echo *.txt "')
function global:grep { 'mine' }
Check 'your own function is left alone' 'grep a *.txt' (ConvertTo-UtilCoreLine 'grep a *.txt')
Remove-Item Function:\grep

Set-Location ([IO.Path]::GetTempPath())
cmd /c "rd /s /q `"$work`""
[Console]::Out.WriteLine("$script:passed passed, $script:failed failed (PowerShell $($PSVersionTable.PSVersion))")
