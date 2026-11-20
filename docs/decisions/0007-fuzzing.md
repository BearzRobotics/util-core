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

## Update 2026-11-20: our own engine, memory caps and the session-killing incident

- **Zig 0.17.1's built-in fuzzer does not run in this environment.** A 20-line project
  reproduces it: `zig build test --fuzz` reports "corrupted coverage file ... pcs_len was
  zero" without `.fuzz = true`, and with it the instrumented binary segfaults in
  `fuzzer_start_test`. Until that is fixed upstream, targets are driven by
  `src/fuzz/engine.zig` (a mutation engine with corpus, splicing, a dictionary of
  troublesome tokens, deterministic seeds). Targets keep the standard
  `fn (ctx, *std.testing.Smith) !void` shape (`Smith.in` is set directly from the bytes),
  so only the call `std.testing.fuzz` becomes `engine.fuzz`; they can move to Zig's fuzzer
  unchanged later. The engine is not coverage-guided: seed corpora matter.
- **Memory is capped.** Every target allocates from `limits.Capped` (64 MiB of live
  bytes, forwarding to `std.testing.allocator` so leaks still fail). `error.OutOfMemory`
  from the cap is a valid outcome; an input that makes a library ask for hundreds of
  megabytes is still worth a report, because the library should refuse such a size with a
  clear message (decision 0005 update).
- **Campaigns run only through `tools/fuzz.sh`**, which starts `zig build fuzz` in a
  transient systemd scope with `MemoryMax` and `RuntimeMaxSec`; hitting either kills every
  process in the scope. Never run a campaign binary directly and never leave one
  running: `timeout` on `zig build` does not kill the test binary it started.
- **Why:** on 2026-11-19 (23:34) and 2026-11-20 (03:23) a Zig test binary named `test`
  grew to 20 and 23 GB, the kernel's out-of-memory kill took it, and systemd then killed
  the whole terminal scope (`Failed with result 'oom-kill'`), including the Claude Code
  session and its agents. Nothing about `sh` or signals was involved.
- A crash or hang cannot be caught in-process: before each run the input is written to
  `$FUZZ_CURRENT`, which is the reproducer; a returned error saves the input to
  `$FUZZ_FINDINGS`.
