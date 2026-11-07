# stdbuf: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU stdbuf 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/stdbuf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "stdbuf invocation" (`info '(coreutils) stdbuf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), stdbuf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stdbuf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_stdbuf.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-i, --input=MODE`: Buffering of standard input (not L).
- `-o, --output=MODE`: Buffering of standard output.
- `-e, --error=MODE`: Buffering of standard error.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- MODE is L (line buffered), 0 (unbuffered) or a size with the usual suffixes.
- Sets _STDBUF_I/O/E and appends libstdbuf.so to LD_PRELOAD, exactly as GNU does.

## Known deviations and gaps

- We do not ship libstdbuf.so: the one installed by GNU coreutils (/usr/libexec/coreutils/libstdbuf.so) is used and stdbuf fails with "failed to find libstdbuf.so" if absent.
- Like GNU, statically linked programs and programs that do not use C stdio are unaffected.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_stdbuf.sh`: 53 differential cases against GNU stdbuf 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
