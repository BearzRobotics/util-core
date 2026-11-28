# NAME

sed - stream editor for filtering and transforming text

# SYNOPSIS

    sed [OPTION]... {script-only-if-no-other-script} [input-file]...
    sed --help | --version

# DESCRIPTION

Stream editor for filtering and transforming text.

# OPTIONS

-n, --quiet, --silent
: Suppress automatic printing of the pattern space.

-e SCRIPT, --expression=SCRIPT
: Add SCRIPT to the commands to run.

-f FILE, --file=FILE
: Add the commands in FILE (`-` is standard input).

-E, -r, --regexp-extended
: Use extended regular expressions.

-i[SUFFIX], --in-place[=SUFFIX]
: Edit files in place; with SUFFIX keep a backup (a `*` in SUFFIX stands for the base name, a `/` makes it a path). If the backup cannot be made, sed stops with status 4 and leaves the file unchanged. The new file gets the owner, group, permissions and POSIX access ACL of the file that was read, as far as the user may set them (see DIFFERENCES FROM GNU).

--follow-symlinks
: Edit the target of a symbolic link when editing in place.

-s, --separate
: Treat files as separate: line numbers and `$` are per file.

-l N, --line-length=N
: Wrap length for the `l` command.

-z, --null-data
: Lines are separated by NUL.

-u, --unbuffered
: Flush output after every line, and take no more from a pipe than is used.

--posix
: Disable some GNU extensions (N at end of input discards the pattern space).

--sandbox
: Reject e, r and w commands.

-b, --binary
: Accepted and ignored.

--help, --version
: Print help or version and exit.

# DIFFERENCES FROM GNU

- A script file that cannot be read to its end (any error but reading a directory) ends sed with status 4; GNU sed runs the part it read.
- A range `ADDR,+N` whose end is past the largest line number goes to the end of the input; GNU's sum wraps around and ends it at once.
- `-i`, when the new file cannot be given the old one's group: GNU says nothing and keeps the group permission bits, which then apply to another group. We limit that group to what others had, drop the set-group-ID bit and warn on standard error. The set-user-ID bit is likewise dropped when the owner cannot be kept. Output and exit status are as in GNU.
- `-i`, when the mode or access ACL cannot be set on the new file: we warn on standard error; the new file allows nobody more than the old one did.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | Invalid command, option or script. |
| 2 | An input file could not be read; the others were processed. |
| 4 | I/O error or other fatal error. |
| N | From `q N` or `Q N`. |


# ENVIRONMENT

none (locale variables are ignored; behaviour is that of the C locale)

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU sed 4.9 (`/usr/bin/sed --version` on the development machine). Consulted 2026-11-07: the GNU sed manual (https://www.gnu.org/software/sed/manual/sed.html) and POSIX.1-2024 sed, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sed.sh`).

See docs/compatibility/sed.md for details.

# LIMITATIONS

- Regular expressions use the Perl-dialect engine of regex-zig through src/posixre.zig. Alternation is made leftmost-longest, as in POSIX and GNU, except in patterns containing `$` or a word anchor, which are leftmost-first; group positions follow the Perl rule.
- `--debug` is accepted but prints nothing extra (GNU prints the program and a trace).
- C locale only: no multibyte characters.
- `-i` does not carry over other extended attributes (GNU sed does not either), nor an SELinux context (GNU sed does).
- `e` and `s///e` run the command with `/bin/sh -c` and read its output through a pipe; no temporary file is used.
- `--version` prints an abbreviated banner.

# SEE ALSO

docs/compatibility/sed.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

