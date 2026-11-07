# sed: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU sed 4.9 in the C locale. Date: 2026-11-07

## Reference

GNU sed 4.9 (`/usr/bin/sed --version` on the development machine). Consulted 2026-11-07: the GNU sed manual (https://www.gnu.org/software/sed/manual/sed.html) and POSIX.1-2024 sed, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sed.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-n, --quiet, --silent`: Suppress automatic printing of the pattern space.
- `-e SCRIPT, --expression=SCRIPT`: Add SCRIPT to the commands to run.
- `-f FILE, --file=FILE`: Add the commands in FILE (`-` is standard input).
- `-E, -r, --regexp-extended`: Use extended regular expressions.
- `-i[SUFFIX], --in-place[=SUFFIX]`: Edit files in place; with SUFFIX keep a backup (a `*` in SUFFIX stands for the base name, a `/` makes it a path).
- `--follow-symlinks`: Edit the target of a symbolic link when editing in place.
- `-s, --separate`: Treat files as separate: line numbers and `$` are per file.
- `-l N, --line-length=N`: Wrap length for the `l` command.
- `-z, --null-data`: Lines are separated by NUL.
- `-u, --unbuffered`: Flush output after every line.
- `--posix`: Disable some GNU extensions (N at end of input discards the pattern space).
- `--sandbox`: Reject e, r and w commands.
- `-b, --binary`: Accepted and ignored.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Commands: `{ } = a b c d D e F g G h H i l n N p P q Q r R s t T v w W x y z : #`, with the GNU one-line forms of `a`, `i` and `c` and `-e` chunks continuing a trailing `a\`.
- Addresses: `N`, `first~step`, `$`, `/re/` and `\cREc` with `I` and `M`, `addr1,+N`, `addr1,~N`, `0,/re/`, and `!`.
- `s` flags `g p N i I m M e w FILE`; replacement escapes `\1`..`\9`, `&`, `\n`, `\t`, `\L \U \l \u \E`, `\cX \dNNN \oNNN \xHH`.
- A missing newline at the end of the last line is preserved; `w /dev/stdout` and `/dev/stderr` are special.
- `#n` on the first line of the script acts as `-n`.
- Input files are read whole into memory before processing.

## Known deviations and gaps

- Leftmost-longest alternation is emulated on top of the leftmost-first engine (src/posixre.zig `Finder`): after the engine finds the leftmost match, longer matches ending at later offsets are tried. This is skipped for patterns containing `$`, `\b`, `\B` or lines with more than 4096 bytes after the match, where the leftmost-first match is used. Submatch positions follow the Perl rule, not POSIX's.
- UTF-8 locales (LC_ALL, LC_CTYPE or LANG naming UTF-8): `.`, bracket expressions, `\w \W \s \S`, `\b \B \< \>`, `y`, `\U \L \u \l` and `I` work on characters, using tables derived from Unicode 16 (src/unicode_tables.zig). Class membership approximates glibc's C.UTF-8 and may differ for rare code points; `\b` handling and case-insensitive matching of non-ASCII letters inside bracket expressions are approximations; invalid byte sequences behave differently from glibc in `y`, `\w` and `\b`. Other locales are treated as C.
- `e` and `s///e` run the command through `/bin/sh` and a temporary file in /tmp.
- `--version` prints an abbreviated banner.

## Tests

`sh test/test_sed.sh`: about 1500 differential cases against GNU sed 4.9 covering s flags and escapes, addresses and ranges, every command on inputs with and without a final newline, options, -i/-s/-z, w files and error messages with their exit statuses.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
