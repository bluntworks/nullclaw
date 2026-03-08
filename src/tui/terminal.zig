//! Terminal primitives: raw mode, size detection, cursor ops, alt screen.
//!
//! All operations use buffered output to minimize syscalls. The caller
//! provides a stack buffer; no heap allocation in any hot-path function.

const std = @import("std");
const builtin = @import("builtin");

/// Terminal dimensions in columns and rows.
pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// SIGWINCH flag — set by signal handler, polled by main loop.
pub var resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Terminal handle with buffered writer and saved termios.
pub const Terminal = struct {
    file: std.fs.File,
    original_termios: if (is_posix) std.posix.termios else void,
    raw_enabled: bool,
    alt_screen: bool,
    out_buf: [4096]u8 = undefined,

    const is_posix = switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    /// Initialize a Terminal from stdout. Does NOT enable raw mode yet.
    pub fn init() Terminal {
        const file = std.fs.File.stdout();
        return .{
            .file = file,
            .original_termios = if (is_posix) std.posix.tcgetattr(file.handle) catch std.mem.zeroes(std.posix.termios) else {},
            .raw_enabled = false,
            .alt_screen = false,
        };
    }

    /// Enable raw mode (disable echo, canonical mode, signals).
    pub fn enableRawMode(self: *Terminal) !void {
        if (!is_posix) return;
        var raw = self.original_termios;

        // Input: no break, no CR-to-NL, no parity, no strip, no flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output: disable post-processing
        raw.oflag.OPOST = false;

        // Local: no echo, no canonical, no extended, no signals
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control: 8-bit chars
        raw.cflag.CSIZE = .CS8;

        // Read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(self.file.handle, .FLUSH, raw);
        self.raw_enabled = true;
    }

    /// Restore original terminal settings.
    pub fn disableRawMode(self: *Terminal) void {
        if (!is_posix or !self.raw_enabled) return;
        std.posix.tcsetattr(self.file.handle, .FLUSH, self.original_termios) catch {};
        self.raw_enabled = false;
    }

    /// Switch to alternate screen buffer.
    pub fn enterAltScreen(self: *Terminal) !void {
        try self.writeEsc("\x1b[?1049h");
        self.alt_screen = true;
    }

    /// Return to main screen buffer.
    pub fn leaveAltScreen(self: *Terminal) !void {
        try self.writeEsc("\x1b[?1049l");
        self.alt_screen = false;
    }

    /// Get terminal size via ioctl.
    pub fn getSize(self: *Terminal) Size {
        if (is_posix) {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(self.file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc == 0 and ws.col > 0 and ws.row > 0) {
                return .{ .cols = ws.col, .rows = ws.row };
            }
        }
        return .{ .cols = 80, .rows = 24 }; // fallback
    }

    /// Install SIGWINCH handler to set resize_pending flag.
    pub fn installResizeHandler() void {
        if (!is_posix) return;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
    }

    fn handleSigwinch(_: c_int) callconv(.c) void {
        resize_pending.store(true, .release);
    }

    // -- cursor operations --------------------------------------------------

    pub fn hideCursor(self: *Terminal) !void {
        try self.writeEsc("\x1b[?25l");
    }

    pub fn showCursor(self: *Terminal) !void {
        try self.writeEsc("\x1b[?25h");
    }

    pub fn moveTo(self: *Terminal, row: u16, col: u16) !void {
        var buf: [24]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return;
        try self.writeEsc(seq);
    }

    pub fn clearLine(self: *Terminal) !void {
        try self.writeEsc("\x1b[2K");
    }

    pub fn clearScreen(self: *Terminal) !void {
        try self.writeEsc("\x1b[2J");
    }

    pub fn clearBelow(self: *Terminal) !void {
        try self.writeEsc("\x1b[J");
    }

    pub fn scrollUp(self: *Terminal, n: u16) !void {
        if (n == 0) return;
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}S", .{n}) catch return;
        try self.writeEsc(seq);
    }

    // -- output helpers -----------------------------------------------------

    fn writeEsc(self: *Terminal, seq: []const u8) !void {
        var bw = self.file.writer(&self.out_buf);
        const w = &bw.interface;
        try w.writeAll(seq);
        try w.flush();
    }

    /// Write styled text: emit SGR open, text, SGR reset.
    pub fn writeStyled(self: *Terminal, text: []const u8, style: @import("style.zig").Style) !void {
        var sgr_buf: [32]u8 = undefined;
        const open = style.encode(&sgr_buf);
        var bw = self.file.writer(&self.out_buf);
        const w = &bw.interface;
        try w.writeAll(open);
        try w.writeAll(text);
        try w.writeAll("\x1b[0m");
        try w.flush();
    }

    /// Write raw bytes to terminal.
    pub fn writeRaw(self: *Terminal, data: []const u8) !void {
        var bw = self.file.writer(&self.out_buf);
        const w = &bw.interface;
        try w.writeAll(data);
        try w.flush();
    }

    /// Full cleanup: show cursor, leave alt screen, disable raw mode.
    pub fn cleanup(self: *Terminal) void {
        self.showCursor() catch {};
        if (self.alt_screen) {
            self.leaveAltScreen() catch {};
        }
        self.disableRawMode();
    }
};

// -- tests ------------------------------------------------------------------

test "Terminal.init does not crash" {
    // In test mode we can't actually manipulate the terminal,
    // but init should not panic.
    _ = Terminal.init();
}

test "Size default" {
    const s = Size{ .cols = 80, .rows = 24 };
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

test "resize_pending starts false" {
    try std.testing.expect(!resize_pending.load(.acquire));
}

test "resize_pending can be set and cleared" {
    resize_pending.store(true, .release);
    try std.testing.expect(resize_pending.load(.acquire));
    resize_pending.store(false, .release);
    try std.testing.expect(!resize_pending.load(.acquire));
}

test "Terminal.getSize returns positive dimensions" {
    var term = Terminal.init();
    const size = term.getSize();
    try std.testing.expect(size.cols > 0);
    try std.testing.expect(size.rows > 0);
}
