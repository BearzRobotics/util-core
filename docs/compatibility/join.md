# join: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU join 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/join --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "join invocation" (`info '(coreutils) join invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/join-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), join, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/join.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_join.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-1 FIELD, -2 FIELD, -j FIELD`: Join field of file 1, of file 2, or of both (`-j1 N`/`-j2 N` obsolete forms accepted).
- `-a FILENUM, -v FILENUM`: Also print unpairable lines of that file / print only those (no joined lines).
- `-e STRING`: Replace empty or missing output fields with STRING.
- `-o FORMAT`: Output list (`0`, `M.N`; `auto` infers it from the first lines).
- `-t CHAR`: Field separator (`-t ''` makes the whole line the field).
- `-i, --ignore-case`: Compare join fields ignoring ASCII case.
- `--header`: Treat the first line of each file as a header, joined and printed first.
- `--check-order, --nocheck-order`: Always / never diagnose unsorted input (default: only after an unpairable line was seen).
- `-z, --zero-terminated`: NUL-terminated lines.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Merge join on sorted input; equal keys on both sides give the cross product of their lines.
- Order diagnostics reproduce GNU's timing exactly (found by differential testing): each line is checked as it is read, only once an unpairable line has been recorded (the record is made after the advance that follows it), and a final `input is not in sorted order` ends the run with status 1.
- Default output is the join field, the remaining fields of file 1, then those of file 2, separated by one space (or the -t character).

## Known deviations and gaps

- Comparison is bytewise (C locale; -i folds ASCII only).
- `--version` prints `join (core-utils) 0.0.0-dev`; `--help` is shorter than GNU's.

## Tests

test/test_join.sh (374 cases: every option, -o formats, header, order checking on 120 tiny input pairs, errors, 12 seeded random file pairs under 14 option mixes) compared with GNU join 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
