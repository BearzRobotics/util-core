% FIND(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
find - search for files in a directory hierarchy

SYNOPSIS
find [-H] [-L] [-P] [-Olevel] [-D debugopts] [path...] [expression]
find --help | --version

DESCRIPTION
Search for files in a directory hierarchy.

OPTIONS
-H, -L, -P
: Symbolic link handling: command-line only, always, never (default).

-O level, -D opts
: Accepted; optimisation levels and debug options have no effect (-D help lists them).

-maxdepth N, -mindepth N, -depth/-d, -mount/-xdev, -noleaf, -ignore_readdir_race, -follow, -daystart, -warn/-nowarn
: Traversal options.

-name, -iname, -path/-wholename, -ipath, -lname, -ilname, -regex, -iregex, -regextype
: Name tests (fnmatch globs; regular expressions default to the Emacs syntax).

-type, -xtype, -size, -perm, -user, -group, -uid, -gid, -nouser, -nogroup, -links, -inum, -samefile, -empty, -fstype, -readable, -writable, -executable
: File property tests.

-atime, -ctime, -mtime, -amin, -cmin, -mmin, -used, -newer, -anewer, -cnewer, -newerXY
: Time tests; X and Y are a, c, m (and t for a date string); B (birth time) is rejected as GNU does here.

-print, -print0, -printf, -fprint, -fprint0, -fprintf, -ls, -fls
: Output actions; -printf supports all GNU directives and flags.

-exec, -execdir, -ok, -okdir (; and +), -delete, -prune, -quit
: Command, removal and control actions.

( ) ! -not -a -and -o -or ,
: Operators with GNU's precedence and error messages.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All files were processed without error.
1	An error occurred (unreadable directory, missing start point, failed -delete or -exec ... +, invalid expression).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU findutils 4.10.0 (`/usr/bin/find --version` on the development machine). Consulted 2026-11-07: the GNU find manual (https://www.gnu.org/software/findutils/manual/html_mono/find.html) and POSIX.1-2024 find, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/find.html. Behaviour was checked by differential tests against the GNU binary (`sh test/test_find.sh`).
See docs/compatibility/find.md for details.

LIMITATIONS
- Only the C locale and UTF-8 quoting of file names in messages are handled; there is no multibyte-aware matching in -name.
- `-regex` accepts Emacs, POSIX basic and extended syntax by translating them to the regex-zig Perl dialect; leftmost-longest alternation is not emulated (the whole path must match, so results are the same except for rare cases with back-references).
- -files0-from, -context (SELinux), -D tracing output and the optimiser (-O) are not implemented.
- `-exec` batching limits are fixed (about 100 KB) instead of being computed from ARG_MAX.
- `-fstype` reads /proc/self/mountinfo; file systems not listed there report `unknown`.

SEE ALSO
docs/compatibility/find.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
