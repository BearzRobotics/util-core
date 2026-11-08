#!/bin/sh
# Build GNU findutils (find, xargs, locate, updatedb, frcode) from source for
# use as the oracle of test/test_locate.sh and test/test_updatedb.sh.
# Usage: tools/build-gnu-findutils.sh [PREFIX]   (default: $HOME/.cache/util-core/findutils)
set -e
PREFIX="${1:-$HOME/.cache/util-core/findutils}"
VER=4.10.0
WORK="$(mktemp -d)"
cd "$WORK"
curl -sLO "https://ftp.gnu.org/gnu/findutils/findutils-$VER.tar.xz"
tar xf "findutils-$VER.tar.xz"
cd "findutils-$VER"
./configure --prefix="$PREFIX" --disable-nls >/dev/null
make -j4 >/dev/null
make install >/dev/null
echo "installed in $PREFIX (set GNU_BIN=$PREFIX/bin to use it)"
