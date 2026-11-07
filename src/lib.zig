//! Public library surface of util-core (the `util_core` module).
//!
//! Everything else under src/ is internal. Consumers add the dependency in
//! build.zig.zon and `exe.root_module.addImport("util_core",
//! dep.module("util_core"))`.

/// Command context and output helpers (`cli.Context` is what every command's
/// `main` takes).
pub const cli = @import("cli.zig");
/// Registry of commands: `commands.all`, `commands.get("ls")`, `commands.find`.
pub const commands = @import("commands.zig");
/// getopt_long-compatible option parser with glibc diagnostics.
pub const getopt = @import("getopt.zig");
/// TZif / POSIX TZ time zones and civil-date arithmetic.
pub const tz = @import("tz.zig");
/// GNU-compatible strftime (C locale).
pub const strftime = @import("strftime.zig");
/// Port of GNU's date-string parser.
pub const datetime = @import("datetime.zig");
/// Exact C-style floating-point formatting.
pub const fmt_float = @import("fmt_float.zig");
/// POSIX BRE/ERE translation onto the regex package.
pub const posixre = @import("posixre.zig");
/// Message digests (md5, sha*, blake2b, ...).
pub const hash = @import("hash.zig");
/// chmod-style symbolic and octal mode parsing.
pub const mode = @import("mode.zig");
