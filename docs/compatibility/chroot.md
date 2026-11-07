# chroot: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU chroot 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/chroot --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chroot invocation" (`info '(coreutils) chroot invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chroot-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chroot, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chroot.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chroot.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--skip-chdir`: Do not change directory to / (only allowed when NEWROOT is /).
- `--userspec=USER[:GROUP], --groups=G,...`: Accepted, but exit with status 125: not supported.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- chroot(2), then chdir("/"), then exec COMMAND (default `$SHELL -i`).

## Known deviations and gaps

- `--userspec` and `--groups` are not implemented.
- Needs CAP_SYS_CHROOT. The privileged path (running a command inside the new root) was not exercised on the development machine, which has no root access; the tests compare diagnostics as an unprivileged user.
- GNU installs `chroot` in /usr/sbin; the test harness uses that directory as the oracle.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_chroot.sh`: 12 differential cases against GNU chroot 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
