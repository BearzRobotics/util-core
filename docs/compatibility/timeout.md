# timeout: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU timeout 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/timeout --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "timeout invocation" (`info '(coreutils) timeout invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), timeout, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/timeout.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_timeout.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-f, --foreground`: Do not create a process group; only the command receives the signal.
- `-k, --kill-after=DURATION`: Send KILL this long after the first signal.
- `-p, --preserve-status`: Exit with the command's status even on timeout.
- `-s, --signal=SIGNAL`: Signal to send (default TERM).
- `-v, --verbose`: Diagnose signals sent.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- DURATION is a number with an optional s, m, h or d suffix; 0 disables the limit.
- The command is started with std.process.spawn; timeout waits on a pidfd and a signalfd with a poll timeout (src/sys.zig `Watcher`), so no signal handler is installed. TERM, INT, HUP and QUIT sent to timeout are forwarded.
- Like GNU, timeout ignores SIGTTIN and SIGTTOU, so a command that reads the terminal from timeout's background process group is stopped while timeout keeps running and enforces the limit. The command starts with the default actions of both. After each signal it sends or forwards (other than KILL), timeout sends CONT to the command and, without `--foreground`, to its group.
- If the command dies from a signal that timeout did not send, timeout kills itself with the same signal, like GNU.

## Library

Module `util_core.timeout` (src/lib/timeout.zig); `src/commands/timeout.zig` is the argument parser and diagnostics wrapper (decision 0004); the process-wide actions (descriptor, signal, niceness, chroot, chdir changes and the exec) stay in the wrapper.

## Extensions

None. Output, diagnostics and exit status follow GNU (decision 0005).

## Known deviations and gaps

- Requires Linux 5.3+ (pidfd_open).
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_timeout.sh`: 69 cases: differential tests against GNU timeout 9.7 in the C locale, and pty cases (python3) for a command that reads the terminal.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
