# install: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU install 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/install --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "install invocation" (`info '(coreutils) install invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/install-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), install, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/install.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_install.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --backup[=CONTROL], -S`: Backups.
- `-c`: Ignored.
- `-C, --compare`: Do not modify a destination that already matches.
- `-d, --directory, -D`: Create directories (with all parents).
- `-g, -o, -m`: Group, owner and mode.
- `-p, -s, --strip-program=PROGRAM`: Preserve timestamps; strip the installed file.
- `-t, -T, -v, --debug`: Destination handling and verbosity.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Files are copied with the shared engine (destination removed before opening, created `u+rw`) and then given the requested owner and mode; `install` runs with umask 0 so modes are exact.
- `-d` creates missing parents with mode 0755 and the final directory with the requested mode.

## Known deviations and gaps

- Only the C locale; SELinux options are accepted and ignored.
- `-o`/`-g` can only name the caller's own ids unless run as root.

## Tests

`sh test/test_install.sh`: about 400 differential cases against GNU install 9.7 (C locale), run without privileges.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
