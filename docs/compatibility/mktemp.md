# mktemp: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU mktemp 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/mktemp --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mktemp invocation" (`info '(coreutils) mktemp invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mktemp, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mktemp.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mktemp.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-d, --directory`: Create a directory.
- `-u, --dry-run`: Print a name without creating anything.
- `-q, --quiet`: Suppress diagnostics about creation failure.
- `--suffix=SUFF`: Append SUFF (no slash); the template must then end in X.
- `-p DIR, --tmpdir[=DIR]`: Put the file in DIR ($TMPDIR or /tmp without DIR).
- `-t`: Interpret TEMPLATE relative to $TMPDIR, else the -p directory, else /tmp.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The last run of X characters (at least 3) is replaced by random letters and digits; text after it is a fixed suffix.
- Files get mode 0600 and directories 0700, both reduced by the umask; names come from the system random source with rejection sampling to avoid bias, and EEXIST retries.
- `-p` and `-t` handling of slashes and absolute templates follows the diagnostics GNU prints.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_mktemp.sh`: 74 differential cases against GNU mktemp 9.7 in the C locale. The random characters differ between runs, so output and tree are compared with every letter and digit masked; fixed text and permissions are checked separately.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
