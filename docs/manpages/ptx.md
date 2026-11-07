% PTX(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
ptx - produce a permuted index of file contents

SYNOPSIS
ptx [OPTION]... [INPUT]...
ptx --help | --version

DESCRIPTION
Produce a permuted index of file contents.

OPTIONS
-A, -R, -r
: Auto, right-side or input references.

-w, -g, -F, -M, -O, -T, -G, -f
: Width, gap, truncation flag, macro name, roff, TeX, traditional, ignore case.

-i, -o, -b
: Ignore, only and break files.

-S, -W
: End-of-sentence and word regular expressions.

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
Reference: GNU coreutils 9.7 (`/usr/bin/ptx --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ptx invocation" (`info '(coreutils) ptx invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ptx-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ptx, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ptx.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ptx.sh`).
See docs/compatibility/ptx.md for details.

LIMITATIONS
- `-S`/`-W` expressions are translated from GNU's Emacs-style syntax to extended syntax and use the project's regex engine; POSIX character classes such as `[[:alpha:]]` behave differently from glibc in this syntax and are not tested.
- With `-W` patterns that can match the empty string GNU loops forever; so do we.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/ptx.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
