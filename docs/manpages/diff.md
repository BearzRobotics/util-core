# NAME

diff - compare files line by line

# SYNOPSIS

    diff [OPTION]... FILE1 FILE2
    diff [OPTION]... --from-file=FILE1 FILE...
    diff [OPTION]... --to-file=FILE2 FILE...
    diff --help | -v | --version

# DESCRIPTION

Compare FILE1 and FILE2 line by line and write the differences, by default in the traditional "normal" format. FILE may be `-` for standard input. If both operands are directories their entries are compared in name order; `-r` descends into subdirectories. If one operand is a directory, the file in it with the other operand's name is used.

The result is not always a minimal edit script: like GNU diff, lines that match nothing in the other file are set aside first, very large inputs use a cut-off, and runs of changes are moved to where they merge with their neighbours. The output agrees with GNU diff 3.12 hunk for hunk (see the compatibility record for the measured agreement).

# OPTIONS

Output style

--normal
: Normal format (the default): `3c3`, `<` for removed lines, `>` for added lines.

-c, -C NUM, --context[=NUM]
: Context format with NUM lines (default 3).

-u, -U NUM, --unified[=NUM]
: Unified format with NUM lines (default 3). A number alone (`-3`) sets the amount of context without choosing the format.

-e, --ed
: An ed script (hunks in reverse order). -f is the forward variant, -n the RCS format.

-y, --side-by-side
: Two columns. `-W NUM` sets the width (default 130), `--left-column` shows only the left column of common lines, `--suppress-common-lines` omits them, `--tabsize=NUM` sets tab stops.

-D NAME, --ifdef=NAME
: Merged output with `#ifdef NAME` around the differences. `--line-format`, `--old-line-format`, `--new-line-format`, `--unchanged-line-format` and the `--old-group-format`, `--new-group-format`, `--unchanged-group-format`, `--changed-group-format` options give full control of the output with `%<`, `%>`, `%=`, `%L`, `%l`, `%dn`-style numbers, `%(A=B?T:E)` and `%c'C'`.

-p, --show-c-function; -F RE, --show-function-line=RE
: Show the nearest preceding line that matches RE (default for -p: a line starting with a letter, `$` or `_`) after the hunk header.

--label LABEL
: Use LABEL instead of the file name and time in context and unified headers (twice for both files).

-t, --expand-tabs; -T, --initial-tab; --tabsize=NUM; --suppress-blank-empty
: Tab handling and blank-line suppression in the output.

-l, --paginate
: Accepted; pagination through pr(1) is not implemented.

--color[=WHEN]; --palette=PALETTE
: Colour the output (`never`, `always`, `auto`). Default colours: added green, removed red, headers bold, hunk headers cyan; the palette uses the `ad`, `de`, `hd` and `ln` capabilities.

Comparison

-i, -E, -Z, -b, -w
: Ignore case, tab expansion, trailing white space, changes in the amount of white space, all white space.

-B, -I RE, --ignore-matching-lines=RE
: Ignore changes in which all lines are blank, or all match RE.

-a, --text; --strip-trailing-cr
: Treat files as text even if they contain NUL in their first 4096 bytes; strip a carriage return before each newline.

-d, --minimal; --speed-large-files; --horizon-lines=NUM
: Tuning of the comparison.

Reporting and directories

-q, --brief; -s, --report-identical-files
: Report only whether files differ; report when they are the same.

-r, --recursive; -N, --new-file; --unidirectional-new-file; --no-dereference
: Recurse into subdirectories; treat absent files as empty; treat absent first files as empty; compare symbolic links themselves.

-x PAT, --exclude=PAT; -X FILE, --exclude-from=FILE; -S FILE, --starting-file=FILE; --ignore-file-name-case; --no-ignore-file-name-case
: Select directory entries.

--from-file=FILE1, --to-file=FILE2
: Compare one file with every operand.

--json
: Print the comparison as JSON instead of text: for two files one object `{kind, old, new, equal, binary, hunks}` with the hunks as `{old_start, old_count, new_start, new_count, lines}` and each line as `{kind (context, removed or added), text, no_newline}`, with `-U` choosing the context; for directories an array of such objects plus `only_in`, `common_subdirectory`, `type_mismatch` and `symlinks_differ` entries. Refused with the style and layout options. Not in GNU diff.

--help, -v, --version
: Usage and version.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | No differences (or only ignored ones). |
| 1 | Differences found. |
| 2 | Trouble: unreadable file, invalid option, write error. |

# STANDARD STREAMS

The report goes to standard output; diagnostics go to standard error. For -e and -f a file that lacks a final newline is reported on standard error and given one, with status 2, as in GNU diff.

# DIFFERENCES FROM GNU

- `-l` (pagination through pr) is accepted and ignored.
- `--diff-program` does not exist here; file name ordering is by bytes (C locale), not by the locale collation.
- Binary detection looks at the first 4096 bytes, as GNU does on the test system; files larger than 1 GiB are refused with a clear error rather than read.
- `--json` is an extension.

# SEE ALSO

cmp(1), diff3(1), sdiff(1), docs/compatibility/diff.md

# VERSION

This manual describes the development version 0.0.0-dev; no release exists.
