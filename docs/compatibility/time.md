# time: compatibility record

Status: implemented; differential tests against GNU time 1.9 pass (`sh test/test_time.sh`). Date: 2026-11-21

## Reference

GNU time 1.9 (`/usr/bin/time` on the development machine, Ubuntu package `time`; its `--version` prints no version number). Consulted 2026-11-21: its `--help` output and behaviour (run as a black box); the format letters are those of its help and manual. Where our text differs from GNU the sections below say so.

## Supported options

`-a --append`, `-f --format`, `-o --output`, `-p --portability`, `-q --quiet`, `-v --verbose`, `-h --help`, `-V --version`. The last of `-f -p -v` wins. `TIME` supplies the default format. Option parsing stops at the first operand.

## Behaviour checked against GNU

- Every format letter and the backslash escapes, including `?` for an unknown letter or a trailing `%` or `\`.
- The "Command exited with non-zero status N" and "Command terminated by signal N" lines (before the summary, to the report stream, off with `-q`).
- A command that cannot be run: "cannot run X: reason", then the summary, exit 127 (not found) or 126.
- Exit status 128+N for a command killed by signal N; `%x` prints 0 then.
- Missing program: "missing program to run" and exit 125.

Diagnostics start with the invoked name (`time:`), where GNU prints the path it was run by.

## Library

Module `util_core.time` (`src/lib/time.zig`): `run` measures one command, `writeFormat` expands a format, `bench` and `writeBench` implement the benchmark view. `src/commands/time.zig` is the wrapper. The facilities `std.Io` lacks are in `src/sys.zig`: `waitUsage` (wait4 with rusage; GetProcessTimes on Windows) and `Perf` (perf_event_open).

## Extensions (decision 0005)

All options below work only with `--bench`; none changes the GNU behaviour. They are listed in `--help` and the man page as "not in GNU time". The table layout, number formats, colours and the significance rule are copied from crap (its `src/main.zig` was read, 2026-11-21; its no-colour padding arithmetic only lines up when escape bytes are counted, so we lay out by visible column to give the coloured layout in both modes). The option names and the export shapes follow hyperfine 2.0.0 (its `--help` and output were observed, not its source). Hyperfine's `--output` is `--bench-output` here because GNU's `--output` is `-o`.

`--bench`, `--duration` (ms), `--runs`, `--min-runs`, `--max-runs`, `--warmup`, `--shell`, `--allow-failures`, `--setup`, `--prepare`, `--conclude`, `--cleanup`, `--parameter-list`, `--parameter-scan`, `--input`, `--bench-output`, `--env`, `--metrics`, `--export-json`, `--export-csv`, `--color`.

Compared with hyperfine 2.0.0 on `sleep 0.01` and `sleep 0.02` (30 runs): means within 0.5 ms (ours slightly higher), delta +91.6% against hyperfine's +95.3% (our 10.8 ms base against its 10.6 ms). Not implemented from hyperfine: `--style`, `--sort`, `--reference`, `--ignore-failure=CODES`, the markdown/asciidoc/orgmode exports, `--command-name`, `--show-output`, the outlier and slow-first-run warnings, and the progress bar.

## Known deviations and gaps

- SIGINT and SIGQUIT are not ignored while waiting, so Ctrl-C reaches both time and the command.
- `%X %D %K %p %t` are 0; Linux does not report them.
- Perf counters are enabled around spawn and wait in time itself (inherited by the command), not from the child's exec, so a little start-up work is counted.
- Benchmark runs are not shuffled; counters are measured from the command's exec (group leader with `enable_on_exec`, as crap does).
- No progress bar while sampling (crap draws one on a terminal).
- Windows: user and kernel time, peak working set and page faults only; compile-checked, not yet run on a real console. macOS: compile-checked only.
