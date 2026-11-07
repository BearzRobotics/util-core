# vdir: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU vdir 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/vdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "vdir invocation" (`info '(coreutils) vdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/vdir-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_vdir.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `(all ls options)`: Same as `ls`; `ls -l -b`: long listing with C-style escapes.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- `ls -l -b`: long listing with C-style escapes. Everything else is shared with `ls` (see docs/compatibility/ls.md).

## Known deviations and gaps

- Same as `ls`.

## Tests

`sh test/test_ls.sh` compares `dir` and `vdir` with the GNU programs for the common option sets.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
