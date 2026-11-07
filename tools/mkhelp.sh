#!/bin/sh
# mkhelp.sh CMD... : write src/help/CMD.txt from GNU's `CMD --help` (C locale),
# without the "GNU coreutils online help" footer. Run from the repository root.
for c in "$@"; do
    PATH=/usr/bin LC_ALL=C "$c" --help | awk '/^GNU coreutils online help/ { exit } { lines[n++] = $0 } END { while (n > 0 && lines[n-1] == "") n--; for (i = 0; i < n; i++) print lines[i] }' > "src/help/$c.txt"
done
