// SPDX-License-Identifier: GPL-2.0-or-later
//! tsort library (decision 0004): topological sort.
//! References: GNU coreutils manual "tsort invocation" (9.7); POSIX.1-2024.
//!
//! Input is pairs of whitespace-separated strings meaning "first before
//! second"; equal strings only register the item. Output order reproduces
//! GNU: nodes with no predecessors seed a first-in-first-out queue in byte
//! order; finishing a node releases its successors in reverse order of
//! insertion. Cycles: when the queue empties with nodes left, a cycle is
//! reported (a `loop` event, then one `loop_node` event per node), its
//! closing edge is dropped, and sorting resumes.
//!
//! Known deviation: GNU's choice of *which* cycle to report and where to
//! start it follows its internal tree walk. This implementation models that
//! walk (and agrees with GNU on most small graphs, always on acyclic input)
//! but cannot guarantee identical diagnostics for every cyclic graph.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {};

pub const Kind = enum {
    /// The input could not be opened (`err`).
    open_failed,
    /// Reading failed (`err`).
    read_failed,
    /// The input holds an odd number of tokens; nothing is sorted.
    odd_tokens,
    /// A cycle was found in the input (`name`); `loop_node` events follow.
    loop,
    /// One node of the reported cycle (`name`).
    loop_node,
};

pub const Event = struct {
    kind: Kind,
    name: []const u8 = "",
    err: ?anyerror = null,
};

pub const Result = struct {
    /// Open or read failure, or an odd number of tokens: no sorting was done.
    failed: bool = false,
    /// Number of cycles found (and broken).
    cycles: u32 = 0,
};

pub const Observer = common.Observer(Event);

const Node = struct {
    name: []const u8,
    /// Successors in insertion order; iterated from the end (GNU prepends).
    succ: std.ArrayList(u32) = .empty,
    count: u32 = 0,
    done: bool = false,
    qlink: ?u32 = null,
};

pub fn run(env: Env, options: Options, input: Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    _ = options;
    const name = input.name orelse "-";
    var arena_state = std.heap.ArenaAllocator.init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opened = input.open(env.io) catch |e| {
        observer.emit(.{ .kind = .open_failed, .name = name, .err = e });
        return .{ .failed = true };
    };
    defer opened.close(env.io);

    // Read everything, then split into tokens.
    var data: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = common.readChunk(env.io, opened.file, &buf) catch |e| {
            observer.emit(.{ .kind = .read_failed, .name = name, .err = e });
            return .{ .failed = true };
        };
        if (n == 0) break;
        try data.appendSlice(arena, buf[0..n]);
    }

    var nodes: std.ArrayList(Node) = .empty;
    var index: std.StringHashMap(u32) = .init(arena);
    var it = std.mem.tokenizeAny(u8, data.items, " \t\n\x0b\x0c\r");
    var pending: ?u32 = null;
    var tokens: usize = 0;
    while (it.next()) |tok| {
        tokens += 1;
        const id = blk: {
            if (index.get(tok)) |i| break :blk i;
            const i: u32 = @intCast(nodes.items.len);
            try nodes.append(arena, .{ .name = tok });
            try index.put(tok, i);
            break :blk i;
        };
        if (pending) |first| {
            pending = null;
            if (first != id) {
                try nodes.items[first].succ.append(arena, id);
                nodes.items[id].count += 1;
            }
        } else pending = id;
    }
    if (tokens % 2 == 1) {
        observer.emit(.{ .kind = .odd_tokens, .name = name });
        return .{ .failed = true };
    }

    // Nodes in byte order: the order of the initial queue.
    const sorted = try arena.alloc(u32, nodes.items.len);
    for (sorted, 0..) |*s, i| s.* = @intCast(i);
    std.mem.sort(u32, sorted, nodes.items, struct {
        fn lt(ns: []Node, x: u32, y: u32) bool {
            return std.mem.lessThan(u8, ns[x].name, ns[y].name);
        }
    }.lt);

    var out = stickyout.Out.init(writer);
    var cycles: u32 = 0;
    var remaining: usize = nodes.items.len;
    var queue: std.ArrayList(u32) = .empty;
    // What breaking one cycle needs, given back before the next: there can
    // be as many cycles as there are nodes.
    var scratch: std.heap.ArenaAllocator = .init(env.gpa);
    defer scratch.deinit();
    while (remaining > 0) {
        queue.clearRetainingCapacity();
        for (sorted) |i| if (!nodes.items[i].done and nodes.items[i].count == 0) try queue.append(arena, i);
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const h = queue.items[qi];
            nodes.items[h].done = true;
            remaining -= 1;
            out.write(nodes.items[h].name);
            out.writeByte('\n');
            const succ = nodes.items[h].succ.items;
            var s = succ.len;
            while (s > 0) {
                s -= 1;
                const t = succ[s];
                nodes.items[t].count -= 1;
                if (nodes.items[t].count == 0) try queue.append(arena, t);
            }
        }
        if (remaining > 0) {
            cycles += 1;
            out.flush();
            observer.emit(.{ .kind = .loop, .name = name });
            try breakCycle(scratch.allocator(), nodes.items, sorted, observer);
            _ = scratch.reset(.retain_capacity);
        }
    }
    try out.finish();
    return .{ .cycles = cycles };
}

/// Find a cycle among the unfinished nodes, report it, and remove its closing
/// edge. Follows GNU's walk: visit the unfinished nodes in byte order, chaining
/// each node that has an edge to the current chain end, until a node already
/// in the chain closes the loop.
fn breakCycle(scratch: std.mem.Allocator, nodes: []Node, sorted: []const u32, observer: Observer) !void {
    var rem: std.ArrayList(u32) = .empty;
    for (sorted) |i| if (!nodes[i].done) {
        nodes[i].qlink = null;
        try rem.append(scratch, i);
    };
    var loop: ?u32 = null;
    var rounds: usize = 0;
    while (rounds <= rem.items.len + 2) : (rounds += 1) {
        for (rem.items) |k| {
            const cur = loop orelse {
                loop = k;
                continue;
            };
            // Does k have an edge to the chain end? (list order: newest first)
            var has_edge = false;
            var si = nodes[k].succ.items.len;
            while (si > 0) {
                si -= 1;
                if (nodes[k].succ.items[si] == cur) {
                    has_edge = true;
                    break;
                }
            }
            if (!has_edge) continue;
            if (nodes[k].qlink != null) {
                // Loop found: chain order from rem[0] is the qlink order.
                var chain: std.ArrayList(u32) = .empty;
                var x: ?u32 = rem.items[0];
                while (x) |xi| : (x = nodes[xi].qlink) {
                    try chain.append(scratch, xi);
                    if (chain.items.len > rem.items.len) break;
                }
                const ki = std.mem.indexOfScalar(u32, chain.items, k) orelse 0;
                const li = std.mem.indexOfScalar(u32, chain.items, cur) orelse ki;
                observer.emit(.{ .kind = .loop_node, .name = nodes[k].name });
                var cyc: std.ArrayList(u32) = .empty;
                try cyc.append(scratch, k);
                var j = li;
                while (j > ki) : (j -= 1) {
                    observer.emit(.{ .kind = .loop_node, .name = nodes[chain.items[j]].name });
                    try cyc.append(scratch, chain.items[j]);
                }
                dropEdge(nodes, cyc.items[cyc.items.len - 1], k);
                return;
            }
            nodes[k].qlink = nodes[cur].qlink;
            nodes[cur].qlink = k;
            loop = k;
        }
    }
    // No cycle found by the walk (should not happen): free the first node.
    const first = rem.items[0];
    observer.emit(.{ .kind = .loop_node, .name = nodes[first].name });
    nodes[first].count = 0;
}

/// Remove one edge `from` -> `to` and release `to` by one predecessor.
fn dropEdge(nodes: []Node, from: u32, to: u32) void {
    var si = nodes[from].succ.items.len;
    while (si > 0) {
        si -= 1;
        if (nodes[from].succ.items[si] == to) {
            _ = nodes[from].succ.orderedRemove(si);
            nodes[to].count -= 1;
            return;
        }
    }
}
