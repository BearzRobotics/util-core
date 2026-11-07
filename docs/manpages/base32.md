% BASE32(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
base32 - base32 encode or decode data

SYNOPSIS
base32 [-d] [-i] [-w COLS] [FILE]
base32 --help | --version

DESCRIPTION
Base32 encode or decode data.

OPTIONS
-d, --decode
: Decode data.

-i, --ignore-garbage
: When decoding, drop characters outside the alphabet (an `=` is never dropped).

-w, --wrap=COLS
: Wrap encoded lines after COLS characters (default 76); 0 disables wrapping.

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
Reference: GNU coreutils 9.7 (`/usr/bin/base32 --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "base32 invocation" (`info '(coreutils) base32 invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/base32-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), base32, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/base32.html. RFC 4648 section 6. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_base32.sh`).
See docs/compatibility/base32.md for details.

LIMITATIONS
- `--version` prints `base32 (core-utils) 0.0.0-dev`; `--help` is shorter than GNU's.

SEE ALSO
docs/compatibility/base32.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
