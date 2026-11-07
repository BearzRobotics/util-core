% STAT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
stat - display file or file system status

SYNOPSIS
stat [OPTION]... FILE...
stat --help | --version

DESCRIPTION
Display file or file system status.

OPTIONS
-L, --dereference
: Follow symbolic links.

-f, --file-system
: Show file system status.

-c, --format=FORMAT / --printf=FORMAT
: Custom format (--printf interprets backslash escapes and prints no trailing newline).

-t, --terse
: Terse form.

--cached=MODE
: Accepted (statx sync flags are not passed on).

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
Reference: GNU coreutils 9.7 (`/usr/bin/stat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "stat invocation" (`info '(coreutils) stat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/stat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), stat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stat.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_stat.sh`).
See docs/compatibility/stat.md for details.

LIMITATIONS
- `%C` reads the `security.selinux` attribute; without it GNU's `failed to get security context` diagnostic is reproduced.
- `%m` walks up the directory tree looking for a device change; bind mounts are not resolved through the mount table.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/stat.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
