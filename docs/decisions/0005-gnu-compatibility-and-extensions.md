# 0005: GNU compatibility is the default; extensions are documented exceptions

Status: accepted by the maintainer. Date: 2026-11-19.

## Context

util-core reimplements GNU coreutils 9.7 (plus sed, grep, find, tree and
locate from their GNU/reference versions). Some commands deliberately do more:
`cat` on a terminal shows a bat-style view, `grep` is meant to carry ripgrep
and FreeBSD extensions, and `--json` exists on record-producing commands.
Those must not erode compatibility, and a reader must be able to see exactly
where the behaviour departs from GNU.

## Decision

1. **Compatible by default.** For every invocation that GNU accepts, with
   standard output not a terminal, stdout bytes, stderr text and the exit
   status equal GNU's (differential suites against the real binaries).
   Piped `cat` stays byte-exact GNU.
2. **An extension is allowed only in one of these forms**, and each must
   be documented:
   - *Presentation on a terminal*: output styling when stdout is a tty and the
     user passed no GNU formatting option (cat's bat view). It must be
     switchable off by a flag and never applies to pipes or redirects.
   - *New options*: a long (or otherwise unused) option GNU does not define
     (`--json`, ripgrep- and FreeBSD-derived grep options). It must not
     change the meaning of any GNU option and is absent from `--help` text that
     is compared with GNU's, unless the command's compatibility record says
     the help is ours.
   - *Behaviour GNU leaves undefined or rejects*: only if GNU's own
     result for that input is an error, never a different success.
3. **Every extension and every deviation is recorded.** Each
   `docs/compatibility/<cmd>.md` has an "Extensions" section (what, why, how
   to turn it off, which test covers it) and a "Known deviations and gaps"
   section (where we are *not* GNU and would like to be). The index is
   `docs/compatibility/extensions.md`.
4. **Each extension has a test** that checks both the extension and that the
   GNU path is unchanged.
5. A deviation without a record is a bug, to be fixed to match GNU or
   documented here.
6. Library modules (decision 0004) implement GNU behaviour; extensions are
   `Options` fields that default to GNU behaviour, so a library caller gets GNU
   unless it asks otherwise.
