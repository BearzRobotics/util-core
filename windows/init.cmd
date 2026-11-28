@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem util-core in this cmd.exe window. Run it from anywhere:
rem
rem     E:\util-core\init.cmd
rem
rem It puts the bin folder next to this file first on PATH (or the folder of this
rem file, when the programs are beside it). Only this window changes. From another
rem batch file, use "call". cmd.exe still runs its own dir, echo, mkdir, rmdir and
rem date: give the full path to run util-core's.

set "UTIL_CORE_BIN=%~dp0bin"
if exist "%UTIL_CORE_BIN%\util-core.exe" goto found
set "UTIL_CORE_BIN=%~dp0."
if exist "%UTIL_CORE_BIN%\util-core.exe" goto found
echo init.cmd: util-core.exe is not in %~dp0 or its bin folder 1>&2
set "UTIL_CORE_BIN="
exit /b 1

:found
set "PATH=%UTIL_CORE_BIN%;%PATH%"
