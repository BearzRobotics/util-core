# NAME

util-core - multicall binary for the util-core command set

# SYNOPSIS

    util-core COMMAND [ARGUMENT]...
    util-core --list
    util-core --help
    COMMAND [ARGUMENT]...        (through a link named after the command)

# DESCRIPTION

`util-core` contains every util-core command in one executable. It runs the command named by its first operand, or by the name it was invoked as: a link or copy named `ls` runs `ls`.

The commands behave exactly as the standalone executables built with `zig build -Dmode=standalone`; both are the same code behind the same library (`util_core`). Each command has its own page, for example `ls(1)`.

# OPTIONS

`--list`
: Print the names of the commands this binary contains, one per line.

`--help`
: Print a short usage message and exit with status 0.

# EXIT STATUS

| Status | Meaning |
|---|---|
| the command's | The command's own exit status. |
| 127 | `COMMAND` is not one of the enabled commands (the shell's "command not found" status). |
| 2 | No command was given. |

# EXAMPLES

Run a command through the multicall binary:

    util-core wc -l file

Install links so the commands can be used by name:

    for c in $(util-core --list); do ln -s util-core "$c"; done

# BUILDING

`zig build -Dmode=multicall` builds only this binary, `-Dmode=standalone` only the per-command executables, and `-Dmode=all` (the default) both. `-Dcommands=a,b,c` limits the commands included.

# SEE ALSO

The page of each command; `docs/decisions/0004-library-first-architecture.md` for the library layout.
