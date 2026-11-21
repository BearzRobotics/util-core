// SPDX-License-Identifier: GPL-2.0-or-later
//! Grammar discovery for a command-line tool: reads `.sublime-syntax` files
//! from directories and picks a grammar for a file or a user-given name.

const std = @import("std");
const Io = std.Io;
const def = @import("definition.zig");
const Theme = @import("theme.zig").Theme;
const builtin_set = @import("builtin.zig");

pub const Session = struct {
    gpa: std.mem.Allocator,
    reg: def.Registry,
    theme: Theme = .{},
    /// Files that could not be read or parsed, across all loadDir calls.
    failed: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Session {
        return .{ .gpa = gpa, .reg = def.Registry.init(gpa) };
    }

    pub fn deinit(s: *Session) void {
        s.theme.deinit(s.gpa);
        s.reg.deinit();
    }

    /// Load every `*.sublime-syntax` file directly inside `dir_path`.
    /// A missing directory is not an error. Returns the number loaded.
    pub fn loadDir(s: *Session, io: Io, dir_path: []const u8) !usize {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var loaded: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sublime-syntax")) continue;
            const text = dir.readFileAlloc(io, entry.name, s.gpa, .limited(8 << 20)) catch {
                s.failed += 1;
                continue;
            };
            defer s.gpa.free(text);
            const full = try std.Io.Dir.path.join(s.gpa, &.{ dir_path, entry.name });
            defer s.gpa.free(full);
            _ = s.reg.load(text, full) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    s.failed += 1;
                    continue;
                },
            };
            loaded += 1;
        }
        return loaded;
    }

    /// Load the grammars built into the binary. Call after `loadDir` so a
    /// user's grammar is found first. Returns the number loaded.
    pub fn loadBuiltin(s: *Session) !usize {
        var loaded: usize = 0;
        for (builtin_set.grammars) |g| {
            _ = s.reg.load(g.text, g.file) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    s.failed += 1;
                    continue;
                },
            };
            loaded += 1;
        }
        return loaded;
    }

    /// Find a grammar by what the user typed: full name ("Rust Enhanced"),
    /// scope ("source.rust"), the last part of the scope ("rust") or a file
    /// extension ("rs"), case-insensitively, in that order.
    pub fn byUserName(s: *Session, name: []const u8) ?*def.Syntax {
        if (s.reg.byName(name)) |x| return x;
        if (s.reg.byScope(name)) |x| return x;
        for (s.reg.syntaxes.items) |syn| {
            const dot = std.mem.lastIndexOfScalar(u8, syn.scope_name, '.') orelse continue;
            if (std.ascii.eqlIgnoreCase(syn.scope_name[dot + 1 ..], name)) return syn;
        }
        for (s.reg.syntaxes.items) |syn| for (syn.extensions) |e| {
            if (std.ascii.eqlIgnoreCase(e, name)) return syn;
        };
        return null;
    }
};

test "user-supplied names resolve by name, scope, scope tail and extension" {
    const gpa = std.testing.allocator;
    var s = Session.init(gpa);
    defer s.deinit();
    const syn = try s.reg.load(
        \\name: Rust Enhanced
        \\scope: source.rust
        \\file_extensions: [rs]
        \\contexts:
        \\  main: []
    , "R.sublime-syntax");
    try std.testing.expect(s.byUserName("rust enhanced") == syn);
    try std.testing.expect(s.byUserName("source.rust") == syn);
    try std.testing.expect(s.byUserName("Rust") == syn);
    try std.testing.expect(s.byUserName("RS") == syn);
    try std.testing.expect(s.byUserName("go") == null);
}

test "every built-in grammar loads without warnings, and common files are detected" {
    const gpa = std.testing.allocator;
    var s = Session.init(gpa);
    defer s.deinit();
    const n = try s.loadBuiltin();
    try std.testing.expectEqual(builtin_set.grammars.len, n);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    for (s.reg.syntaxes.items) |syn| {
        if (syn.warnings.items.len != 0) {
            std.debug.print("{s}: {s}\n", .{ syn.name, syn.warnings.items[0] });
            return error.GrammarHasWarnings;
        }
    }
    const cases = [_]struct { path: []const u8, scope: []const u8 }{
        .{ .path = "main.zig", .scope = "source.zig" },
        .{ .path = "lib.rs", .scope = "source.rust" },
        .{ .path = "x.py", .scope = "source.python" },
        .{ .path = "a.c", .scope = "source.c" },
        .{ .path = "a.hpp", .scope = "source.cpp" },
        .{ .path = "Makefile", .scope = "source.makefile" },
        .{ .path = "x.json", .scope = "source.json" },
        .{ .path = "README.md", .scope = "text.html.markdown" },
    };
    for (cases) |c| {
        const syn = s.reg.detect(c.path, "") orelse {
            std.debug.print("no grammar for {s}\n", .{c.path});
            return error.NotDetected;
        };
        if (!std.mem.startsWith(u8, syn.scope_name, c.scope[0..@min(c.scope.len, 8)])) {
            std.debug.print("{s}: got {s}, wanted {s}\n", .{ c.path, syn.scope_name, c.scope });
            return error.WrongGrammar;
        }
    }
}
