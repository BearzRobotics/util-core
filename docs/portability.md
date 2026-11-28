# Portability: Linux, macOS, Windows

Every command and the whole library compile for the targets below. Operating
system facilities live only in `src/sys.zig` (Linux) and `src/sys/other.zig`
(macOS, Windows), with a Windows or macOS implementation behind the same
function signatures wherever `std` provides what is needed
(decision `docs/decisions/0002-std-io-exceptions.md`). A facility that cannot
exist on a platform fails with a one-line diagnostic and the command's usual
failure status; it never silently succeeds. WASI is not supported.

## Targets and status

| Target | Compiles (multicall and standalone) | Run | Test status |
|---|---|---|---|
| x86_64-linux-musl, aarch64-linux-musl | yes | yes | every `test/test_*.sh` suite (differential against GNU coreutils) |
| x86_64-windows | yes | yes | `test/test_windows_wine.sh` (106 cases, a smoke test) under wine; `test/test_windows_vm.sh` on Windows 11, see "Known to fail on Windows" |
| aarch64-windows | yes | no | compiled only |
| aarch64-macos, x86_64-macos | yes | no | compiled only; no Mac was available. The libc code in `src/sys/other.zig` is unexecuted |

### Known to fail on Windows

`test/test_windows_vm.sh` runs the cases on a real Windows machine over SSH and
compares them with the Linux build. On 2026-11-28, on Windows 11:

| Shell | Passed | Not run |
|---|---|---|
| `cmd.exe` | 328 of 329 | |
| PowerShell 7.7.0 | 314 of 328 | `yes \| head`, checked by hand |
| Windows PowerShell 5.1 | 273 of 328 | `yes \| head`, which never ends there |

`df` fails in all three. The other PowerShell failures are how PowerShell treats
what is typed or what goes through a pipe, see "PowerShell" below. Most
commands have only a few cases, and nothing interactive is covered (paging on a
console, Ctrl-C, prompts). No Windows archives are published yet.

- `df` does not list the file systems.

Fixed since 0.3.0: setting file times and permissions crashed (`touch`,
`install`, `mkdir -m`, `cp -p`, `cp -a`); `dd oflag=append` overwrote instead
of appending; `split`, `link`, `ln`, `cp -l`, `shred -u`, `whoami`, changing
the case of a name with `mv`, and the commands that run another program (`env`,
`nice` and the rest) failed.

"Compiles" means `zig build -Dtarget=T -Doptimize=ReleaseSmall` with both
`-Dmode=multicall` and `-Dmode=standalone`, all commands.

## Cross-compiling

```
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall            # util-core.exe and one NAME.exe per command
zig build -Dtarget=aarch64-macos  -Doptimize=ReleaseSmall -Dmode=multicall
zig build -Dtarget=x86_64-windows -Dcommands=cat,ls,cp -Dmode=standalone   # quick iteration
```

`-Dman=false` skips the manual pages. Nothing in `build.zig` depends on the
host.

## What works where

| Area | Linux | macOS | Windows |
|---|---|---|---|
| Wildcards in arguments | the shell's job | the shell's job | expanded by the program when `cmd.exe` started it, see below |
| Text, data and hashing commands (cat, wc, sort, cut, tr, uniq, sed, grep, seq, printf, md5sum, ...) | yes | yes | yes |
| File commands (cp, mv, rm, mkdir, touch, ln, find, ls, du, stat, tail, tee, ...) | yes | yes | yes, with the differences below |
| `date` | yes | yes | yes; `date -s` is `Function not implemented` |
| File owner, group, device numbers, hard-link counts in `stat`, `ls -l`, `find -user`, `test -O` | yes | yes | not available: every file reports owner and group 0, devices 0; `chown`-style requests succeed only for owner 0 or "unchanged", else `Operation not permitted` |
| Permission bits | yes | yes | only the read-only attribute: `chmod` toggles it, `stat` shows 644/755 (755 for directories and `.exe .bat .cmd .com`), read-only files lose write bits |
| Symbolic links (`ln -s`, `readlink`, `cp -P`) | yes | yes | need the symlink privilege (error otherwise) |
| `mknod`, `mkfifo`, `chroot` | yes | yes (needs root) | `Function not implemented` |
| `nice` | yes | yes | `nice` prints 0; setting fails with `Function not implemented` |
| `nohup` | yes | yes | exits 125 with "not supported on this platform" |
| `timeout` | yes | yes (kqueue) | yes: waits on the process handle, terminates it on timeout (status 124); signal choice is ignored, no signal forwarding |
| `env --block-signal/--default-signal/--ignore-signal` | yes | yes | fail with a diagnostic |
| `sync` | yes | yes | per-file sync works; plain `sync` is `Function not implemented` |
| `df` | yes (`statfs`) | yes | total/free/available of the volume; no filesystem type or inode counts |
| `tee -a`, `nohup.out` append | atomic `O_APPEND` | atomic `O_APPEND` | open, then seek to the end (not atomic between writers) |
| Sparse copy (`cp --sparse`, `dd conv=sparse` hole detection) | yes | yes | holes are written as data |
| Open flags (`dd iflag=`/`oflag=` such as `append`, `dsync`, `sync`, `nonblock`, `noctty`, `nofollow`; `touch`, `truncate`, `sync` and `split` not waiting on a FIFO) | yes | yes, through `openat(2)` and `fcntl` (compile-checked); `direct` and `noatime` are ignored | ignored |
| SELinux / extended-attribute contexts (`ls -Z`, `stat %C`, `cp --context`) | yes | not supported | not supported |
| `uname`, `arch`, `hostid`, `nproc` | yes | yes | `uname` reports `Windows_NT`, the computer name, the NT version and build; `nproc` as `std` reports it |
| Signals (`kill`-like behaviour, `ls` colour reset on SIGINT, SIGPIPE) | yes | yes | no signals; the code compiles to no-ops |

Wildcards: `cmd.exe` passes `*.txt` on as it is, so on Windows each program
expands it, by the Unix shell's rules: `*` and `?` count only outside double
quotes (`find . -name "*.txt"` gets the pattern), a pattern that matches nothing
stays, matches are sorted, and a name starting with "." needs a pattern starting
with ".". Names match whatever their case (ASCII letters only). `[` is an
ordinary character, and the hidden attribute does not hide a file. This happens
only when `cmd.exe` is the program that started the command. Arguments passed
by other programs (`xargs`, `find -exec`, `env`) are never expanded, as on
Unix, and neither are those from PowerShell, so `ls.exe *.txt` gets the text
`*.txt` there.

### Portable use

The Windows archive `scripts/package.sh` builds can be unpacked anywhere, a
flash drive included. Nothing is installed: run `init.cmd` in a `cmd.exe`
window, or `. .\init.ps1` in PowerShell. Each puts the `bin` folder beside it
first on `PATH` for that window. The archive holds one program per command as
well as `util-core.exe`, because FAT32 and exFAT have no hard links to give one
program many names. No Windows archives are published yet.

### PowerShell

PowerShell 7.4 or later is supported (tested: 7.7.0). Load `windows/init.ps1`
with a dot, with the programs in a `bin` folder beside it or in its own folder:

    . E:\util-core\init.ps1

For that session it

* puts the programs first on `PATH`, ahead of the `sort.exe` and `find.exe` in
  `C:\Windows\System32`;
* removes `cat`, `cp`, `diff`, `dir`, `echo`, `ls`, `mkdir`, `mv`, `pwd`, `rm`,
  `rmdir`, `sleep`, `sort` and `tee`, PowerShell's own aliases and function, so
  that those names run util-core. What expects PowerShell's `ls` or `rm` in the
  same session gets util-core's;
* expands unquoted wildcards in util-core commands typed at the prompt, by the
  rules above. `ls *.txt` lists the files, and `find . -name '*.txt'` gets the
  pattern.

PowerShell gives a program the same text for `*.txt` and `'*.txt'`, so the
programs cannot do this. The script looks at the typed line and replaces each
unquoted pattern with a call that lists the names; `Get-History` shows that
form. **Scripts are not read this way**, nor is `pwsh -Command`. There, and
without `init.ps1` (where several of the names need their `.exe`), let
PowerShell list the names:

    ls.exe -l (Get-ChildItem -Name *.txt)          # names in this directory
    ls.exe -l (Resolve-Path -Relative sub\*.txt)   # in another one

When nothing matches those give no names at all, so `cat.exe` and the like then
wait for standard input.

**Windows PowerShell 5.1 is not supported.** `init.ps1` there sets `PATH` and
the names, says so, and leaves wildcards alone. Its handling of pipes and `>`
changes data, see below; Microsoft's coreutils package asks for PowerShell 7.4
as well.

**Quote what PowerShell would read as its own.** Both versions change these
before the program sees them; in single quotes they arrive as typed.

| Typed | The program gets | Write |
|---|---|---|
| `cut.exe -d, -f1` | nothing: a syntax error | `cut.exe -d ',' -f1`, `'-t,'` |
| `date.exe -d @0` | `-d` | `'@0'` |
| `sed.exe -i.bak` | `-i` `.bak` | `'-i.bak'` |
| `-exec cat.exe {} +`, `-I{}` | `-encodedCommand` and other words | `'{}'`, `'-I{}'` |
| `echo.exe "a"*` | `a` `*` | `'a*'` |

Windows PowerShell 5.1 also drops an empty argument (`''`) and loses double
quotes inside an argument. PowerShell 7.7.0 passes both on, but replaces a bare
`~` with the home directory.

**Pipes and `>`.** Windows PowerShell 5.1 treats what programs write as text. In
the tests, `>` wrote UTF-16 files, pipes between two programs added carriage
returns (`wc.exe` counted 37 bytes for 31), non-ASCII text and binary data
changed, and `md5sum.exe a > sums` followed by `md5sum.exe -c sums` failed. A
pipeline whose first program writes for ever (`yes.exe | head.exe -n 3`) does
not end: it had taken 3.2 GB when it was stopped. Use PowerShell 7 or
`cmd.exe` for such work. In PowerShell 7.7.0 the pipe and `>` cases passed.
When the second program ends before reading everything, it may report "The pipe
is being closed" for the first.

### cmd.exe

Wildcards work as typed. Only double quotes quote; `'` is an ordinary
character. `cmd.exe` has commands of its own named `dir`, `echo`, `mkdir`,
`rmdir` and `date`, which run in place of util-core's. In the tests on Windows
11 even `mkdir.exe` and `date.exe` ran the built-in one, so give the program's
full path.

Paths: Windows accepts `/` and `\`; the commands print the path text they were
given. Text is never translated (no CRLF conversion).

## Testing

* Linux: the whole suite (`test/run_all_tests.sh`), unchanged by the portable
  work. The suites run against the Linux build only.
* Windows: `test/test_windows_wine.sh` runs the x86_64-windows build under
  wine 10.0 (in a private wine prefix) and compares standard output and exit
  status of 106 small cases with the Linux build. The commands covered are cat,
  wc, sort, ls, cp, rm, mkdir, date, find, grep, sed, printf, test, env, seq,
  md5sum, tr, cut, uniq, tee, head, tail, du, stat, basename and readlink. It
  skips cleanly when wine or either build is missing. Standard error is not
  compared. Result: **106 passed, 0 failed.** Differences found while writing
  it and kept out of the comparison on purpose: directory sizes (`ls -S`
  sorts a directory by 4096 on Linux, 0 on Windows).
  **This is wine, not Windows.** Wine runs the same PE binaries against its own
  reimplementation of the Windows API, so it shows the programs start, parse
  arguments, read and write files and pipes, and walk directories, but not how
  real Windows file systems, permissions, symbolic links or console behave. A
  run on a real Windows machine is planned before release.
* `test/windows_init_test.ps1` checks `windows/init.ps1` on a Windows machine
  (49 checks in PowerShell 7.7.0, 16 in 5.1). It calls the line rewriting
  directly; typing at a prompt was checked separately over SSH on 2026-11-28.
* macOS: compile-checked only. The libc paths (open, stat, chown, signals, kqueue
  watcher, statfs) have never been executed; treat them as untested.
