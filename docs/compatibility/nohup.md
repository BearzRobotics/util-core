# nohup: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU nohup 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/nohup --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nohup invocation" (`info '(coreutils) nohup invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nohup-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), nohup, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/nohup.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nohup.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options


- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Ignores SIGHUP. A terminal on standard input is replaced by /dev/null opened write-only; a terminal on standard output is appended to ./nohup.out (mode 0600) or $HOME/nohup.out; a terminal on standard error is sent to standard output. The notices GNU prints are reproduced.
- Only a sole `--help`/`--version` is special; the first operand starts the command.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_nohup.sh`: 28 differential cases against GNU nohup 9.7 in the C locale. Terminal cases run under script(1) on a pty.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
