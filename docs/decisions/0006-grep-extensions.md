# 0006: grep extensions for ripgrep and FreeBSD parity

Status: accepted by the maintainer's delegation ("keep as much feature parity as
possible, I'll leave it to you to make a decision"). Date: 2026-11-19. Not yet
implemented. Policy: decision 0005.

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
