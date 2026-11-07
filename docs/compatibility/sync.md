# sync: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU sync 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/sync --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sync invocation" (`info '(coreutils) sync invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sync-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), sync, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sync.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sync.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-d, --data`: fdatasync each FILE.
- `-f, --file-system`: syncfs the file system containing each FILE.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- With no FILE, sync(2); with FILEs, fsync each (or fdatasync/syncfs).
- `--data` needs at least one FILE and cannot be combined with `--file-system`.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_sync.sh`: 26 differential cases against GNU sync 9.7 in the C locale. Effects of syncing are not observable, so statuses and diagnostics are compared.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
