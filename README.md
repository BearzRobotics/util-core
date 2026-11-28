# util-core

Core utilities in Zig (`ls`, `cat`, `cp`, `sort`, `date`, `find`, `sed`, ...),
as a **library** (`util_core`) plus thin command-line wrappers, and a
multicall binary, `util-core` (`util-core ls ...`, or invoked through a link
named after a command; `util-core --list` lists the commands). Spec and rules: `ai/`; design
decisions and compatibility records: `docs/`.

## Build modes

```
zig build                      # everything: one binary per command, plus util-core (multicall)
zig build -Dmode=standalone    # only the one-binary-per-command executables
zig build -Dmode=multicall     # only the util-core multicall binary
zig build -Dcommands=ls,cat,cp # a subset of the commands
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # install bin/ and share/man/man1
zig build test                 # unit tests
```

Needs Zig 0.17.1. Release builds are stripped (`-Dstrip=false` keeps debug info).

## Binary size

The programs are larger than you might expect, and most of that is a fixed
cost of Zig's standard library, above all its new I/O layer, not of what the
commands do. We accept it for now and expect it to shrink as Zig improves.

Upstream issues, both open on 2026-11-28:

* [ziglang/zig #31421](https://codeberg.org/ziglang/zig/issues/31421): unused
  `std.Io` functions are not optimized out. This is the one to follow.
* [ziglang/zig #31073](https://codeberg.org/ziglang/zig/issues/31073): an empty
  program grew after Zig 0.15.2. Related; the issue does not settle the cause.

A program that does nothing, built with Zig 0.17.1 and stripped (bytes):

| Program | Build | x86_64 Linux (musl) | x86_64 Windows |
|---|---|---|---|
| `pub fn main() u8` | ReleaseSmall | 4,840 | 4,608 |
| takes `std.process.Init`, which sets up `std.Io` | ReleaseSmall | 148,016 | 439,296 |
| `pub fn main() u8` | ReleaseSafe | 298,648 | 548,864 |
| takes `std.process.Init` | ReleaseSafe, as released | 349,672 | 603,648 |

ReleaseSafe is large even without `std.Io` in the signature, from the safety
and crash-reporting code it brings in. With that and `std.Io` both switched off,
an empty program is under 5 KB again, but the commands need them.

Every standalone command pays that last figure: `true` is 353 KB on Linux and
641 KB on Windows. With about 100 programs, all of `bin/` comes to 58 MB on
Linux and 89 MB on Windows. For a small install, build only the multicall
binary (`-Dmode=multicall`) and link the command names to it;
`-Doptimize=ReleaseSmall` makes it smaller still, without ReleaseSafe's runtime
safety checks.

## Manual pages

The pages are Markdown in the dkman layout (`docs/manpages/`). `-Dman` (on by default,
`-Dman=false` to skip) installs them to `PREFIX/share/man/man1/NAME.1.md`, where
dkman and dkde-help find them; `tools/mdman-convert.py` and any Markdown-to-man tool
can produce man(7) if you need it.

## Use as a library

`build.zig.zon`: `.dependencies = .{ .util_core = .{ .url = "...", .hash = "..." } }`
(`zig fetch --save` fills both), then in `build.zig`:

```zig
const uc = b.dependency("util_core", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("util_core", uc.module("util_core"));
```

The library takes `std.Io`, parses no arguments and prints nothing it was not
asked to; each command is a module (`util_core.grep`, `util_core.diff`, ...).
See `docs/decisions/0004-library-first-architecture.md` and the header comment
of each `src/lib/*.zig`.

## Download

Prebuilt archives are attached to each [release](https://github.com/BearzRobotics/util-core/releases):
`util-core-VERSION-linux-x86_64.tar.gz` and `-linux-aarch64.tar.gz` (static musl),
with `SHA256SUMS`. Each holds
`bin/` (every command plus the `util-core` multicall binary) and `share/man/man1/`.

```
sha256sum -c --ignore-missing SHA256SUMS
tar xzf util-core-0.3.0-linux-x86_64.tar.gz
```

## Supported platforms

| Platform | Prebuilt download | Tested |
|---|---|---|
| Linux x86_64, aarch64 | yes (static musl) | x86_64: every test suite, differential against GNU |
| Windows x86_64 | no | builds from source; several commands fail or crash on real Windows (see `docs/portability.md`) |
| Windows aarch64 | no | compiled only |
| macOS x86_64, aarch64 | no | compile-checked in CI only |

macOS builds from source (`zig build`, or `-Dtarget=aarch64-macos` from another host) and is
compile-checked in CI, but no prebuilt binaries are provided because no maintainer owns a Mac.
Prebuilt macOS binaries will be offered once a volunteer with a Mac steps up to test and
maintain that platform. What works where is in `docs/portability.md`.

Cutting a release: `docs/release.md`. Changes: `CHANGELOG.md`.

## License

Copyright (c) 2026 Dakota Keeler and the util-core contributors.

util-core is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version (SPDX: `GPL-2.0-or-later`). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY. The full text is in `LICENSE`. This is an
independent implementation: it does not contain code from GNU coreutils, which
was used only as a behavioural reference.
