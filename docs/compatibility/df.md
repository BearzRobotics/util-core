# df: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU df 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/df --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "df invocation" (`info '(coreutils) df invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/df-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), df, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/df.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_df.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --all`: Include pseudo, duplicate and inaccessible file systems.
- `-B, --block-size=SIZE, -k, -m, -h, -H, --si`: Size units; DF_BLOCK_SIZE, BLOCK_SIZE and BLOCKSIZE are honoured.
- `-i, --inodes`: Inode information instead of block usage.
- `-l, --local`: Only local file systems.
- `--output[=FIELD_LIST]`: Choose columns: source, fstype, itotal, iused, iavail, ipcent, size, used, avail, pcent, file, target.
- `-P, --portability`: POSIX output format.
- `--sync, --no-sync`: Accepted; sync(2) is not needed on Linux.
- `--total`: Produce a grand total.
- `-t, --type=TYPE, -x, --exclude-type=TYPE, -T, --print-type`: Select, exclude and show file system types.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The mount table comes from /proc/self/mountinfo and is filtered like GNU: duplicate devices are dropped in favour of the entry with a real device name or the shortest mount point, dummy file systems are hidden without -a (the dummy list is that of coreutils 9.7: autofs, devtmpfs, fuse.portal, proc, squashfs, subfs, debugfs, devpts, fusectl, mqueue, rpc_pipefs, sysfs, devfs, kernfs, ignore, none).
- With FILE operands the file system holding each file (or the device named) is found as GNU does, including `over-mounted by another device` and the fallback that walks up to the mount point.
- Column widths, the `1K-blocks` / `1024-blocks` / `Size` headers, the rounded-up percentage arithmetic and the negative values for over-committed file systems follow df.c.

## Known deviations and gaps

- Only /proc/self/mountinfo is read (no /etc/mtab fallback); without it df fails with the `cannot read table of mounted file systems` diagnostic.
- Remote file system detection uses the same name rules as GNU but the file systems are never contacted before statfs.
- C locale only: control characters in names become `?` and wide characters are counted as bytes.

## Tests

`sh test/test_df.sh`: 290 differential cases against GNU df 9.7 (C locale), each retried a few times because usage figures of live file systems change between the two runs.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
