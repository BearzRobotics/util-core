% DF(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
df - report file system space usage

SYNOPSIS
df [OPTION]... [FILE]...
df --help | --version

DESCRIPTION
Report file system space usage.

OPTIONS
-a, --all
: Include pseudo, duplicate and inaccessible file systems.

-B, --block-size=SIZE, -k, -m, -h, -H, --si
: Size units; DF_BLOCK_SIZE, BLOCK_SIZE and BLOCKSIZE are honoured.

-i, --inodes
: Inode information instead of block usage.

-l, --local
: Only local file systems.

--output[=FIELD_LIST]
: Choose columns: source, fstype, itotal, iused, iavail, ipcent, size, used, avail, pcent, file, target.

-P, --portability
: POSIX output format.

--sync, --no-sync
: Accepted; sync(2) is not needed on Linux.

--total
: Produce a grand total.

-t, --type=TYPE, -x, --exclude-type=TYPE, -T, --print-type
: Select, exclude and show file system types.

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
Reference: GNU coreutils 9.7 (`/usr/bin/df --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "df invocation" (`info '(coreutils) df invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/df-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), df, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/df.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_df.sh`).
See docs/compatibility/df.md for details.

LIMITATIONS
- Only /proc/self/mountinfo is read (no /etc/mtab fallback); without it df fails with the `cannot read table of mounted file systems` diagnostic.
- Remote file system detection uses the same name rules as GNU but the file systems are never contacted before statfs.
- C locale only: control characters in names become `?` and wide characters are counted as bytes.

SEE ALSO
docs/compatibility/df.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
