# 0007: Fuzzing with Zig's built-in fuzzer

Status: accepted by the maintainer. Date: 2026-11-19.

## Decision

Every library entry point that consumes untrusted bytes (patterns, scripts, formats,
numbers, dates, file contents) has a fuzz test under `src/fuzz/`, written with
`std.testing.fuzz` (the `Smith` input type). `zig build fuzz` runs them once on their
corpus; `zig build fuzz --fuzz` fuzzes continuously; `zig build test` runs them once as
regression tests. Library-first (decision 0004) is what makes this possible: a fuzz test
calls the library with generated `Options` and input, with no process or terminal.

## Rules

- A fuzz test checks invariants, not output equality: no crash, no hang (bounded work),
  no leak (use `std.testing.allocator`), no out-of-bounds, and well-formed output.
  Where a GNU oracle exists, a separate script compares on the inputs the fuzzer found.
- Seed corpora come from the existing differential suites and real-world inputs.
- A crash or hang found is fixed, the fixing input is added to the corpus, and the fix
  must keep the GNU differential suite at its count.
- One file per area, each with one owner at a time: quoting, text, lang, stream.
