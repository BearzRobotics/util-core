# NAME

ln - make links between files

# SYNOPSIS

    ln [OPTION]... [-T] TARGET LINK_NAME | TARGET | TARGET... DIRECTORY | -t DIRECTORY TARGET...
    ln --help | --version

# DESCRIPTION

Make links between files.

# OPTIONS

-s, --symbolic
: Symbolic links.

-f, --force
: Replace existing destinations.

-i, --interactive
: Prompt (reads y/n from standard input).

-b, --backup[=CONTROL]
: Back up replaced files (`none`, `simple`, `numbered`, `existing` and their aliases); `-S SUFFIX` (which also turns backups on) and `SIMPLE_BACKUP_SUFFIX` set the simple suffix; one that is empty or contains `/` means `~`. Backups are named as by cp, mv and install: `existing` is numbered when any numbered backup exists, and `numbered` takes the highest number plus one.

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

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | An error occurred (or, for check-style modes, a check failed). |


# ENVIRONMENT

`VERSION_CONTROL` chooses the backup type when `--backup` gives none; `SIMPLE_BACKUP_SUFFIX` sets the simple backup suffix. Locale variables are ignored; behaviour is that of the C locale.

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU coreutils 9.7 (`/usr/bin/ln --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ln invocation" (`info '(coreutils) ln invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ln, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ln.sh`).

See docs/compatibility/ln.md for details.

# DIFFERENCES FROM GNU

- With -i and no backup, a destination that holds the source's data is refused ("'SRC' and 'DEST' are the same file", status 1), as it is with -f. GNU 9.7 asks and then destroys the data.
- For a hard link (without -L and without a backup), a TARGET that is a symbolic link leading to LINK_NAME is refused the same way when LINK_NAME is the file's only name (`ln -f link file`). GNU 9.7 replaces the file by a link that points at itself, losing the data.

# LIMITATIONS

- `--help` is shorter than GNU's.

# SEE ALSO

docs/compatibility/ln.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

