% RM(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
rm - remove files or directories

SYNOPSIS
rm [OPTION]... [FILE]...
rm --help | --version

DESCRIPTION
Remove files or directories.

OPTIONS
-f, --force
: Ignore nonexistent files and arguments, never prompt.

-i, -I, --interactive[=WHEN]
: Prompt before every removal (-i), once before removing more than three files or recursing (-I), or per WHEN (never, once, always).

-r, -R, --recursive
: Remove directories and their contents recursively.

-d, --dir
: Remove empty directories.

-v, --verbose
: Explain what is being done.

--one-file-system
: With -r, skip (and report) directories on a different device from the command-line argument; the parent is then kept and the exit status is 1.

--preserve-root[=all], --no-preserve-root
: Refuse to operate recursively on `/` (default). `=all` is treated as plain --preserve-root.

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
Reference: GNU coreutils 9.7 (`/usr/bin/rm --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "rm invocation" (`info '(coreutils) rm invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), rm, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/rm.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_rm.sh`).
See docs/compatibility/rm.md for details.

LIMITATIONS
- `--preserve-root=all` does not compare devices against the parent.

SEE ALSO
docs/compatibility/rm.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
