% DD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
dd - convert and copy a file

SYNOPSIS
dd [OPERAND]...
dd OPTION
dd --help | --version

DESCRIPTION
Convert and copy a file.

OPTIONS
if=FILE, of=FILE
: Input and output files.

bs=, ibs=, obs=, cbs=
: Block sizes (suffixes b c k K M G ... and `x` products).

count=, skip=, iseek=, seek=, oseek=
: Block counts and offsets.

conv=
: ascii, ebcdic, ibm, block, unblock, lcase, ucase, sparse, swab, sync, excl, nocreat, notrunc, noerror, fdatasync, fsync.

iflag=, oflag=
: append, direct, directory, dsync, sync, fullblock, nonblock, noatime, nocache, noctty, nofollow, count_bytes, skip_bytes, seek_bytes.

status=
: none, noxfer, progress.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	An error occurred (or, for check-style modes, a check failed).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/dd --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "dd invocation" (`info '(coreutils) dd invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), dd, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dd.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_dd.sh`).
See docs/compatibility/dd.md for details.

LIMITATIONS
- SIGUSR1 does not print statistics.
- `status=progress` prints at most one update per second and may skip it for very short copies.
- O_DIRECT alignment and posix_fadvise (`nocache`) are not handled.
- `iflag`/`oflag` flags that need an open file (`append`, `dsync`...) apply to files named with `if=`/`of=`; for standard streams only `fcntl` flags are set.

SEE ALSO
docs/compatibility/dd.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
