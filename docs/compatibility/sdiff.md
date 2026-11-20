# sdiff: compatibility record

Status: complete for the GNU options; verified against GNU diffutils 3.12. Date: 2026-11-20

## Reference

GNU diffutils 3.12 (`/usr/bin/sdiff --version`). Consulted: the GNU manual node "Interactive Merging with sdiff" and "Side by Side". Settled by probing the installed binary; the 3.12 sources were read for understanding only (no code or text copied).

## Supported options

- `-o/--output`, `-i`, `-E`, `-Z`, `-b`, `-W` (ignore all space), `-B`, `-I RE`, `--strip-trailing-cr`, `-a`, `-w/--width`, `-l/--left-column`, `-s/--suppress-common-lines`, `-t/--expand-tabs`, `--tabsize`, `-d`, `-H`, `-v/--version`, `--help`.
- The layout is the one of `diff -y` (shared code, `diffsbs.zig`); unlike `diff -y`, identical files are listed in full.
- Interactive merge: the `%` prompt, commands `l`/`1`, `r`/`2`, `q`, `s`, `v`, `e`, `el`/`e1`, `er`/`e2`, `eb`, `ed` (the editor is `$EDITOR`, default `ed`, run on a temporary file), the command summary on stderr for anything else, common lines copied to the output file, exit status 1 when differences were merged and 2 for `q` or end of input.
- Option errors are worded as GNU's (they come from `diff` there): `diff: invalid width '0'`, `diff: FILE: No such file or directory`.

## Extensions

- `--json` (not in GNU): `{files, rows}` where a row has `marker` (`equal`, `changed`, `left_only`, `right_only`), `left_line`, `left`, `right_line`, `right`. Refused with `-o` and the layout options. Listed in `--help` as a non-GNU line. Tested by `test/test_sdiff_json.sh`.

## Known deviations and gaps

- The comparison is built in unless `--diff-program` names another program: without `-o` it is run as GNU runs it (translated options, `-y -- FILE1 FILE2`) and its status returned; with `-o` it is run with `--sdiff-merge-assist` and its `i`/`c` protocol drives the same prompt.
- The `ed` command's headers (`--- FILE N`, `--- FILE N,M`, none for an empty range) and the whole prompt were verified against GNU with scripted sessions (436 sessions over single-line, multi-line and empty ranges, files without a final newline, `-s -l -B`, failing and missing editors, unterminated last answers).
- `-d` is `--minimal` as in GNU: the engine skips the discard pass and searches without the shortcut, which is analyze.c's rule (there is no separate sdiff behaviour).
- The editor is started with `std.process.spawn` on `$EDITOR`; there is no shell, so `EDITOR` must be a program name or path (GNU runs it through the same exec path).

## Measured agreement

20000 generated pairs (all input kinds of the diff campaign) in 18 listing option sets plus a scripted `-o` session each: 380000 of 380000 comparisons identical to GNU sdiff 3.12.

## Library

`util_core.sdiff`: `rows` (aligned rows as data), `list`, `interact` (answers from a caller-supplied `Io.Reader`, an `Editor` callback, an `Observer`), `writeJson`.

## Tests

`sh test/test_sdiff.sh` (listing options, errors, scripted interactive sessions compared with GNU including the output file, generated pairs), `sh test/test_sdiff_json.sh`.
