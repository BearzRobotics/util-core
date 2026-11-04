Core Utils — Specification
Status: Draft 0.1
Implementation language: Zig
Engineering policy: AGENTS.md
Scope: Portable command-line utilities and reusable supporting libraries
1. Purpose
Core Utils is a clean, independently usable implementation of a collection of portable command-line utilities in Zig. It aims for strong GNU command-line compatibility where applicable, while deliberately organizing commands according to portability and utility rather than reproducing GNU package boundaries.

The project is not a distribution-specific component. It must remain usable independently of DKBuilder, DKDE, and any particular Linux distribution.
2. Goals
1. Implement the selected utilities in Zig, prioritizing correctness, maintainability, and measured performance.
2. Support Linux with musl or glibc, Windows, and macOS, with platform-specific limitations documented per command.
3. Match GNU-compatible command names, options, output, exit status, and relevant edge-case behavior by default, except for explicitly documented deviations.
4. Provide modern, opt-in enhancements: ripgrep-inspired capabilities in grep, bat-inspired presentation in cat, and an optional dust-inspired terminal visualization in du.
5. Separate reusable operations from CLI argument handling and presentation.
6. Support conventional individual executables and optional multicall packaging.
7. Make command behavior testable with golden fixtures, differential tests, and platform-specific tests.
8. Prefer pure Zig implementation for the project's own code; exceptions require a documented decision.
3. Non-goals
- Reproducing GNU coreutils' exact package composition.
- Implementing commands that fundamentally require a Unix/POSIX environment; those belong in the independent util-unix project.
- Reimplementing an entire shell as part of Core Utils. sh is excluded pending a separate shell specification.
- Guaranteeing identical behavior across operating systems where filesystem, permission, process, terminal, or locale semantics differ.
- Maintaining undocumented compatibility with GNU bugs.
- Treating optional rich output as the default for pipelines or scripts.
4. Project boundaries
4.1 Core Utils versus util-unix
A command belongs in Core Utils when its primary purpose can be expressed portably across the supported systems, even if some options need platform-specific handling. A command belongs in util-unix when its essential operation depends on Unix-specific kernel, account, device, mount, terminal, or process facilities.

Package provenance is not a classification rule. Commands historically distributed by GNU findutils, grep, sed, diffutils, or other projects may be included here.

Some commands need a classification decision before implementation; see §14.
4.2 Independent projects
- Core Utils and util-unix MUST build and release independently.
- Neither project MUST depend on the other.
- Shared functionality MAY be extracted into a separately specified Zig library if reuse demonstrably justifies it.
- Do not create a generic shared framework merely to eliminate small amounts of duplication.
5. Compatibility policy
5.1 Baseline
For each command, maintain a compatibility record identifying:
- GNU or other reference implementation and version;
- relevant POSIX specification, if any;
- supported options and GNU extensions;
- expected exit codes and stdout/stderr behavior;
- platform-specific differences;
- deliberate deviations and optional enhancements;
- tests that substantiate the claimed compatibility.
Official GNU manuals, POSIX specifications, and upstream documentation are authoritative references. Do not claim complete GNU compatibility without comprehensive evidence.
5.2 Default behavior
- Preserve conventional command behavior by default, especially when stdout is redirected or piped.
- Preserve byte-oriented operation where the reference command is byte-oriented.
- Do not silently insert syntax highlighting, paging, headers, decorations, or ANSI escapes into machine-readable output.
- When output or option semantics differ intentionally, document the difference in the command's manual page and compatibility record.
- Explicit user options and configuration may enable richer behavior.
- Respect standard conventions such as --, --help, and --version where applicable.
5.3 Cross-platform behavior
- Define path, separator, symlink, file metadata, encoding, newline, locale, and terminal behavior explicitly per command.
- Avoid emulating unsupported filesystem or OS features in ways that silently change results.
- Report unsupported options clearly rather than silently ignoring them.
- Use platform abstractions only where they simplify genuine differences; keep hot-path costs measurable.
5.4 Terminal color policy
- Every command that can emit color or text-style (SGR) escapes MUST follow this policy; shared code lives in the CLI facilities (src/cli.zig: When, noColor, colorEnabled for color, styleEnabled for non-color styles) so commands cannot diverge.
- NO_COLOR: when the NO_COLOR environment variable is set to a non-empty string (any value, including "0"), commands MUST NOT add color by default. An empty value is treated as unset. (Convention: https://no-color.org; the wording here is paraphrased from memory and must be checked against the site when the policy is next reviewed.)
- Precedence, highest first: an explicit option (--color=always forces color, --color=never forbids it); configuration files; NO_COLOR; automatic detection. Automatic detection enables color only when the output stream is a terminal and TERM is not "dumb".
- The decision is made per output stream: diagnostics on stderr are judged by whether stderr is a terminal, independently of stdout.
- NO_COLOR removes color only, as the convention says. Text styles that are not colors (bold, faint, italic, underline, reverse) are not affected by NO_COLOR and follow terminal detection. "Color" means any SGR parameter that sets a foreground or background color (30-37, 38, 39, 40-47, 48, 49, 90-97, 100-107). An explicit --color=never disables every SGR sequence, color and styles alike, because it is the explicit request for plain output (project decision, as bat does); TERM=dumb and a non-terminal stream under auto also get none. Where a tool uses color to tell things apart (for example gray for secondary text) it falls back to a non-color style such as faint when only color is off. Non-escape decorations such as line numbers and grids are controlled by their own options, not by NO_COLOR.
- Deliberate deviation from GNU: where GNU tools offer --color=auto (ls, dir, vdir, grep), ours also honor NO_COLOR under auto. Explicit --color=always still forces color. Document this in each affected command's compatibility record.
- Tests: each color-capable command needs tests for NO_COLOR set, set to empty, and overridden by --color=always, run with a terminal on stdout.
6. Architecture
6.1 Native Zig library
Core operations SHOULD be implemented in one or more native Zig modules that can be imported into another Zig program through the Zig package/build system. Reusable library functions MUST NOT assume a process-wide CLI, write to stdout implicitly, or terminate the process.

Library APIs SHOULD accept explicit allocators, readers/writers, paths, or handles where appropriate, and document ownership, lifetimes, error behavior, and resource bounds.

Not every command must become a public library API: extract operations where reuse is meaningful rather than mechanically exposing internal functions.
6.2 Command frontends
Each command frontend owns:
- argument parsing and GNU-compatible option semantics;
- selection of stdin/stdout/stderr and exit status;
- command-specific help and diagnostic presentation;
- invoking reusable core operations;
- optional enhanced terminal presentation.
Shared CLI facilities MAY cover common argument conventions, terminal detection, diagnostics, and output formatting without forcing unrelated commands into one abstraction.
6.3 Optional C FFI
- Standalone library builds SHOULD offer optional C-compatible static and shared artifacts when the public native API is sufficiently defined.
- The native Zig module remains the primary interface for Zig consumers; importing it MUST NOT require linking the C wrapper.
- C headers MUST define ownership, allocation, destruction, error reporting, and supported platforms.
- The C API/ABI MUST be clearly labeled experimental and unstable while the underlying library is unstable. No source or binary compatibility guarantee is implied.
- A future stable ABI requires a separate architectural decision and compatibility policy.
7. Build and packaging modes
The build MUST support these modes where technically feasible:
1. Individual executables (default): one independently runnable executable per selected command.
2. Multicall via invocation name: one executable dispatches by its basename (argv[0]), with symlinks, hardlinks, or copies installed under command names as supported by the platform.
3. Multicall via explicit subcommand: a single executable accepts core-utils <command> [arguments...] (final binary name configurable).
Requirements:
- Dispatch MUST have deterministic behavior, including unknown-command errors and help.
- The same command implementation and tests MUST back all applicable modes.
- Builds SHOULD permit selecting a subset of commands to reduce size.
- Build scripts MUST not require the host to be Linux when targeting Windows or macOS.
- Cross-compilation and installation layout MUST be documented.
- Version, licensing, and build provenance SHOULD be reproducible.
The exact build-option names and multicall binary name are implementation decisions, not yet fixed by this specification.
8. Enhanced commands
8.1 grep
- Provide a GNU-compatible baseline, including documented regular-expression modes and exit codes.
- Add explicitly documented, opt-in ripgrep-inspired functionality where appropriate (for example recursive discovery, ignore rules, and efficient searching).
- Do not imply full ripgrep compatibility merely by implementing selected features.
- Maintain stable, script-friendly output when enhanced features are not enabled.
8.2 cat
- Provide ordinary GNU-compatible cat behavior for scripts and redirected output.
- Offer opt-in bat-inspired features such as syntax highlighting, line numbers, and optional paging.
- Clearly define when terminal-aware defaults may apply; no decorations in pipelines unless explicitly requested.
- Color follows §5.4 (NO_COLOR, --color). The bat view itself (grid, line numbers, header) is not affected by NO_COLOR; it is chosen by --decorations/--style.
- Layout of the bat view matches bat 0.26.1 byte for byte for the implemented styles (full, numbers, grid, header, header-filesize and combinations), verified by comparison in docs/compatibility/cat.md.
- Document the syntax definition and highlighting backend chosen.
8.3 du
- Provide GNU-compatible disk-usage reporting as the baseline, subject to filesystem limitations.
- Offer an optional dust-inspired terminal interface or visualization.
- Keep scanning and accounting logic independent from the TUI.
- Define handling of hardlinks, symlinks, sparse files, inaccessible paths, and filesystem boundaries.
9. Performance and resource behavior
- Prefer streaming operations for large files and pipelines.
- Avoid loading entire inputs into memory unless the command requires it or an explicit option requests it.
- Keep allocations, thread counts, caches, and buffering bounded or configurable.
- Avoid unnecessary background activity and terminal rendering in noninteractive mode.
- Benchmark representative workloads against relevant existing utilities before making performance claims.
- Performance improvements MUST NOT silently compromise correctness or compatibility.
10. Errors, diagnostics, and security
- Emit diagnostics to stderr without corrupting stdout or binary streams.
- Preserve meaningful errors and exit statuses.
- Treat file contents, paths, environment variables, and arguments as untrusted input.
- Prevent integer overflow, invalid offsets, unchecked path assumptions, and unbounded allocations where practical.
- Avoid leaking secrets or arbitrary file contents in logs.
- Support configurable debug diagnostics without adding overhead to ordinary command execution.
11. Tests and verification
- Provide Zig unit tests for reusable logic and command-level integration tests for CLI behavior.
- Use golden output and differential testing against pinned GNU versions where licensing and platform availability permit.
- Include edge cases: empty inputs, binary data, Unicode, malformed arguments, huge files, broken pipes, inaccessible paths, and allocation failures.
- Run each applicable command test under individual-executable and multicall dispatch modes.
- Include Windows, Linux, and macOS CI or document unverified targets.
- Track per-command compatibility gaps rather than representing partially implemented commands as complete.
- Validate enhanced modes separately from baseline compatibility.
12. Documentation
- AGENTS.md: portable engineering standards.
- SPEC.md: normative project requirements.
- docs/architecture.md: current implementation and module boundaries.
- docs/decisions/: rationale and consequences of significant choices.
- docs/manpages/: per-command documentation using docs/manpages/template.md.
- docs/compatibility/: per-command supported options, differences, and reference versions (recommended).
Manpages MUST document default behavior, enhanced options, portability limitations, exit statuses, and relevant examples. Cite official manuals/specifications where they substantiate claims.
13. Command inventory
Status values are intentionally blank until implementation and verification. Suggested future statuses: planned, in progress, partial, verified, deferred, excluded.
Command	Status	Notes
[		Alias/interface of test
b2sum		
base32		
base64		
basenc		
basename		
cat		Optional bat-inspired mode
cksum		
comm		
cp		
csplit		
cut		
date		Platform/locale behavior to specify
dd		
diff		Not in GNU coreutils package; deliberately included
dir		
dircolors		
dirname		
du		Optional dust-inspired TUI
echo		
env		
expr		
factor		
false		
find		Not in GNU coreutils package; deliberately included
fmt		
fold		
grep		Optional ripgrep-inspired extensions
head		
join		
locate		Database format/portability to specify
less		Pager; deliberately included
ls		
md5sum		
mkdir		
mktemp		
mv		
nl		
numfmt		
od		
paste		
printenv		
printf		
pr		
ptx		
pwd		
realpath		
rm		
rmdir		
sed		Not in GNU coreutils package; deliberately included
seq		
sha1sum		
sha224sum		
sha256sum		
sha384sum		
sha512sum		
shuf		
sleep		
sort		
split		
sum		
tac		
tail		
tee		
test		
timeout		
touch		
tr		
tree		Deliberately included
true		
truncate		
tsort		
unexpand		
uniq		
updatedb		Database format/portability to specify
vdir		
wc		
xargs		Deliberately included
yes		


Excluded pending separate specification
- sh: a shell is a distinct language/runtime project, not a portable core utility.
14. Open design decisions
These are unresolved questions, not requirements silently decided by this draft:
1. Whether date, timeout, env, locate, and updatedb can meet the desired cross-platform semantics with documented limitations.
2. Whether to keep dir, vdir, and [ as separately installed command names in every build mode.
3. ~~How cat chooses terminal enhancements by default~~ Resolved (2026-11-04): the bat view is the default only when stdout is a terminal and no GNU formatting option is given; pipes, redirects and GNU options always get GNU bytes (see 8.2).
4. ~~Which regex engine supports grep~~ Resolved (2026-11-04): a separate pure-Zig library, ~/de/regex-zig (see its SPEC.md), imported as a package. grep must provide the full GNU option set and the ripgrep feature set (ignore files, recursive/parallel walking, type filters, multiline, --json, etc.). Remaining question: the exact enumerated option inventory, to be recorded in docs/compatibility/grep.md.
5. ~~Whether less should be a full pager~~ Resolved (2026-11-04): less is a full pager implementation.
6. What scope of GNU compatibility is required for the first prototype release.
7. ~~Whether C FFI targets ship from the outset~~ Resolved (2026-11-04): Zig comes first; any C FFI is later, optional work. Dependencies on sibling libraries (e.g. regex-zig) point at a local path for now and move to a vendored GitHub tarball once the library is released.
8. Which command families share internal libraries without introducing excessive coupling.
15. Initial acceptance criteria
A prototype release is acceptable when:
- At least one representative command builds and passes tests on Linux, Windows, and macOS, or missing verification is explicitly documented.
- The default individual-executable build and both multicall dispatch modes operate correctly for supported commands.
- Native Zig library consumers can import a supported reusable operation without linking a CLI executable.
- GNU-compatible behavior and deviations are documented and tested for each command marked verified.
- Enhanced cat, grep, and du modes do not corrupt ordinary pipeline behavior.
- Build, test, installation, and command documentation are sufficient for an unrelated contributor to reproduce the results.
References to consult during implementation: GNU Coreutils manual; GNU Grep manual; GNU Findutils manual; GNU Diffutils manual; GNU Sed manual; POSIX Shell and Utilities specification; official manuals for less, ripgrep, bat, and dust. Pin versions and sections in command-specific documentation. This draft does not claim those sources were consulted or verified for each command.