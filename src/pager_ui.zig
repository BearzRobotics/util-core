// SPDX-License-Identifier: GPL-2.0-or-later
//! Interactive paging on the terminal, shared by `less` and `cat`: the
//! terminal in raw mode on the alternate screen, a thread that reads keys, and
//! a growing `Pager` that the producer (the thread that reads the input)
//! feeds while the user scrolls. So a long or endless stream can be paged
//! without waiting for it to finish.
//!
//! Two threads touch the pager, always under `mutex`: the key thread (keys,
//! resize) and the producer (new data). Each redraws after its own change; the
//! producer limits itself to about 30 frames a second.
//!
//! The model and the drawing are in src/lib/pager.zig; the raw terminal is
//! `sys.Tty`. When the process ends while the key thread is still blocked in
//! a read, the operating system cleans it up.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const pager = @import("lib/pager.zig");

pub const Options = pager.Options;

pub const Outcome = enum {
    /// The user left the pager.
    quit,
    /// Everything fitted on one screen (and `quit_if_fits` was set): the text
    /// was printed to the terminal and no pager was shown.
    printed,
};

pub const Ui = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    tty: sys.Tty,
    pg: pager.Pager,
    out_buf: [16384]u8 = undefined,
    out: Io.File.Writer,
    last_draw: Io.Timestamp,
    thread: ?std.Thread = null,
    /// Set (under the mutex) when the key thread has ended or the viewer was
    /// shut down by the producer.
    stopped: bool = false,
    /// The alternate screen was already left (or never entered).
    left: bool = false,
    /// The alternate screen is in use.
    entered: bool = false,
    sink_state: Sink = undefined,

    /// Open the terminal and show an empty pager. Null when there is no
    /// terminal to page on.
    /// With `lazy`, the screen is taken over only once the text no longer
    /// fits on one screen (or the input ends), so short output never flashes.
    pub fn start(gpa: std.mem.Allocator, io: Io, opts: Options, name: []const u8, lazy: bool) ?*Ui {
        var tty = sys.Tty.open(io) orelse return null;
        const size: sys.TtySize = tty.size() orelse .{ .rows = 24, .cols = 80 };
        // The key thread may outlive the pager (it can sit in a blocking read
        // until the process ends), so the struct it reads comes from the page
        // allocator: it is never freed and the leak checker does not track it.
        const ui = std.heap.page_allocator.create(Ui) catch {
            tty.close(io);
            return null;
        };
        ui.* = .{
            .io = io,
            .gpa = gpa,
            .tty = tty,
            .pg = pager.Pager.init(gpa, opts, size.rows, size.cols),
            .out = undefined,
            .last_draw = Io.Timestamp.now(io, .awake),
        };
        ui.pg.name = name;
        ui.out = Io.File.stdout().writerStreaming(io, &ui.out_buf);
        if (lazy) {
            ui.left = true;
        } else ui.ensureEntered();
        ui.thread = std.Thread.spawn(.{}, keyLoop, .{ui}) catch {
            ui.restore();
            ui.pg.deinit();
            ui.tty.close(io);
            return null;
        };
        return ui;
    }

    fn lock(ui: *Ui) void {
        ui.mutex.lockUncancelable(ui.io);
    }

    fn unlock(ui: *Ui) void {
        ui.mutex.unlock(ui.io);
    }

    /// Take over the screen if that has not happened yet (mutex held, or
    /// before the key thread starts).
    fn ensureEntered(ui: *Ui) void {
        if (ui.entered) return;
        ui.entered = true;
        ui.left = false;
        pager.Pager.enter(&ui.out.interface) catch {};
        ui.draw();
    }

    /// Redraw (mutex held).
    fn draw(ui: *Ui) void {
        if (!ui.entered) return;
        if (ui.tty.size()) |s| ui.pg.resize(s.rows, s.cols);
        ui.pg.render(&ui.out.interface) catch {};
        ui.out.interface.flush() catch {};
        ui.last_draw = Io.Timestamp.now(ui.io, .awake);
    }

    /// Leave the alternate screen (mutex held or the key thread gone).
    fn restore(ui: *Ui) void {
        if (ui.left) return;
        ui.left = true;
        pager.Pager.leave(&ui.out.interface) catch {};
        ui.out.interface.flush() catch {};
    }

    fn keyLoop(ui: *Ui) void {
        var parser: pager.KeyParser = .{};
        while (true) {
            // End of input on the terminal: nobody can type, so stop reading but
            // let the pager finish its output (no keys means no way to quit it).
            const b = ui.tty.readByte() orelse return;
            const k = parser.feed(b) orelse continue;
            ui.lock();
            if (ui.stopped) {
                ui.unlock();
                return;
            }
            if (!ui.entered) {
                // Nothing is shown yet: only Ctrl-C does anything.
                if (k == .interrupt) {
                    ui.stopped = true;
                    ui.quitNow();
                }
                ui.unlock();
                continue;
            }
            if (ui.tty.size()) |s| ui.pg.resize(s.rows, s.cols);
            const act = ui.pg.key(k);
            if (act == .quit) {
                // The producer may be blocked reading a stream that never ends;
                // leave the terminal tidy and end the process, as less does.
                ui.stopped = true;
                ui.quitNow();
            }
            if (act == .redraw) ui.draw();
            ui.unlock();
        }
    }

    /// Restore the terminal and end the process (mutex held).
    fn quitNow(ui: *Ui) noreturn {
        ui.restore();
        ui.tty.close(ui.io);
        std.process.exit(0);
    }

    /// Add input (producer thread). Returns error.Quit once the user has left.
    pub fn feed(ui: *Ui, bytes: []const u8) error{ Quit, OutOfMemory }!void {
        ui.lock();
        defer ui.unlock();
        if (ui.stopped) return error.Quit;
        const changed = try ui.pg.append(bytes);
        if (!ui.entered) {
            if (ui.pg.fits()) return; // still short: stay on the normal screen
            ui.ensureEntered();
            return;
        }
        if (!changed) return;
        // At most ~30 frames a second: wait out the rest of the interval
        // (the input is buffered by the pipe meanwhile).
        const since = ui.last_draw.untilNow(ui.io, .awake).toMilliseconds();
        if (since < 33) {
            ui.unlock();
            ui.io.sleep(Io.Duration.fromMilliseconds(33 - since), .awake) catch {};
            ui.lock();
            if (ui.stopped) return error.Quit;
        }
        ui.draw();
    }

    /// A writer whose bytes go to `feed`; lets `cat` write its output
    /// straight into the pager.
    pub fn sink(ui: *Ui, buffer: []u8) *Io.Writer {
        ui.sink_state = .{ .ui = ui, .writer = .{
            .vtable = &.{ .drain = Sink.drain },
            .buffer = buffer,
        } };
        return &ui.sink_state.writer;
    }

    /// The producer has no more input. With `quit_if_fits`, a text that fits
    /// on one screen is printed and the pager closed (less -F). Otherwise
    /// wait here until the user leaves.
    pub fn finish(ui: *Ui, quit_if_fits: bool) Outcome {
        ui.lock();
        ui.pg.finish();
        if (ui.stopped) {
            ui.unlock();
            return .quit;
        }
        if (quit_if_fits and ui.pg.fits()) {
            ui.stopped = true;
            ui.restore();
            // Put the text on the normal screen, as plain output.
            var w = Io.File.stdout().writerStreaming(ui.io, &ui.out_buf);
            w.interface.writeAll(ui.pg.text.items) catch {};
            w.interface.flush() catch {};
            ui.unlock();
            return .printed;
        }
        ui.ensureEntered();
        ui.draw();
        ui.unlock();
        if (ui.thread) |t| {
            t.join();
            ui.thread = null;
        }
        return .quit;
    }

    /// Restore the terminal and free everything. Call after `finish`, or to
    /// abandon the pager early.
    pub fn deinit(ui: *Ui) void {
        ui.lock();
        const was_stopped_by_user = ui.stopped;
        ui.stopped = true;
        ui.unlock();
        _ = was_stopped_by_user;
        // The key thread may still be blocked in a read; do not join it.
        if (ui.thread) |t| t.detach();
        ui.lock();
        ui.restore();
        // A running key thread looks at `stopped` before it touches the pager,
        // so the text can be freed now; the struct itself stays (see `start`).
        ui.pg.deinit();
        ui.unlock();
        ui.tty.close(ui.io);
    }
};

const Sink = struct {
    ui: *Ui,
    writer: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const s: *Sink = @fieldParentPtr("writer", w);
        if (w.end > 0) {
            s.ui.feed(w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            s.ui.feed(d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| s.ui.feed(last) catch return error.WriteFailed;
        n += last.len * splat;
        return n;
    }
};
