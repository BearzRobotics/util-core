# 0002: Exceptions to the std.Io rule (src/sys.zig)

Status: accepted by the maintainer; rows added as new commands need them (last: 2026-11-07, system-information tools). Date: 2026-11-07

## Context

ai/AGENTS.md §13 requires the `std.Io` interface (`const Io = std.Io;`) for
portability "unless there is a compelling reason not to", with the maintainer's
approval. On 2026-11-07 the whole tree was audited (`grep` for `std.posix`,
`std.os`, `std.fs`, `std.io`, `std.c`, `std.Thread`) against the Zig 0.17.1
standard library (`~/.zvm/0.17.1/lib/std`, files `Io.zig`, `Io/File.zig`,
`Io/Dir.zig`, `Io/Terminal.zig`, `process.zig`).

Converted: `std.fs.path.*` and `std.fs.max_path_bytes` (deprecated aliases) now
use `std.Io.Dir.path.*` and `std.Io.Dir.max_path_bytes`.

Not convertible: five facilities for which that standard library has no
`std.Io` API. They previously sat in `cli.zig`, `tee.zig`, `cat.zig` and
`tail.zig`.

## Decision

Keep these as exceptions, collected in **`src/sys.zig`** (and its non-Linux half `src/sys/other.zig`), the only files allowed
to use `std.posix` / `std.os`. Commands call `sys.*`; none imports a POSIX
module. Linux code is in `sys.zig`; every other OS (macOS, Windows) is served by
`src/sys/other.zig` behind the same signatures, dispatched with a comptime
`builtin.os.tag` check. Where a facility cannot exist on the platform the
function returns `E.NOSYS` / `E.OPNOTSUPP` (or a documented neutral value) so
the command prints a one-line diagnostic. See `docs/portability.md`.

| `sys` function | Used by | What it does | Why `std.Io` cannot |
|---|---|---|---|
| `ignoreSignal`, `defaultSignal`, `inheritSigpipe` | every entry point (SIGPIPE), `tee` (SIGINT, SIGPIPE) | `sigaction` | no signal API; Zig's runtime catches SIGPIPE, which would turn `cmd \| head` into a write-error message and lose an inherited "ignore" in the programs a command runs |
| `umask` | `mkdir` | read the process umask (Linux: `umask(2)` set-and-restore; elsewhere 022) | no query API |
| `terminalColumns` | `cat` (bat-style view) | `ioctl(TIOCGWINSZ)` on standard output | `Io.File.isTty` only answers yes or no |
| `processAlive` | `tail --pid` | `kill(pid, 0)`; EPERM counts as alive | no signal or process-probe API |
| `openAppend` | `tee -a` | `openat` with `O_APPEND` | `Io.Dir.createFile` has no append mode; a seek to the end is not atomic with concurrent writers |
| `identity`, `supplementaryGroups` | `id`, `groups`, `whoami` | `getuid`/`geteuid`/`getgid`/`getegid`, `getgroups` | no process-identity API |
| `uname` | `uname`, `arch`, `hostid` | the `uname(2)` system call | no host-information API |
| `affinityCpus` | `nproc` | `sched_getaffinity` | no CPU-set API |
| `signalNumber`, `signalName`, `setSignal`, `unblockSignal`, `signalState`, `sendSignal` | `env`, `nohup`, `timeout` | `rt_sigaction`, `rt_sigprocmask`, `kill` | no signal API |
| `Watcher`, `waitPid`, `becomeGroupLeader` | `timeout` | `pidfd_open`, `signalfd`, `ppoll`, `wait4`, `setpgid` | `Child.wait` has no timeout and no signal events |
| `dup2`, `fdOpen`, `openAppendMode` | `nohup` | `dup2`, `fcntl(F_GETFD)`, `openat(O_APPEND)` | no descriptor-level API |
| `getNice`, `setNice` | `nice` | `getpriority`, `setpriority` | no scheduling API |
| `syncFile` | `sync` | `sync`, `fsync`, `fdatasync`, `syncfs` | no flush API |
| `chroot`, `mknod` | `chroot`, `mkfifo`, `mknod` | `chroot`, `mknodat` | no such API |
| `chownAt` | `cp`, `mv`, `install` | `fchownat` | `Io.File` has no owner-change API |
| `catchSignals`, `restoreCaughtSignals`, `takeCaughtSignal`, `deliverCaughtSignal` | `ls` (reset colour on SIGINT, SIGTERM, SIGTSTP, ...) | `sigaction` with `SA_RESTART` recording the signal, then `kill` of ourselves with the default action | no signal API (add to the list of facilities to ask std.Io for upstream: handlers and raise) |
| `fileStat`, `errnoText` | `test` (and later `stat`, `ls`, `du`, `find`, `chown`) | `statx(2)` for owner, group, device, block count and nanosecond times | `Io.File.Stat` has no uid, gid, device number or block count |

One related use stays outside `sys.zig`: `cli.giveBack` calls
`io.vtable.fileSeekBy`. That is part of the `Io` interface itself, but it
reaches into the vtable because `Io.File` has no public seek method.

## Alternatives considered

- **Leave the calls inline where they were.** Rejected: the exceptions were
  scattered over four files and undocumented.
- **Emulate each with `std.Io`.** `openAppend` by seeking to the end loses
  `O_APPEND` atomicity; the others have no emulation at all.
- **Drop the features** (`tee -a`, `tee -i`, `tail --pid`, `cat` width,
  `mkdir -m` defaults). Rejected: they are GNU behaviour the tests compare.

## Consequences

- The exception list is one file, one table. A new OS-level need must be added
  there and to this record, with the reason `std.Io` cannot serve it.
- **Revisit on each Zig upgrade.** Re-run the audit (`grep -rn "std\.posix\|std\.os\b" src`)
  and the check for Io equivalents (signals, umask, terminal size, process
  probing, append-mode `createFile`). When `std.Io` gains one, replace the
  `sys` function and delete its row. The expectation is that this table shrinks
  over time.
- Windows and macOS builds exist (`docs/portability.md`); where a facility is
  missing the command fails with a diagnostic rather than pretending.

## Portable-OS additions (2026-11-19)

All of these are in `src/sys/other.zig`, reached through the `sys.*` function of
the same name. "Io" rows use the single-threaded `std.Io` instance
(`Io.Threaded.global_single_threaded`) because `sys` functions carry no `io`.

| `sys` function(s) | macOS | Windows | Why `sys` and not the caller's `std.Io` |
|---|---|---|---|
| `fileStat`, `fstatFd` | libc `fstatat`/`fstat` (owner, device, blocks) | `Io` `statFile`/`stat`; ids and devices read 0 | `Io.File.Stat` lacks owner/device/blocks; the `FileStat` shape is shared with Linux |
| `openFd`, `readFd`, `writeAllFd`, `writeFd`, `closeFd`, `ftruncateFd`, `fchmodFd`, `setTimes`, `mkdirPath`, `unlinkPath`, `renamePath`, `linkPath`, `symlinkPath`, `readlinkPath`, `chmodPath`, `accessPath`, `readDirRaw` | `Io` | `Io` | errno-faithful results (`E`) and the descriptor-level calling convention cp, mv, install, sed, grep, find use |
| `seekFd` | libc `lseek` (SEEK_DATA/HOLE swapped) | `Io` seek vtable; no SEEK_DATA/HOLE | `Io.File` has no public seek |
| `fchownFd`, `chownAt` | libc | succeeds only for owner 0/unchanged, else `E.PERM` | no owner API |
| `openAppend`, `openAppendMode` | libc `open(O_APPEND)` | open, then seek to end (not atomic) | no append mode |
| `getStatusFlags`, `setStatusFlags` | 0 / no-op | 0 / no-op | `fcntl` flags (dd, shred) |
| `umask`, `setUmask` | libc | fixed 022 | no query API |
| `terminalColumns` | `ioctl(TIOCGWINSZ)` | `GetConsoleScreenBufferInfo` | tty size |
| `processAlive`, `sendSignal`, `waitPid` | `kill`, `waitpid` | `OpenProcess`/`WaitForSingleObject`/`TerminateProcess`/`GetExitCodeProcess` | `Child.wait` has no timeout |
| `Watcher` (`timeout`) | `kqueue` (EVFILT_PROC, EVFILT_SIGNAL) | `WaitForSingleObject` with a timeout; no signal events | pidfd/signalfd are Linux |
| `setSignal`, `unblockSignal`, `signalState`, `catchSignals`, `signalOwnGroup`, `raiseSelf` | `sigaction`, `sigprocmask` | `E.NOSYS` / false (no signals) | no signal API |
| `identity`, `supplementaryGroups` | libc `getuid` ... `getgroups` | all ids 0, no groups | no identity API |
| `uname` | libc `uname` | `RtlGetVersion`, `GetComputerNameA` | no host info API |
| `getNice`, `setNice`, `becomeGroupLeader`, `parentPid`, `chrootPath`, `mknodPath`, `syncFile(.all)`, `setRealtime` | libc | `E.NOSYS` | no such API |
| `statfs` | libc `statfs` (`$INODE64` on x86_64) | `GetDiskFreeSpaceExW` | no filesystem-statistics API |
| `getXattr` | `E.OPNOTSUPP` | `E.OPNOTSUPP` | SELinux/xattr contexts are Linux |
| `monotonicNs`, `permissionsFromMode`, `handleFromFd`, `signo`, `Handle`, `Pid` | portable | portable | helpers that hide the `Io.File.Handle` (pointer on Windows) and `Child.Id` types |
