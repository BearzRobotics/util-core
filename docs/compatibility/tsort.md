# tsort: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU tsort 9.7 in the C locale. Date: 2026-11-06

## Reference

GNU coreutils 9.7 (`/usr/bin/tsort --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "tsort invocation" (`info '(coreutils) tsort invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tsort-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tsort, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tsort.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tsort.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-w`: Exit status is the number of cycles found (at most 125). POSIX.1-2024; GNU 9.7 lacks it, so there is no GNU reference output for it.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Input is whitespace-separated pairs meaning "first before second"; equal items only register the node.
- Output order reproduces GNU: nodes with no predecessors seed a FIFO queue in byte order; successors are released in reverse insertion order.
- On a cycle: "input contains a loop:" and the nodes are printed to stderr, the closing edge is dropped, sorting resumes, exit status 1.

## Known deviations and gaps

- Which cycle GNU reports, and where it starts, follows GNU's internal tree walk. This implementation models it and matches on most small graphs and always on acyclic input, but identical diagnostics for every cyclic graph are not guaranteed.
- An odd number of tokens is rejected as in GNU.

## Tests

test/test_tsort.sh (stdout, normalised stderr and exit status compared with GNU tsort 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
