# link: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU link 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/link --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "link invocation" (`info '(coreutils) link invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/link-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), link, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/link.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_link.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Creates FILE2 as a hard link to FILE1 (no directory special-casing, no overwriting).

## Known deviations and gaps

- Error wording comes from the Zig error set, so rare errno values may print their Zig name.

## Tests

test/test_link.sh (15 cases) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
