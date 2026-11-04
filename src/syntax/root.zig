//! Sublime-syntax highlighting: YAML subset reader, grammar loader, and the
//! line-oriented engine. See docs/decisions/0001-cat-syntax-highlighting.md.

pub const yaml = @import("yaml.zig");
pub const definition = @import("definition.zig");
pub const engine = @import("engine.zig");
pub const theme = @import("theme.zig");
pub const session = @import("session.zig");

test {
    _ = yaml;
    _ = definition;
    _ = engine;
    _ = theme;
    _ = session;
}
