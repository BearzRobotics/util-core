// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz-test root (decision 0007). `zig build fuzz` runs every fuzz test once on its
//! corpus; `zig build fuzz --fuzz` fuzzes continuously with Zig's built-in fuzzer.
//! `zig build test` also runs them once, as regression tests.
//!
//! One file per area under src/fuzz/, each owned by one author so edits do not
//! collide; add a file by adding a line here.

test {
    _ = @import("fuzz/quoting.zig");
    _ = @import("fuzz/text.zig");
    _ = @import("fuzz/lang.zig");
    _ = @import("fuzz/stream.zig");
}
