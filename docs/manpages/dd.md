# NAME

dd - convert and copy a file

# SYNOPSIS

    dd [OPERAND]...
    dd OPTION
    dd --help | --version

# DESCRIPTION

Convert and copy a file.

# OPTIONS

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

# SIGNALS

SIGUSR1 (and SIGINFO where it exists) makes a running dd print the I/O statistics to standard error and carry on; with POSIXLY_CORRECT set it keeps its usual effect. SIGINT, unless it was ignored, prints the statistics before ending dd. Windows has neither.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | An error occurred (or, for check-style modes, a check failed). |


# ENVIRONMENT

none (locale variables are ignored; behaviour is that of the C locale)

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU coreutils 9.7 (`/usr/bin/dd --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "dd invocation" (`info '(coreutils) dd invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), dd, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dd.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_dd.sh`).

See docs/compatibility/dd.md for details.

# LIMITATIONS

- `status=progress` writes a line between blocks once at least a second has passed since the last one (as GNU does), so a shorter copy shows none, and none is written while a single read or write blocks.
- O_DIRECT alignment and posix_fadvise (`nocache`) are not handled.
- `iflag`/`oflag` flags that need an open file (`append`, `dsync`...) apply to files named with `if=`/`of=`; for standard streams only `fcntl` flags are set.

# SEE ALSO

docs/compatibility/dd.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

