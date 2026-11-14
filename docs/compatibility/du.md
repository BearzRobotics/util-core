# du: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU du 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/du --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "du invocation" (`info '(coreutils) du invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), du, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/du.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_du.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --all`: Write counts for all files, not just directories.
- `--apparent-size, -b, --bytes`: Apparent sizes (`st_size` of regular files and symbolic links; 0 otherwise).
- `-B, --block-size=SIZE, -k, -m, -h, --si`: Size units, including the `human-readable` and `si` specifications; DU_BLOCK_SIZE, BLOCK_SIZE and BLOCKSIZE are honoured.
- `-c, --total`: Produce a grand total.
- `-d, --max-depth=N, -s, --summarize`: Limit the depth of printed entries.
- `-D, -H, --dereference-args, -L, --dereference, -P, --no-dereference`: Symbolic link handling.
- `-l, --count-links`: Count hard-linked files each time.
- `-S, --separate-dirs`: Directories exclude the size of their subdirectories.
- `-t, --threshold=SIZE`: Hide entries smaller (positive SIZE) or larger (negative SIZE) than SIZE.
- `--time[=WORD], --time-style=STYLE`: Show the latest modification (or atime, ctime) time; `full-iso`, `long-iso`, `iso`, `+FORMAT`; TIME_STYLE is honoured.
- `--inodes`: Count inodes instead of blocks.
- `-x, --one-file-system`: Skip directories on other file systems.
- `--exclude=PATTERN, -X, --exclude-from=FILE`: Skip entries matching a shell pattern (matched against the whole path and every suffix that follows a slash).
- `-0, --null, --files0-from=F`: NUL-terminated output and input lists.
- `--help, --version`: Print help or version and exit.

- `--json` (extension, not in GNU): one JSON array, one object per line, for every line `du` would print: `path`, `size` (bytes, null on overflow), `inodes`, `time` and `time_nsec` (the latest time under the path, per `--time`), `time_kind` and `total` (true for the `--total` line). Cannot be combined with `-h`, `--si`, `-k`, `-m`, `-B`, `-0` or `--time-style` (fixed units and format). `--threshold`, `-d`, `-s`, `-a`, `-S`, `-c`, `-x`, `-L`, `--exclude` and `--apparent-size`/`-b` apply as usual. Not listed in `--help`. Rules: `docs/decisions/0003-json-output.md`.

## Supported behaviour

- The traversal is a recursive walk that reproduces the per-level totals GNU du.c keeps for fts: each directory is reported after its entries, children are added to their directory unless -S is given, and the grand total counts every entry once.
- Files with several links are counted once per run (or per `-l`), directories reached twice through several arguments are counted once, and sizes follow `st_blocks * 512` or the apparent size rules.
- Diagnostics (`cannot access`, `cannot read directory`, `invalid maximum depth`, `invalid --threshold argument '-0'`, summarize/max-depth warnings) match GNU, including the lack of an errno text for dangling symlinks under -L.

## Known deviations and gaps

- fts is not used: entries are visited in the order the file system returns them, and cycles reached through symbolic links under -L are skipped quietly as fts does while -P cycles produce the `Circular directory structure` warning.
- The mount-point test behind `-x` compares device numbers only (GNU uses the same rule); bind mounts of one device are not special-cased.
- Times are formatted in the local zone from /usr/share/zoneinfo or TZ; leap seconds are not applied.

## Tests

`sh test/test_du.sh`: 315 differential cases against GNU du 9.7 (C locale): sizes and units, hard links, symbolic links, depth, thresholds, time styles and zones, excludes, `--files0-from`, error paths and usage.

`sh test/test_du_json.sh`: 33 checks of `--json` against GNU `du -B1`, `du --inodes` and `du --time` over a tree with hard links, a symlink, a name with a space and an unreadable directory, for the common option combinations, the three time kinds, `--total`, and the refused options.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
