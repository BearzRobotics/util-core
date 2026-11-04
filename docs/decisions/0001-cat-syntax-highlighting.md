# 0001: Syntax highlighting backend for cat

Status: accepted by the maintainer; step 1 started. Date: 2026-11-04

## Context

SPEC §8.2 requires bat-inspired syntax highlighting in `cat` and a documented
backend choice. Requirements: support many languages, stream input (SPEC §9),
no highlighting in pipes by default, and keep the project's own code pure Zig
unless a decision says otherwise (SPEC §3.8).

bat uses syntect with Sublime `.sublime-syntax` grammars. As recalled (not
re-verified against bat's source in this session), it reads and highlights one
line at a time, carrying parser state between lines.

## Decision

1. Implement a **line-oriented Sublime-syntax engine in pure Zig**: grammars are
   data, the engine keeps a context stack between lines, so memory use is
   independent of file size.
2. Use the **regex engine in pure Zig** from the independent `regex-zig`
   package (`~/de/regex-zig`, SPEC there), shared with `grep` and `sed`.
   No C dependency. Step 1 (Perl/Oniguruma parser and bounded backtracker) is
   implemented; see its docs/compatibility/perl.md.
3. **Load grammars as data**: a directory of `.sublime-syntax` files (user
   config dir) plus a set embedded at build time. A small YAML-subset reader
   (only what the format needs) is part of the engine.

## Regex engine constraint (important)

Sublime grammars rely on Oniguruma features: lookahead and lookbehind,
backreferences, `\G`, atomic groups, possessive quantifiers, Unicode classes.
These cannot be matched by a linear-time automaton (RE2 style), which is what
ripgrep-style `grep` wants by default. So the shared module has:

- one parser and AST (flags, classes, anchors, groups, Unicode properties);
- a **linear-time backend** (Pike VM / DFA) for `grep` default searching;
- a **backtracking backend** for syntax grammars and for `grep -P` / `--pcre2`
  style features, with a step limit to bound worst-case time (SPEC §10).

The single-engine alternative would force grep onto a backtracker and lose its
performance and worst-case guarantees.

## Alternatives considered

- Hand-written lexers per language: tens of languages at most; high upkeep.
- Vendored tree-sitter: C runtime plus per-language generated C. Parses whole
  buffers, so it does not stream; needs a size cap and differs from bat.
- Vendored Oniguruma plus Zig engine: viable fallback if the Zig backtracker
  proves too slow or too incomplete (decided by the spike below).

## Consequences

- Large up-front cost: regex engine, YAML subset, Sublime engine, theme mapping.
- Highlighting quality is bounded by how much of Oniguruma we implement; the
  compatibility record must list unsupported constructs.
- Embedded grammars need a **license audit** per grammar before inclusion. Not
  done. Until then, only user-supplied grammars load.
- Themes: map scopes to terminal colors (16 and 256 color, truecolor optional).

## Plan

1. Regex module: parser and AST, backtracking backend, tests from the
   Oniguruma/PCRE feature set the grammars use. Spike: run a few real grammars
   (e.g. JSON, shell, Markdown) against sample files; measure speed.
2. YAML subset reader and Sublime context engine.
3. Theme mapping and cat integration (`-l/--language`, auto-detect by
   extension and first line).
4. Linear-time backend and grep integration.
5. License audit and embedded grammar set.

Go/no-go after step 1: if the backtracker cannot run the spike grammars at
acceptable speed, revisit vendored Oniguruma.

## Status (2026-11-04)

Step 1 (regex parser and backtracker) and step 2 (YAML subset, grammar loader,
line engine) exist as a spike; see docs/compatibility/sublime-syntax.md.

Go/no-go measurement: the Rust Enhanced grammar highlights 2.5 MB in about
2.1 s (ReleaseSafe) after adding a first-byte prefilter to regex-zig (6.6 s
before). Throughput is acceptable for the typical `cat` use (source files of
tens of KB, tens of ms) and is not yet competitive for multi-megabyte files.
Decision: continue with the pure-Zig engine; do not vendor Oniguruma yet.
Further speedups to try, in order: literal-prefix scanning, anchored-pattern
shortcuts (`^...`), single-byte loop specialisation, then a lazy DFA for
patterns without back-references or look-around.

Open: scope-assembly rules and push-order are from memory and unverified;
the grammar set needs a license audit; UTF-8 matching is not implemented.

## Step 3 status (2026-11-04)

`cat` now highlights through this engine: grammar discovery
(`src/syntax/session.zig`), a 16-colour theme (`theme.zig`), `-l/--language`,
`--syntax-dir`, `--list-languages`, detection by name then first line. No
grammars are bundled, pending the license audit (step 5).
