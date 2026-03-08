//! Raw keystroke reading with escape sequence parsing.
//!
//! Reads individual bytes from stdin and translates multi-byte escape
//! sequences (arrow keys, home/end, etc.) into `Key` values. Uses
//! `std.posix.poll` with a 50 ms timeout to distinguish a lone Escape
//! press from the start of an escape sequence.

const std = @import("std");
const builtin = @import("builtin");

/// Represents a single keypress.
pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    delete,
    tab,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    ctrl_a,
    ctrl_b,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_f,
    ctrl_k,
    ctrl_l,
    ctrl_n,
    ctrl_p,
    ctrl_u,
    ctrl_w,
    unknown,
};

const ESCAPE_TIMEOUT_MS = 50;

/// Read a single key from stdin. Blocks until a key is available.
/// Returns `null` on EOF.
pub fn readKey() ?Key {
    const stdin = std.fs.File.stdin();
    const b = readByte(stdin) orelse return null;

    return switch (b) {
        '\r', '\n' => .enter,
        127 => .backspace,
        '\t' => .tab,
        1 => .ctrl_a,
        2 => .ctrl_b,
        3 => .ctrl_c,
        4 => .ctrl_d,
        5 => .ctrl_e,
        6 => .ctrl_f,
        11 => .ctrl_k,
        12 => .ctrl_l,
        14 => .ctrl_n,
        16 => .ctrl_p,
        21 => .ctrl_u,
        23 => .ctrl_w,
        '\x1b' => parseEscape(stdin),
        else => .{ .char = b },
    };
}

fn parseEscape(stdin: std.fs.File) Key {
    // Poll to see if more bytes are coming (part of an escape sequence).
    if (!hasPendingInput(stdin)) return .escape;

    const b2 = readByte(stdin) orelse return .escape;
    if (b2 == '[') {
        return parseCsi(stdin);
    } else if (b2 == 'O') {
        // SS3 sequences (some terminals send these for function keys)
        const b3 = readByte(stdin) orelse return .escape;
        return switch (b3) {
            'H' => .home,
            'F' => .end,
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .unknown,
        };
    }
    return .unknown;
}

fn parseCsi(stdin: std.fs.File) Key {
    const b3 = readByte(stdin) orelse return .escape;
    return switch (b3) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '1' => parseCsiExtended(stdin, b3),
        '3' => parseCsiTilde(stdin, .delete),
        '5' => parseCsiTilde(stdin, .page_up),
        '6' => parseCsiTilde(stdin, .page_down),
        '7' => parseCsiTilde(stdin, .home),
        '8' => parseCsiTilde(stdin, .end),
        else => .unknown,
    };
}

fn parseCsiExtended(stdin: std.fs.File, _: u8) Key {
    const b4 = readByte(stdin) orelse return .unknown;
    return switch (b4) {
        '~' => .home,
        ';' => {
            // Modified key: e.g., \x1b[1;5A (Ctrl+Up)
            // Consume modifier digit and final byte
            _ = readByte(stdin); // modifier
            _ = readByte(stdin); // final
            return .unknown;
        },
        else => .unknown,
    };
}

fn parseCsiTilde(stdin: std.fs.File, key: Key) Key {
    const tilde = readByte(stdin) orelse return .unknown;
    if (tilde == '~') return key;
    return .unknown;
}

fn readByte(file: std.fs.File) ?u8 {
    var buf: [1]u8 = undefined;
    const n = file.read(&buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}

fn hasPendingInput(file: std.fs.File) bool {
    if (comptime builtin.os.tag == .windows) {
        // On Windows, assume more bytes follow an escape
        return true;
    }
    var fds = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, ESCAPE_TIMEOUT_MS) catch return false;
    return ready > 0;
}

// -- tests ------------------------------------------------------------------

test "Key union size is small" {
    try std.testing.expect(@sizeOf(Key) <= 2);
}

test "Key char variant" {
    const k = Key{ .char = 'a' };
    switch (k) {
        .char => |c| try std.testing.expectEqual(@as(u8, 'a'), c),
        else => unreachable,
    }
}

test "Key special variants exist" {
    // Verify the enum tags exist by constructing each variant
    const k1: Key = .enter;
    const k2: Key = .backspace;
    const k3: Key = .delete;
    const k4: Key = .tab;
    const k5: Key = .escape;
    const k6: Key = .up;
    const k7: Key = .down;
    const k8: Key = .left;
    const k9: Key = .right;
    const k10: Key = .home;
    const k11: Key = .end;
    const k12: Key = .page_up;
    const k13: Key = .page_down;
    const k14: Key = .ctrl_a;
    const k15: Key = .ctrl_c;
    const k16: Key = .ctrl_d;
    const k17: Key = .ctrl_e;
    const k18: Key = .ctrl_k;
    const k19: Key = .ctrl_u;
    const k20: Key = .ctrl_w;
    // Ensure they're all usable
    _ = .{ k1, k2, k3, k4, k5, k6, k7, k8, k9, k10, k11, k12, k13, k14, k15, k16, k17, k18, k19, k20 };
}

test "hasPendingInput does not crash on /dev/null" {
    if (comptime builtin.os.tag == .windows) return;
    const devnull = std.fs.openFileAbsolute("/dev/null", .{}) catch return;
    defer devnull.close();
    // /dev/null may report ready or not depending on OS; just verify no crash
    _ = hasPendingInput(devnull);
}
