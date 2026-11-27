#!/bin/sh
# Run scripts/run-suites.sh with the GNU versions the suites are written against
# (Ubuntu 26.04: coreutils 9.7, diffutils 3.12, grep 3.12, less 668), in a
# throwaway container and as an ordinary user. Build first, then:
#
#   docker run --rm --tmpfs /tmp:exec,mode=1777 --security-opt apparmor=unconfined \
#       -v "$PWD:/src:ro" ubuntu:26.04 sh /src/scripts/suites-container.sh [SUITE...]
#
# /tmp is a tmpfs because tail -f behaves differently on the overlay file
# system. Docker's AppArmor profile fails paths over 8 KiB, which the deep-tree
# tests of du need.
set -e
[ -f /.dockerenv ] || { echo "suites-container: this installs packages; run it in a container" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
# Ubuntu ships uutils as coreutils; the suites compare against GNU.
apt-get install -y -qq --allow-remove-essential coreutils-from-gnu coreutils-from-uutils- \
    diffutils findutils grep sed less time tree python3 ripgrep ugrep xz-utils zstd bzip2 >/tmp/apt.log 2>&1 ||
    { cat /tmp/apt.log; exit 1; }

useradd --create-home tester
mkdir /work
tar -C /src --exclude=./.git --exclude=./.claude --exclude=./.zig-cache --exclude=./zig-pkg -cf - . | tar -C /work -xf -
chown -R tester /work
exec setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester LC_ALL=C.UTF-8 \
    sh /work/scripts/run-suites.sh "$@"
