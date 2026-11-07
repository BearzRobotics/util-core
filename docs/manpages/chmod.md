% CHMOD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
chmod - change file mode bits

SYNOPSIS
chmod [OPTION]... MODE[,MODE]... FILE... | OCTAL-MODE FILE... | --reference=RFILE FILE...
chmod --help | --version

DESCRIPTION
Change file mode bits.

OPTIONS
-c, -v, -f
: Report changes / every file / suppress most errors.

-R, -H, -L, -P
: Recurse; symlink-to-directory arguments traversed (-H, default), all symlinks traversed (-L), none (-P). Symlinks met inside a tree are skipped unless -L.

-h, --no-dereference, --dereference
: Act on a symlink itself (it cannot change, so it is left alone) or its target.

--reference=RFILE
: Use RFILE's mode.

--preserve-root, --no-preserve-root
: Refuse to recurse on `/` (including `/.`, reported as `(same as '/')`).

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
Reference: GNU coreutils 9.7 (`/usr/bin/chmod --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chmod invocation" (`info '(coreutils) chmod invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chmod, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chmod.sh`).
See docs/compatibility/chmod.md for details.

LIMITATIONS
- `-h` on a symlink does nothing (as on Linux, where symlink modes cannot be changed); `--help` is shorter than GNU's.

SEE ALSO
docs/compatibility/chmod.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
