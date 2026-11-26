# NAME

shred - overwrite a file to hide its contents, and optionally delete it

# SYNOPSIS

    shred [OPTION]... FILE...
    shred --help | --version

# DESCRIPTION

Overwrite a file to hide its contents, and optionally delete it.

# OPTIONS

-f, --force
: Make the file writable if needed.

-n, --iterations=N
: Number of passes (default 3).

--random-source=FILE
: Take random bytes from FILE.

-s, --size=N
: Shred this many bytes.

-u, --remove[=HOW]
: Remove after overwriting (`unlink`, `wipe`, `wipesync`).

-v, --verbose, -x, --exact, -z, --zero
: Progress, exact size, final zero pass.

--help, --version
: Print help or version and exit.

# DIFFERENCES FROM GNU

- When `-u` cannot rename a file in order to wipe its name, shred prints a
  warning on standard error before removing it. GNU says nothing. The exit
  status is GNU's.

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

Reference: GNU coreutils 9.7 (`/usr/bin/shred --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "shred invocation" (`info '(coreutils) shred invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/shred-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_shred.sh`).

See docs/compatibility/shred.md for details.

# LIMITATIONS

- Random data and the order of the fixed patterns come from a ChaCha8 stream (a cryptographically secure generator) seeded with 32 bytes from the operating system, not from GNU's ISAAC. With `--random-source` they are the file's own bytes, so the resulting passes differ from GNU's for the same file.
- Direct I/O is not requested.

# SEE ALSO

docs/compatibility/shred.md, docs/architecture.md

# VERSION

This manual describes util-core 0.2.0.

