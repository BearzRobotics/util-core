// SPDX-License-Identifier: GPL-2.0-or-later
//! Util Core build script. See SPEC.md §7 for the packaging modes.
//!
//! Options:
//!   -Dcommands=a,b,c   build only these commands (default: all)
//!   -Dmode=standalone|multicall|all
//!                      what to install (default: all)
//!   -Dman=bool         install the manual pages (default: on)
//!   -Dstrip=bool       strip debug info (default: on unless -Doptimize=Debug)
//!
//! Outputs (zig-out/bin; manual pages in zig-out/share/man/man1 as NAME.1.md, which
//! dkman and dkde-help read):
//!   <command>  one executable per selected command   (-Dmode=standalone, all)
//!   util-core  multicall binary; `util-core <command> ...` or invoked through
//!              a link named after a command          (-Dmode=multicall, all)
//!
//! Nothing here depends on the host OS, so cross-compilation works with
//! -Dtarget=. Supported targets: Linux (x86_64, aarch64; run and tested),
//! macOS (aarch64-macos, x86_64-macos; compile-checked only) and Windows
//! (x86_64-windows, aarch64-windows; x86_64 run natively). See
//! docs/portability.md.

const std = @import("std");
const commands = @import("src/commands.zig");

/// Which executables `zig build` installs.
const Mode = enum {
    /// One executable per command, no multicall binary.
    standalone,
    /// Only the `util-core` multicall binary.
    multicall,
    /// Both.
    all,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds are stripped by default so sizes compare fairly with
    // distribution binaries (GNU coreutils ships stripped); -Dstrip=false
    // keeps debug info for profiling.
    const strip = b.option(bool, "strip", "Strip debug info from command executables (default: on unless Debug)") orelse (optimize != .debug);

    const mode = b.option(Mode, "mode", "What to build: standalone (one binary per command), multicall (util-core only) or all (default)") orelse .all;
    const install_man = b.option(bool, "man", "Install the manual pages as share/man/man1/NAME.1.md (default: on)") orelse true;
    const selected = selectCommands(b);
    const regex_mod = b.dependency("regex", .{ .target = target, .optimize = optimize }).module("regex");
    const yaml_mod = b.dependency("yaml", .{ .target = target, .optimize = optimize }).module("yaml");

    const test_step = b.step("test", "Run Zig unit tests");

    // Library module for dependants: dep.module("util_core").
    const lib = b.addModule("util_core", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("regex", regex_mod);
    lib.addImport("yaml", yaml_mod);

    // Individual executables.
    if (mode != .multicall) for (selected) |name| {
        const opts = b.addOptions();
        opts.addOption([]const u8, "command", name);
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/exe.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.addImport("regex", regex_mod);
        exe.root_module.addImport("yaml", yaml_mod);
        b.installArtifact(exe);
    };

    // Multicall executable.
    if (mode != .standalone) {
        const opts = b.addOptions();
        opts.addOption([]const []const u8, "commands", selected);
        const exe = b.addExecutable(.{
            .name = "util-core",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/multicall.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.addImport("regex", regex_mod);
        exe.root_module.addImport("yaml", yaml_mod);
        b.installArtifact(exe);
    }

    // Manual pages (Markdown, rendered by dkman and dkde-help; see docs/manpages/README.md).
    if (install_man) {
        for (selected) |name| {
            // `[` is documented on the `test` page.
            const page = if (std.mem.eql(u8, name, "[")) "test" else name;
            const src = b.fmt("docs/manpages/{s}.md", .{page});
            const dest = b.fmt("{s}.1.md", .{name});
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(src), .{ .custom = "share/man/man1" }, dest).step);
        }
        if (mode != .standalone) {
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("docs/manpages/util-core.md"), .{ .custom = "share/man/man1" }, "util-core.1.md").step);
        }
    }

    // Fuzz tests (src/fuzz/, decision 0007): ordinary tests driven by our own mutation
    // engine (src/fuzz/engine.zig; Zig 0.17.1's built-in fuzzer does not run). `zig build
    // test` runs them as short regression tests; `zig build fuzz` is the campaign and is
    // meant to be started through tools/fuzz.sh, which sets the iteration count and caps
    // memory and time.
    {
        const fuzz_t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "regex", .module = regex_mod }, .{ .name = "yaml", .module = yaml_mod } },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(fuzz_t).step);
        const campaign = b.addRunArtifact(fuzz_t);
        campaign.has_side_effects = true; // never cached: every campaign really runs
        b.step("fuzz", "Run the fuzz campaign (use tools/fuzz.sh)").dependOn(&campaign.step);
    }

    // Syntax-highlighting modules (they depend on regex-zig and yaml-zig).
    const syntax_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/syntax/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "regex", .module = regex_mod }, .{ .name = "yaml", .module = yaml_mod } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(syntax_unit).step);

    // Developer tool for trying grammars: zig-out/bin/syntax-probe GRAMMAR -- FILE
    const probe = b.addExecutable(.{
        .name = "syntax-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/syntax/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "regex", .module = regex_mod }, .{ .name = "yaml", .module = yaml_mod } },
        }),
    });
    // Not part of an installation: `zig build syntax-probe`.
    b.step("syntax-probe", "Build the grammar tool zig-out/bin/syntax-probe GRAMMAR... -- FILE")
        .dependOn(&b.addInstallArtifact(probe, .{}).step);

    // Unit tests: every file under src/ reachable from the registry.
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "regex", .module = regex_mod }, .{ .name = "yaml", .module = yaml_mod } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

fn selectCommands(b: *std.Build) []const []const u8 {
    const requested = b.option([]const u8, "commands", "Comma-separated commands to build (default: all)") orelse
        return &commands.all;

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, requested, ',');
    while (it.next()) |name| {
        const known = for (commands.all) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else false;
        if (!known) std.debug.panic("unknown command '{s}' in -Dcommands", .{name});
        list.append(b.allocator, name) catch @panic("OOM");
    }
    return list.items;
}
