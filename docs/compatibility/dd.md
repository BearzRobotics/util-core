# dd: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU dd 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/dd --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "dd invocation" (`info '(coreutils) dd invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), dd, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dd.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_dd.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `if=FILE, of=FILE`: Input and output files.
- `bs=, ibs=, obs=, cbs=`: Block sizes (suffixes b c k K M G ... and `x` products).
- `count=, skip=, iseek=, seek=, oseek=`: Block counts and offsets.
- `conv=`: ascii, ebcdic, ibm, block, unblock, lcase, ucase, sparse, swab, sync, excl, nocreat, notrunc, noerror, fdatasync, fsync.
- `iflag=, oflag=`: append, direct, directory, dsync, sync, fullblock, nonblock, noatime, nocache, noctty, nofollow, count_bytes, skip_bytes, seek_bytes.
- `status=`: none, noxfer, progress.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Operand parsing, the copy loop (partial reads, `conv=sync`, `noerror`, `swab`, `block`/`unblock`), the character-set tables and the statistics lines follow dd.c; the transfer summary uses the same SI/IEC wording and rate arithmetic.
- Only `--help` and `--version` are options.

## Known deviations and gaps

- SIGUSR1 does not print statistics.
- `status=progress` prints at most one update per second and may skip it for very short copies.
- O_DIRECT alignment and posix_fadvise (`nocache`) are not handled.
- `iflag`/`oflag` flags that need an open file (`append`, `dsync`...) apply to files named with `if=`/`of=`; for standard streams only `fcntl` flags are set.

## Tests

`sh test/test_dd.sh`: 1055 differential cases against GNU dd 9.7 (C locale) with the timing line masked.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
