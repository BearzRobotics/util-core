# uniq: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU uniq 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/uniq --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "uniq invocation" (`info '(coreutils) uniq invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/uniq-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), uniq, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/uniq.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_uniq.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, --count`: Prefix each output line with its repeat count (width 7).
- `-d, --repeated`: Print only repeated lines, one per group.
- `-D, --all-repeated[=METHOD]`: Print all lines of repeated groups; METHOD is none, prepend or separate.
- `--group[=METHOD]`: Print all lines, delimiting groups: separate (default), prepend, append or both.
- `-u, --unique`: Print only lines that are not repeated.
- `-i, --ignore-case`: Ignore ASCII case when comparing.
- `-f, --skip-fields=N`: Skip N blank-delimited fields before comparing; `-N` is the traditional spelling.
- `-s, --skip-chars=N`: Skip N characters (bytes) after the skipped fields.
- `-w, --check-chars=N`: Compare at most N characters.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Option combinations (-c with -d/-u, -D with -u, --group with the others) follow GNU, including the error messages.
- An OUTPUT operand writes to that file (`-` is standard output). The last line always gets a terminator.

## Known deviations and gaps

- Comparison is bytewise (C locale); LC_COLLATE and multibyte characters are not used; -i folds ASCII only.
- The traditional `+N` option is not recognised (it is a file name, GNU's default).
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_uniq.sh (stdout, normalised stderr and exit status compared with GNU uniq 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
