# NAME

time - run a command and report the resources it used

# SYNOPSIS

    time [OPTION]... COMMAND [ARG]...
    time --bench [OPTION]... 'COMMAND LINE'...
    time --help | --version

# DESCRIPTION

Run COMMAND, wait for it, and print how long it took and what it used: user and system CPU time, elapsed time, maximum resident memory, page faults, context switches and block I/O. The report goes to standard error (or to a file with **-o**). The exit status is the command's own.

With **--bench** the program is a small benchmarking tool: every operand is a command line that is run many times with its output discarded, and the result is a table of mean and spread, range and outliers per measurement, with each later command compared against the first.

# OPTIONS

-a, --append
: With **-o**, append to the file instead of overwriting it.

-f, --format=FORMAT
: Use FORMAT instead of the default. See FORMAT below. The TIME environment variable supplies a format when **-f** is not given.

-o, --output=FILE
: Write the report to FILE instead of standard error.

-p, --portability
: Use the POSIX format: `real %e`, `user %U`, `sys %S`, one per line.

-q, --quiet
: Do not print the "Command exited with non-zero status" or "Command terminated by signal" line.

-v, --verbose
: Print every measurement, one per line.

-h, --help, -V, --version
: Print help or version and exit.

The last of **-f**, **-p** and **-v** wins. Option processing stops at the first operand.

# BENCHMARK OPTIONS

These are an extension; GNU time has none of them. They work only with **--bench** and are an error without it. The long names are hyperfine's where hyperfine has one, except **--bench-output** (hyperfine's `--output`; GNU's **--output** is **-o**). There are no short forms, so every GNU short option keeps its meaning.

--bench
: Run every operand, a command line (white space separates words; single and double quotes group them, a backslash escapes), repeatedly with its standard output discarded, and print one table per command. Cannot be combined with **-a -f -o -p -q -v**.

--duration=MS
: Keep sampling each command for MS milliseconds (default 5000), but at least the minimum number of runs.

--runs=N, --min-runs=N, --max-runs=N
: Run exactly N times; at least N times (default 3); at most N times (default 10000).

--warmup=N
: N unmeasured runs before sampling (default 0).

--shell=SHELL
: Run each command as `SHELL -c COMMAND` (`/C` on Windows). The hooks below always go through a shell: SHELL, or `sh` (`cmd` on Windows).

--allow-failures
: Compare commands that exit non-zero. Without it the first failing run stops the benchmark, printing the command's standard error (first 4 KiB) and exiting with 1. A command killed by a signal always stops it.

--setup=CMD, --prepare=CMD, --conclude=CMD, --cleanup=CMD
: Shell commands run around the measured command, outside the timing. `--setup` once before a command's runs; `--prepare` before every run, warm-ups included; `--conclude` after every run; `--cleanup` once after its runs (also after a failure). Give an option once to use it for every command, or once per command (after parameter expansion). A hook that exits non-zero stops the benchmark with exit status 1.

--parameter-list=NAME=V1,V2,...
: Run every command once per value, replacing `{NAME}` in the command and the hooks. Several parameters give all combinations, the first varying slowest.

--parameter-scan=NAME:MIN:MAX[:STEP]
: The same for the numbers from MIN to MAX in steps of STEP (default 1); integers unless one of the three has a fraction.

--input=FILE
: Standard input of the commands, opened afresh for every run. The default is the null device.

--bench-output=WHERE
: Standard output of the commands: `null` (default), `inherit` or a file (truncated once, then written by every run). Standard error is captured for the failure report.

--env=ASSIGNMENTS
: Environment for the commands and hooks: our own plus `NAME=VALUE` words separated by white space, with shell-style quoting but no expansion.

--metrics=LIST
: Which rows to show: a preset (`default`: wall time, memory and, where available, the counters; `time`: wall, CPU, user and system time; `all`) or comma-separated row names: `wall_time cpu_time user_time system_time peak_rss cpu_cycles instructions cache_references cache_misses branch_misses`. hyperfine's `time_wall_clock time_cpu time_user time_system memory_peak_resident` are accepted. Rows are always drawn in that order; units cannot be given.

--export-json=FILE, --export-csv=FILE
: Write the results when all commands have run. JSON is `{"results": [...]}` with, per command, `command mean stddev median user system min max` in seconds, the raw `times` (seconds) and `memory_usage_byte` per run, `exit_codes` and, with parameters, `parameters`; the shape of hyperfine's. CSV has the columns `command,mean,stddev,median,user,system,min,max` followed by one `parameter_NAME` column per parameter.

--color=WHEN
: auto (default), never or ansi (always is accepted as ansi). Colour marks the headings, the unit suffixes, and the delta: a bright red 💩 for a significantly higher value, a bright green ⚡ for a significantly lower one.

# FORMAT

`%%` a literal percent sign; `%C` the command line; `%c` involuntary context switches; `%E` elapsed real time as [hours:]minutes:seconds; `%e` elapsed seconds; `%F` major page faults; `%I` file system inputs; `%k` signals delivered; `%M` maximum resident set size in KB; `%O` file system outputs; `%P` percent of CPU; `%R` minor page faults; `%r` socket messages received; `%S` system time in seconds; `%s` socket messages sent; `%U` user time in seconds; `%W` swaps; `%w` voluntary context switches; `%x` exit status; `%Z` page size. `%D %K %p %t %X` (average memory sizes) are always 0, as on Linux. `\n`, `\t` and `\\` are escapes. An unknown conversion prints `?` and the character.

The default format is:

    %Uuser %Ssystem %Eelapsed %PCPU (%Xavgtext+%Davgdata %Mmaxresident)k
    %Iinputs+%Ooutputs (%Fmajor+%Rminor)pagefaults %Wswaps

# BENCHMARK OUTPUT

The layout is crap's. For each command a header `Benchmark N (R runs): COMMAND` and a table:

      measurement          mean ± σ            min … max           outliers         delta
      wall_time          24.3ms ± 1.43ms    22.6ms … 29.3ms          1 ( 5%)        0%
      peak_rss           1.65MB ± 87.9KB    1.52MB … 1.78MB          0 ( 0%)        0%

The delta column appears with two or more commands. `wall_time` and `peak_rss` are shown by default. A time that measured as 0 is shown as 0; a memory or counter row whose largest value is 0 was not available and is left out. On Linux, when the kernel allows it (perf_event_paranoid, not inside most virtual machines), `cpu_cycles`, `instructions`, `cache_references`, `cache_misses` and `branch_misses` count user-space events of the command and its children from its exec on; otherwise a note says so and they are omitted. Outliers lie more than 1.5 interquartile ranges outside the quartiles (quartiles taken by index, as crap does); their share is yellow from 10%. For the second and later commands the delta is the change of the mean against the first command with its 95% half-width (pooled t interval); it is marked significant only when the whole interval lies beyond 1% on one side. A measurement that is 0 for the first command has no delta (`n/a`).

`peak_rss` is the child's peak resident set as the kernel reports it, which also counts the memory the process had between `fork` and `exec`, so it is not smaller than our own size.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 125 | time itself failed (bad option, report could not be written). |
| 126 | COMMAND found but could not be invoked. |
| 127 | COMMAND not found. |
| 128+N | The command was killed by signal N. |
| other | The exit status of COMMAND. |

With **--bench**: 0 on success, 1 when a command failed, 125 on usage errors.

# ENVIRONMENT

TIME
: Default format when **-f** is not given.

NO_COLOR, TERM
: Disable colour in benchmark mode.

# STANDARD STREAMS

The report goes to standard error unless **-o** is used; the command's own standard streams are passed through. In benchmark mode the table goes to standard output and the commands' streams are discarded.

# COMPATIBILITY

Reference: GNU time 1.9 (`/usr/bin/time` on the development machine). Behaviour was checked by differential tests (`sh test/test_time.sh`). The benchmark table follows crap (its source was read, see below); the hooks, parameters, export and `--metrics` follow hyperfine 2.0.0 as seen from its `--help`, not its source.

See docs/compatibility/time.md for details.

# LIMITATIONS

- GNU time ignores SIGINT and SIGQUIT while it waits; we do not.
- The average memory sizes of the format are always 0.
- Hardware counters need Linux and permission.
- No progress bar while sampling, and no warning about slow first runs or many outliers.
- Unlike crap, command lines are split with quote handling rather than at single spaces, and standard input is the null device unless `--input` is given.
- Windows reports user and kernel time, peak working set and page faults only; macOS is compile-checked only.

# SEE ALSO

timeout(1), docs/compatibility/time.md

# VERSION

This manual describes util-core 0.2.0.
