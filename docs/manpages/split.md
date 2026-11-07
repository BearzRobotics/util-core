% SPLIT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
split - split a file into pieces

SYNOPSIS
split [OPTION]... [FILE [PREFIX]]
split --help | --version

DESCRIPTION
Split a file into pieces.

OPTIONS
-l, --lines=N, -N
: Lines per output file.

-b, --bytes=SIZE
: Bytes per output file.

-C, --line-bytes=SIZE
: At most SIZE bytes of whole records per file.

-n, --number=CHUNKS
: N, K/N, l/N, l/K/N, r/N, r/K/N.

-a, --suffix-length=N
: Suffix length (0 = automatic).

-d, -x, --numeric-suffixes[=FROM], --hex-suffixes[=FROM]
: Numeric or hex suffixes.

--additional-suffix=SUFFIX
: Append to every name.

-e, --elide-empty-files
: With -n, do not create empty files.

-t, --separator=SEP
: Record separator.

--filter=COMMAND
: Pipe each piece to `$SHELL -c COMMAND` with $FILE set.

-u, --unbuffered
: Write immediately (-n r/...).

--verbose
: Report each file created.

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
Reference: GNU coreutils 9.7 (`/usr/bin/split --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "split invocation" (`info '(coreutils) split invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/split-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), split, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/split.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_split.sh`).
See docs/compatibility/split.md for details.

LIMITATIONS
- `--hex-suffixes=FROM` is implemented as documented; GNU 9.7 itself produces garbage names (`xf:`, `xfC`...) for it, so it is not tested.
- With `-n l/N` or `r/N` where N exceeds the input size GNU keeps creating files until the suffixes run out; we stop at N.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/split.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
