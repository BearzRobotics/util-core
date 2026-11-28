# NAME

mv - move (rename) files

# SYNOPSIS

    mv [OPTION]... [-T] SOURCE DEST
    mv [OPTION]... SOURCE... DIRECTORY
    mv [OPTION]... -t DIRECTORY SOURCE...
    mv --help | --version

# DESCRIPTION

Move (rename) files.

# OPTIONS

-b, --backup[=CONTROL], -S, --suffix
: Backups.

-f, -i, -n, -u, --update[=WHEN]
: Overwrite policy.

-t, -T, --strip-trailing-slashes, -v, --debug
: Destination handling and verbosity.

--no-copy
: Fail instead of copying across file systems.

--help, --version
: Print help or version and exit.

# DIFFERENCES FROM GNU

- When the destination cannot store a source's POSIX ACL, the failure is
  reported as GNU reports it, but the group and other permissions are narrowed
  so that nobody gains access. GNU 9.7 leaves the owning group with the ACL's
  mask.
- A move between file systems writes the destination tree by name in the
  directories it made, so replacing one with a symbolic link meanwhile does not
  redirect the copy (see cp(1)).

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | An error occurred (or, for check-style modes, a check failed). |


# ENVIRONMENT

none (locale variables are ignored; behaviour is that of the C locale)

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU coreutils 9.7 (`/usr/bin/mv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mv invocation" (`info '(coreutils) mv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mv, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mv.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mv.sh`).

See docs/compatibility/mv.md for details.

# LIMITATIONS

- `--exchange` is not implemented.
- Only the C locale: names, quotes and messages are the English/ASCII ones.
- POSIX ACLs travel with the mode (`-p`, `-a`, `--preserve=mode`, and mv between file systems): the source's access ACL and a directory's default ACL are copied, as in GNU. If the destination cannot store them the copy is reported (`preserving permissions for ...`) and, unlike GNU 9.7, which leaves the ACL mask as the owning group's permission, the group and other bits are narrowed so that nobody gains access. SELinux contexts and other extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored). ACLs are handled on Linux only.

# SEE ALSO

docs/compatibility/mv.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

