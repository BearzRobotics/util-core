# sed: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU sed 4.9 in the C locale. Date: 2026-11-07

Library: `util_core.sed` (src/lib/sed.zig): `compile` turns script text (`-e` and `-f` chunks) into a `Program` or a structured `CompileError` (kind, chunk, position or line, message); `run` executes a `Program` over inputs and writes to an `Io.Writer`, so one script can be compiled once and run many times. `src/commands/sed.zig` only parses arguments, reads `-f` files and words the diagnostics (decision 0004).

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
- Input is read as it is processed, with one byte of look-ahead where `$` needs it (so `yes | sed 5q` ends and `tail -f log | sed ...` runs); only the unused part of a read is held. What has been written is flushed before sed waits for more input from a pipe or terminal. `-u` takes no more from a pipe than it uses, and after `q` or `Q` a seekable standard input is left just after the last line used, as in GNU.

## Extensions

None. Every option and command is GNU sed 4.9's (including `--debug`, `--sandbox`, `-z` and the `e`, `F`, `z`, `W`, `R`, `T`, `v` commands); the only departures from GNU are listed under the deviations below (leftmost-longest emulation, UTF-8 tables, abbreviated `--version`).

## Known deviations and gaps

- Leftmost-longest alternation is added on top of the leftmost-first engine (src/posixre.zig `Finder`): the pattern is also compiled with regex-zig's native POSIX dialect, which finds in one pass how far the longest match from the same start reaches, and the translated pattern then gives that match and its groups. Submatch positions follow the Perl rule, not POSIX's. This is skipped for patterns containing `$` or a word anchor (`\b \B \< \>`), where the leftmost-first match is used. A pattern the native parser rejects is searched by trying each end up to 512 bytes from the start of the match. The extra pass runs on regex-zig's Pike VM: a pattern whose longer branch can run on to the end of the line (`a\|a.*z`) costs time quadratic in the line length when there are very many matches (as in GNU, but slower).
- UTF-8 locales (LC_ALL, LC_CTYPE or LANG naming UTF-8): `.`, bracket expressions, `\w \W \s \S`, `\b \B \< \>`, `y`, `\U \L \u \l` and `I` work on characters, using tables derived from Unicode 16 (src/unicode_tables.zig). Class membership approximates glibc's C.UTF-8 and may differ for rare code points; `\b` handling and case-insensitive matching of non-ASCII letters inside bracket expressions are approximations; invalid byte sequences behave differently from glibc in `y`, `\w` and `\b`. Other locales are treated as C.
- `\<` and `\>` in the C locale: the pattern is translated for regex-zig's Perl dialect, which has only `\b`. Where a literal word character or `\w` is next to the anchor on the word's side (`\<foo`, `bar\>`), `\b` means the same and is used. Elsewhere (`s/\>//`, `\<[a-z]*`) a lookahead is added, which, as in UTF-8 locales, needs the backtracking engine: it is slower, and on very long lines the search can reach its limit. Removing that needs word-start and word-end assertions in the Perl dialect of regex-zig.
- `e` and `s///e` run the command with `/bin/sh -c` and read its output through a pipe; no temporary file is used.
- `--version` prints an abbreviated banner.

## Tests

`sh test/test_sed.sh`: about 1500 differential cases against GNU sed 4.9 covering s flags and escapes, addresses and ranges, every command on inputs with and without a final newline, options, -i/-s/-z, w files and error messages with their exit statuses.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
