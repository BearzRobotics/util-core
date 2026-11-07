# pathchk: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU pathchk 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/pathchk --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "pathchk invocation" (`info '(coreutils) pathchk invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/pathchk-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), pathchk, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pathchk.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_pathchk.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-p`: Check the POSIX portable character set and the minimum limits (14 per component, 255 per name).
- `-P`: Reject empty names and components that start with `-`.
- `--portability`: Same as -p -P.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Without -p the name is examined with lstat; errors other than ENOENT are reported.
- Exit status 1 if any NAME fails.

## Known deviations and gaps

- Without -p the limits are the Linux defaults (NAME_MAX 255, PATH_MAX 4096); `pathconf` of the actual file system is not consulted.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_pathchk.sh`: 138 differential cases against GNU pathchk 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
