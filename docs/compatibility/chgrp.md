# chgrp: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU chgrp 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/chgrp --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chgrp invocation" (`info '(coreutils) chgrp invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chgrp, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chgrp.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chgrp.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, --changes`: Report only when a change is made.
- `-v, --verbose`: Report every file processed.
- `-f, --silent, --quiet`: Suppress most error messages.
- `--dereference / -h, --no-dereference`: Affect the referent of each symbolic link (default) or the link itself.
- `--preserve-root / --no-preserve-root`: Refuse (or not) to operate recursively on `/`.
- `--reference=RFILE`: Use RFILE's owner and group.
- `-R, --recursive`: Operate on files and directories recursively.
- `-H, -L, -P`: Symbolic link traversal with -R (default -P).
- `--from=CURRENT_OWNER:CURRENT_GROUP`: Change only files whose current owner and/or group match.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- OWNER[:[GROUP]] is parsed like gnulib userspec: names are looked up in /etc/passwd and /etc/group, `+N` forces a numeric id, `user:` means the user's login group, `:GROUP` leaves the owner alone, and `user.group` is accepted with a warning when the whole string is not a user name.
- Under -R directories are changed after their contents (fts post-order), `-R` implies `-h` unless -H or -L is given, and `-R --dereference` without -H/-L is rejected.
- Messages for -c/-v (`changed ownership of 'f' from a:b to c:d`, `retained as`, `failed to change`) follow chown-core.c, including its use of stale stat data after a failed dereference.
- Errors use the strerror text of the failing system call; exit status is 0 or 1.
- `chgrp` is the same program with the group-only usage and a GROUP argument.

## Known deviations and gaps

- Names come from /etc/passwd and /etc/group only (no NSS), as in the other commands.
- Only privileges an ordinary user has were exercised by the tests: changes to other users cannot be tested without root, so the successful chown-to-other-user path is covered only by its error behaviour.
- The fts cycle diagnostics are reduced to the `WARNING: Circular directory structure.` text for -P and -H below the command line; -L silently refuses to descend into a cycle as fts does.
- fts is not used: traversal order is the order returned by the file system, and `FTS_DEFER_STAT` stat-avoidance for -h without verbose output is not reproduced, so a file that vanishes mid-run reports `cannot access` rather than `changing ownership of`.

## Tests

`sh test/test_chown.sh`: 256 differential cases (specs, options, recursion, errors, usage); `sh test/test_chgrp.sh`: 89 cases. Both run unprivileged against GNU 9.7 and compare output, exit status and resulting owners and groups.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
