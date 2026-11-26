# mknod: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU mknod 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/mknod --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mknod invocation" (`info '(coreutils) mknod invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mknod-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mknod, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mknod.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mknod.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-m, --mode=MODE`: Permissions.
- `-Z, --context[=CTX]`: As for mkfifo.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- TYPE is b, c/u or p (only the first character is looked at, like GNU). MAJOR and MINOR accept decimal, octal (0) and hex (0x).
- Operand-count diagnostics reproduce GNU's wording.

## Safety

The new file is created and its mode set relative to one open descriptor of its parent directory, and the mode is never set through a symbolic link. If another user replaces the new file before the mode is set, mknod reports `cannot set permissions` and leaves the other file alone.

## Library

Module `util_core.mknod` (src/lib/mknod.zig); `src/commands/mknod.zig` is the argument parser and diagnostics wrapper (decision 0004).

## Extensions

None. Output, diagnostics and exit status follow GNU (decision 0005).

## Known deviations and gaps

- Creating block/character devices needs privilege that the development account lacks, so those paths were verified only down to the "Operation not permitted" diagnostic.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_mknod.sh`: 64 differential cases against GNU mknod 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
