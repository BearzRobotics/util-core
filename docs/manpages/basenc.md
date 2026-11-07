% BASENC(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
basenc - encode or decode data in one of several encodings

SYNOPSIS
basenc --ENCODING [-d] [-i] [-w COLS] [FILE]
basenc --help | --version

DESCRIPTION
Encode or decode data in one of several encodings.

OPTIONS
--base64, --base64url, --base32, --base32hex, --base16, --base2msbf, --base2lsbf, --z85
: Select the encoding (one is required).

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
Reference: GNU coreutils 9.7 (`/usr/bin/basenc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "basenc invocation" (`info '(coreutils) basenc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/basenc-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), basenc, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/basenc.html. RFC 4648 sections 4 to 8; ZeroMQ spec 32/Z85. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_basenc.sh`).
See docs/compatibility/basenc.md for details.

LIMITATIONS
- `--version` prints `basenc (core-utils) 0.0.0-dev`; `--help` is shorter than GNU's.
- Block sizes for partial output on malformed large inputs follow what was observed on GNU 9.7 for small inputs; inputs much larger than 64 KiB with errors in the middle are not tested.

SEE ALSO
docs/compatibility/basenc.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
