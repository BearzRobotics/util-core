# NAME

cmp - compare two files byte by byte

# SYNOPSIS

    cmp [OPTION]... FILE1 [FILE2 [SKIP1 [SKIP2]]]
    cmp --help | -v | --version

# DESCRIPTION

Compare FILE1 and FILE2 byte by byte and report the first difference: its byte number and its line number, both counted from 1. With no FILE2, or when a FILE is `-`, standard input is read. When the inputs are equal nothing is printed. If one input is a prefix of the other, cmp reports where the shorter one ended.

SKIP1 and SKIP2 (or the -i option) give a number of bytes to skip at the start of each input. Numbers may end in a multiplier: `kB` 1000, `K` 1024, `MB` 1000000, `M` 1048576, and so on for G, T, P, E, Z and Y (with `B` for powers of 1000 and an optional `iB` for powers of 1024). A number starting with `0x` is hexadecimal and one starting with `0` is octal. A value too large for 64 bits is taken as the largest one.

# OPTIONS

-b, --print-bytes
: Also show the differing bytes: as octal and as a character (control characters as `^X`, bytes with the high bit set as `M-` followed by the same notation). With the first-difference output the word `char` becomes `byte`. `-c` and `--print-chars` are accepted as the same option.

-i SKIP, --ignore-initial=SKIP
: Skip the first SKIP bytes of both inputs.

-i SKIP1:SKIP2, --ignore-initial=SKIP1:SKIP2
: Skip the first SKIP1 bytes of FILE1 and the first SKIP2 bytes of FILE2. When skips are given more than once, or also as operands, the largest value for each file is used.

-l, --verbose
: Print the byte number (decimal) and the two differing bytes (octal) of every difference, one per line, and go on to the end of the shorter input. The byte number column is as wide as the number of digits of the smaller file size.

-n LIMIT, --bytes=LIMIT
: Compare at most LIMIT bytes (after skipping).

-s, --quiet, --silent
: Print nothing; only the exit status tells the result. Incompatible with -l.

--json
: Print the result as one JSON object instead of text: `file1`, `file2`, `equal`, `bytes_compared`, `first_difference` (an object with `byte`, `line`, `byte1`, `byte2`, or null), `eof` (an object with `file`, `after_byte`, `line`, `partial_line`, or null) and, with -l, `difference_count` and the list `differences`. The exit status is unchanged. Refused with -b and -s. Not in GNU cmp.

--help
: Print a usage summary and exit.

-v, --version
: Print version information and exit.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | The inputs are the same. |
| 1 | The inputs differ, or one ended before the other. |
| 2 | Trouble: an unreadable input, an invalid option or operand, or a write error. |

# STANDARD STREAMS

The report goes to standard output. The end-of-input message (`cmp: EOF on FILE after byte N`, `... line L`, `... in line L` when the last line is incomplete, or `which is empty`) and all diagnostics go to standard error.

# DIFFERENCES FROM GNU

None known in the text modes. `--json` is an extension.

# SEE ALSO

diff(1), docs/compatibility/cmp.md

# VERSION

This manual describes util-core 0.3.0.
