// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz-test root (decision 0007). `zig build test` runs every test here as a short
//! regression test: each corpus entry, then a few mutations. A longer campaign is
//! `sh tools/fuzz.sh`, which runs `zig build fuzz` under a memory cap and a time
//! limit; both use src/fuzz/engine.zig. (Zig's built-in `--fuzz` does not work.)
//! Only file-name quoting is covered so far: text, lang and stream are placeholders.
//!
//! One file per area under src/fuzz/, each owned by one author so edits do not
//! collide; add a file by adding a line here.

test {
    _ = @import("fuzz/limits.zig");
    _ = @import("fuzz/engine.zig");
    _ = @import("fuzz/quoting.zig");
    _ = @import("fuzz/text.zig");
    _ = @import("fuzz/lang.zig");
    _ = @import("fuzz/stream.zig");
}
