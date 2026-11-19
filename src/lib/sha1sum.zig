// SPDX-License-Identifier: GPL-2.0-or-later
//! sha1sum library: the shared checksum module (`hashsum.zig`) preset for this
//! command. `defaults()` gives the command's options; `generate` prints
//! checksums and `check` verifies a list.
const hashsum = @import("hashsum.zig");

pub const Options = hashsum.Options;
pub const Event = hashsum.Event;
pub const Observer = hashsum.Observer;
pub const Result = hashsum.Result;
pub const Input = hashsum.Input;
pub const Env = hashsum.Env;
pub const generate = hashsum.generate;
pub const check = hashsum.check;

/// Defaults of sha1sum.
pub fn defaults() Options {
    return Options.init(.sha1sum);
}
