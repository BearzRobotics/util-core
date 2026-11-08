# rm: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU rm 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/rm --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "rm invocation" (`info '(coreutils) rm invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), rm, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/rm.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_rm.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-f, --force`: Ignore nonexistent files and arguments, never prompt.
- `-i, -I, --interactive[=WHEN]`: Prompt before every removal (-i), once before removing more than three files or recursing (-I), or per WHEN (never, once, always).
- `-r, -R, --recursive`: Remove directories and their contents recursively.
- `-d, --dir`: Remove empty directories.
- `-v, --verbose`: Explain what is being done.
- `--one-file-system`: With -r, skip (and report) directories on a different device from the command-line argument; the parent is then kept and the exit status is 1.
- `--preserve-root[=all], --no-preserve-root`: Refuse to operate recursively on `/` (default). `=all` is treated as plain --preserve-root.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Prompts read answers from standard input and follow GNU's wording (`descend into directory`, `remove regular empty file`, `remove write-protected ...`).
- A directory whose contents could not all be removed (error or --one-file-system skip) is left in place without a further prompt; declined prompts do not block the parent's own prompt.
- Exit status 0 when everything requested was removed (or missing with -f), 1 otherwise.

## Known deviations and gaps

- `--preserve-root=all` does not compare devices against the parent.

## Tests

`sh test/test_rm.sh`: about 270 differential cases using the file-tree comparison (run_tree) against GNU rm 9.7, covering plain/recursive/forced/verbose/interactive removal of files, symlinks, fifos, read-only entries and directories, prompt answer files, and `--one-file-system` over a tmpfs mounted in a user namespace (`unshare -rm`; skipped if unavailable).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
