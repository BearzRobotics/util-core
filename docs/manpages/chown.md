% CHOWN(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
chown - change file owner and group

SYNOPSIS
chown [OPTION]... [OWNER][:[GROUP]] FILE...
chown [OPTION]... --reference=RFILE FILE...
chown --help | --version

DESCRIPTION
Change file owner and group.

OPTIONS
-c, --changes
: Report only when a change is made.

-v, --verbose
: Report every file processed.

-f, --silent, --quiet
: Suppress most error messages.

--dereference / -h, --no-dereference
: Affect the referent of each symbolic link (default) or the link itself.

--from=CURRENT_OWNER:CURRENT_GROUP
: Change only files whose current owner and/or group match.

--preserve-root / --no-preserve-root
: Refuse (or not) to operate recursively on `/`.

--reference=RFILE
: Use RFILE's owner and group.

-R, --recursive
: Operate on files and directories recursively.

-H, -L, -P
: Symbolic link traversal with -R (default -P).

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
Reference: GNU coreutils 9.7 (`/usr/bin/chown --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chown invocation" (`info '(coreutils) chown invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chown, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chown.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chown.sh`).
See docs/compatibility/chown.md for details.

LIMITATIONS
- Names come from /etc/passwd and /etc/group only (no NSS), as in the other commands.
- Only privileges an ordinary user has were exercised by the tests: changes to other users cannot be tested without root, so the successful chown-to-other-user path is covered only by its error behaviour.
- The fts cycle diagnostics are reduced to the `WARNING: Circular directory structure.` text for -P and -H below the command line; -L silently refuses to descend into a cycle as fts does.
- fts is not used: traversal order is the order returned by the file system, and `FTS_DEFER_STAT` stat-avoidance for -h without verbose output is not reproduced, so a file that vanishes mid-run reports `cannot access` rather than `changing ownership of`.

SEE ALSO
docs/compatibility/chown.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
