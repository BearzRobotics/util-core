# sha384sum: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU sha384sum 9.7 in the C locale. Date: 2026-11-07

Library: `util_core.sha384sum` (src/lib/sha384sum.zig), a thin preset of the shared module src/lib/hashsum.zig (`util_core.hashsum`); `src/commands/sha384sum.zig` and src/hashsum.zig are the argument parser and diagnostics only.

## Reference

GNU coreutils 9.7 (`/usr/bin/sha384sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sha2 utilities invocation" (`info '(coreutils) sha2 utilities invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sha2 utilities-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sha384sum.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --binary`: Mark each input as binary in the output (` *`); the digest is unaffected.
- `-t, --text`: Text mode (default; ` ` flag).
- `-c, --check`: Read checksums from the FILEs and verify the files they name (untagged, tagged, and BSD-reversed lines; backslash-escaped names).
- `--tag`: BSD-style output `TAG (NAME) = DIGEST`; implies binary mode.
- `-z, --zero`: End lines with NUL and do not escape file names.
- `--ignore-missing, --quiet, --status, --strict, -w/--warn`: Check-mode controls, as GNU.
- `--help, --version`: Print help or version and exit.
- `--json` (extension, not in GNU): one JSON object per input, one per line: `file` (null for standard input read without an operand), `algorithm`, `digest` (lowercase hex; null for the numeric algorithms), `checksum` (the number for crc, crc32b, bsd and sysv; null for digests), `size` (bytes, for crc, crc32b, bsd and sysv; null otherwise) and `blocks` (bsd and sysv). Cannot be combined with `--check`, `--raw`, `--base64`, `--tag`, `--untagged` or `--zero`. Not listed in `--help`. Rules: `docs/decisions/0003-json-output.md`.

## Supported behaviour

- Digest: SHA-384 (FIPS 180-4), from std.crypto; one shared implementation (src/hashsum.zig) serves every checksum tool.
- Output `DIGEST<space><mode>NAME`, or tagged with `--tag`; a name containing backslash, newline or carriage return is escaped and the line starts with a backslash (not with `-z`).
- Check mode prints `NAME: OK`, `NAME: FAILED` or `NAME: FAILED open or read`, then the same `WARNING:` summaries as GNU (computed checksums that did not match, files that could not be read, improperly formatted lines), and exits 1 on any failure; `--strict` also fails on improper lines.
- File names in diagnostics are quoted as GNU `quotef` does (`cli.quote`).
- `-` or no operand reads standard input.

## Extensions

- `--json` (decision 0003, form 2 of decision 0005): one JSON object per input. Why: the checksum as data for programs. Off by default; only an explicit `--json` changes output, and GNU invocations are unaffected. Covered by `test/test_hashsum_json.sh`, which also checks the refused combinations.

## Known deviations and gaps

- `--version` prints `NAME (util-core) 0.0.0-dev`; `--help` is shorter than GNU's and names the tool as invoked.
- Digest hex is compared case-insensitively; GNU also accepts upper-case hex.

## Tests

test/test_sha384sum.sh (116 cases from test/hashtests.sh: every block-size boundary up to 64 KiB plus 1 MB, escaping, all option errors, every check-mode path) compared with GNU sha384sum 9.7 under LC_ALL=C (stdout, normalised stderr, exit status).

`sh test/test_hashsum_json.sh`: 69 checks of `--json` for md5sum, sha1sum, sha224sum, sha256sum, sha384sum, sha512sum, b2sum (including `-l 256`) and every cksum algorithm, against the digest or number GNU prints for the same input, plus stdin, several files, errors and the refused combinations. One script covers all of these tools.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
