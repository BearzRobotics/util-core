# mkdir: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU mkdir 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/mkdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "mkdir invocation" (`info '(coreutils) mkdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mkdir, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkdir.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_mkdir.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-m, --mode=MODE`: Set the mode of each created directory (chmod syntax, relative to a=rwx; the umask applies only to clauses without who). Does not affect parents made by -p.
- `-p, --parents`: Create missing parents (mode: umask-modified rwx plus u+wx); existing directories are not an error.
- `-v, --verbose`: Print `mkdir: created directory 'X'` on standard output for each directory created.
- `-Z, --context[=CTX]`: Accepted and ignored (no SELinux/SMACK support).
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Modes: octal (0-7777) and symbolic (`u=rwx,g=rx,o=`, `a-x`, `g=u`, `u+s`, ...), implemented in src/mode.zig and checked against GNU mkdir -m for 25+ modes and three umasks.
- The directory is created with MODE & 0777 (masked further by the umask) and then chmod'ed to the exact mode, so it is never less restrictive than MODE (POSIX).
- Errors as GNU: `cannot create directory 'X': File exists / No such file or directory / Not a directory`. Processing continues after an error (exit 1).

## Known deviations and gaps

- GNU 9.7 creates `-m +t` (also `o+t`, `a+t`) as 1755; we create 1777. The rule behind GNU's result was not determined, so it is not emulated.
- The umask is read with umask(2) on Linux; elsewhere 022 is assumed.
- -Z / --context are ignored.
- Windows: mode bits are not meaningful; untested.

## Tests

test/test_mkdir.sh (stdout, normalised stderr, exit status and resulting file tree compared with GNU mkdir 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
