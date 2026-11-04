# Sublime syntax engine: compatibility record

Status: partial, spike quality (not verified against Sublime Text or syntect).
Date: 2026-11-04. Code: `src/syntax/` (yaml.zig, definition.zig, engine.zig,
probe.zig). Regex: the `regex-zig` package, Oniguruma dialect.

## Reference

Sublime Text syntax-definition documentation (syntax.html) and the Oniguruma
regex syntax. NEITHER was consulted while writing this; behaviour below comes
from the author's recollection and from checks against two real grammars
(C++ from fmt's support/, Rust Enhanced) with no reference highlighter to
compare against. Treat all scope output as unverified.

## Supported

- YAML subset: block mappings/sequences, quoted and plain scalars, block
  scalars, flow collections, comments. Anchors/aliases/tags, multi-line quoted
  scalars and multiple documents are rejected with a line number.
- Grammar: `name`, `scope`, `file_extensions`, `first_line_match` (stored, not
  yet used for detection), `variables` (recursive `{{x}}`), contexts, `match`
  and `include` rules, `scope`, `captures`, `push`/`set`/`pop` (including
  `pop: N`), anonymous contexts, `meta_scope`, `meta_content_scope`,
  `meta_include_prototype`, the `prototype` context, cross-syntax references
  (`scope:source.x[#ctx]`, `Packages/.../X.sublime-syntax[#ctx]`) when the
  target grammar is loaded in the same Registry.
- Engine: one line at a time with state carried in a context stack, so memory
  does not grow with file size. Earliest match wins, first rule on ties.

## Reported, not silent (recorded in `Syntax.warnings`)

`extends`, `with_prototype`, `embed`, `escape`, `branch_point`/`fail`,
`clear_scopes`, `meta_prepend`/`meta_append`, patterns the regex engine
rejects, and includes or push targets that cannot be resolved. The affected
rule is skipped, so highlighting degrades instead of failing.

## Known gaps and unverified assumptions

- Order when several contexts are listed in `push`/`set`: implemented as "last
  listed is on top". UNVERIFIED against Sublime's documentation.
- Which meta scopes apply to a pop/set/push match text: see the comment at the
  top of `engine.zig`. UNVERIFIED.
- Detection uses file name / extension, then `first_line_match` (first line of the first chunk read). `hidden_file_extensions` is not used. When several grammars match, the first loaded wins.
- Rules containing `\G` are not cached and `\G` means "start of this search".
- The C++ grammar needs the C grammar loaded for includes such as
  `scope:source.c#preprocessor-line-ending`. Without it, `#include` lines never
  end. Loading sets of grammars with dependency resolution is not done yet.
- Byte-based regex: no Unicode classes or case folding (see regex-zig).
- A zero-width-match loop is broken after 64 steps by emitting one byte.
- Stack depth is capped at 256 contexts; at most 16 contexts per push.
- Embedded grammar set and license audit: not started.

## Used by cat

`cat` loads grammars from `--syntax-dir` and `~/.config/cat/syntaxes`, only for
a highlighted bat view. Measured end to end (ReleaseSafe): 400 KB of Rust in
0.41 s and 2.5 MB in 2.6 s, with max RSS 2.1 MB for both (memory does not grow
with file size). Theme: `src/syntax/theme.zig`, 16 ANSI colors, longest scope
prefix wins, innermost scope wins.

## Measured (2026-11-04, WSL2, single thread, this machine)

Rust Enhanced grammar over 96,000 lines / 2.5 MB (a 12-line sample repeated):

| build        | time    | throughput |
|--------------|---------|------------|
| ReleaseSafe  | 2.1 s   | ~1.2 MB/s  |
| ReleaseFast  | 1.5 s   | ~1.7 MB/s  |

Before the first-byte prefilter in regex-zig, ReleaseSafe took 6.6 s. The
sample is repetitive and not representative of real code; bat was not
available to compare against.

## Tests

`zig build test` (yaml, toy grammar end to end including state across lines,
lookup, loop termination, warnings). Manual: `zig-out/bin/syntax-probe`.
