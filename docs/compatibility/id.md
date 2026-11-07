# id: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU id 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/id --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "id invocation" (`info '(coreutils) id invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/id-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), id, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/id.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_id.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-u, -g, -G`: Print only the effective user ID, group ID or all group IDs.
- `-n`: Names instead of numbers.
- `-r`: Real instead of effective IDs.
- `-z`: NUL-delimited output (not in the default format).
- `-a`: Ignored.
- `-Z, --context`: Reports that SELinux is not available.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Default format `uid=N(name) gid=N(name) groups=...`; the effective group is listed first, then the supplementary groups from `getgroups(2)` in kernel order. For a named user the groups are the primary group plus every group of /etc/group that lists the user (glibc `getgrouplist` order).
- A USER may be a name or an existing numeric ID; anything else is `'X': no such user` (exit 1).

## Known deviations and gaps

- Names come from /etc/passwd and /etc/group only (no NSS).
- SELinux contexts are not supported (`-Z` fails as on a kernel without SELinux).

## Tests

test/test_id.sh (every option mix, 16 user arguments including numeric and unknown ones) compared with GNU id 9.7 on the same machine.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
