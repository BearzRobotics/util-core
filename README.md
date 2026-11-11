# util-core

Core utilities in Zig (`ls`, `cat`, `cp`, `sort`, `date`, `find`, `sed`, ...),
as a **library** (`util_core`) plus thin command-line wrappers, and a
multicall binary, `main` (`main ls ...`, or invoked through a link named after
a command; `main --list` lists the commands). Spec and rules: `ai/`; design
decisions and compatibility records: `docs/`.

```
zig build              # one binary per command in zig-out/bin, plus main (multicall)
zig build test         # unit tests
```

## License

Copyright (c) 2026 Dakota Keeler and the util-core contributors.

util-core is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version (SPDX: `GPL-2.0-or-later`). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY. The full text is in `LICENSE`. This is an
independent implementation: it does not contain code from GNU coreutils, which
was used only as a behavioural reference.
