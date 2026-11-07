% CP(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
cp - copy files and directories

SYNOPSIS
cp [OPTION]... [-T] SOURCE DEST
cp [OPTION]... SOURCE... DIRECTORY
cp [OPTION]... -t DIRECTORY SOURCE...
cp --help | --version

DESCRIPTION
Copy files and directories.

OPTIONS
-a, --archive
: Same as `-dR --preserve=all`.

--attributes-only
: Copy attributes, not data.

--backup[=CONTROL], -b, -S, --suffix
: Backups (`none`, `simple`, `existing`, `numbered`); VERSION_CONTROL and SIMPLE_BACKUP_SUFFIX are honoured.

--copy-contents, -d, -H, -L, -P
: Symlink and special-file handling.

-f, -i, -n, -u, --update[=WHEN]
: Overwrite policy (`all`, `none`, `none-fail`, `older`).

-l, -s
: Hard or symbolic links instead of copies.

-p, --preserve[=LIST], --no-preserve=LIST
: mode, ownership, timestamps, links, context, xattr, all.

--parents, -R/-r, -t, -T, -v, -x, --debug
: Directories, destination handling, verbosity.

--reflink[=WHEN], --sparse=WHEN, --remove-destination, --strip-trailing-slashes, --keep-directory-symlink
: As documented by GNU.

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
Reference: GNU coreutils 9.7 (`/usr/bin/cp --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "cp invocation" (`info '(coreutils) cp invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cp, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cp.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cp.sh`).
See docs/compatibility/cp.md for details.

LIMITATIONS
- Only the C locale: names, quotes and messages are the English/ASCII ones.
- SELinux contexts, ACLs and extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored).
- Reflink (`--reflink=always`) reports `failed to clone ... Operation not supported`; `auto` falls back to a normal copy. File data is copied with read/write rather than `copy_file_range`, so `--debug` states what GNU would report.
- Sparse files: holes are detected with SEEK_DATA/SEEK_HOLE and recreated; `--sparse=always` turns blocks of zeros into holes.
- Reading a FIFO source blocks until a writer appears, exactly like GNU.

SEE ALSO
docs/compatibility/cp.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
