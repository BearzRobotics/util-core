// SPDX-License-Identifier: GPL-2.0-or-later
//! Version-aware file name comparison (GNU filevercmp, coreutils 9.6
//! lib/filevercmp.c, consulted 2026-11-07), C locale.

const std = @import("std");

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Length of the prefix of `s` left after removing the suffix matching
/// `(\.[A-Za-z~][A-Za-z0-9~]*)*$` (never all of a nonempty `s`).
fn filePrefixLen(s: []const u8) usize {
    const n = s.len;
    var prefixlen: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i == n) return prefixlen;
        i += 1;
        prefixlen = i;
        while (i + 1 < n and s[i] == '.' and (isAlpha(s[i + 1]) or s[i + 1] == '~')) {
            i += 2;
            while (i < n and (isAlpha(s[i]) or isDigit(s[i]) or s[i] == '~')) i += 1;
        }
    }
}

fn order(s: []const u8, pos: usize) i32 {
    if (pos == s.len) return -1;
    const c = s[pos];
    if (isDigit(c)) return 0;
    if (isAlpha(c)) return c;
    if (c == '~') return -2;
    return @as(i32, c) + 256;
}

fn verrevcmp(s1: []const u8, s2: []const u8) i32 {
    var p1: usize = 0;
    var p2: usize = 0;
    while (p1 < s1.len or p2 < s2.len) {
        var first_diff: i32 = 0;
        while ((p1 < s1.len and !isDigit(s1[p1])) or (p2 < s2.len and !isDigit(s2[p2]))) {
            const c1 = order(s1, p1);
            const c2 = order(s2, p2);
            if (c1 != c2) return c1 - c2;
            p1 += 1;
            p2 += 1;
        }
        while (p1 < s1.len and s1[p1] == '0') p1 += 1;
        while (p2 < s2.len and s2[p2] == '0') p2 += 1;
        while (p1 < s1.len and p2 < s2.len and isDigit(s1[p1]) and isDigit(s2[p2])) {
            if (first_diff == 0) first_diff = @as(i32, s1[p1]) - @as(i32, s2[p2]);
            p1 += 1;
            p2 += 1;
        }
        if (p1 < s1.len and isDigit(s1[p1])) return 1;
        if (p2 < s2.len and isDigit(s2[p2])) return -1;
        if (first_diff != 0) return first_diff;
    }
    return 0;
}

pub fn cmp(a: []const u8, b: []const u8) i32 {
    if (a.len == 0) return if (b.len == 0) 0 else -1;
    if (b.len == 0) return 1;
    if (a[0] == '.') {
        if (b[0] != '.') return -1;
        const adot = a.len == 1;
        const bdot = b.len == 1;
        if (adot) return if (bdot) 0 else -1;
        if (bdot) return 1;
        const adotdot = a[1] == '.' and a.len == 2;
        const bdotdot = b[1] == '.' and b.len == 2;
        if (adotdot) return if (bdotdot) 0 else -1;
        if (bdotdot) return 1;
    } else if (b[0] == '.') return 1;

    const ap = filePrefixLen(a);
    const bp = filePrefixLen(b);
    const one_pass = ap == a.len and bp == b.len;
    const result = verrevcmp(a[0..ap], b[0..bp]);
    return if (result != 0 or one_pass) result else verrevcmp(a, b);
}
