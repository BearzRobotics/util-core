//! tsort — topological sort.
//! References: GNU coreutils manual "tsort invocation" (9.7); POSIX.1-2024
//! tsort.
//!
//! Input is pairs of whitespace-separated strings meaning "first before
//! second"; equal strings only register the item. Output order reproduces
//! GNU: nodes with no predecessors seed a first-in-first-out queue in byte
//! order; finishing a node releases its successors in reverse order of
//! insertion. Cycles: when the queue empties with nodes left, a cycle is
//! reported ("input contains a loop:" then one node per line), its closing
//! edge is dropped, and sorting resumes; the exit status is then 1.
//!
//! Known deviation: GNU's choice of *which* cycle to report and where to
//! start it follows its internal tree walk. This implementation models that
//! walk (and agrees with GNU on most small graphs, always on acyclic input)
//! but cannot guarantee identical diagnostics for every cyclic graph.
//! -w (POSIX.1-2024) makes the exit status the number of cycles found (at most
//! 125); GNU 9.7 does not have -w.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "help", "version" };

const Node = struct {
    name: []const u8,
    /// Successors in insertion order; iterated from the end (GNU prepends).
    succ: std.ArrayList(u32) = .empty,
    count: u32 = 0,
    done: bool = false,
    qlink: ?u32 = null,
};

pub fn main(ctx: cli.Context) u8 {
    var count_cycles = false;
    var path: ?[]const u8 = null;
    var only_operands = false;
    var extra: ?[]const u8 = null;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (path == null) path = a else if (extra == null) extra = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| if (k == 0) return help(ctx) else return if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        }
        for (a[1..]) |c| switch (c) {
            'w' => count_cycles = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (extra) |e| {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ e, ctx.name });
        return 1;
    }
    const name = path orelse "-";

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = cli.openInput(ctx.io, name) catch |e| {
        if (e == error.IsDir) cli.warn(ctx, "{s}: read error: Is a directory", .{name}) else cli.warn(ctx, "{s}: {s}", .{ name, cli.errText(e) });
        return 1;
    };
    defer cli.closeInput(ctx.io, file);

    // Read everything, then split into tokens.
    var data: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = cli.readChunk(ctx.io, file, &buf) catch |e| {
            cli.warn(ctx, "{s}: read error: {s}", .{ name, cli.errText(e) });
            return 1;
        };
        if (n == 0) break;
        data.appendSlice(arena, buf[0..n]) catch return oom(ctx);
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
            nodes.append(arena, .{ .name = tok }) catch return oom(ctx);
            index.put(tok, i) catch return oom(ctx);
            break :blk i;
        };
        if (pending) |first| {
            pending = null;
            if (first != id) {
                nodes.items[first].succ.append(arena, id) catch return oom(ctx);
                nodes.items[id].count += 1;
            }
        } else pending = id;
    }
    if (tokens % 2 == 1) {
        cli.warn(ctx, "{s}: input contains an odd number of tokens", .{name});
        return 1;
    }

    // Nodes in byte order: the order of the initial queue.
    const sorted = arena.alloc(u32, nodes.items.len) catch return oom(ctx);
    for (sorted, 0..) |*s, i| s.* = @intCast(i);
    std.mem.sort(u32, sorted, nodes.items, struct {
        fn lt(ns: []Node, x: u32, y: u32) bool {
            return std.mem.lessThan(u8, ns[x].name, ns[y].name);
        }
    }.lt);

    var out = cli.Out.init(ctx.io);
    var cycles: u32 = 0;
    var remaining: usize = nodes.items.len;
    var queue: std.ArrayList(u32) = .empty;
    while (remaining > 0) {
        queue.clearRetainingCapacity();
        for (sorted) |i| if (!nodes.items[i].done and nodes.items[i].count == 0) queue.append(arena, i) catch return oom(ctx);
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
                if (nodes.items[t].count == 0) queue.append(arena, t) catch return oom(ctx);
            }
        }
        if (remaining > 0) {
            cycles += 1;
            out.flush();
            cli.warn(ctx, "{s}: input contains a loop:", .{name});
            breakCycle(ctx, arena, nodes.items, sorted) catch return oom(ctx);
        }
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    if (cycles > 0) return if (count_cycles) @intCast(@min(cycles, 125)) else 1;
    return 0;
}

/// Find a cycle among the unfinished nodes, print it, and remove its closing
/// edge. Follows GNU's walk: visit the unfinished nodes in byte order, chaining
/// each node that has an edge to the current chain end, until a node already
/// in the chain closes the loop.
fn breakCycle(ctx: cli.Context, arena: std.mem.Allocator, nodes: []Node, sorted: []const u32) !void {
    var rem: std.ArrayList(u32) = .empty;
    for (sorted) |i| if (!nodes[i].done) {
        nodes[i].qlink = null;
        try rem.append(arena, i);
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
                    try chain.append(arena, xi);
                    if (chain.items.len > rem.items.len) break;
                }
                const ki = std.mem.indexOfScalar(u32, chain.items, k) orelse 0;
                const li = std.mem.indexOfScalar(u32, chain.items, cur) orelse ki;
                cli.warn(ctx, "{s}", .{nodes[k].name});
                var cyc: std.ArrayList(u32) = .empty;
                try cyc.append(arena, k);
                var j = li;
                while (j > ki) : (j -= 1) {
                    cli.warn(ctx, "{s}", .{nodes[chain.items[j]].name});
                    try cyc.append(arena, chain.items[j]);
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
    cli.warn(ctx, "{s}", .{nodes[first].name});
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

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tsort [OPTION] [FILE]\n" ++
        "Write totally ordered list consistent with the partial ordering in FILE.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "  -w                count cycles in the exit status (POSIX)\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
