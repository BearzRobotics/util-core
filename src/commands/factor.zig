//! factor — print the prime factors of each number.
//! Reference: GNU coreutils manual "factor invocation" (9.7). POSIX does not
//! specify factor.
//!
//! Numbers up to 2^128-1 are factored with 128-bit arithmetic: trial division
//! by small primes, then Miller-Rabin and Brent's variant of Pollard's rho.
//! Larger inputs (GNU uses GMP) are reduced by trial division with
//! std.math.big; if what remains still does not fit 128 bits it is factored
//! with big-integer Miller-Rabin and rho, which is only practical when the
//! number has a factor of moderate size. Both rho loops stop after a fixed
//! number of steps and the number is then reported as too hard: GNU also uses
//! elliptic-curve factoring (not implemented here), so it finishes numbers
//! such as 2^128+1 instantly where this would run for minutes.

const std = @import("std");
const cli = @import("../cli.zig");
const big = std.math.big.int;

const long_names = [_][]const u8{ "exponents", "help", "version" };

const TooHard = error{TooHard};
/// Pollard-rho iteration limit per call (about ten seconds for 128-bit moduli with Montgomery steps).
const rho_step_limit: u64 = 1 << 29;

pub fn main(ctx: cli.Context) u8 {
    var exponents = false;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-' or (a.len >= 2 and std.ascii.isDigit(a[1]) and false)) {
            operands.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| {
                    if (eq != null) {
                        cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                        return 1;
                    }
                    switch (k) {
                        0 => exponents = true,
                        1 => return help(ctx),
                        else => return if (cli.printVersion(ctx)) 0 else 1,
                    }
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'h' => exponents = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    if (operands.items.len > 0) {
        for (operands.items) |tok| if (!one(ctx, &out, tok, exponents)) {
            status = 1;
        };
    } else {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(ctx.gpa);
        const stdin = std.Io.File.stdin();
        while (true) {
            data.ensureUnusedCapacity(ctx.gpa, 64 * 1024) catch return oom(ctx);
            const n = cli.readChunk(ctx.io, stdin, data.unusedCapacitySlice()) catch |e| {
                cli.warn(ctx, "read error: {s}", .{cli.errText(e)});
                return 1;
            };
            if (n == 0) break;
            data.items.len += n;
        }
        var it = std.mem.tokenizeAny(u8, data.items, " \t\n");
        while (it.next()) |tok| if (!one(ctx, &out, tok, exponents)) {
            status = 1;
        };
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

/// Factor one token and print the line. Returns false for an invalid token.
fn one(ctx: cli.Context, out: *cli.Out, tok: []const u8, exponents: bool) bool {
    // Leading blanks and a leading '+' are accepted (as by GNU), nothing else.
    var t = std.mem.trimStart(u8, tok, " \t\n\r\x0b\x0c");
    if (t.len > 0 and t[0] == '+') t = t[1..];
    var valid = t.len > 0;
    for (t) |c| valid = valid and std.ascii.isDigit(c);
    if (!valid) {
        out.flush();
        cli.warn(ctx, "{f} is not a valid positive integer", .{cli.quoteC(tok)});
        return false;
    }
    var list: std.ArrayList(u128) = .empty;
    defer list.deinit(ctx.gpa);
    var big_factors: std.ArrayList([]u8) = .empty; // decimal text of factors above 128 bits
    defer {
        for (big_factors.items) |s| ctx.gpa.free(s);
        big_factors.deinit(ctx.gpa);
    }

    const digits = std.mem.trimStart(u8, t, "0");
    // The number is printed without leading zeros ("0" for zero).
    const shown = if (digits.len == 0) "0" else digits;
    if (digits.len == 0) {
        out.print("{s}:\n", .{shown});
        return true;
    }
    if (digits.len <= 38) {
        const n = std.fmt.parseInt(u128, digits, 10) catch null;
        if (n) |v| {
            factor128(v, ctx.gpa, &list) catch |e| return failure(ctx, out, shown, e);
            out.print("{s}:", .{shown});
            writeFactors(out, list.items, exponents);
            out.writeByte('\n');
            return true;
        }
    }
    // Longer than 128 bits (or 39 digits that may overflow): big integers.
    factorBig(ctx.gpa, digits, &list, &big_factors) catch |e| return failure(ctx, out, shown, e);
    std.mem.sort(u128, list.items, {}, std.sort.asc(u128));
    // Small factors (all below 2^128) come first, then the large ones.
    out.print("{s}:", .{shown});
    writeFactors(out, list.items, exponents);
    for (big_factors.items) |s| {
        out.writeByte(' ');
        out.write(s);
    }
    out.writeByte('\n');
    return true;
}

fn failure(ctx: cli.Context, out: *cli.Out, shown: []const u8, e: anyerror) bool {
    out.flush();
    if (e == error.TooHard) {
        cli.warn(ctx, "{s}: too hard to factor (no elliptic-curve method; gave up after {d} rho steps)", .{ shown, rho_step_limit });
    } else cli.warn(ctx, "memory exhausted", .{});
    return false;
}

fn writeFactors(out: *cli.Out, f: []const u128, exponents: bool) void {
    var i: usize = 0;
    while (i < f.len) {
        var j = i;
        while (j < f.len and f[j] == f[i]) j += 1;
        const e = j - i;
        if (exponents and e > 1) {
            out.print(" {d}^{d}", .{ f[i], e });
        } else {
            var k: usize = 0;
            while (k < e) : (k += 1) out.print(" {d}", .{f[i]});
        }
        i = j;
    }
}

// ------------------------------------------------------------ 128-bit math

const small_primes = blk: {
    @setEvalBranchQuota(100000);
    var ps: [303]u16 = undefined; // all primes below 2000
    var n: usize = 0;
    var c: u16 = 2;
    while (c < 2000) : (c += 1) {
        var is = true;
        var d: u16 = 2;
        while (d * d <= c) : (d += 1) {
            if (c % d == 0) {
                is = false;
                break;
            }
        }
        if (is) {
            ps[n] = c;
            n += 1;
        }
    }
    break :blk ps[0..n].*;
};

fn mulmod(a: u128, b: u128, m: u128) u128 {
    if (m <= std.math.maxInt(u64)) return @intCast((@as(u128, a) * b) % m);
    return @intCast((@as(u256, a) * b) % m);
}

/// 128 x 128 -> 256 bit product as (hi, lo).
fn mulWide(a: u128, b: u128) struct { hi: u128, lo: u128 } {
    const mask: u128 = std.math.maxInt(u64);
    const a0 = a & mask;
    const a1 = a >> 64;
    const b0 = b & mask;
    const b1 = b >> 64;
    const p00 = a0 * b0;
    const p01 = a0 * b1;
    const p10 = a1 * b0;
    const p11 = a1 * b1;
    const mid = (p00 >> 64) + (p01 & mask) + (p10 & mask);
    return .{
        .lo = (p00 & mask) | (mid << 64),
        .hi = p11 + (p01 >> 64) + (p10 >> 64) + (mid >> 64),
    };
}

/// Montgomery arithmetic modulo an odd n < 2^128 (R = 2^128). Much cheaper
/// than a 256-bit remainder for the long rho iterations.
const Mont = struct {
    n: u128,
    neg_inv: u128, // -n^-1 mod 2^128

    fn init(n: u128) Mont {
        // Newton iteration for the inverse of an odd number mod 2^128.
        var inv: u128 = n; // correct to 3 bits
        for (0..6) |_| inv *%= 2 -% n *% inv;
        return .{ .n = n, .neg_inv = 0 -% inv };
    }

    /// a * b * R^-1 mod n, for a, b < n.
    fn mul(m: Mont, a: u128, b: u128) u128 {
        const t = mulWide(a, b);
        const q = t.lo *% m.neg_inv;
        const qn = mulWide(q, m.n);
        // t + q*n is divisible by R; its low half cancels, leaving a carry
        // exactly when t.lo is nonzero.
        const carry: u128 = @intFromBool(t.lo != 0);
        const sum = @addWithOverflow(t.hi, qn.hi);
        const sum2 = @addWithOverflow(sum[0], carry);
        const over = sum[1] | sum2[1];
        var r = sum2[0];
        if (over == 1 or r >= m.n) r -%= m.n;
        return r;
    }

    fn toMont(m: Mont, a: u128) u128 {
        return @intCast((@as(u256, a % m.n) << 128) % m.n);
    }

    fn add(m: Mont, a: u128, b: u128) u128 {
        const s = @addWithOverflow(a, b);
        return if (s[1] == 1 or s[0] >= m.n) s[0] -% m.n else s[0];
    }
};

fn powmod(base: u128, exp: u128, m: u128) u128 {
    var r: u128 = 1 % m;
    var b = base % m;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = mulmod(r, b, m);
        b = mulmod(b, b, m);
    }
    return r;
}

fn isPrime(n: u128) bool {
    if (n < 2) return false;
    for (small_primes[0..25]) |p| {
        if (n == p) return true;
        if (n % p == 0) return false;
    }
    var d = n - 1;
    var s: u32 = 0;
    while (d & 1 == 0) : (d >>= 1) s += 1;
    // The first 13 prime bases are deterministic below 3.3e24; the extra
    // bases make a false positive beyond that astronomically unlikely.
    for (small_primes[0..25]) |p| {
        var x = powmod(p, d, n);
        if (x == 1 or x == n - 1) continue;
        var composite = true;
        var r: u32 = 1;
        while (r < s) : (r += 1) {
            x = mulmod(x, x, n);
            if (x == n - 1) {
                composite = false;
                break;
            }
        }
        if (composite) return false;
    }
    return true;
}

fn gcd128(a0: u128, b0: u128) u128 {
    var a = a0;
    var b = b0;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

/// A nontrivial divisor of the odd composite `n` (Brent's cycle detection).
fn rho(n: u128) TooHard!u128 {
    if (n > std.math.maxInt(u64) and n & 1 == 1) return rhoMont(n);
    var c: u128 = 1;
    var steps: u64 = 0;
    while (true) : (c += 1) {
        var y: u128 = 2;
        var x: u128 = 2;
        var q: u128 = 1;
        var g: u128 = 1;
        var r: u128 = 1;
        var ys: u128 = 2;
        const m: u128 = 128;
        while (g == 1) {
            x = y;
            var i: u128 = 0;
            while (i < r) : (i += 1) y = (mulmod(y, y, n) + c) % n;
            steps += @intCast(r);
            if (steps > rho_step_limit) return error.TooHard;
            var k: u128 = 0;
            while (k < r and g == 1) {
                ys = y;
                var j: u128 = 0;
                while (j < @min(m, r - k)) : (j += 1) {
                    y = (mulmod(y, y, n) + c) % n;
                    q = mulmod(q, if (x > y) x - y else y - x, n);
                }
                g = gcd128(q, n);
                k += m;
            }
            r *= 2;
        }
        if (g == n) {
            // The batch overshot: redo it one step at a time.
            g = 1;
            while (g == 1) {
                ys = (mulmod(ys, ys, n) + c) % n;
                g = gcd128(if (x > ys) x - ys else ys - x, n);
            }
        }
        if (g != n) return g;
    }
}

/// Brent's rho in Montgomery form (n odd). Values stay in Montgomery form;
/// the factor test only needs differences, whose gcd with n is unaffected by
/// the common factor R.
fn rhoMont(n: u128) TooHard!u128 {
    const mc = Mont.init(n);
    var c: u128 = 1;
    var steps: u64 = 0;
    while (true) : (c += 1) {
        const cm = mc.toMont(c);
        var y: u128 = mc.toMont(2);
        var x: u128 = y;
        var ys: u128 = y;
        var q: u128 = mc.toMont(1);
        var g: u128 = 1;
        var r: u128 = 1;
        const m: u128 = 128;
        while (g == 1) {
            x = y;
            var i: u128 = 0;
            while (i < r) : (i += 1) y = mc.add(mc.mul(y, y), cm);
            steps += @intCast(r);
            if (steps > rho_step_limit) return error.TooHard;
            var k: u128 = 0;
            while (k < r and g == 1) {
                ys = y;
                var j: u128 = 0;
                while (j < @min(m, r - k)) : (j += 1) {
                    y = mc.add(mc.mul(y, y), cm);
                    q = mc.mul(q, if (x > y) x - y else y - x);
                }
                g = gcd128(q, n);
                k += m;
            }
            r *= 2;
        }
        if (g == n) {
            g = 1;
            while (g == 1) {
                ys = mc.add(mc.mul(ys, ys), cm);
                g = gcd128(if (x > ys) x - ys else ys - x, n);
            }
        }
        if (g != n) return g;
    }
}

fn factor128(n0: u128, gpa: std.mem.Allocator, out: *std.ArrayList(u128)) (std.mem.Allocator.Error || TooHard)!void {
    var n = n0;
    if (n < 2) return;
    for (small_primes) |p| {
        if (@as(u128, p) * p > n) break;
        while (n % p == 0) {
            try out.append(gpa, p);
            n /= p;
        }
    }
    if (n > 1) try splitRec(n, gpa, out);
    std.mem.sort(u128, out.items, {}, std.sort.asc(u128));
}

fn splitRec(n: u128, gpa: std.mem.Allocator, out: *std.ArrayList(u128)) (std.mem.Allocator.Error || TooHard)!void {
    if (n == 1) return;
    if (isPrime(n)) return out.append(gpa, n);
    // A perfect square defeats rho for small cases, so catch it directly.
    const r = isqrt(n);
    if (r * r == n) {
        try splitRec(r, gpa, out);
        return splitRec(r, gpa, out);
    }
    const d = try rho(n);
    try splitRec(d, gpa, out);
    try splitRec(n / d, gpa, out);
}

fn isqrt(n: u128) u128 {
    if (n < 2) return n;
    var x: u128 = @as(u128, 1) << @intCast((128 - @clz(n) + 1) / 2);
    while (true) {
        const y = (x + n / x) / 2;
        if (y >= x) return x;
        x = y;
    }
}

// -------------------------------------------------------------- big numbers

/// Factor a decimal string that may exceed 128 bits. Factors below 2^128 go
/// to `small`, larger ones are appended as decimal text to `large`.
fn factorBig(gpa: std.mem.Allocator, digits: []const u8, small: *std.ArrayList(u128), large: *std.ArrayList([]u8)) !void {
    var n = try big.Managed.init(gpa);
    defer n.deinit();
    try n.setString(10, digits);
    var q = try big.Managed.init(gpa);
    defer q.deinit();
    var r = try big.Managed.init(gpa);
    defer r.deinit();

    // Trial division by the small primes.
    for (small_primes) |p| {
        while (true) {
            var pm = try big.Managed.initSet(gpa, p);
            defer pm.deinit();
            try big.Managed.divTrunc(&q, &r, &n, &pm);
            if (!r.eqlZero()) break;
            try small.append(gpa, p);
            std.mem.swap(big.Managed, &n, &q);
        }
    }
    try splitBig(gpa, &n, small, large);
    std.mem.sort(u128, small.items, {}, std.sort.asc(u128));
}

fn splitBig(gpa: std.mem.Allocator, n: *big.Managed, small: *std.ArrayList(u128), large: *std.ArrayList([]u8)) !void {
    if (n.toConst().eqlZero()) return;
    if (n.toInt(u128)) |v| {
        if (v == 1) return;
        var tmp: std.ArrayList(u128) = .empty;
        defer tmp.deinit(gpa);
        try splitRec(v, gpa, &tmp);
        try small.appendSlice(gpa, tmp.items);
        return;
    } else |_| {}
    if (try bigIsPrime(gpa, n)) {
        try large.append(gpa, try n.toString(gpa, 10, .lower));
        return;
    }
    var d = try bigRho(gpa, n);
    defer d.deinit();
    var q = try big.Managed.init(gpa);
    defer q.deinit();
    var r = try big.Managed.init(gpa);
    defer r.deinit();
    try big.Managed.divTrunc(&q, &r, n, &d);
    try splitBig(gpa, &d, small, large);
    try splitBig(gpa, &q, small, large);
}

fn bigPowMod(gpa: std.mem.Allocator, base: u64, exp: *const big.Managed, m: *const big.Managed) !big.Managed {
    var result = try big.Managed.initSet(gpa, 1);
    errdefer result.deinit();
    var b = try big.Managed.initSet(gpa, base);
    defer b.deinit();
    var t = try big.Managed.init(gpa);
    defer t.deinit();
    var q = try big.Managed.init(gpa);
    defer q.deinit();
    const bits = exp.bitCountAbs();
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        if (bitSet(exp, i)) {
            try t.mul(&result, &b);
            try big.Managed.divTrunc(&q, &result, &t, m);
        }
        try t.mul(&b, &b);
        try big.Managed.divTrunc(&q, &b, &t, m);
    }
    return result;
}

fn bitSet(x: *const big.Managed, i: usize) bool {
    const limb_bits = @bitSizeOf(std.math.big.Limb);
    const limbs = x.toConst().limbs;
    const li = i / limb_bits;
    if (li >= limbs.len) return false;
    return (limbs[li] >> @intCast(i % limb_bits)) & 1 == 1;
}

fn bigIsPrime(gpa: std.mem.Allocator, n: *const big.Managed) !bool {
    var one_m = try big.Managed.initSet(gpa, 1);
    defer one_m.deinit();
    var nm1 = try big.Managed.init(gpa);
    defer nm1.deinit();
    try nm1.sub(n, &one_m);
    // n - 1 = d * 2^s
    var d = try nm1.clone();
    defer d.deinit();
    var s: usize = 0;
    while (!d.isOdd()) : (s += 1) try d.shiftRight(&d, 1);
    for (small_primes[0..20]) |p| {
        var x = try bigPowMod(gpa, p, &d, n);
        defer x.deinit();
        if (x.toConst().orderAgainstScalar(1) == .eq or x.toConst().order(nm1.toConst()) == .eq) continue;
        var composite = true;
        var t = try big.Managed.init(gpa);
        defer t.deinit();
        var q = try big.Managed.init(gpa);
        defer q.deinit();
        var r: usize = 1;
        while (r < s) : (r += 1) {
            try t.mul(&x, &x);
            try big.Managed.divTrunc(&q, &x, &t, n);
            if (x.toConst().order(nm1.toConst()) == .eq) {
                composite = false;
                break;
            }
        }
        if (composite) return false;
    }
    return true;
}

fn bigRho(gpa: std.mem.Allocator, n: *const big.Managed) !big.Managed {
    var c: u64 = 1;
    while (c < 4) : (c += 1) {
        var x = try big.Managed.initSet(gpa, 2);
        defer x.deinit();
        var y = try big.Managed.initSet(gpa, 2);
        defer y.deinit();
        var t = try big.Managed.init(gpa);
        defer t.deinit();
        var q = try big.Managed.init(gpa);
        defer q.deinit();
        var diff = try big.Managed.init(gpa);
        defer diff.deinit();
        var g = try big.Managed.initSet(gpa, 1);
        defer g.deinit();
        var steps: usize = 0;
        while (g.toConst().orderAgainstScalar(1) == .eq and steps < 20_000) : (steps += 1) {
            // Floyd: x moves one step, y two.
            try t.mul(&x, &x);
            try t.addScalar(&t, c);
            try big.Managed.divTrunc(&q, &x, &t, n);
            for (0..2) |_| {
                try t.mul(&y, &y);
                try t.addScalar(&t, c);
                try big.Managed.divTrunc(&q, &y, &t, n);
            }
            if (x.toConst().order(y.toConst()) == .gt) try diff.sub(&x, &y) else try diff.sub(&y, &x);
            try g.gcd(&diff, n);
        }
        if (g.toConst().orderAgainstScalar(1) != .eq and g.toConst().order(n.toConst()) != .eq) return g.clone();
    }
    return error.TooHard;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: factor [OPTION] [NUMBER]...\n" ++
        "Print the prime factors of each specified integer NUMBER.  If none\n" ++
        "are specified on the command line, read them from standard input.\n\n" ++
        "  -h, --exponents   print repeated factors in form p^e unless e is 1\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}

test "factor128" {
    const t = std.testing;
    var list: std.ArrayList(u128) = .empty;
    defer list.deinit(t.allocator);
    try factor128(18446744073709551615, t.allocator, &list);
    try t.expectEqualSlices(u128, &.{ 3, 5, 17, 257, 641, 65537, 6700417 }, list.items);
    list.clearRetainingCapacity();
    try factor128(340282366920938463463374607431768211455, t.allocator, &list);
    try t.expectEqualSlices(u128, &.{ 3, 5, 17, 257, 641, 65537, 274177, 6700417, 67280421310721 }, list.items);
    try t.expect(isPrime(1000000007));
    try t.expect(!isPrime(1000000007 * 998244353));
}

test "Montgomery multiplication agrees with 256-bit remainder" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..2000) |_| {
        const n = rnd.int(u128) | 1 | (@as(u128, 1) << 100);
        const mc = Mont.init(n);
        const a = rnd.int(u128) % n;
        const b = rnd.int(u128) % n;
        const am = mc.toMont(a);
        const bm = mc.toMont(b);
        const prod = mc.mul(am, bm);
        const want: u128 = @intCast((@as(u256, a) * b) % n);
        try std.testing.expectEqual(mc.toMont(want), prod);
    }
    // Moduli close to 2^128 exercise the carry paths.
    const n: u128 = std.math.maxInt(u128) - 158; // odd
    const mc = Mont.init(n);
    const a = n - 1;
    const prod = mc.mul(mc.toMont(a), mc.toMont(a));
    try std.testing.expectEqual(mc.toMont(1), prod);
}
