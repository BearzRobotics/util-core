# rmdir: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU rmdir 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/rmdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "rmdir invocation" (`info '(coreutils) rmdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/rmdir-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), rmdir, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/rmdir.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_rmdir.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-p, --parents`: Remove DIRECTORY, then each ancestor in turn, stopping at the first that cannot be removed.
- `-v, --verbose`: Print `rmdir: removing directory, 'X'` on standard output before each removal.
- `--ignore-fail-on-non-empty`: Do not report or count failures caused by a non-empty directory.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- `rmdir -p a/b/c` removes c, b, a; `./a/b` also tries `.`, which the OS refuses (`Invalid argument`), exactly as GNU prints.
- Trailing slashes are accepted. Failing parents are reported as `failed to remove directory 'X': ...`.

## Known deviations and gaps

- `rmdir .` is refused by our code before calling the OS (the standard library treats EINVAL from rmdir as a programmer bug and panics); the message matches GNU's.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_rmdir.sh (stdout, normalised stderr, exit status and resulting file tree compared with GNU rmdir 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
