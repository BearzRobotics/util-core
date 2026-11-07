% MD5SUM(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
md5sum - compute and check MD5 message digests

SYNOPSIS
md5sum [-bctzw] [--tag] [--quiet|--status|--strict|--ignore-missing] [FILE]...
md5sum --help | --version

DESCRIPTION
Compute and check MD5 message digests.

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
Reference: GNU coreutils 9.7 (`/usr/bin/md5sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "md5sum invocation" (`info '(coreutils) md5sum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/md5sum-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_md5sum.sh`).
See docs/compatibility/md5sum.md for details.

LIMITATIONS
- `--version` prints `NAME (core-utils) 0.0.0-dev`; `--help` is shorter than GNU's and names the tool as invoked.
- Digest hex is compared case-insensitively; GNU also accepts upper-case hex.

SEE ALSO
docs/compatibility/md5sum.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
