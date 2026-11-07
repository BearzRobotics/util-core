# groups: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU groups 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/groups --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "groups invocation" (`info '(coreutils) groups invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/groups-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_groups.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- No operand: the current process's groups (`id -Gn`); with names each line is `NAME : group ...`.

## Known deviations and gaps

- Only /etc/passwd and /etc/group are consulted.

## Tests

test/test_groups.sh compared with GNU groups 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
