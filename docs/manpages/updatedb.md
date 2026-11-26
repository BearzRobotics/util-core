# NAME

updatedb - create or update a locate database

# SYNOPSIS

    updatedb [OPTION]...
    updatedb --help | --version

# DESCRIPTION

Create or update a locate database.

# OPTIONS

--localpaths=DIRS, --netpaths=DIRS
: Directories to index (shell-style globbing is applied).

--prunepaths=DIRS, --prunefs=TYPES
: Paths and file-system types to skip.

--output=FILE, --dbformat=FORMAT
: Output database and format (LOCATE02 or slocate).

--findoptions=OPTS
: Extra options for the file walk (-xdev, -depth, -maxdepth, -mindepth, -noleaf, ...).

--localuser=USER
: Search the local paths as USER, so that the database holds only the names USER
can find. Without it they are searched as the caller; a database built by root
then lists every file, and anyone can read it.

--netuser=USER
: When run by root, search the network paths as USER (default `daemon`).

--help, --version
: Print help or version and exit.

# DIFFERENCES FROM GNU

- GNU runs the search through `su`. Here updatedb itself takes the user's
  effective user id, group id and supplementary groups (from /etc/passwd and
  /etc/group; users known only through NSS, such as LDAP, are not found) while
  it searches, then takes its own back to write the database. No login shell is
  involved.
- If the search cannot be done as the named user (unknown user, or the caller
  is neither root nor that user) updatedb says so, writes nothing and exits 1.
  GNU's `su` asks for a password, also when USER is the caller. Naming
  yourself here changes nothing.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | An error occurred (or, for check-style modes, a check failed). |


# ENVIRONMENT

LOCATE_PATH (locate); FINDOPTIONS, SEARCHPATHS, NETPATHS, PRUNEPATHS, PRUNEFS, LOCALUSER, NETUSER, LOCATE_DB (updatedb). Locale variables are ignored.

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C.

See docs/compatibility/updatedb.md for details.

# LIMITATIONS

- --localuser/--netuser work on Linux only; elsewhere a request to change user fails.
- Databases are byte-identical to GNU's in all tested cases.

# SEE ALSO

docs/compatibility/updatedb.md, docs/architecture.md

# VERSION

This manual describes util-core 0.2.0.

