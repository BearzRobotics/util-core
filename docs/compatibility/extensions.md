# Extensions and deviations index

Policy: decision 0005. GNU behaviour is the default; everything below is an
opt-in or terminal-only departure. Per-command detail is in each
`docs/compatibility/<cmd>.md`.

| Command | Extension | Applies when | Turn off |
|---|---|---|---|
| cat | bat-style view (header, grid, line numbers, syntax highlighting) | stdout is a terminal and no GNU formatting option is given | pipe/redirect, or any GNU formatting option |
| ls, dir, vdir, stat, df, du, wc, date, printenv, md5sum..b2sum, cksum | `--json` structured output (listed in `--help` and the man page as "not in GNU") | the option is given | do not pass it |
| ls, dir, vdir | diagnostic: `memory exhausted: the listing is incomplete` (GNU: `memory exhausted`; same exit status 2) | an allocation fails | n/a |
| find | `-json` action (listed in `--help`) | the action is given | do not pass it |
| tree | `-J` is tree's own JSON output (not an extension) | n/a | n/a |
| cat (and others, see their records) | see Extensions in each `docs/compatibility/<cmd>.md` | | |
| grep | none yet (ripgrep- and FreeBSD-derived options are planned, not implemented) | n/a | n/a |

TODO (audit in progress): complete this table from the per-command records;
grep's extension list is not yet enumerated in docs/compatibility/grep.md.
