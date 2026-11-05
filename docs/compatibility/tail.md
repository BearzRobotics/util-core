# tail: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU tail 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/tail --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tail invocation" (`info '(coreutils) tail invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tail-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tail, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tail.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_tail.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, --bytes=[+]NUM`: Output the last NUM bytes; with `+`, start at byte NUM.
- `-n, --lines=[+]NUM`: Output the last NUM lines (default 10); with `+`, start at line NUM.
- `-f, --follow[=descriptor]`: Keep reading data appended to regular files (polling).
- `-s, --sleep-interval=N`: With -f, seconds between polls (default 1).
- `--pid=PID`: With -f, stop after process PID has exited.
- `-q, --quiet, --silent`: Never print file name headers.
- `-v, --verbose`: Always print file name headers.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `-F, --follow=name, --retry, --max-unchanged-stats`: NOT IMPLEMENTED: rejected with an error.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Named regular files are read backwards from the end; pipes and standard input are streamed while keeping only the last N items.
- `+NUM` starts at item NUM (POSIX origin 1). NUM suffixes as in head.
- Obsolete `-NUM[bcl][f]` as the first argument; other letters are rejected like GNU (`option used in invalid context`).
- -f polls the file size; a shrinking file prints `FILE: file truncated` and is re-read from the start; with several files a header is printed whenever the source changes.

## Known deviations and gaps

- Not implemented: -F, --follow=name, --retry, --max-unchanged-stats (rejected with an error).
- -f is polling only (no inotify); it follows regular files only, whereas GNU also follows FIFOs. -f is ignored for pipes on standard input, as in the manual.
- The obsolete `tail +5` form is treated as a file name (GNU's default since POSIX 2001); POSIX `-r` is not supported (GNU has none).
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_tail.sh (stdout, normalised stderr, exit status compared with GNU tail 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
