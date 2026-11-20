// SPDX-License-Identifier: GPL-2.0-or-later
//! Thin adapter over the regex package so callers see one small error set.
//!
//! regex-zig 0.3.0 made `searcher` return an inferred error set that includes
//! `error.GaveUp`, the lazy DFA's "cache exhausted" signal. Searches fall back
//! to the Pike VM on their own; failing to *create* a searcher means the
//! matcher could not get its working memory, which callers treat like any
//! other allocation failure.

const std = @import("std");
const regex = @import("regex");

/// `re` is a `regex.Regex` or `regex.RegexSet`.
pub fn searcher(re: anytype, gpa: std.mem.Allocator) error{OutOfMemory}!regex.Searcher {
    return re.searcher(gpa) catch error.OutOfMemory;
}
