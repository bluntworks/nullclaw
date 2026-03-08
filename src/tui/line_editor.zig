//! Line editor with cursor movement, history navigation, and kill-ring.
//!
//! Uses a fixed 4096-byte buffer (stack-resident). Renders the current
//! line at a caller-specified terminal row. Integrates with the shared
//! history load/save in `src/channels/cli.zig`.

const std = @import("std");
const input_mod = @import("input.zig");
const Key = input_mod.Key;
const Terminal = @import("terminal.zig").Terminal;

pub const MAX_LINE = 4096;

/// Line editor state. Stack-allocated, no heap.
pub const LineEditor = struct {
    buf: [MAX_LINE]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    // History navigation
    history: []const []const u8 = &.{},
    history_pos: usize = 0, // points past end when not browsing
    saved_line: [MAX_LINE]u8 = undefined,
    saved_len: usize = 0,

    // Rendering context
    prompt: []const u8 = "> ",
    render_row: u16 = 0,

    /// Process a key event. Returns the completed line (without newline)
    /// when Enter is pressed, or `null` to keep editing.
    pub fn handleKey(self: *LineEditor, key: Key) ?[]const u8 {
        switch (key) {
            .enter => {
                if (self.len == 0) return null;
                const line = self.buf[0..self.len];
                // Check for backslash continuation
                if (self.len > 0 and self.buf[self.len - 1] == '\\') {
                    self.buf[self.len - 1] = ' ';
                    return null;
                }
                return line;
            },
            .char => |c| self.insertChar(c),
            .backspace => self.deleteBack(),
            .delete => self.deleteForward(),
            .left => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .right => {
                if (self.cursor < self.len) self.cursor += 1;
            },
            .home, .ctrl_a => self.cursor = 0,
            .end, .ctrl_e => self.cursor = self.len,
            .ctrl_b => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .ctrl_f => {
                if (self.cursor < self.len) self.cursor += 1;
            },
            .ctrl_k => self.killToEnd(),
            .ctrl_u => self.killToStart(),
            .ctrl_w => self.killWordBack(),
            .up, .ctrl_p => self.historyPrev(),
            .down, .ctrl_n => self.historyNext(),
            .ctrl_l => {}, // handled by caller (clear screen)
            else => {},
        }
        return null;
    }

    /// Insert a character at the cursor position.
    fn insertChar(self: *LineEditor, c: u8) void {
        if (self.len >= MAX_LINE) return;
        if (self.cursor < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
        }
        self.buf[self.cursor] = c;
        self.len += 1;
        self.cursor += 1;
    }

    /// Delete the character before the cursor.
    fn deleteBack(self: *LineEditor) void {
        if (self.cursor == 0) return;
        if (self.cursor < self.len) {
            std.mem.copyForwards(u8, self.buf[self.cursor - 1 .. self.len - 1], self.buf[self.cursor..self.len]);
        }
        self.cursor -= 1;
        self.len -= 1;
    }

    /// Delete the character at the cursor.
    fn deleteForward(self: *LineEditor) void {
        if (self.cursor >= self.len) return;
        if (self.cursor + 1 < self.len) {
            std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
        }
        self.len -= 1;
    }

    /// Kill from cursor to end of line.
    fn killToEnd(self: *LineEditor) void {
        self.len = self.cursor;
    }

    /// Kill from start of line to cursor.
    fn killToStart(self: *LineEditor) void {
        if (self.cursor == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
        self.len -= self.cursor;
        self.cursor = 0;
    }

    /// Kill the word before the cursor (deletes back to previous whitespace).
    fn killWordBack(self: *LineEditor) void {
        if (self.cursor == 0) return;
        var end = self.cursor;
        // Skip trailing whitespace
        while (end > 0 and self.buf[end - 1] == ' ') end -= 1;
        // Skip word chars
        while (end > 0 and self.buf[end - 1] != ' ') end -= 1;
        const removed = self.cursor - end;
        if (removed == 0) return;
        std.mem.copyForwards(u8, self.buf[end .. self.len - removed], self.buf[self.cursor..self.len]);
        self.len -= removed;
        self.cursor = end;
    }

    /// Navigate to the previous history entry.
    fn historyPrev(self: *LineEditor) void {
        if (self.history.len == 0) return;
        if (self.history_pos == 0) return;

        // Save current line on first navigation
        if (self.history_pos == self.history.len) {
            @memcpy(self.saved_line[0..self.len], self.buf[0..self.len]);
            self.saved_len = self.len;
        }

        self.history_pos -= 1;
        self.setLineFromHistory(self.history[self.history_pos]);
    }

    /// Navigate to the next history entry (or restore saved line).
    fn historyNext(self: *LineEditor) void {
        if (self.history.len == 0) return;
        if (self.history_pos >= self.history.len) return;

        self.history_pos += 1;
        if (self.history_pos == self.history.len) {
            // Restore saved line
            @memcpy(self.buf[0..self.saved_len], self.saved_line[0..self.saved_len]);
            self.len = self.saved_len;
            self.cursor = self.len;
        } else {
            self.setLineFromHistory(self.history[self.history_pos]);
        }
    }

    fn setLineFromHistory(self: *LineEditor, entry: []const u8) void {
        const copy_len = @min(entry.len, MAX_LINE);
        @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    /// Render the prompt and current line at `render_row`.
    pub fn render(self: *LineEditor, term: *Terminal) !void {
        try term.moveTo(self.render_row, 0);
        try term.clearLine();

        var out_buf: [4096]u8 = undefined;
        var bw = term.file.writer(&out_buf);
        const w = &bw.interface;

        try w.writeAll(self.prompt);
        try w.writeAll(self.buf[0..self.len]);
        try w.flush();

        // Position cursor
        const cursor_col: u16 = @intCast(self.prompt.len + self.cursor);
        try term.moveTo(self.render_row, cursor_col);
    }

    /// Reset editor state for the next line.
    pub fn clear(self: *LineEditor) void {
        self.len = 0;
        self.cursor = 0;
    }

    /// Set history and position to end (not browsing).
    pub fn setHistory(self: *LineEditor, history: []const []const u8) void {
        self.history = history;
        self.history_pos = history.len;
    }

    /// Return the current buffer content as a slice.
    pub fn content(self: *const LineEditor) []const u8 {
        return self.buf[0..self.len];
    }
};

// -- tests ------------------------------------------------------------------

test "insertChar basic" {
    var ed = LineEditor{};
    ed.insertChar('h');
    ed.insertChar('i');
    try std.testing.expectEqualStrings("hi", ed.content());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "insertChar in middle" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('c');
    ed.cursor = 1;
    ed.insertChar('b');
    try std.testing.expectEqualStrings("abc", ed.content());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "deleteBack" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('b');
    ed.insertChar('c');
    ed.deleteBack();
    try std.testing.expectEqualStrings("ab", ed.content());
}

test "deleteBack at start does nothing" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.cursor = 0;
    ed.deleteBack();
    try std.testing.expectEqualStrings("a", ed.content());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "deleteForward" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('b');
    ed.insertChar('c');
    ed.cursor = 1;
    ed.deleteForward();
    try std.testing.expectEqualStrings("ac", ed.content());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "deleteForward at end does nothing" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.deleteForward();
    try std.testing.expectEqualStrings("a", ed.content());
}

test "killToEnd" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('b');
    ed.insertChar('c');
    ed.cursor = 1;
    ed.killToEnd();
    try std.testing.expectEqualStrings("a", ed.content());
}

test "killToStart" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('b');
    ed.insertChar('c');
    ed.cursor = 2;
    ed.killToStart();
    try std.testing.expectEqualStrings("c", ed.content());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "killWordBack" {
    var ed = LineEditor{};
    for ("hello world") |c| ed.insertChar(c);
    ed.killWordBack();
    try std.testing.expectEqualStrings("hello ", ed.content());
}

test "killWordBack with trailing spaces" {
    var ed = LineEditor{};
    for ("hello   ") |c| ed.insertChar(c);
    ed.killWordBack();
    try std.testing.expectEqualStrings("", ed.content());
}

test "handleKey enter returns line" {
    var ed = LineEditor{};
    ed.insertChar('h');
    ed.insertChar('i');
    const result = ed.handleKey(.enter);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hi", result.?);
}

test "handleKey enter on empty returns null" {
    var ed = LineEditor{};
    const result = ed.handleKey(.enter);
    try std.testing.expect(result == null);
}

test "handleKey backslash continuation" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('\\');
    const result = ed.handleKey(.enter);
    try std.testing.expect(result == null);
    // Backslash replaced with space
    try std.testing.expectEqual(@as(u8, ' '), ed.buf[1]);
}

test "handleKey arrows move cursor" {
    var ed = LineEditor{};
    ed.insertChar('a');
    ed.insertChar('b');
    _ = ed.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    _ = ed.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    _ = ed.handleKey(.home);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    _ = ed.handleKey(.end);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "history navigation" {
    var ed = LineEditor{};
    const history = [_][]const u8{ "first", "second", "third" };
    ed.setHistory(&history);

    // Type something
    ed.insertChar('c');
    ed.insertChar('u');
    ed.insertChar('r');

    // Navigate up
    ed.historyPrev();
    try std.testing.expectEqualStrings("third", ed.content());
    ed.historyPrev();
    try std.testing.expectEqualStrings("second", ed.content());
    // Navigate back down
    ed.historyNext();
    try std.testing.expectEqualStrings("third", ed.content());
    // Back to original
    ed.historyNext();
    try std.testing.expectEqualStrings("cur", ed.content());
}

test "history prev at start stays" {
    var ed = LineEditor{};
    const history = [_][]const u8{"only"};
    ed.setHistory(&history);

    ed.historyPrev();
    try std.testing.expectEqualStrings("only", ed.content());
    ed.historyPrev(); // should not crash
    try std.testing.expectEqualStrings("only", ed.content());
}

test "clear resets state" {
    var ed = LineEditor{};
    ed.insertChar('x');
    ed.clear();
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "setHistory updates position" {
    var ed = LineEditor{};
    const history = [_][]const u8{ "a", "b" };
    ed.setHistory(&history);
    try std.testing.expectEqual(@as(usize, 2), ed.history_pos);
}
