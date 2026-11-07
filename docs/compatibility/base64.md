# base64: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU base64 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/base64 --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "base64 invocation" (`info '(coreutils) base64 invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/base64-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), base64, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/base64.html. RFC 4648 section 4. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_base64.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-d, --decode`: Decode data.
- `-i, --ignore-garbage`: When decoding, drop characters outside the alphabet (an `=` is never dropped).
- `-w, --wrap=COLS`: Wrap encoded lines after COLS characters (default 76); 0 disables wrapping.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Encoding is streamed; the final line gets a newline unless `-w 0`.
- Decoding is incremental like gnulib's: complete quanta are written at once, and when a quantum is invalid the bytes already decoded from it are still written before `invalid input` (exit 1). A final quantum without padding is accepted when its trailing bits are zero.
- Newlines are always ignored while decoding; concatenated padded blocks decode in sequence.

## Known deviations and gaps

- `--version` prints `base64 (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.
- A directory operand prints `read error: Is a directory` as GNU does.

## Tests

test/test_base64.sh (835 cases from test/basetests.sh: all lengths 0 to 17 and around 76, 4096 and 65536, every wrap size, round trips, ~100 malformed inputs and 240 seeded garbage inputs, each with and without -i) compared with GNU base64 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
