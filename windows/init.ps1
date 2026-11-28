# SPDX-License-Identifier: GPL-2.0-or-later
# util-core in this PowerShell session. Load it with a dot, from anywhere:
#
#     . E:\util-core\init.ps1
#
# It puts the bin folder next to this file first on PATH (or this file's own
# folder, when the programs are beside it) and removes the PowerShell aliases
# that hide util-core commands, so that "ls" runs ls.exe. In PowerShell 7.4 and
# later it also expands unquoted wildcards in the util-core commands typed at
# the prompt. Only this session changes; nothing is installed or saved.
#
# Windows PowerShell 5.1 is not supported beyond the names: its own handling of
# pipes and ">" changes what the programs read and write, and a pipeline whose
# first program never stops writing ("yes | head") does not end. See
# docs/portability.md.
#
# If PowerShell refuses to run scripts, allow it for this session first:
#     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

if ($MyInvocation.InvocationName -ne '.') {
    Write-Warning "Nothing changed. Load this script with a dot: . `"$PSCommandPath`""
    return
}

$global:UtilCoreBin = Join-Path $PSScriptRoot 'bin'
if (-not (Test-Path -LiteralPath (Join-Path $global:UtilCoreBin 'util-core.exe'))) {
    $global:UtilCoreBin = $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $global:UtilCoreBin 'util-core.exe'))) {
    Write-Warning "Nothing changed: util-core.exe is not in $PSScriptRoot or its bin folder."
    return
}

# First on PATH, once: Windows has a sort.exe and a find.exe of its own.
$env:Path = (@($global:UtilCoreBin) + @($env:Path -split ';' |
        Where-Object { $_ -and $_.TrimEnd('\') -ne $global:UtilCoreBin })) -join ';'

# PowerShell's own names for commands util-core has.
foreach ($name in 'cat', 'cp', 'diff', 'dir', 'echo', 'ls', 'mv', 'pwd', 'rm', 'rmdir', 'sleep', 'sort', 'tee') {
    # An alias may exist in more than one scope.
    while (Test-Path -LiteralPath "Alias:\$name") { Remove-Item -LiteralPath "Alias:\$name" -Force }
}
if (Test-Path -LiteralPath 'Function:\mkdir') { Remove-Item -LiteralPath 'Function:\mkdir' -Force }

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    Write-Warning ("util-core: PowerShell $($PSVersionTable.PSVersion) is not supported. The commands are on PATH, " +
        "but wildcards are not expanded, and pipes and '>' change binary and text data. Use PowerShell 7.4 or later, or cmd.exe.")
    return
}

# ---- wildcards
# PowerShell gives a program the same text for *.txt and '*.txt', so the program
# cannot expand them. The typed line still shows the difference: each unquoted
# pattern given to a util-core command is replaced by a call that lists the
# names. Everything else, pipes and redirections included, stays as typed.

# The names a pattern matches, by the rules util-core follows under cmd.exe:
# "*" and "?" only, "[" is ordinary, a leading "." must be written, any case,
# sorted. A pattern that matches nothing is given back.
function global:Expand-UtilCoreWildcard([string]$Pattern) {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return $Pattern }
    $text = $Pattern
    # PowerShell replaces "~" in a bare word itself; in a call it would not.
    if ($text -match '^~[\\/]') {
        $text = $HOME + $text.Substring(1)
    }
    # What names no directory entry: a drive, or a server and share.
    $root = [regex]::Match($text, '^([\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?|[A-Za-z]:[\\/]*|[\\/]+)?').Value
    $paths = @($root)
    $listed = $false
    foreach ($part in [regex]::Matches($text.Substring($root.Length), '([^\\/]+)([\\/]*)')) {
        $name = $part.Groups[1].Value
        $separators = $part.Groups[2].Value
        $next = New-Object System.Collections.Generic.List[string]
        if ($name -notmatch '[*?]') {
            foreach ($before in $paths) {
                $full = $before + $part.Value
                if ($listed) {
                    if (-not (Test-Path -LiteralPath $full)) { continue }
                    if ($separators -and -not (Test-Path -LiteralPath $full -PathType Container)) { continue }
                }
                $next.Add($full)
            }
        } else {
            $listed = $true
            $expression = '^' + [regex]::Escape($name).Replace('\*', '.*').Replace('\?', '([\uD800-\uDBFF][\uDC00-\uDFFF]|.)') + '$'
            foreach ($before in $paths) {
                # .NET has a current directory of its own: give it a full path.
                $directory = if (-not $before) { $location.ProviderPath }
                    elseif ([IO.Path]::IsPathRooted($before)) { $before }
                    else { Join-Path $location.ProviderPath $before }
                try { $entries = [IO.Directory]::GetFileSystemEntries($directory) } catch { continue }
                foreach ($entry in $entries) {
                    $leaf = [IO.Path]::GetFileName($entry)
                    if ($leaf.StartsWith('.') -and -not $name.StartsWith('.')) { continue }
                    if ($leaf -notmatch $expression) { continue }
                    if ($separators -and -not [IO.Directory]::Exists($entry)) { continue }
                    $next.Add($before + $leaf + $separators)
                }
            }
        }
        $paths = @($next)
    }
    if (-not $listed -or $paths.Count -eq 0) { return $Pattern }
    $sorted = [string[]]$paths
    $keys = [string[]]@($sorted | ForEach-Object { $_.Replace('\', '/') })
    [Array]::Sort($keys, $sorted, [StringComparer]::Ordinal)
    return $sorted
}

# A command line with the unquoted patterns of util-core commands replaced.
function global:ConvertTo-UtilCoreLine([string]$Line) {
    if ($Line -notmatch '[*?]') { return $Line }
    $tokens = $null
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { return $Line }
    $changes = @()
    $commands = $tree.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if (-not $name -or $name -match '[\\/:]') { continue }
        # Only when the name really runs a util-core program.
        $found = Get-Command -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found -or $found.CommandType -ne 'Application') { continue }
        if ((Split-Path -Parent $found.Source) -ne $global:UtilCoreBin) { continue }
        # After --% the user has asked for the text as it is.
        if ($command.Extent.Text -match '(^|\s)--%(\s|$)') { continue }
        foreach ($element in ($command.CommandElements | Select-Object -Skip 1)) {
            $constant = $element -is [System.Management.Automation.Language.StringConstantExpressionAst]
            $expandable = $element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            if (-not ($constant -or $expandable)) { continue }
            if ($element.StringConstantType -ne 'BareWord') { continue }
            $written = $element.Extent.Text
            # Anything quoted or escaped in the word leaves it alone.
            if ($written -notmatch '[*?]' -or $written -match '[''"`\u2018-\u201E]') { continue }
            $argument = if ($constant) { "'" + $element.Value + "'" } else { '"' + $written + '"' }
            $changes += [pscustomobject]@{
                Start = $element.Extent.StartOffset
                End = $element.Extent.EndOffset
                Text = "(Expand-UtilCoreWildcard $argument)"
            }
        }
    }
    foreach ($change in ($changes | Sort-Object Start -Descending)) {
        $Line = $Line.Substring(0, $change.Start) + $change.Text + $Line.Substring($change.End)
    }
    return $Line
}

# PowerShell reads each typed line through this function. Scripts do not.
if (Get-Module -Name PSReadLine) {
    function global:PSConsoleHostReadLine {
        $lastRunStatus = $?
        Microsoft.PowerShell.Core\Set-StrictMode -Off
        $line = if ([Microsoft.PowerShell.PSConsoleReadLine].GetMethods() |
                Where-Object { $_.Name -eq 'ReadLine' -and $_.GetParameters().Count -ge 3 }) {
            [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext, $lastRunStatus)
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext)
        }
        try { ConvertTo-UtilCoreLine $line } catch { $line }
    }
}
