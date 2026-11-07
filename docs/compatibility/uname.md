# uname: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU uname 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/uname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "uname invocation" (`info '(coreutils) uname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/uname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), uname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/uname.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_uname.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --all`: All of the following, in this order.
- `-s, --kernel-name`: Kernel name.
- `-n, --nodename`: Network node host name.
- `-r, --kernel-release`: Kernel release.
- `-v, --kernel-version`: Kernel version.
- `-m, --machine`: Machine hardware name.
- `-p, --processor`: Processor type; the machine name here, as GNU 9.7 prints on this platform.
- `-i, --hardware-platform`: Hardware platform; the machine name.
- `-o, --operating-system`: `GNU/Linux`.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Values come from the `uname(2)` system call (src/sys.zig); with no option `-s` is assumed.
- Long options may be abbreviated; an ambiguous abbreviation lists the candidates like glibc getopt.

## Known deviations and gaps

- `-p`/`-i` always print the machine name; GNU prints `unknown` and omits them from `-a` on systems that cannot tell, which does not occur on Linux/x86_64.

## Tests

test/test_uname.sh (every option and many combinations, abbreviations, errors) compared with GNU uname 9.7 under LC_ALL=C on the same machine.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
