#!/bin/sh
# Build GNU findutils (find, xargs, locate, updatedb, frcode) from source for
# use as the oracle of test/test_locate.sh and test/test_updatedb.sh.
# Usage: tools/build-gnu-findutils.sh [PREFIX]   (default: $HOME/.cache/util-core/findutils)
set -e
PREFIX="${1:-$HOME/.cache/util-core/findutils}"
VER=4.10.0
# What is fetched is run, so it must be the release itself. This digest is of a
# copy whose signature (findutils-4.10.0.tar.xz.sig) was checked with the GNU
# keyring on 2026-11-27: Bernhard Voelker, key A5189DB69C1164D33002936646502EF796917195.
SHA256=1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSLO "https://ftp.gnu.org/gnu/findutils/findutils-$VER.tar.xz"
echo "$SHA256  findutils-$VER.tar.xz" | sha256sum -c --quiet || { echo "findutils-$VER.tar.xz is not the expected file; nothing was run" >&2; exit 1; }
tar xf "findutils-$VER.tar.xz"
cd "findutils-$VER"
./configure --prefix="$PREFIX" --disable-nls >/dev/null
make -j4 >/dev/null
make install >/dev/null
echo "installed in $PREFIX (set GNU_BIN=$PREFIX/bin to use it)"
