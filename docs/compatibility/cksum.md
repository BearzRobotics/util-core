# cksum: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU cksum 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/cksum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "cksum invocation" (`info '(coreutils) cksum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cksum-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cksum, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cksum.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cksum.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --algorithm=TYPE`: `crc` (default, POSIX), `crc32b`, `sysv`, `bsd`, `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `blake2b`, `sm3`.
- `--tag, --untagged`: Tagged (default for digests) or untagged output; the last one given wins.
- `--base64`: Base64 digests.
- `--raw`: Write only the raw big-endian digest or number, for a single input.
- `-l, --length=BITS`: BLAKE2b digest length (see b2sum).
- `-c, --check, --ignore-missing, --quiet, --status, --strict, -w/--warn`: Verify digest lists; the algorithm is detected from tagged lines, and untagged lines need `-a`.
- `-z, --zero`: NUL-terminated lines.
- `-b, -t`: Accepted for compatibility; `-t` requires `--untagged` as in GNU.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The default prints `CRC BYTES [NAME]` using the POSIX CRC (polynomial 0x04C11DB7, length appended, complemented); `crc32b` is the zlib CRC-32.
- `sysv` and `bsd` print the `sum` formats; they cannot be verified with `-c`.
- SM3 (GB/T 32905-2016) and BLAKE2b are implemented in src/hash.zig; MD5, SHA-1 and SHA-2 come from std.crypto.

## Known deviations and gaps

- `--debug` is accepted and prints nothing (GNU reports which CPU-accelerated implementation it chose).
- `--version` prints `cksum (core-utils) 0.0.0-dev`.

## Tests

test/test_cksum.sh (556 cases: every algorithm on boundary-sized inputs, tag/untagged/base64/raw/length/zero combinations, check mode with auto-detected algorithms, error paths) compared with GNU cksum 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
