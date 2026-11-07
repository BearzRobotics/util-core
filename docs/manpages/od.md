% OD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
od - dump files in octal and other formats

SYNOPSIS
od [OPTION]... [FILE]...
od --help | --version

DESCRIPTION
Dump files in octal and other formats.

OPTIONS
-A, --address-radix=RADIX
: Address radix d, o, x or n.

-j, --skip-bytes=BYTES / -N, --read-bytes=BYTES
: Skip / limit input (decimal, 0x hex, 0 octal, b/KB/K... suffixes).

-t, --format=TYPE
: a c d o u x f with sizes; z suffix appends the printable text; several -t allowed.

-a -b -c -d -f -i -l -o -s -x
: Traditional single-letter formats.

-v, --output-duplicates
: No `*` for repeated lines.

-w[BYTES], --width
: Bytes per line (default 16, 32 without argument).

-S, --strings[=BYTES]
: Print NUL-terminated strings.

--endian=big|little
: Byte order of multi-byte elements.

--traditional
: OFFSET and LABEL operands.

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
Reference: GNU coreutils 9.7 (`/usr/bin/od --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "od invocation" (`info '(coreutils) od invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/od-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), od, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/od.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_od.sh`).
See docs/compatibility/od.md for details.

LIMITATIONS
- x87 pseudo-denormal encodings (exponent 0, integer bit 1, non-zero fraction) are printed differently from glibc.
- `-w0` aborts GNU od; here it is an error.
- Multibyte characters are not interpreted.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/od.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
