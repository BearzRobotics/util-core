# NAME

diff3 - compare three files line by line

# SYNOPSIS

    diff3 [OPTION]... MYFILE OLDFILE YOURFILE
    diff3 --help | -v | --version

# DESCRIPTION

Compare MYFILE and YOURFILE, both derived from OLDFILE, and report where they differ. The differences between OLDFILE and each of the others are computed and blocks that touch in OLDFILE are combined. Each block is one of: only MYFILE differs (`====1`), only OLDFILE differs (`====2`, MYFILE and YOURFILE agree), only YOURFILE differs (`====3`), or all three differ (`====`, a conflict). A FILE of `-` is standard input (once).

The default report lists each block with the line range in every file (`1:2c`, `3:6a`, ...) and the text, indented by two spaces. The ed and merge options turn the result into an ed script or the merged file.

# OPTIONS

-e, --ed
: An ed script that incorporates into MYFILE the changes from OLDFILE to YOURFILE; overlapping changes take YOURFILE's text.

-E, --show-overlap
: Like -e, but bracket the conflicts with `<<<<<<<`, `=======` and `>>>>>>>` lines (named after MYFILE and YOURFILE).

-3, --easy-only
: Like -e, but only the non-overlapping changes.

-x, --overlap-only; -X
: Like -e, but only the overlapping changes. -X is accepted as the same.

-A, --show-all
: Like -E, and also the text of OLDFILE (`|||||||`); changes that only OLDFILE lacks are bracketed too.

-m, --merge
: Write the merged file itself, in the style of -A when no other option is given. Cannot be combined with -i.

-i
: Append `w` and `q` to an ed script.

-T, --initial-tab
: Use a tab instead of two spaces before the text in the default report.

-L LABEL, --label=LABEL
: Names for the conflict markers; all three or none.

-a, --text; --strip-trailing-cr
: Treat files as text; strip a carriage return before each newline.

--diff-program=PROGRAM
: Run PROGRAM instead of the built-in comparison. It is called as GNU diff3 calls it (`PROGRAM [-a] [--strip-trailing-cr] --horizon-lines=100 ---no-directory -- OLDFILE OTHER`) and must print a normal-format diff; the text of the lines still comes from the files. A program that cannot be run gives `subsidiary program 'X' not found` (or `could not be invoked`, `failed (exit status N)`) and status 2. The default `diff` stays in process.

--json
: One JSON object: `files`, `conflicts` and `blocks`, each with a `kind` (`unchanged`, `only-first`, `only-second`, `only-third`, `overlap`) and, for the three files, `start`, `count` and the `lines`. Refused with the other output options. Not in GNU diff3.

--help, -v, --version
: Usage and version.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success (the default report and non-bracketing ed scripts always exit 0). |
| 1 | The ed script or merge contains conflict markers. |
| 2 | Trouble. |

# DIFFERENCES FROM GNU

- The three-way blocks and the ed and merge forms were reproduced by observing GNU diff3 3.12; the agreement on generated inputs is in the compatibility record.
- With `--diff-program` the line text is taken from the files, not from the program's output, so a program whose output contradicts the files can give different text than GNU's; a binary input is reported as `diff failed: Binary files ... differ` naming MYFILE and YOURFILE.
- `--json` is an extension.

# SEE ALSO

diff(1), sdiff(1), docs/compatibility/diff3.md

# VERSION

This manual describes util-core 0.2.0.
