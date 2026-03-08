//! ANSI colors and text styling.
//!
//! Provides `Style` and `Color` types for terminal text formatting,
//! plus `shouldColorize()` and `enableWindowsVT100()` extracted from
//! `src/doctor.zig` so both doctor and TUI share one implementation.

const std = @import("std");
const builtin = @import("builtin");

/// ANSI foreground/background color codes.
pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    /// Return the ANSI code for use as a foreground color.
    pub fn fgCode(self: Color) u8 {
        return @intFromEnum(self);
    }

    /// Return the ANSI code for use as a background color (fg + 10).
    pub fn bgCode(self: Color) u8 {
        return @intFromEnum(self) + 10;
    }
};

/// Text style: foreground, background, and attributes.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    pub const reset = Style{};

    /// Write the ANSI SGR sequence for this style into `buf`.
    /// Returns the slice of `buf` that was written.
    pub fn encode(self: Style, buf: *[32]u8) []const u8 {
        var pos: usize = 0;
        buf[pos] = '\x1b';
        pos += 1;
        buf[pos] = '[';
        pos += 1;

        var need_sep = false;

        if (self.bold) {
            buf[pos] = '1';
            pos += 1;
            need_sep = true;
        }
        if (self.dim) {
            if (need_sep) {
                buf[pos] = ';';
                pos += 1;
            }
            buf[pos] = '2';
            pos += 1;
            need_sep = true;
        }
        if (self.italic) {
            if (need_sep) {
                buf[pos] = ';';
                pos += 1;
            }
            buf[pos] = '3';
            pos += 1;
            need_sep = true;
        }
        if (self.underline) {
            if (need_sep) {
                buf[pos] = ';';
                pos += 1;
            }
            buf[pos] = '4';
            pos += 1;
            need_sep = true;
        }
        if (self.fg != .default) {
            if (need_sep) {
                buf[pos] = ';';
                pos += 1;
            }
            pos += writeU8(buf[pos..], self.fg.fgCode());
            need_sep = true;
        }
        if (self.bg != .default) {
            if (need_sep) {
                buf[pos] = ';';
                pos += 1;
            }
            pos += writeU8(buf[pos..], self.bg.bgCode());
            need_sep = true;
        }

        if (!need_sep) {
            // Reset: \x1b[0m
            buf[pos] = '0';
            pos += 1;
        }

        buf[pos] = 'm';
        pos += 1;
        return buf[0..pos];
    }
};

/// Legacy color constants matching the old doctor.zig `Color` struct.
/// Kept for compatibility; new code should use `Style` or `Color` enum.
pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const cyan = "\x1b[36m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
};

/// Determine whether the given file handle should receive ANSI color output.
/// Respects the NO_COLOR convention (https://no-color.org/) and checks isTty.
pub fn shouldColorize(file: std.fs.File) bool {
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("NO_COLOR")) |_| return false;
    }
    if (!file.isTty()) return false;
    if (builtin.os.tag == .windows) {
        return enableWindowsVT100() catch false;
    }
    return true;
}

/// Windows-specific: enable ENABLE_VIRTUAL_TERMINAL_PROCESSING on stdout.
pub fn enableWindowsVT100() !bool {
    if (builtin.os.tag != .windows) return true;
    const windows = std.os.windows;
    const handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    var mode: windows.DWORD = 0;
    if (windows.kernel32.GetConsoleMode(handle, &mode) == 0) return false;
    mode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
    return windows.kernel32.SetConsoleMode(handle, mode) != 0;
}

// -- helpers ----------------------------------------------------------------

fn writeU8(buf: []u8, val: u8) usize {
    if (val >= 100) {
        buf[0] = '0' + val / 100;
        buf[1] = '0' + (val / 10) % 10;
        buf[2] = '0' + val % 10;
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + val / 10;
        buf[1] = '0' + val % 10;
        return 2;
    } else {
        buf[0] = '0' + val;
        return 1;
    }
}

// -- tests ------------------------------------------------------------------

test "Style.encode reset" {
    var buf: [32]u8 = undefined;
    const seq = (Style{}).encode(&buf);
    try std.testing.expectEqualStrings("\x1b[0m", seq);
}

test "Style.encode bold red" {
    var buf: [32]u8 = undefined;
    const seq = (Style{ .bold = true, .fg = .red }).encode(&buf);
    try std.testing.expectEqualStrings("\x1b[1;31m", seq);
}

test "Style.encode dim italic cyan bg" {
    var buf: [32]u8 = undefined;
    const seq = (Style{ .dim = true, .italic = true, .bg = .cyan }).encode(&buf);
    try std.testing.expectEqualStrings("\x1b[2;3;46m", seq);
}

test "Style.encode fg only" {
    var buf: [32]u8 = undefined;
    const seq = (Style{ .fg = .green }).encode(&buf);
    try std.testing.expectEqualStrings("\x1b[32m", seq);
}

test "Style.encode bright colors" {
    var buf: [32]u8 = undefined;
    const seq = (Style{ .fg = .bright_white }).encode(&buf);
    try std.testing.expectEqualStrings("\x1b[97m", seq);
}

test "Color fg and bg codes" {
    try std.testing.expectEqual(@as(u8, 31), Color.red.fgCode());
    try std.testing.expectEqual(@as(u8, 41), Color.red.bgCode());
    try std.testing.expectEqual(@as(u8, 97), Color.bright_white.fgCode());
    try std.testing.expectEqual(@as(u8, 107), Color.bright_white.bgCode());
}

test "shouldColorize returns false for non-TTY" {
    const devnull = std.fs.openFileAbsolute("/dev/null", .{}) catch return;
    defer devnull.close();
    try std.testing.expect(!shouldColorize(devnull));
}

test "ansi constants are valid escape sequences" {
    try std.testing.expect(ansi.reset[0] == '\x1b');
    try std.testing.expect(ansi.green[0] == '\x1b');
    try std.testing.expect(ansi.red[0] == '\x1b');
}

test "writeU8 single digit" {
    var buf: [4]u8 = undefined;
    const n = writeU8(&buf, 5);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("5", buf[0..n]);
}

test "writeU8 two digits" {
    var buf: [4]u8 = undefined;
    const n = writeU8(&buf, 42);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("42", buf[0..n]);
}

test "writeU8 three digits" {
    var buf: [4]u8 = undefined;
    const n = writeU8(&buf, 107);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("107", buf[0..n]);
}
