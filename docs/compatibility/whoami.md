# whoami: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU whoami 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/whoami --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "whoami invocation" (`info '(coreutils) whoami invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/whoami-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_whoami.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Looks up the effective user ID in /etc/passwd; reports `cannot find name for user ID N` when absent.

## Known deviations and gaps

- Only /etc/passwd is consulted (no NSS), so users known only to LDAP or similar are not found.

## Tests

test/test_whoami.sh compared with GNU whoami 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
