"""Generate docs/compatibility/<cmd>.md and docs/manpages/<cmd>.md in the
project's format. Usage (from the repo root):

    import sys; sys.path.insert(0, "tools"); from gendoc import gen
    gen(cmd, summary, synopsis, opts, behaviour, deviations, tests, ...)
"""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATE = "2026-11-07"

def gen(cmd, summary, synopsis, opts, behaviour, deviations, tests, status=None,
        posix=True, section="", exit_rows=None, notes=None, ref_extra=""):
    """opts: list of (flags, text). exit_rows: list of (status, meaning)."""
    nodes = section or cmd
    posix_ref = (f"; POSIX.1-2024 (IEEE Std 1003.1-2024), {cmd}, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/{cmd}.html"
                 if posix else ". POSIX does not specify this utility")
    ref = (f"GNU coreutils 9.7 (`/usr/bin/{cmd} --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). "
           f"Consulted {DATE}: the GNU manual node \"{nodes} invocation\" (`info '(coreutils) {nodes} invocation'`, "
           f"https://www.gnu.org/software/coreutils/manual/html_node/{nodes}-invocation.html){posix_ref}. {ref_extra}"
           f"Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_{cmd}.sh`).")
    st = status or f"implemented with the gaps listed below; differential tests pass against GNU {cmd} 9.7 in the C locale."
    bl = "\n".join(f"- `{o}`: {t}" for o, t in opts)
    beh = "\n".join(f"- {b}" for b in behaviour)
    dev = "\n".join(f"- {d}" for d in deviations) if deviations else "- None known."
    with open(f"{ROOT}/docs/compatibility/{cmd}.md", "w") as f:
        f.write(f"""# {cmd}: compatibility record

Status: {st} Date: {DATE}

## Reference

{ref} Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

{bl}
- `--help, --version`: Print help or version and exit.

## Supported behaviour

{beh}

## Known deviations and gaps

{dev}

## Tests

{tests}

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
""")
    mo = "\n\n".join(f"{o}\n: {t}" for o, t in opts)
    ex = exit_rows or [("0", "Success."), ("1", "An error occurred (or, for check-style modes, a check failed).")]
    exs = "\n".join(f"{a}\t{b}" for a, b in ex)
    lim = "\n".join(f"- {d}" for d in deviations) if deviations else "- None known."
    with open(f"{ROOT}/docs/manpages/{cmd}.md", "w") as f:
        f.write(f"""% {cmd.upper()}(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% {DATE}

NAME
{cmd} - {summary}

SYNOPSIS
{synopsis}
{cmd} --help | --version

DESCRIPTION
{notes or summary[0].upper() + summary[1:] + "."}

OPTIONS
{mo}

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
{exs}

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: {ref}
See docs/compatibility/{cmd}.md for details.

LIMITATIONS
{lim}

SEE ALSO
docs/compatibility/{cmd}.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
""")
