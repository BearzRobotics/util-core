% FMT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
fmt - simple optimal text formatter

SYNOPSIS
fmt [-WIDTH] [OPTION]... [FILE]...
fmt --help | --version

DESCRIPTION
Simple optimal text formatter.

OPTIONS
-w, --width=WIDTH
: Maximum line width (default 75, at most 2500).

-g, --goal=WIDTH
: Goal width (default 93% of the width).

-c, --crown-margin
: Preserve the indentation of the first two lines.

-t, --tagged-paragraph
: First line indent differs from the second.

-s, --split-only
: Split long lines, do not refill.

-u, --uniform-spacing
: One space between words, two after sentences.

-p, --prefix=STRING
: Only reformat lines beginning with STRING.

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
Reference: GNU coreutils 9.7 (`/usr/bin/fmt --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "fmt invocation" (`info '(coreutils) fmt invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/fmt-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), fmt, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fmt.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_fmt.sh`).
See docs/compatibility/fmt.md for details.

LIMITATIONS
- Widths count bytes (C locale).
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/fmt.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
