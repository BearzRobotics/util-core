# hostid: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU hostid 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/hostid --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "hostid invocation" (`info '(coreutils) hostid invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/hostid-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_hostid.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Prints 8 hexadecimal digits: the content of /etc/hostid when present, otherwise the IPv4 address of the host name in /etc/hosts with its 16-bit halves swapped (glibc `gethostid`); 0 when neither is available.

## Known deviations and gaps

- Host names are resolved through /etc/hosts only, not DNS.

## Tests

test/test_hostid.sh compared with GNU hostid 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
