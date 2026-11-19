// SPDX-License-Identifier: GPL-2.0-or-later
//! base64 library: the shared encoder in `baseenc.zig` with `Kind.base64`.
//! Use `run(env, .{ .kind = .base64, ... }, input, writer)`.
pub const baseenc = @import("baseenc.zig");
pub const Options = baseenc.Options;
pub const Result = baseenc.Result;
pub const Input = baseenc.Input;
pub const Env = baseenc.Env;
pub const run = baseenc.run;
