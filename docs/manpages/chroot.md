% CHROOT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
chroot - run a command with a different root directory

SYNOPSIS
chroot [OPTION] NEWROOT [COMMAND [ARG]...]
chroot --help | --version

DESCRIPTION
Run a command with a different root directory.

OPTIONS
--skip-chdir
: Do not change directory to / (only allowed when NEWROOT is /).

--userspec=USER[:GROUP], --groups=G,...
: Accepted, but exit with status 125: not supported.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
125	chroot itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/chroot --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chroot invocation" (`info '(coreutils) chroot invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chroot-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chroot, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chroot.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chroot.sh`).
See docs/compatibility/chroot.md for details.

LIMITATIONS
- `--userspec` and `--groups` are not implemented.
- Needs CAP_SYS_CHROOT. The privileged path (running a command inside the new root) was not exercised on the development machine, which has no root access; the tests compare diagnostics as an unprivileged user.
- GNU installs `chroot` in /usr/sbin; the test harness uses that directory as the oracle.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/chroot.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
