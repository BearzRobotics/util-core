# logname: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU logname 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/logname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "logname invocation" (`info '(coreutils) logname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/logname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), logname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/logname.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_logname.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Reads /proc/self/loginuid, maps it to a name through /etc/passwd, and otherwise prints `logname: no login name` (exit 1), which is what glibc's getlogin() does first.

## Known deviations and gaps

- The utmp fallback of getlogin() is not implemented, so a login known only to utmp is reported as `no login name`.

## Tests

test/test_logname.sh compared with GNU logname 9.7 (the result depends on the login session of the test run).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
