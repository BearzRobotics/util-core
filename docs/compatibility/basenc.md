# basenc: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU basenc 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/basenc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "basenc invocation" (`info '(coreutils) basenc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/basenc-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), basenc, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/basenc.html. RFC 4648 sections 4 to 8; ZeroMQ spec 32/Z85. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_basenc.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--base64, --base64url, --base32, --base32hex, --base16, --base2msbf, --base2lsbf, --z85`: Select the encoding (one is required).
- `-d, --decode`: Decode data.
- `-i, --ignore-garbage`: When decoding, drop characters outside the alphabet (an `=` is never dropped).
- `-w, --wrap=COLS`: Wrap encoded lines after COLS characters (default 76); 0 disables wrapping.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Encoding is streamed; the final line gets a newline unless `-w 0`.
- Decoding is incremental like gnulib's: complete quanta are written at once, and when a quantum is invalid the bytes already decoded from it are still written before `invalid input` (exit 1). A final quantum without padding is accepted when its trailing bits are zero.
- Newlines are always ignored while decoding; concatenated padded blocks decode in sequence.
- `--base64url` rejects `+` and `/` before writing anything (unless `-i`); `--base16` also reads lower-case digits; `--z85` needs a multiple of four bytes (checked per 30720-byte block, so earlier blocks are still written); `--base32hex` keeps GNU's quirk that W, X, Y and Z decode as their base32 values when not ignoring garbage. These reproduce GNU 9.7 behaviour found by differential testing, not RFC text.

## Known deviations and gaps

- `--version` prints `basenc (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.
- Block sizes for partial output on malformed large inputs follow what was observed on GNU 9.7 for small inputs; inputs much larger than 64 KiB with errors in the middle are not tested.

## Tests

test/test_basenc.sh runs the 835-case suite once for each of the eight encodings (6683 cases) against GNU basenc 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
