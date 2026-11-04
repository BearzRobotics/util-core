% DIRCOLORS(1) Version 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
dircolors - output commands to set the LS_COLORS environment variable

SYNOPSIS
dircolors [OPTION]... [FILE]

DESCRIPTION
Read a color database (FILE, standard input when FILE is -, or the built-in database) and print the shell command that sets LS_COLORS, which `ls --color` uses to choose colors for file types and extensions. The output is meant to be evaluated by a shell, for example `eval "$(dircolors -b)"`.

The built-in database is the standard set of defaults. `dircolors --print-database` prints it so it can be copied and edited.

OPTIONS
-b, --sh, --bourne-shell
: Output Bourne shell code: `LS_COLORS='...';` followed by `export LS_COLORS`.

-c, --csh, --c-shell
: Output C shell code: `setenv LS_COLORS '...'`.

-p, --print-database
: Print the built-in database and exit. The output is itself a valid database. Cannot be combined with a FILE, -b / -c, or --print-ls-colors.

--print-ls-colors
: Print one line per entry, colored as the entry says (`ESC[VALUEm`, the key, a tab, the value, `ESC[0m`). The strings are not shell-quoted. The escape sequences are the purpose of this option, so NO_COLOR does not apply. Cannot be combined with -b / -c or -p.

--help
: Print usage to standard output and exit.

--version
: Print version information to standard output and exit.

Long options may be abbreviated to an unambiguous prefix, and the short options may be clustered (`-bp`).

When neither -b nor -c is given, the syntax is chosen from $SHELL: C shell syntax if the last path component is exactly `csh` or `tcsh`, otherwise Bourne. If SHELL is unset or empty, an error is reported. If both -b and -c are given the last one wins.

DATABASE FORMAT
One entry per line: a KEYWORD, white space, then a VALUE, a list of SGR codes such as `01;34`. Blank lines are ignored. A `#` ends the line's value wherever it appears, which makes the rest a comment. White space around the value is removed. A line with a keyword but no value is an error.

KEYWORD is, case-insensitively, one of: NORMAL (NORM), FILE, RESET, DIR, LINK (LNK, SYMLINK), ORPHAN, MISSING, FIFO (PIPE), SOCK, BLOCK (BLK), CHAR (CHR), DOOR, EXEC, LEFTCODE (LEFT), RIGHTCODE (RIGHT), ENDCODE (END), SETUID (SUID), SETGID (SGID), STICKY, CAPABILITY, MULTIHARDLINK, CLRTOEOL, OTHER_WRITABLE, STICKY_OTHER_WRITABLE. Or it is a pattern beginning with `*` (for example `*~`), or an extension beginning with `.` (`.gz` means `*.gz`). OPTIONS, COLOR and EIGHTBIT are accepted and ignored.

TERM and COLORTERM lines take a glob pattern, matched case-sensitively against $TERM (`none` if unset or empty) and $COLORTERM (empty if unset). A matching line enables the entries after it. A non-matching line disables them, unless it follows a matching line with no entry in between. Entries before the first such line always apply. Because a later line can cancel an earlier match, one file can enable entries for some terminals and then disable them again.

An unknown keyword is an error only while a matching TERM or COLORTERM block is active; elsewhere it is skipped silently. All problems in the file are reported, and no output is produced if there are any.

The built-in database lists the terminals known to support color; for any other terminal LS_COLORS is empty. COLORTERM with any non-empty value also enables the colors.

Output quoting: inside the single-quoted result, `'` is written `'\''`; a `:` or `=` gets a backslash unless a backslash or `^` already protects it (LS_COLORS has its own escapes); in C shell syntax `!` gets a backslash.

ENVIRONMENT
SHELL
: Selects the output syntax when no option does.

TERM, COLORTERM
: Select database entries as described above.

EXIT STATUS
0 on success; 1 for a usage error, an unreadable FILE, or any problem in the database: `FILE:LINE: invalid line;  missing second token` or `FILE:LINE: unrecognized keyword 'KEYWORD'` (the built-in database is named `<internal>`).

SEE ALSO
ls(1)
