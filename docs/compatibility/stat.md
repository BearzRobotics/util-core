# stat: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU stat 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/stat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "stat invocation" (`info '(coreutils) stat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/stat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), stat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stat.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_stat.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-L, --dereference`: Follow symbolic links.
- `-f, --file-system`: Show file system status.
- `-c, --format=FORMAT / --printf=FORMAT`: Custom format (--printf interprets backslash escapes and prints no trailing newline).
- `-t, --terse`: Terse form.
- `--cached=MODE`: Accepted (statx sync flags are not passed on).
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- File data comes from statx(2) (including birth time); `-f` uses statfs(2) with GNU's file-system type table.
- Directives, printf-style flags/width/precision, `%N` quoting (QUOTING_STYLE honoured when a format is given) and the `%X`-style fractional seconds follow GNU stat.c.

## Known deviations and gaps

- `%C` reads the `security.selinux` attribute; without it GNU's `failed to get security context` diagnostic is reproduced.
- `%m` walks up the directory tree looking for a device change; bind mounts are not resolved through the mount table.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_stat.sh`: 989 differential cases against GNU stat 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
