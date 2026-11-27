# less: compatibility record

Status: implemented as a subset; interactive, so verified by hand and by unit tests of the model, not by a differential suite. Date: 2026-11-21

## Reference

GNU less 668 (`less --version` on the development machine). Its `--help` and key behaviour were consulted as a black box; its source was not.

## Library

Module `util_core.pager` (`src/lib/pager.zig`): the growing text, wrapping, scrolling, search and frame drawing, with no terminal access (decision 0004). `src/pager_ui.zig` is the shared interactive layer (raw terminal through `sys.Tty`, a key-reading thread, a mutex-protected pager fed by the producer). `src/commands/less.zig` is the wrapper; `cat` uses the same UI.

## Supported

Options `-F -R -r -S -N -i -I`, the long names of those, `--help`, `--version`; a set of other options is accepted and ignored (see the manual page). Keys as listed in the manual page, including follow (`F`), which keeps showing data that arrives from a pipe or is added to a regular file (the last one, if several). Streaming: input is read by the calling thread and fed to the pager while the user scrolls; the screen is redrawn at most about 30 times a second.

## Extensions

Scrolling, searching and quitting work while following; GNU less has to be interrupted first. Otherwise it is a subset of less. Choice of the alternate screen: the text is not left on the screen after quitting (less without `-X`).

## Known deviations and gaps

- Search is plain text (smart case with `-i`), not a regular expression, and does not wrap past the end.
- `:n`, `:p`, `v`, marks, numeric prefixes, `-P` prompts, `+CMD` and the `LESS` variable are not implemented.
- Several files are one concatenated text.
- Following keeps the open descriptor: there is no `--follow-name`, so rotated files are not reopened, and truncation is not noticed. `+F` is not implemented.
- Display widths: a UTF-8 character counts one column, tabs go to the next multiple of 8; wide and combining characters are not handled.
- Characters a terminal could act on are shown as text: U+0080 to U+009F as `<U+009B>`, bytes that are not UTF-8 as `<9B>` (GNU less highlights these; with `-R` it takes U+009B as the start of a sequence). Valid UTF-8 is passed in every locale, also where GNU less in the C locale shows its bytes as `<C3><A9>`. `-r` is the same as `-R`: GNU's `-r`, which passes everything, is not provided.
- A lone ESC is a key of its own and swallows the byte after it.
- The text is kept in memory.
- Windows and macOS: compiled, not run.
