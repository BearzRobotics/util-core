% DU(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
du - estimate file space usage

SYNOPSIS
du [OPTION]... [FILE]...
du [OPTION]... --files0-from=F
du --help | --version

DESCRIPTION
Estimate file space usage.

OPTIONS
-a, --all
: Write counts for all files, not just directories.

--apparent-size, -b, --bytes
: Apparent sizes (`st_size` of regular files and symbolic links; 0 otherwise).

-B, --block-size=SIZE, -k, -m, -h, --si
: Size units, including the `human-readable` and `si` specifications; DU_BLOCK_SIZE, BLOCK_SIZE and BLOCKSIZE are honoured.

-c, --total
: Produce a grand total.

-d, --max-depth=N, -s, --summarize
: Limit the depth of printed entries.

-D, -H, --dereference-args, -L, --dereference, -P, --no-dereference
: Symbolic link handling.

-l, --count-links
: Count hard-linked files each time.

-S, --separate-dirs
: Directories exclude the size of their subdirectories.

-t, --threshold=SIZE
: Hide entries smaller (positive SIZE) or larger (negative SIZE) than SIZE.

--time[=WORD], --time-style=STYLE
: Show the latest modification (or atime, ctime) time; `full-iso`, `long-iso`, `iso`, `+FORMAT`; TIME_STYLE is honoured.

--inodes
: Count inodes instead of blocks.

-x, --one-file-system
: Skip directories on other file systems.

--exclude=PATTERN, -X, --exclude-from=FILE
: Skip entries matching a shell pattern (matched against the whole path and every suffix that follows a slash).

-0, --null, --files0-from=F
: NUL-terminated output and input lists.

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
Reference: GNU coreutils 9.7 (`/usr/bin/du --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "du invocation" (`info '(coreutils) du invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), du, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/du.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_du.sh`).
See docs/compatibility/du.md for details.

LIMITATIONS
- fts is not used: entries are visited in the order the file system returns them, and cycles reached through symbolic links under -L are skipped quietly as fts does while -P cycles produce the `Circular directory structure` warning.
- The mount-point test behind `-x` compares device numbers only (GNU uses the same rule); bind mounts of one device are not special-cased.
- Times are formatted in the local zone from /usr/share/zoneinfo or TZ; leap seconds are not applied.

SEE ALSO
docs/compatibility/du.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
