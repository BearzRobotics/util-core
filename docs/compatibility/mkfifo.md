# mkfifo: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU mkfifo 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/mkfifo --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mkfifo invocation" (`info '(coreutils) mkfifo invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mkfifo-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mkfifo, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkfifo.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mkfifo.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-m, --mode=MODE`: Set the permissions (chmod syntax, relative to a=rw); applied after creation so the umask does not remove bits.
- `-Z, --context[=CTX]`: Accepted; with a CTX a warning says SELinux is unavailable.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- mknodat(2) with S_IFIFO; modes above 0777 are rejected like GNU.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_mkfifo.sh`: 84 differential cases against GNU mkfifo 9.7 in the C locale. Each case compares the resulting tree (names, types, modes).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
