# split: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU split 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/split --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "split invocation" (`info '(coreutils) split invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/split-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), split, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/split.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_split.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-l, --lines=N, -N`: Lines per output file.
- `-b, --bytes=SIZE`: Bytes per output file.
- `-C, --line-bytes=SIZE`: At most SIZE bytes of whole records per file.
- `-n, --number=CHUNKS`: N, K/N, l/N, l/K/N, r/N, r/K/N.
- `-a, --suffix-length=N`: Suffix length (0 = automatic).
- `-d, -x, --numeric-suffixes[=FROM], --hex-suffixes[=FROM]`: Numeric or hex suffixes.
- `--additional-suffix=SUFFIX`: Append to every name.
- `-e, --elide-empty-files`: With -n, do not create empty files.
- `-t, --separator=SEP`: Record separator.
- `--filter=COMMAND`: Pipe each piece to `$SHELL -c COMMAND` with $FILE set.
- `-u, --unbuffered`: Write immediately (-n r/...).
- `--verbose`: Report each file created.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Without -a the suffix grows when exhausted in order-preserving fashion (x89 then x9000, xyz then xzaaa), as GNU does.
- The tests compare the names, modes and contents (cksum) of every output file.

## Known deviations and gaps

- `--hex-suffixes=FROM` is implemented as documented; GNU 9.7 itself produces garbage names (`xf:`, `xfC`...) for it, so it is not tested.
- With `-n l/N` or `r/N` where N exceeds the input size GNU keeps creating files until the suffixes run out; we stop at N.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_split.sh`: 215 differential cases against GNU split 9.7 in the C locale. Includes seeded random inputs and filters.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
