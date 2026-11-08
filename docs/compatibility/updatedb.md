# updatedb: compatibility record

Status: implemented; databases are byte-identical to GNU updatedb 4.10.0 in the tests (C locale). Date: 2026-11-07

## Reference

GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C. Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--localpaths=DIRS, --netpaths=DIRS`: Directories to index (shell-style globbing is applied).
- `--prunepaths=DIRS, --prunefs=TYPES`: Paths and file-system types to skip.
- `--output=FILE, --dbformat=FORMAT`: Output database and format (LOCATE02 or slocate).
- `--findoptions=OPTS`: Extra options for the file walk (-xdev, -depth, -maxdepth, -mindepth, -noleaf, ...).
- `--netuser=USER, --localuser=USER`: Accepted and ignored.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Walks the tree, sorts the names bytewise, front-codes them and writes the database to FILE.n then renames it. Environment overrides: FINDOPTIONS, SEARCHPATHS, NETPATHS, PRUNEPATHS, PRUNEFS, LOCATE_DB.
- A failing walk still produces a header-only database and exit status 0, as the GNU shell script does.

## Known deviations and gaps

- --localuser/--netuser (su) are ignored.
- Databases are byte-identical to GNU's in all tested cases.

## Tests

`sh test/test_updatedb.sh`: about 58 differential cases comparing output, status and database bytes with GNU updatedb 4.10.0.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
