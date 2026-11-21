# grep benchmark matrix (2026-11-20)

Method: `sh bench/grep-matrix.sh` (data from `bench/grep-gen.py`: a 100 MB and a 10 MB
word file, a 10 MB UTF-8 file, 10000 small files, word lists of 10/1000/3000).
Each cell is `wall ms / CPU ms (user+sys) / peak RSS MB`, the fastest of 5 runs; standard output goes to a
pipe that is read and discarded (never /dev/null: GNU grep and ours stop at the first match there).
`base` is util-core grep before this work, `ours` after. Tools: GNU grep 3.12, ripgrep 15.1, ugrep 7.5
(rg's RSS includes its memory maps; rg/ugrep CPU exceeds wall in `-r` rows because they search in parallel).
Machine: shared, load average 20+ during the run (other jobs), so wall times are noisy; ReleaseFast.
`crap` could not be used: it needs perf events and `kernel.perf_event_paranoid` is 4 here, so
there are no cycle or instruction counts; profiles came from callgrind (valgrind lacks AVX-512,
so those builds use `-Dcpu=x86_64_v3`).

| case | gnu wall / cpu ms / MB | base wall / cpu ms / MB | ours wall / cpu ms / MB | rg wall / cpu ms / MB | ugrep wall / cpu ms / MB |
|---|---|---|---|---|---|
| lit-rare | 64 / 63 / 11 | 224 / 224 / 11 | 36 / 36 / 11 | 16 / 15 / 106 | 17 / 17 / 11 |
| lit-common -c | 87 / 87 / 11 | 185 / 185 / 11 | 100 / 100 / 11 | 92 / 89 / 105 | 56 / 55 / 11 |
| lit-common out | 16 / 16 / 13 | 36 / 33 / 20 | 17 / 15 / 19 | 14 / 14 / 16 | 18 / 18 / 12 |
| lit-nohit | 54 / 54 / 11 | 177 / 177 / 11 | 28 / 27 / 11 | 10 / 10 / 105 | 14 / 14 / 11 |
| lit -c two | 9 / 9 / 11 | 20 / 20 / 11 | 6 / 6 / 11 | 6 / 6 / 16 | 5 / 5 / 11 |
| -i rare | 62 / 62 / 11 | 117 / 117 / 11 | 28 / 28 / 11 | 16 / 16 / 106 | 15 / 15 / 11 |
| -i common -c | 92 / 92 / 11 | 158 / 158 / 11 | 80 / 79 / 11 | 120 / 119 / 106 | 80 / 78 / 11 |
| -w -c | 155 / 155 / 11 | 209 / 209 / 11 | 95 / 95 / 11 | 114 / 114 / 106 | 57 / 57 / 11 |
| -x -c | 56 / 56 / 11 | 497 / 497 / 11 | 56 / 56 / 11 | 34 / 34 / 106 | 40 / 40 / 11 |
| -v -c | 93 / 93 / 11 | 183 / 183 / 11 | 79 / 79 / 11 | 72 / 71 / 106 | 85 / 85 / 11 |
| -v out | 22 / 17 / 13 | 35 / 33 / 18 | 20 / 18 / 17 | 16 / 14 / 16 | 19 / 19 / 12 |
| -o rare | 55 / 55 / 11 | 192 / 192 / 11 | 37 / 36 / 11 | 17 / 17 / 106 | 18 / 18 / 11 |
| -o common | 36 / 34 / 12 | 52 / 51 / 12 | 29 / 28 / 12 | 16 / 16 / 16 | 10 / 10 / 12 |
| -n rare | 81 / 79 / 11 | 192 / 192 / 11 | 27 / 26 / 11 | 15 / 15 / 106 | 15 / 15 / 11 |
| -n common | 16 / 16 / 13 | 26 / 24 / 18 | 14 / 13 / 19 | 17 / 17 / 16 | 17 / 17 / 12 |
| -b -o common | 26 / 26 / 13 | 37 / 36 / 13 | 24 / 23 / 13 | 13 / 13 / 16 | 9 / 9 / 13 |
| -F 1 pattern | 52 / 52 / 11 | 220 / 219 / 11 | 37 / 37 / 11 | 18 / 16 / 106 | 17 / 17 / 11 |
| -F 10 patterns | 365 / 363 / 11 | 417 / 417 / 11 | 390 / 389 / 11 | 64 / 64 / 106 | 69 / 69 / 11 |
| -F 1000 patterns | 108 / 108 / 11 | 104 / 103 / 11 | 96 / 96 / 11 | 21 / 21 / 17 | 18 / 18 / 11 |
| -E alt 3 lits | 99 / 99 / 11 | 200 / 200 / 11 | 34 / 34 / 11 | 15 / 15 / 106 | 21 / 21 / 11 |
| -E alt common | 11 / 11 / 11 | 1437 / 1434 / 11 | 46 / 46 / 11 | 16 / 16 / 16 | 10 / 10 / 11 |
| -f 3000 words | 140 / 140 / 11 | 278 / 278 / 11 | 283 / 282 / 11 | 68 / 67 / 17 | 49 / 48 / 11 |
| -f 3000 words -F | 174 / 172 / 11 | 352 / 350 / 11 | 330 / 329 / 11 | 66 / 63 / 17 | 46 / 46 / 11 |
| anchored ^ | 89 / 88 / 11 | 666 / 666 / 11 | 83 / 83 / 11 | 72 / 72 / 106 | 57 / 56 / 11 |
| anchored $ | 87 / 87 / 11 | 629 / 628 / 11 | 81 / 80 / 11 | 64 / 64 / 106 | 87 / 87 / 11 |
| -x regex | 15 / 15 / 11 | 46 / 46 / 11 | 45 / 45 / 11 | 12 / 12 / 16 | 30 / 30 / 11 |
| backref | 332 / 332 / 11 | 185 / 185 / 11 | 185 / 184 / 11 | 45 / 45 / 16 | 43 / 43 / 11 |
| classes | 85 / 85 / 11 | 229 / 229 / 11 | 27 / 27 / 11 | 84 / 84 / 106 | 32 / 31 / 11 |
| classes line | 60 / 59 / 11 | 516 / 515 / 11 | 509 / 508 / 11 | 51 / 50 / 106 | 92 / 92 / 11 |
| -r tree rare | 53 / 53 / 13 | 106 / 104 / 15 | 59 / 58 / 15 | 22 / 159 / 16 | 23 / 135 / 17 |
| -r tree -c | 59 / 59 / 12 | 102 / 102 / 12 | 60 / 60 / 13 | 20 / 170 / 14 | 22 / 137 / 14 |
| -r --include | 15 / 15 / 12 | 48 / 48 / 12 | 26 / 26 / 12 | 7 / 49 / 13 | 9 / 40 / 13 |
| -r -l | 43 / 43 / 14 | 82 / 82 / 12 | 51 / 50 / 12 | 20 / 156 / 13 | 19 / 126 / 14 |
| utf8 -c lit | 8 / 8 / 12 | 17 / 16 / 11 | 8 / 8 / 12 | 8 / 8 / 16 | 7 / 6 / 11 |
| utf8 -ci lit | 10 / 10 / 12 | 40 / 40 / 12 | 38 / 38 / 12 | 13 / 13 / 16 | 8 / 8 / 12 |
| utf8 . regex | 14 / 14 / 11 | 56 / 56 / 12 | 42 / 42 / 11 | 9 / 9 / 16 | 8 / 8 / 12 |
| utf8 -w -c | 6 / 6 / 11 | 2559 / 2558 / 12 | 7 / 7 / 12 | 3 / 3 / 16 | 3 / 3 / 11 |

## Reading the table

- Single-pattern rows (literal, -i, -w, -x, -v -c, -o, -n, -F 1, 3-literal alternation, anchored `^lit`/`lit$`,
  classes with a literal): ours is at or below GNU everywhere except `lit-common -c` (about 1.1x) and
  `-v out` (about 1.1x). On a 100 MB file, the rare literal went from 224 ms to 36 ms (GNU 64 ms).
- Rows still behind GNU: `classes line` (`^[a-m]+[[:space:]][n-z]+`, 8.5x), `-x regex` (3x),
  `utf8 -ci` (3.8x), `utf8 .` regex (3x), `-f 3000 words` (2.0x, -F: 1.9x), `-F 10 patterns` (1.07x),
  `-F 1000` (0.9x), `-r --include` (1.7x, 10000 files), `-r` rows (about 1.1x).
  All of these run the regex-zig 0.3.0 lazy DFA per line (or per buffer) and that DFA costs roughly
  30-60 instructions per input byte (callgrind: 64 instr/byte for `^[a-m]+[[:space:]][n-z]+`),
  against about 1-2 for GNU's. The per-byte loop is `Dfa.findEnd`/`step` (a non-inlined call per byte), and for a
  one-byte first-byte set it recomputes `ByteSet.count()` and scans 256 `has()` calls on every call.
  Faster needs that loop tightened inside regex-zig, not a change in util-core.
- rg and ugrep use SIMD multi-literal engines (Teddy). Since the multi-literal round (src/multisearch.zig, an Aho-Corasick automaton behind a two-byte vector filter) ours uses that for lists of any size and for alternations that expand to a finite set of strings; see the second table below.
- Memory: RSS is 11-19 MB on every row; the read buffer is 96 KiB plus one line and is released after a file
  larger than 4 MiB; the DFA caches are capped (16 MiB for a few patterns, 256 MiB for lists, grown only on demand).
  Nothing grows per file or per pattern beyond that.

## Multi-literal round (2026-11-20)

Same data and method as above (wall / cpu ms / RSS MB, fastest of 5); `base` is the build before the change. Rows for the other patterns are unchanged.

| case | GNU | base | ours | rg | ugrep |
|---|---|---|---|---|---|
| -F 10 patterns (100 MB) | 289 / 288 / 11 | 382 / 382 / 11 | 86 / 86 / 11 | 58 / 58 / 105 | 69 / 69 / 11 |
| -F 1000 patterns | 154 / 150 / 11 | 104 / 104 / 11 | 46 / 46 / 11 | 28 / 28 / 16 | 26 / 26 / 11 |
| -E alt common `(two\|the)s?` | 12 / 12 / 11 | 33 / 33 / 11 | 9 / 9 / 11 | 13 / 13 / 16 | 10 / 9 / 11 |
| -E alt 3 lits | 100 / 100 / 11 | 33 / 33 / 11 | 32 / 31 / 11 | 14 / 14 / 106 | 20 / 20 / 11 |
| -f 3000 words | 135 / 134 / 11 | 236 / 236 / 11 | 49 / 49 / 11 | 52 / 52 / 17 | 36 / 36 / 11 |
| -f 3000 words -F | 142 / 142 / 11 | 275 / 275 / 11 | 50 / 50 / 11 | 52 / 52 / 17 | 48 / 47 / 11 |
| -r --include (10000 files) | 16 / 16 / 12 | 28 / 28 / 13 | 17 / 17 / 13 | 10 / 46 / 13 | 11 / 39 / 13 |
| -f 3000 words -w | 149 / 149 / 11 | minutes | 42 / 42 / 11 | 21 / 21 / 18 | 37 / 37 / 11 |
