# users: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU users 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/users --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "users invocation" (`info '(coreutils) users invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/users-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_users.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Reads Linux utmp records (384 bytes, type 7 = user process; name at offset 44, 32 bytes) from FILE or /var/run/utmp, sorted and space-separated.
- A missing or unreadable file prints nothing and succeeds, as GNU 9.7 does.

## Known deviations and gaps

- GNU 9.7 is built with systemd and falls back to systemd-logind sessions when /var/run/utmp is absent (as on this WSL machine, where it prints the session user). logind's session files are private data and are not read, so without a utmp file this prints nothing.

## Tests

test/test_users.sh (hand-made utmp files: ordering, duplicates, non-user records, truncated and over-long records, bad files) compared with GNU users 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
