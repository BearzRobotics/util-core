# Extensions and deviations index

Policy: decision 0005. GNU behaviour is the default; everything below is an
opt-in or terminal-only departure. Per-command detail is in each
`docs/compatibility/<cmd>.md`.

| Command | Extension | Applies when | Turn off |
|---|---|---|---|
| cat | bat-style view (header, grid, line numbers, syntax highlighting) | stdout is a terminal and no GNU formatting option is given | pipe/redirect, or any GNU formatting option |
| ls, dir, vdir, stat, df, du, wc, date, printenv, checksum tools, find, tree | `--json` / `-json` structured output | the option is given | do not pass it |
| grep | ripgrep and FreeBSD options | the option is given | do not pass it |

TODO (audit in progress): complete this table from the per-command records;
grep's extension list is not yet enumerated in docs/compatibility/grep.md.
