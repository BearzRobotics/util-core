% BASE64(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
base64 - base64 encode or decode data

SYNOPSIS
base64 [-d] [-i] [-w COLS] [FILE]
base64 --help | --version

DESCRIPTION
Base64 encode or decode data.

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
Reference: GNU coreutils 9.7 (`/usr/bin/base64 --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "base64 invocation" (`info '(coreutils) base64 invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/base64-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), base64, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/base64.html. RFC 4648 section 4. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_base64.sh`).
See docs/compatibility/base64.md for details.

LIMITATIONS
- `--version` prints `base64 (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.
- A directory operand prints `read error: Is a directory` as GNU does.

SEE ALSO
docs/compatibility/base64.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
