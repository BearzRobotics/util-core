//! File mode operands as understood by chmod(1) and mkdir -m.
//! References: POSIX.1-2024 chmod (octal and symbolic modes, "mode"
//! operand grammar); GNU coreutils manual, "File permissions" and
//! "mkdir invocation" (GNU details: umask handling when no `who` is given,
//! `X`, copy-from-class permissions, special bits).
//!
//! Grammar (symbolic):  clause[,clause]...   clause = [ugoa]*  (op perm*)+
//!   op   = + - =
//!   perm = r w x X s t   or a single u g o (copy that class's permissions)
//! Octal: 1-4 octal digits, value at most 07777.
//!
//! Semantics checked against GNU 9.7 `mkdir -m` (see test/test_mkdir.sh): with
//! no `who`, all classes are affected but the bits in the umask are left alone
//! for + and - and are not set by =.

const std = @import("std");

const all_bits: u16 = 0o7777;

/// Apply `text` to `old` and return the new mode, or null when the text is
/// not a valid mode. `is_dir` matters for `X`. `umask` is used only for
/// clauses without a `who`.
pub fn apply(text: []const u8, old: u16, is_dir: bool, umask: u16) ?u16 {
    if (text.len == 0) return null;
    if (std.ascii.isDigit(text[0])) {
        const v = std.fmt.parseInt(u16, text, 8) catch return null;
        return if (v > all_bits) null else v;
    }
    var mode = old;
    var i: usize = 0;
    while (true) {
        // who
        var who: u16 = 0;
        var mentioned = false;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= all_bits,
                else => break,
            }
            mentioned = true;
        }
        if (!mentioned) who = all_bits;
        // one or more (op perm*) groups
        if (i >= text.len or std.mem.indexOfScalar(u8, "+-=", text[i]) == null) return null;
        while (i < text.len and std.mem.indexOfScalar(u8, "+-=", text[i]) != null) {
            const op = text[i];
            i += 1;
            var value: u16 = 0;
            if (i < text.len and std.mem.indexOfScalar(u8, "ugo", text[i]) != null) {
                const cls: u16 = switch (text[i]) {
                    'u' => (mode >> 6) & 7,
                    'g' => (mode >> 3) & 7,
                    else => mode & 7,
                };
                value = cls | (cls << 3) | (cls << 6);
                i += 1;
            } else while (i < text.len) : (i += 1) {
                switch (text[i]) {
                    'r' => value |= 0o444,
                    'w' => value |= 0o222,
                    'x' => value |= 0o111,
                    'X' => {
                        if (is_dir or (mode & 0o111) != 0) value |= 0o111;
                    },
                    's' => value |= 0o6000,
                    't' => value |= 0o1000,
                    else => break,
                }
            }
            const affected = who;
            value &= affected;
            if (!mentioned) value &= ~umask;
            switch (op) {
                '+' => mode |= value,
                '-' => mode &= ~value,
                else => mode = (mode & ~affected) | value,
            }
        }
        if (i >= text.len) return mode;
        if (text[i] != ',') return null;
        i += 1;
    }
}

test "octal" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o755), apply("755", 0, true, 0));
    try t.expectEqual(@as(?u16, 0o7777), apply("7777", 0, true, 0));
    try t.expectEqual(@as(?u16, 0), apply("0", 0o777, true, 0));
    try t.expect(apply("10000", 0, true, 0) == null);
    try t.expect(apply("789", 0, true, 0) == null);
    try t.expect(apply("", 0, true, 0) == null);
}

test "symbolic with umask 022 from 0777 (values measured with GNU mkdir -m)" {
    const t = std.testing;
    const u: u16 = 0o022;
    try t.expectEqual(@as(?u16, 0o577), apply("-w", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o666), apply("a-x", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o477), apply("u=r", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o555), apply("=rx", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o4777), apply("u+s", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o2777), apply("g+s", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o750), apply("u=rwx,g=rx,o=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o722), apply("go-rx", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o777), apply("g=u", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0), apply("a=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0), apply("=", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o755), apply("a+rx,go-w", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o7777), apply("u+s,g+s,o+t", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o1000), apply("=t", 0o777, true, u));
    try t.expectEqual(@as(?u16, 0o646), apply("g-w,-x", 0o777, true, u));
}

test "invalid" {
    const t = std.testing;
    try t.expect(apply("zz", 0, true, 0) == null);
    try t.expect(apply("u", 0, true, 0) == null);
    try t.expect(apply("u+q", 0, true, 0) == null);
    try t.expect(apply("u+r,", 0, true, 0) == null);
    try t.expect(apply("+r,,", 0, true, 0) == null);
}

test "X" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 0o755), apply("a+X", 0o644, true, 0));
    try t.expectEqual(@as(?u16, 0o644), apply("a+X", 0o644, false, 0));
    try t.expectEqual(@as(?u16, 0o755), apply("a+X", 0o744, false, 0));
}
