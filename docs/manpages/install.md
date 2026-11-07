% INSTALL(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
install - copy files and set attributes

SYNOPSIS
install [OPTION]... [-T] SOURCE DEST
install [OPTION]... SOURCE... DIRECTORY
install [OPTION]... -t DIRECTORY SOURCE...
install [OPTION]... -d DIRECTORY...
install --help | --version

DESCRIPTION
Copy files and set attributes.

OPTIONS
-b, --backup[=CONTROL], -S
: Backups.

-c
: Ignored.

-C, --compare
: Do not modify a destination that already matches.

-d, --directory, -D
: Create directories (with all parents).

-g, -o, -m
: Group, owner and mode.

-p, -s, --strip-program=PROGRAM
: Preserve timestamps; strip the installed file.

-t, -T, -v, --debug
: Destination handling and verbosity.

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
Reference: GNU coreutils 9.7 (`/usr/bin/install --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "install invocation" (`info '(coreutils) install invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/install-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), install, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/install.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_install.sh`).
See docs/compatibility/install.md for details.

LIMITATIONS
- Only the C locale; SELinux options are accepted and ignored.
- `-o`/`-g` can only name the caller's own ids unless run as root.

SEE ALSO
docs/compatibility/install.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
