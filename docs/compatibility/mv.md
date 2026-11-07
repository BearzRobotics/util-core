# mv: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU mv 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/mv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mv invocation" (`info '(coreutils) mv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mv, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mv.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mv.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --backup[=CONTROL], -S, --suffix`: Backups.
- `-f, -i, -n, -u, --update[=WHEN]`: Overwrite policy.
- `-t, -T, --strip-trailing-slashes, -v, --debug`: Destination handling and verbosity.
- `--no-copy`: Fail instead of copying across file systems.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- `rename(2)` is tried first (RENAME_NOREPLACE); when the destination exists or the move crosses file systems the shared copy engine of cp copies the tree with attributes preserved and removes the source (`removed 'x'` is shown with -v).

## Known deviations and gaps

- `--exchange` is not implemented.
- Only the C locale: names, quotes and messages are the English/ASCII ones.
- SELinux contexts, ACLs and extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored).

## Tests

`sh test/test_mv.sh`: about 380 differential cases against GNU mv 9.7 (C locale). Moves across file systems are exercised by hand only, since the test directories share one file system.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
