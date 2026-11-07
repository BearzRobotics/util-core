# od: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU od 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/od --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "od invocation" (`info '(coreutils) od invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/od-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), od, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/od.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_od.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-A, --address-radix=RADIX`: Address radix d, o, x or n.
- `-j, --skip-bytes=BYTES / -N, --read-bytes=BYTES`: Skip / limit input (decimal, 0x hex, 0 octal, b/KB/K... suffixes).
- `-t, --format=TYPE`: a c d o u x f with sizes; z suffix appends the printable text; several -t allowed.
- `-a -b -c -d -f -i -l -o -s -x`: Traditional single-letter formats.
- `-v, --output-duplicates`: No `*` for repeated lines.
- `-w[BYTES], --width`: Bytes per line (default 16, 32 without argument).
- `-S, --strings[=BYTES]`: Print NUL-terminated strings.
- `--endian=big|little`: Byte order of multi-byte elements.
- `--traditional`: OFFSET and LABEL operands.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Columns of all formats are aligned to the widest, repeated full lines become `*`, and the last block is zero-padded like GNU.
- Floating point is printed as the shortest decimal that reads back (precision tried from 6/15/18 digits), as GNU's ftoastr does; half and bfloat16 go through float.
- The old `[FILE] [OFFSET]` operand form is accepted only without the newer options (-A -j -N -S -t -v -w), as in GNU 9.7.

## Known deviations and gaps

- x87 pseudo-denormal encodings (exponent 0, integer bit 1, non-zero fraction) are printed differently from glibc.
- `-w0` aborts GNU od; here it is an error.
- Multibyte characters are not interpreted.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_od.sh`: 560 differential cases against GNU od 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
