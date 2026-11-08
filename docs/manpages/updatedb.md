% UPDATEDB(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
updatedb - create or update a locate database

SYNOPSIS
updatedb [OPTION]...
updatedb --help | --version

DESCRIPTION
Create or update a locate database.

OPTIONS
--localpaths=DIRS, --netpaths=DIRS
: Directories to index (shell-style globbing is applied).

--prunepaths=DIRS, --prunefs=TYPES
: Paths and file-system types to skip.

--output=FILE, --dbformat=FORMAT
: Output database and format (LOCATE02 or slocate).

--findoptions=OPTS
: Extra options for the file walk (-xdev, -depth, -maxdepth, -mindepth, -noleaf, ...).

--netuser=USER, --localuser=USER
: Accepted and ignored.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	An error occurred (or, for check-style modes, a check failed).

ENVIRONMENT
LOCATE_PATH (locate); FINDOPTIONS, SEARCHPATHS, NETPATHS, PRUNEPATHS, PRUNEFS, LOCATE_DB (updatedb). Locale variables are ignored.

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C.
See docs/compatibility/updatedb.md for details.

LIMITATIONS
- --localuser/--netuser (su) are ignored.
- Databases are byte-identical to GNU's in all tested cases.

SEE ALSO
docs/compatibility/updatedb.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
