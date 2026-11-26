# updatedb: compatibility record

Status: implemented; databases are byte-identical to GNU updatedb 4.10.0 in the tests (C locale). Date: 2026-11-07

Library: `util_core.updatedb` (`src/lib/updatedb.zig`); `src/commands/updatedb.zig` is the thin wrapper (decision 0004).

## Reference

GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C. Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--localpaths=DIRS, --netpaths=DIRS`: Directories to index (shell-style globbing is applied).
- `--prunepaths=DIRS, --prunefs=TYPES`: Paths and file-system types to skip.
- `--output=FILE, --dbformat=FORMAT`: Output database and format (LOCATE02 or slocate).
- `--findoptions=OPTS`: Extra options for the file walk (-xdev, -depth, -maxdepth, -mindepth, -noleaf, ...).
- `--localuser=USER, --netuser=USER` (also LOCALUSER, NETUSER): search the local paths, and as root the network paths (default `daemon`), with that user's effective ids and groups.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Walks the tree, sorts the names bytewise, front-codes them and writes the database to a new temporary file `FILE.n.XXXXXXXX` (created exclusively, mode 0600, made 0644 through its descriptor) then renames it. Environment overrides: FINDOPTIONS, SEARCHPATHS, NETPATHS, PRUNEPATHS, PRUNEFS, LOCATE_DB.
- A failing walk still produces a header-only database and exit status 0, as the GNU shell script does.
- If PRUNEPATHS does not make a regular expression, GNU find's message is printed, nothing is walked and the database is header-only, as with GNU: pruning is never silently dropped. A directory whose name cannot be matched because of a matching limit is pruned.
- As GNU find does for the GNU script, the walk works relative to the open directories and never follows a symbolic link, including one that takes a directory's place during the walk. Paths longer than PATH_MAX are recorded; below 10000 levels (4000 in a debug build) or 64 KiB of names a directory is reported (`File name too long`) and skipped.

## Extensions

None. The executable follows the GNU updatedb script. The library (`util_core.updatedb`) adds `buildDatabase`, which returns the front-coded database bytes without writing the output file, and reports the script's messages as Observer events.

## Known deviations and gaps

- GNU changes user with `su`; here the searching thread takes the user's effective ids and supplementary groups (from /etc/passwd and /etc/group, no NSS) and takes its own back before the database is written. Linux only; elsewhere a change of user fails.
- When the user cannot be assumed (unknown, or the caller is not root) nothing is written and the status is 1; GNU's `su` asks for a password, even when the user is the caller.
- GNU writes through the fixed name `FILE.n`; ours is a name of its own for each run (see Supported behaviour), so a symbolic link in a directory others can write to is never followed and concurrent runs do not share a file. A run that is killed while writing leaves `FILE.n.XXXXXXXX` behind. Messages still say `FILE.n`, and an old `FILE.n` is removed before the search, as by the script.
- Databases are byte-identical to GNU's in all tested cases.

## Tests

`sh test/test_updatedb.sh`: about 58 differential cases comparing output, status and database bytes with GNU updatedb 4.10.0.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
