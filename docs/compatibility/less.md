# less: compatibility record

Status: implemented as a subset; interactive, so verified by hand and by unit tests of the model, not by a differential suite. Date: 2026-11-21

## Reference

GNU less 668 (`less --version` on the development machine). Its `--help` and key behaviour were consulted as a black box; its source was not.

## Library

Module `util_core.pager` (`src/lib/pager.zig`): the growing text, wrapping, scrolling, search and frame drawing, with no terminal access (decision 0004). `src/pager_ui.zig` is the shared interactive layer (raw terminal through `sys.Tty`, a key-reading thread, a mutex-protected pager fed by the producer). `src/commands/less.zig` is the wrapper; `cat` uses the same UI.

## Supported

Options `-F -R -r -S -N -i -I`, the long names of those, `--help`, `--version`; a set of other options is accepted and ignored (see the manual page). Keys as listed in the manual page, including follow (`F`), which keeps showing data that arrives. Streaming: input is read by the calling thread and fed to the pager while the user scrolls; the screen is redrawn at most about 30 times a second.

## Extensions

None; it is a subset of less. Choice of the alternate screen: the text is not left on the screen after quitting (less without `-X`).

## Known deviations and gaps

- Search is plain text (smart case with `-i`), not a regular expression, and does not wrap past the end.
- `:n`, `:p`, `v`, marks, numeric prefixes, `-P` prompts, `+CMD` and the `LESS` variable are not implemented.
- Several files are one concatenated text.
- Display widths: bytes count one column, UTF-8 continuation bytes none, tabs go to the next multiple of 8; wide and combining characters are not handled.
- A lone ESC is a key of its own and swallows the byte after it.
- The text is kept in memory.
- Windows and macOS: compiled, not run.
