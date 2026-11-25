// SPDX-License-Identifier: GPL-2.0-or-later
//! Sublime-syntax highlighting: grammar loader and the line-oriented
//! engine (grammars are read with the yaml-zig package). See docs/decisions/0001-cat-syntax-highlighting.md.

pub const definition = @import("definition.zig");
pub const engine = @import("engine.zig");
pub const theme = @import("theme.zig");
pub const session = @import("session.zig");
pub const builtin = @import("builtin.zig");

test {
    _ = definition;
    _ = engine;
    _ = theme;
    _ = session;
}
