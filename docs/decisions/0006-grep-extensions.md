# 0006: grep extensions for ripgrep and FreeBSD parity

Status: accepted by the maintainer's delegation ("keep as much feature parity as
possible, I'll leave it to you to make a decision"). Date: 2026-11-19.
Implemented 2026-11-19 (see "Implementation record" below). Policy: decision 0005.

## Rules

- Every extension is opt-in and does not change the meaning of any GNU grep
  option or its default behaviour. Piped, plain `grep` output stays GNU-exact.
- Where ripgrep or FreeBSD use a short option that GNU already uses for
  something else (`-r`, `-Z`, `-z`, `-S`... ), only the long form is provided.
- Each option gets a test, a man page entry and an Extensions line in
  docs/compatibility/grep.md.

## Chosen set

From ripgrep (long options only): `--json` (JSON Lines results), `--smart-case`,
`--glob=GLOB` (include/exclude with `!`), `--hidden`, `--no-ignore` and
`--ignore-vcs` (honour `.gitignore`, off by default, so recursion stays GNU
unless asked), `--replace=TEXT` (with `-o`), `--count-matches`, `--stats`,
`--type=NAME` with a small built-in table, `--max-columns=N`, `--sort=KEY`.

From FreeBSD: `--mmap` (accepted, ignored), `-O`, `-p`, `-S` (symlink handling
for recursion, unused by GNU), `--null` is already GNU's `-Z`. FreeBSD's `-J`,
`-Z`, `-z` decompression options conflict with GNU's `-Z` and `-z` and are
offered as `--decompress` only.

## Not chosen

Anything that would make GNU invocations behave differently, and ripgrep's
configuration file and parallel output ordering, which have no GNU analogue.

## Implementation record (2026-11-19)

Oracles: ripgrep 15.1.0 (`rg`), ugrep 7.5.0, the FreeBSD grep of the Chimera
sysroot (`tools/bsdrun.sh`), GNU grep 3.12. Tests: `test/test_grep_ext.sh`.

### Implemented, with the decisions taken

ripgrep: `--json`, `--smart-case`, `--glob`, `--hidden`/`--no-hidden`,
`--ignore-vcs`/`--no-ignore`, `--replace`, `--count-matches`, `--stats`,
`--type`/`--type-not`/`--type-list` (31 of rg's 218 types), `--max-columns`
(+`--max-columns-preview`), `--sort`/`--sortr`.

- ripgrep's defaults differ from GNU's (hidden files skipped, ignore files
  honoured, no zero counts with `-c`). GNU wins as the default: `--hidden` and
  `--no-ignore` name GNU's default, `--no-hidden` and `--ignore-vcs` give rg's.
  `--count-matches` follows rg (omits files without matches) because it is rg's
  option; GNU `-c` is unchanged.
- No short letters for ripgrep options (`-g`, `-t`, `-T`, `-S`, `-r`, `-c`...):
  `-r` and `-c` clash, and the policy is long-only for the rest. `-S` is
  FreeBSD's.
- `--glob`, `--type` apply only to files found by walking, as in rg.
- `--json`: each file's `end` message is written after its last match; `-o`
  does not change it; binary detection is off.
- `--ignore-vcs` reads `.gitignore` and `.ignore` of the searched directories
  only (no parent directories, `.git/info/exclude`, global ignore file or
  `.rgignore`).

ugrep: `--and`, `--andnot`, `--not`, `--bool` (boolean queries).

- ugrep's `--json` is a different format (a JSON array); rg's JSON Lines wins.
  `--sort` accepts ugrep's `rname`-style reverse spellings and `name`, `used`,
  `changed` aliases.
- `-%`, `-%%` (ugrep's short forms of `--bool`) are not provided: `%` is not a
  GNU letter, but long-only keeps the rule uniform.
- ugrep's default pattern syntax is ERE; ours stays GNU's -G.
- Skipped, with the reason: `--fuzzy` (`-Z` clashes with GNU; the matching
  engine would be a project of its own), `--format`, `--csv`, `--xml`,
  `--cpp` (large output-template language), `--filter` (runs external
  programs), `--zmax` and archive formats beyond what std.compress reads
  (zip, tar, 7z, brotli, lz4, bzip2), `--index` (builds on-disk indexes),
  `--tree`, `--hexdump` and the TUI (`-Q`) (terminal presentation, large scope),
  `--files`/`--lines` boolean modes, `--config`.

FreeBSD: `-O`, `-p`, `-S`, `--include-dir`, `--mmap`, `--decompress`.

- FreeBSD `-R`/`-r` follow all links by default; GNU `-r` follows only command
  line links. GNU wins; `-O`, `-p`, `-S` give FreeBSD's choices (`-S` all, `-O`
  command line only, `-p` none; with `-O`/`-p` links to files met while walking
  are read, as FreeBSD does, unlike GNU `-r`).
- FreeBSD `--context` takes an optional number (default 2); GNU requires one.
  GNU wins; not provided.
- FreeBSD `-U` (binary files are searched but not printed) clashes with GNU's
  `-U`; GNU wins.
- FreeBSD `-J`, `-M`, `-X`, `-Z`, `-z` (decompression) clash with GNU letters
  (`-X`, `-Z`, `-z`) or are obsolete; offered as `--decompress` for gzip,
  zlib, xz and zstd (std.compress). bzip2, lzma, lz4 are not supported.
- `--include-dir`/`--exclude-dir` in FreeBSD process rules in order with last
  match winning; we keep GNU's `--exclude-dir` and add `--include-dir` as a
  plain allow list.
- `--null` is GNU's `-Z` already; `-y`, `-u` exist.

Library `Options` fields: `smart_case`, `json`, `stats`, `count_matches`,
`replace`, `max_columns`, `max_columns_preview`, `search_hidden`, `ignore_vcs`,
`rg_globs`, `type_include`, `type_exclude`, `sort`, `sort_reverse`, `symlinks`,
`include_dirs`, `decompress`; boolean queries through
`Matcher.compileTerms`/`compileQuery`. All default to GNU behaviour.

### regex-zig 0.3.0

Used: the lazy DFA (via one alternation of all patterns, for line selection
with four or more patterns, no back-references), the Pike VM/DFA selection of
`Regex.compile`, `Searcher.matchesAnywhere`. Not used: `RegexSet` itself (it
compiles every pattern twice and the combined search can be had from `Regex`
alone), `LineStream`/`matchingLines` (grep's line scanner must keep GNU's
context, binary and encoding rules), native `posix_bre`/`posix_ere` dialects
(the posixre.zig translation implements GNU's leniency and diagnostics; not
re-verified).

### Measurements

See "Performance" in docs/compatibility/grep.md: `-f` with 3000 words over a
10 MB file, GNU 172 ms, rg 56 ms, ugrep 41 ms, ours 1.99 s (was about 55 s).
The single-pattern path is unchanged code.
