% CKSUM(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
cksum - print or verify file checksums and CRCs

SYNOPSIS
cksum [-a ALGORITHM] [-l BITS] [--tag|--untagged] [--base64] [--raw] [-c] [FILE]...
cksum --help | --version

DESCRIPTION
Print or verify file checksums and CRCs.

OPTIONS
-a, --algorithm=TYPE
: `crc` (default, POSIX), `crc32b`, `sysv`, `bsd`, `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `blake2b`, `sm3`.

--tag, --untagged
: Tagged (default for digests) or untagged output; the last one given wins.

--base64
: Base64 digests.

--raw
: Write only the raw big-endian digest or number, for a single input.

-l, --length=BITS
: BLAKE2b digest length (see b2sum).

-c, --check, --ignore-missing, --quiet, --status, --strict, -w/--warn
: Verify digest lists; the algorithm is detected from tagged lines, and untagged lines need `-a`.

-z, --zero
: NUL-terminated lines.

-b, -t
: Accepted for compatibility; `-t` requires `--untagged` as in GNU.

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
Reference: GNU coreutils 9.7 (`/usr/bin/cksum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "cksum invocation" (`info '(coreutils) cksum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cksum-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cksum, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cksum.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cksum.sh`).
See docs/compatibility/cksum.md for details.

LIMITATIONS
- `--debug` is accepted and prints nothing (GNU reports which CPU-accelerated implementation it chose).
- `--version` prints `cksum (util-core) 0.0.0-dev`.

SEE ALSO
docs/compatibility/cksum.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
