# unlink: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU unlink 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/unlink --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "unlink invocation" (`info '(coreutils) unlink invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/unlink-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), unlink, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/unlink.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_unlink.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Removes exactly one name; a directory is refused with the system's `Is a directory`.

## Known deviations and gaps

- None known.

## Tests

test/test_unlink.sh (16 cases) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
