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

Keep these as exceptions, collected in **`src/sys.zig`**, the only file allowed
to use `std.posix` / `std.os`. Commands call `sys.*`; none imports a POSIX
module. Every function is a no-op or returns a safe default on Windows and
WASI.

| `sys` function | Used by | What it does | Why `std.Io` cannot |
|---|---|---|---|
| `ignoreSignal`, `defaultSignal`, `restoreSigpipe` | every entry point (SIGPIPE), `tee` (SIGINT, SIGPIPE) | `sigaction` | no signal API; Zig's runtime ignores SIGPIPE, which would turn `cmd \| head` into a write-error message |
| `umask` | `mkdir` | read the process umask (Linux: `umask(2)` set-and-restore; elsewhere 022) | no query API |
| `terminalColumns` | `cat` (bat-style view) | `ioctl(TIOCGWINSZ)` on standard output | `Io.File.isTty` only answers yes or no |
| `processAlive` | `tail --pid` | `kill(pid, 0)`; EPERM counts as alive | no signal or process-probe API |
| `openAppend` | `tee -a` | `openat` with `O_APPEND` | `Io.Dir.createFile` has no append mode; a seek to the end is not atomic with concurrent writers |
| `identity`, `supplementaryGroups` | `id`, `groups`, `whoami` | `getuid`/`geteuid`/`getgid`/`getegid`, `getgroups` | no process-identity API |
| `uname` | `uname`, `arch`, `hostid` | the `uname(2)` system call | no host-information API |
| `affinityCpus` | `nproc` | `sched_getaffinity` | no CPU-set API |
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
- Ports to Windows and WASI keep working but without those features.
