// SPDX-License-Identifier: GPL-2.0-or-later
//! Grammars shipped inside the binary: our own `.sublime-syntax` files in
//! `src/syntax/builtin/`, written for this project (no third-party grammar
//! text, so no license audit is needed; decision 0001). `Session.loadBuiltin`
//! loads them after any user grammars, so a user's file of the same name or
//! extension wins.
//!
//! To add a grammar: put the file in `src/syntax/builtin/` and list it here.

pub const Entry = struct { file: []const u8, text: []const u8 };

pub const grammars = [_]Entry{
    .{ .file = "asm.sublime-syntax", .text = @embedFile("builtin/asm.sublime-syntax") },
    .{ .file = "batch.sublime-syntax", .text = @embedFile("builtin/batch.sublime-syntax") },
    .{ .file = "c.sublime-syntax", .text = @embedFile("builtin/c.sublime-syntax") },
    .{ .file = "cmake.sublime-syntax", .text = @embedFile("builtin/cmake.sublime-syntax") },
    .{ .file = "conf.sublime-syntax", .text = @embedFile("builtin/conf.sublime-syntax") },
    .{ .file = "cpp.sublime-syntax", .text = @embedFile("builtin/cpp.sublime-syntax") },
    .{ .file = "csharp.sublime-syntax", .text = @embedFile("builtin/csharp.sublime-syntax") },
    .{ .file = "css.sublime-syntax", .text = @embedFile("builtin/css.sublime-syntax") },
    .{ .file = "diff.sublime-syntax", .text = @embedFile("builtin/diff.sublime-syntax") },
    .{ .file = "dockerfile.sublime-syntax", .text = @embedFile("builtin/dockerfile.sublime-syntax") },
    .{ .file = "dotenv.sublime-syntax", .text = @embedFile("builtin/dotenv.sublime-syntax") },
    .{ .file = "gitignore.sublime-syntax", .text = @embedFile("builtin/gitignore.sublime-syntax") },
    .{ .file = "go.sublime-syntax", .text = @embedFile("builtin/go.sublime-syntax") },
    .{ .file = "haskell.sublime-syntax", .text = @embedFile("builtin/haskell.sublime-syntax") },
    .{ .file = "html.sublime-syntax", .text = @embedFile("builtin/html.sublime-syntax") },
    .{ .file = "ini.sublime-syntax", .text = @embedFile("builtin/ini.sublime-syntax") },
    .{ .file = "java.sublime-syntax", .text = @embedFile("builtin/java.sublime-syntax") },
    .{ .file = "javascript.sublime-syntax", .text = @embedFile("builtin/javascript.sublime-syntax") },
    .{ .file = "json.sublime-syntax", .text = @embedFile("builtin/json.sublime-syntax") },
    .{ .file = "kotlin.sublime-syntax", .text = @embedFile("builtin/kotlin.sublime-syntax") },
    .{ .file = "lua.sublime-syntax", .text = @embedFile("builtin/lua.sublime-syntax") },
    .{ .file = "makefile.sublime-syntax", .text = @embedFile("builtin/makefile.sublime-syntax") },
    .{ .file = "markdown.sublime-syntax", .text = @embedFile("builtin/markdown.sublime-syntax") },
    .{ .file = "nim.sublime-syntax", .text = @embedFile("builtin/nim.sublime-syntax") },
    .{ .file = "odin.sublime-syntax", .text = @embedFile("builtin/odin.sublime-syntax") },
    .{ .file = "perl.sublime-syntax", .text = @embedFile("builtin/perl.sublime-syntax") },
    .{ .file = "php.sublime-syntax", .text = @embedFile("builtin/php.sublime-syntax") },
    .{ .file = "powershell.sublime-syntax", .text = @embedFile("builtin/powershell.sublime-syntax") },
    .{ .file = "python.sublime-syntax", .text = @embedFile("builtin/python.sublime-syntax") },
    .{ .file = "ruby.sublime-syntax", .text = @embedFile("builtin/ruby.sublime-syntax") },
    .{ .file = "rust.sublime-syntax", .text = @embedFile("builtin/rust.sublime-syntax") },
    .{ .file = "shell.sublime-syntax", .text = @embedFile("builtin/shell.sublime-syntax") },
    .{ .file = "sql.sublime-syntax", .text = @embedFile("builtin/sql.sublime-syntax") },
    .{ .file = "swift.sublime-syntax", .text = @embedFile("builtin/swift.sublime-syntax") },
    .{ .file = "toml.sublime-syntax", .text = @embedFile("builtin/toml.sublime-syntax") },
    .{ .file = "typescript.sublime-syntax", .text = @embedFile("builtin/typescript.sublime-syntax") },
    .{ .file = "vim.sublime-syntax", .text = @embedFile("builtin/vim.sublime-syntax") },
    .{ .file = "xml.sublime-syntax", .text = @embedFile("builtin/xml.sublime-syntax") },
    .{ .file = "yaml.sublime-syntax", .text = @embedFile("builtin/yaml.sublime-syntax") },
    .{ .file = "zig.sublime-syntax", .text = @embedFile("builtin/zig.sublime-syntax") },
};
