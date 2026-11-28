# NAME

csplit - split a file into sections determined by context lines

# SYNOPSIS

    csplit [OPTION]... FILE PATTERN...
    csplit --help | --version

# DESCRIPTION

Split a file into sections determined by context lines.

# OPTIONS

INTEGER, /REGEXP/[OFFSET], %REGEXP%[OFFSET], {N}, {*}
: Patterns.

-b, --suffix-format=FORMAT
: printf-style integer format for the numbering.

-f, --prefix
: Output prefix (default xx).

-n, --digits
: Digits in the number.

-k, -s/-q, -z, --suppress-matched
: Keep files, quiet, elide empty, drop matched lines.

--help, --version
: Print help or version and exit.

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

Reference: GNU coreutils 9.7 (`/usr/bin/csplit --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "csplit invocation" (`info '(coreutils) csplit invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/csplit-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), csplit, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/csplit.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_csplit.sh`).

See docs/compatibility/csplit.md for details.

# LIMITATIONS

- The whole input is read into memory before splitting.
- A `--digits` value, field width or precision above 1048576 is "memory exhausted". GNU says that from 2147483647 on, or when it cannot allocate the name; below that, such a name is too long to create anyway.
- `--help` omits the "GNU coreutils online help" footer.

# SEE ALSO

docs/compatibility/csplit.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

