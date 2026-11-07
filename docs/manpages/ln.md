% LN(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
ln - make links between files

SYNOPSIS
ln [OPTION]... [-T] TARGET LINK_NAME | TARGET | TARGET... DIRECTORY | -t DIRECTORY TARGET...
ln --help | --version

DESCRIPTION
Make links between files.

OPTIONS
-s, --symbolic
: Symbolic links.

-f, --force
: Replace existing destinations.

-i, --interactive
: Prompt (reads y/n from standard input).

-b, --backup[=CONTROL]
: Back up replaced files (`none`, `simple`, `numbered`, `existing` and their aliases); `-S SUFFIX` and `SIMPLE_BACKUP_SUFFIX` set the simple suffix.

-L, -P
: Hard links follow / do not follow symbolic-link sources.

-n, --no-dereference
: Treat a symlink-to-directory destination as a file.

-r, --relative
: With -s, make the link relative to its own directory.

-t DIR, -T
: Target directory / treat the destination as a normal file.

-v, --verbose
: Print each link as GNU does (`'dest' => 'src'`, `->` for symbolic ones, `'backup~' ~ 'dest' => 'src'` with backups).

-d, -F
: Ignored.

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
Reference: GNU coreutils 9.7 (`/usr/bin/ln --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ln invocation" (`info '(coreutils) ln invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ln, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ln.sh`).
See docs/compatibility/ln.md for details.

LIMITATIONS
- Same-file detection compares inode numbers only (`std.Io.File.Stat` has no device number), so files on different devices with equal inode numbers would be taken for one file.
- `--help` is shorter than GNU's.

SEE ALSO
docs/compatibility/ln.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
