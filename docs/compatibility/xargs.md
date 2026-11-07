# xargs: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU xargs 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU findutils xargs 4.10.0 (`/usr/bin/xargs --version` on the development machine). Consulted 2026-11-07: the findutils manual "xargs invocation"; POSIX.1-2024 xargs, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/xargs.html. Behaviour was checked by differential tests against the installed binary run with LC_ALL=C (`sh test/test_xargs.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-0, --null, -d, --delimiter=DELIM`: Items end with NUL or the given character; no quote or backslash processing.
- `-a, --arg-file=FILE`: Read items from FILE instead of standard input.
- `-E EOF-STR, -e[EOF-STR], --eof[=EOF-STR]`: Logical end-of-file string.
- `-I R, -i[R], --replace[=R]`: Replace R in the initial arguments with each input line (one command per item).
- `-L N, -l[N], --max-lines[=N]`: At most N non-blank input lines per command.
- `-n N, --max-args=N, -s N, --max-chars=N, -x, --exit`: Limits on the argument count and command length.
- `-P N, --max-procs=N, --process-slot-var=VAR`: Run several commands at once; the slot number is exported in VAR.
- `-p, --interactive, -t, --verbose, -o, --open-tty`: Prompting (needs /dev/tty), tracing, and reading the child's input from the terminal.
- `-r, --no-run-if-empty, --show-limits`: Skip an empty run; print the size limits.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The input grammar follows xargs: blanks and newlines separate items, single/double quotes and backslashes quote, a line ending in a blank continues under -L, an unmatched quote fails with GNU's message after running the complete commands already collected (not under -L).
- A NUL byte in the input is kept in the item and cuts the argument that contains it, after one warning, as GNU does.
- Exit status: 0 on success, 123 when a command exited with 1-125, 124 when one exited with 255 (xargs stops), 125 when one was killed by a signal, 126/127 when it could not be run, 1 for xargs's own errors.
- Conflicting -I/-L/-n options warn and the later one wins; `--show-limits` follows the arithmetic of ARG_MAX, the environment size and the 128 KiB buffer.

## Known deviations and gaps

- -x combined with an argument that cannot fit differs from GNU in some edge cases (the exact point at which GNU aborts is not reproduced).
- -P runs commands concurrently but reaps them in start order, so a failing later command is reported after earlier ones finish.
- -p and -o need a controlling terminal, which the test suite does not have; the error path is checked only by hand.

## Tests

`sh test/test_xargs.sh`: 670 differential cases against GNU findutils xargs 4.10 (C locale), including `--show-limits` under an empty environment.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
