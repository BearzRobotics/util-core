% MV(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
mv - move (rename) files

SYNOPSIS
mv [OPTION]... [-T] SOURCE DEST
mv [OPTION]... SOURCE... DIRECTORY
mv [OPTION]... -t DIRECTORY SOURCE...
mv --help | --version

DESCRIPTION
Move (rename) files.

OPTIONS
-b, --backup[=CONTROL], -S, --suffix
: Backups.

-f, -i, -n, -u, --update[=WHEN]
: Overwrite policy.

-t, -T, --strip-trailing-slashes, -v, --debug
: Destination handling and verbosity.

--no-copy
: Fail instead of copying across file systems.

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
Reference: GNU coreutils 9.7 (`/usr/bin/mv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mv invocation" (`info '(coreutils) mv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mv, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mv.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mv.sh`).
See docs/compatibility/mv.md for details.

LIMITATIONS
- `--exchange` is not implemented.
- Only the C locale: names, quotes and messages are the English/ASCII ones.
- SELinux contexts, ACLs and extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored).

SEE ALSO
docs/compatibility/mv.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
