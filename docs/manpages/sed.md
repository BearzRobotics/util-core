% SED(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
sed - stream editor for filtering and transforming text

SYNOPSIS
sed [OPTION]... {script-only-if-no-other-script} [input-file]...
sed --help | --version

DESCRIPTION
Stream editor for filtering and transforming text.

OPTIONS
-n, --quiet, --silent
: Suppress automatic printing of the pattern space.

-e SCRIPT, --expression=SCRIPT
: Add SCRIPT to the commands to run.

-f FILE, --file=FILE
: Add the commands in FILE (`-` is standard input).

-E, -r, --regexp-extended
: Use extended regular expressions.

-i[SUFFIX], --in-place[=SUFFIX]
: Edit files in place; with SUFFIX keep a backup (a `*` in SUFFIX stands for the base name, a `/` makes it a path).

--follow-symlinks
: Edit the target of a symbolic link when editing in place.

-s, --separate
: Treat files as separate: line numbers and `$` are per file.

-l N, --line-length=N
: Wrap length for the `l` command.

-z, --null-data
: Lines are separated by NUL.

-u, --unbuffered
: Flush output after every line.

--posix
: Disable some GNU extensions (N at end of input discards the pattern space).

--sandbox
: Reject e, r and w commands.

-b, --binary
: Accepted and ignored.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid command, option or script.
2	An input file could not be read; the others were processed.
4	I/O error or other fatal error.
N	From `q N` or `Q N`.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU sed 4.9 (`/usr/bin/sed --version` on the development machine). Consulted 2026-11-07: the GNU sed manual (https://www.gnu.org/software/sed/manual/sed.html) and POSIX.1-2024 sed, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sed.sh`).
See docs/compatibility/sed.md for details.

LIMITATIONS
- Regular expressions use the Perl-dialect engine of regex-zig through src/posixre.zig: alternation is leftmost-first, POSIX and GNU use leftmost-longest, so `s/a|ab/X/` differs on "ab".
- `--debug` is accepted but prints nothing extra (GNU prints the program and a trace).
- C locale only: no multibyte characters.
- `e` and `s///e` run the command through `/bin/sh` and a temporary file in /tmp.
- `--version` prints an abbreviated banner.

SEE ALSO
docs/compatibility/sed.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
