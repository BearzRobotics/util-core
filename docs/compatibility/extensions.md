# Extensions and deviations index

Policy: decision 0005. GNU behaviour is the default; everything below is an
opt-in or terminal-only departure. Per-command detail is in each
`docs/compatibility/<cmd>.md`.

| Command | Extension | Applies when | Turn off |
|---|---|---|---|
| cat | bat-style view (header, grid, line numbers, syntax highlighting) | stdout is a terminal and no GNU formatting option is given | pipe/redirect, or any GNU formatting option |
| time | `--bench`: poop/crap-style comparison of commands with `--duration`, `--runs`, `--warmup`, `--shell` and more (see the man page) | `--bench` is given | do not pass it |
| ls, dir, vdir, stat, df, du, wc, date, printenv, md5sum..b2sum, cksum | `--json` structured output (listed in `--help` and the man page as "not in GNU") | the option is given | do not pass it |
| ls, dir, vdir | diagnostic: `memory exhausted: the listing is incomplete` (GNU: `memory exhausted`; same exit status 2) | an allocation fails | n/a |
| cmp, diff, diff3, sdiff | `--json` structured output: the comparison as data (listed in `--help` and the man page as "not in GNU"); refused with the options that define a text layout | the option is given | do not pass it |
| find | `-json` action (listed in `--help`) | the action is given | do not pass it |
| tree | `-J` is tree's own JSON output (not an extension) | n/a | n/a |
| less | scrolling, searching and quitting keep working while following (`F`); after scrolling back the view stays put while data is still read. GNU less takes no other command until following is interrupted. In both, `^X` or the interrupt key stops following | following | n/a |
| cat (and others, see their records) | see Extensions in each `docs/compatibility/<cmd>.md` | | |
| grep | ripgrep-, ugrep- and FreeBSD-derived options: `--json`, `--smart-case`, `--glob`, `--hidden`/`--no-hidden`, `--ignore-vcs`, `--replace`, `--count-matches`, `--stats`, `--type`/`--type-not`/`--type-list`, `--max-columns`, `--sort`, `--and`/`--andnot`/`--not`/`--bool`, `-O`/`-p`/`-S`, `--include-dir`, `--mmap`, `--decompress`; clearer stderr for invalid -P patterns, regex limits, out of memory and decompression failures (listed in `--help` as "(not in GNU)") | the option is given (diagnostics: the failure occurs) | do not pass it |

TODO (audit in progress): complete this table from the per-command records.
