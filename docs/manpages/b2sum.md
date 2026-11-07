% B2SUM(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
b2sum - compute and check BLAKE2b message digests

SYNOPSIS
b2sum [-bctzw] [-l BITS] [--tag] [--quiet|--status|--strict|--ignore-missing] [FILE]...
b2sum --help | --version

DESCRIPTION
Compute and check BLAKE2b message digests.

OPTIONS
-b, --binary
: Mark each input as binary in the output (` *`); the digest is unaffected.

-t, --text
: Text mode (default; ` ` flag).

-c, --check
: Read checksums from the FILEs and verify the files they name (untagged, tagged, and BSD-reversed lines; backslash-escaped names).

--tag
: BSD-style output `TAG (NAME) = DIGEST`; implies binary mode.

-z, --zero
: End lines with NUL and do not escape file names.

--ignore-missing, --quiet, --status, --strict, -w/--warn
: Check-mode controls, as GNU.

-l, --length=BITS
: Digest length in bits, a multiple of 8; 0 or more than 512 means 512. Shortened digests are tagged `BLAKE2b-BITS`.

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
Reference: GNU coreutils 9.7 (`/usr/bin/b2sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "b2sum invocation" (`info '(coreutils) b2sum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/b2sum-invocation.html). POSIX does not specify this utility. Digest: RFC 7693. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_b2sum.sh`).
See docs/compatibility/b2sum.md for details.

LIMITATIONS
- `--version` prints `NAME (util-core) 0.0.0-dev`; `--help` is shorter than GNU's and names the tool as invoked.
- Digest hex is compared case-insensitively; GNU also accepts upper-case hex.
- Keyed hashing and the other BLAKE2 parameters are not offered (neither does GNU b2sum).

SEE ALSO
docs/compatibility/b2sum.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
