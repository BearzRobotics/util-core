# b2sum: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU b2sum 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/b2sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "b2sum invocation" (`info '(coreutils) b2sum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/b2sum-invocation.html). POSIX does not specify this utility. Digest: RFC 7693. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_b2sum.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --binary`: Mark each input as binary in the output (` *`); the digest is unaffected.
- `-t, --text`: Text mode (default; ` ` flag).
- `-c, --check`: Read checksums from the FILEs and verify the files they name (untagged, tagged, and BSD-reversed lines; backslash-escaped names).
- `--tag`: BSD-style output `TAG (NAME) = DIGEST`; implies binary mode.
- `-z, --zero`: End lines with NUL and do not escape file names.
- `--ignore-missing, --quiet, --status, --strict, -w/--warn`: Check-mode controls, as GNU.
- `-l, --length=BITS`: Digest length in bits, a multiple of 8; 0 or more than 512 means 512. Shortened digests are tagged `BLAKE2b-BITS`.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- BLAKE2b per RFC 7693 implemented in src/hash.zig with a run-time digest length (std.crypto only offers compile-time lengths); the length goes into the parameter block, so a 128-bit digest is not a truncation of the 512-bit one.
- Same output, escaping and check-mode behaviour as the other checksum tools; when checking, the digest length is taken from the line.

## Known deviations and gaps

- `--version` prints `NAME (util-core) 0.0.0-dev`; `--help` is shorter than GNU's and names the tool as invoked.
- Digest hex is compared case-insensitively; GNU also accepts upper-case hex.
- Keyed hashing and the other BLAKE2 parameters are not offered (neither does GNU b2sum).

## Tests

test/test_b2sum.sh (116 cases from test/hashtests.sh) compared with GNU b2sum 9.7 under LC_ALL=C; test/test_cksum.sh covers `-a blake2b -l N` for N = 0 to 1024.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
