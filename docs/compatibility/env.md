# env: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU env 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/env --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "env invocation" (`info '(coreutils) env invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/env-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), env, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/env.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_env.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-i, --ignore-environment, -`: Start with an empty environment.
- `-0, --null`: End each printed variable with NUL (not allowed with a command).
- `-u, --unset=NAME`: Remove NAME from the environment.
- `-C, --chdir=DIR`: Change directory before running COMMAND (only the last -C counts).
- `-a, --argv0=ARG`: Pass ARG as COMMAND's argv[0].
- `-S, --split-string=S`: Split S into arguments (quotes, escapes, ${VAR}, comments) and re-parse.
- `-v, --debug`: Trace each step on standard error.
- `--block-signal[=SIG], --default-signal[=SIG], --ignore-signal[=SIG]`: Change the signal disposition inherited by COMMAND; without SIG every signal.
- `--list-signal-handling`: Print non-default signal dispositions to standard error.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- COMMAND is searched for in the PATH of the *modified* environment, as GNU does with execvp (src/exec.zig).
- Exit status: 125 env failed, 126 command found but not runnable, 127 not found, otherwise the command's status.

## Known deviations and gaps

- `NAME=VALUE` with an empty NAME is ignored (the environment map cannot hold it); GNU stores it.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_env.sh`: 105 differential cases against GNU env 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
