# util-core

Core utilities in Zig (`ls`, `cat`, `cp`, `sort`, `date`, `find`, `sed`, ...),
as a **library** (`util_core`) plus thin command-line wrappers, and a
multicall binary, `util-core` (`util-core ls ...`, or invoked through a link
named after a command; `util-core --list` lists the commands). Spec and rules: `ai/`; design
decisions and compatibility records: `docs/`.

```
zig build                      # everything: one binary per command, plus util-core (multicall)
zig build -Dmode=standalone    # only the one-binary-per-command executables
zig build -Dmode=multicall     # only the util-core multicall binary
zig build test         # unit tests
```

Platforms: Linux (x86_64, aarch64), macOS (aarch64, x86_64) and Windows
(x86_64, aarch64) are built from any host with `-Dtarget=`, for example
`zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall`. Linux is the
reference platform and the only one the full test suites run on; macOS is
compile-checked only and Windows is checked under wine (a real Windows run is planned before release). What works where is
in `docs/portability.md`.

## License

Copyright (c) 2026 Dakota Keeler and the util-core contributors.

util-core is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version (SPDX: `GPL-2.0-or-later`). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY. The full text is in `LICENSE`. This is an
independent implementation: it does not contain code from GNU coreutils, which
was used only as a behavioural reference.
