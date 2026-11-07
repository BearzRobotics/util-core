# nproc: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU nproc 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/nproc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nproc invocation" (`info '(coreutils) nproc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nproc-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nproc.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--all`: Count installed processors (the cpuN entries of /sys/devices/system/cpu).
- `--ignore=N`: Leave out N processors, but never print less than 1.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The default counts the CPUs the process may run on (`sched_getaffinity`), limited by `OMP_NUM_THREADS` (first comma-separated item) and `OMP_THREAD_LIMIT`, as GNU does.

## Known deviations and gaps

- `--all` counts directories under /sys/devices/system/cpu; GNU asks the C library for the configured processors, which gives the same answer on Linux.

## Tests

test/test_nproc.sh (options, 11x3 OpenMP variable combinations, errors) compared with GNU nproc 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
