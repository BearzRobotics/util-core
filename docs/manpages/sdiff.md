# NAME

sdiff - side-by-side merge of file differences

# SYNOPSIS

    sdiff [OPTION]... FILE1 FILE2
    sdiff -o OUTFILE [OPTION]... FILE1 FILE2
    sdiff --help | -v | --version

# DESCRIPTION

Show FILE1 and FILE2 in two columns: common lines on both sides, changed lines with `|`, lines only in the first file with `<`, lines only in the second with `>`. Identical files are shown in full. With -o the differences are resolved interactively into OUTFILE.

At each group of differences sdiff prints `%` and reads a command from standard input: `l` (or `1`) use the left lines, `r` (or `2`) the right, `el`, `er`, `eb`, `ed`, `e` edit the left, the right, both, both with headers, or a blank version in `$EDITOR` (default `ed`) and use the result, `s` stop showing common lines, `v` show them again, `q` quit (status 2). Anything else prints a summary of the commands. End of input also quits with status 2. Common lines are copied to OUTFILE as they pass.

# OPTIONS

-o FILE, --output=FILE
: Merge interactively into FILE.

-w NUM, --width=NUM
: Output at most NUM columns (default 130).

-l, --left-column; -s, --suppress-common-lines
: Show only the left column of common lines; omit them.

-t, --expand-tabs; --tabsize=NUM
: Expand tabs; tab stops every NUM columns.

-i, -E, -Z, -b, -W, -B, -I RE
: Ignore case, tab expansion, trailing white space, changes in the amount of white space, all white space (-W), blank lines, lines matching RE.

-a, --text; --strip-trailing-cr; -d; -H
: Treat files as text; strip carriage returns; try harder for a smaller set of changes; assume large files.

--diff-program=PROGRAM
: Only `diff` is accepted.

--json
: The aligned rows as one JSON object: `files` and `rows`, each row with `marker` (`equal`, `changed`, `left_only`, `right_only`), `left_line`, `left`, `right_line`, `right`. Refused with -o and the layout options. Not in GNU sdiff.

--help, -v, --version
: Usage and version.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | The inputs are the same. |
| 1 | They differ (also after an interactive merge that ran to the end). |
| 2 | Trouble, or the merge was quit early. |

# DIFFERENCES FROM GNU

- The comparison is built in (`--diff-program` other than `diff` is refused).
- The text of the headers written by the `ed` command is this implementation's.
- `--json` is an extension.

# SEE ALSO

diff(1), diff3(1), docs/compatibility/sdiff.md

# VERSION

This manual describes the development version 0.0.0-dev; no release exists.
