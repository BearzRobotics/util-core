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
| x86_64-windows | yes | partly | the 79 cases of `test/test_windows_wine.sh` (a smoke test of 27 commands) pass under wine 10.0 and on Windows 11; wider checks fail, see "Known to fail on Windows" |
| aarch64-windows | yes | no | compiled only |
| aarch64-macos, x86_64-macos | yes | no | compiled only; no Mac was available. The libc code in `src/sys/other.zig` is unexecuted |

### Known to fail on Windows

Found on Windows 11 (2026-11-27), not yet examined. No Windows archives are
published while these stand.

- `cp -a`, `touch` and `install` crash: Zig 0.17.1's standard library has not
  implemented setting file times or permissions on Windows.
- `split` fails to create its output; `shred` reports that it cannot sync the
  directory; `ln` and `link` cannot make hard links.
- `env` does not find a program named by its full path; `whoami` finds no name
  for the user.
- `cp` could not copy any file in 0.2.0 and earlier ("cannot fstat"); that is
  fixed in 0.3.0.

Only a few of the commands have been run on real Windows.

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

Paths: Windows accepts `/` and `\`; the commands print the path text they were
given. Text is never translated (no CRLF conversion).

## Testing

* Linux: the whole suite (`test/run_all_tests.sh`), unchanged by the portable
  work. The suites run against the Linux build only.
* Windows: `test/test_windows_wine.sh` runs the x86_64-windows build under
  wine 10.0 (in a private wine prefix) and compares standard output and exit
  status of 79 small cases with the Linux build. The commands covered are cat,
  wc, sort, ls, cp, rm, mkdir, date, find, grep, sed, printf, test, env, seq,
  md5sum, tr, cut, uniq, tee, head, tail, du, stat, basename and readlink. It
  skips cleanly when wine or either build is missing. Standard error is not
  compared. Result: **79 passed, 0 failed.** Differences found while writing
  it and kept out of the comparison on purpose: directory sizes (`ls -S`
  sorts a directory by 4096 on Linux, 0 on Windows).
  **This is wine, not Windows.** Wine runs the same PE binaries against its own
  reimplementation of the Windows API, so it shows the programs start, parse
  arguments, read and write files and pipes, and walk directories, but not how
  real Windows file systems, permissions, symbolic links or console behave. A
  run on a real Windows machine is planned before release.
* macOS: compile-checked only. The libc paths (open, stat, chown, signals, kqueue
  watcher, statfs) have never been executed; treat them as untested.
