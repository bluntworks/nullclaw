//! Screen layout and rendering for the TUI agent REPL.
//!
//! Layout (top to bottom):
//!   Row 0              — Status bar (model, provider, tokens)
//!   Rows 1..H-6        — Chat area (scrollback ring buffer)
//!   Row H-5            — Separator line (chat/log boundary)
//!   Rows H-4..H-2      — Log panel (3 lines, dim text)
//!   Row H-1            — Input line (managed by LineEditor)
//!
//! The chat area uses a pre-allocated ring buffer (~1000 lines) for
//! scrollback. Word wrapping is performed at render time based on
//! current terminal width.

const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const Size = @import("terminal.zig").Size;
const style_mod = @import("style.zig");
const Style = style_mod.Style;

/// Maximum number of logical lines in scrollback.
const MAX_SCROLLBACK = 1000;
/// Maximum characters per logical line.
const MAX_LINE_CHARS = 512;
/// Number of rows reserved for the log panel.
const LOG_PANEL_HEIGHT: u16 = 3;
/// Maximum number of log entries in the ring buffer.
const LOG_SCROLLBACK = 50;

/// A single line in the scrollback buffer.
const ScrollLine = struct {
    buf: [MAX_LINE_CHARS]u8 = undefined,
    len: u16 = 0,
    is_user: bool = false,
    is_raw: bool = false,

    fn text(self: *const ScrollLine) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Renderer = struct {
    term: *Terminal,
    size: Size,

    // Scrollback ring buffer
    lines: [MAX_SCROLLBACK]ScrollLine = [_]ScrollLine{.{}} ** MAX_SCROLLBACK,
    line_count: usize = 0,
    write_pos: usize = 0, // next write position in ring

    // Log panel ring buffer
    log_lines: [LOG_SCROLLBACK]ScrollLine = [_]ScrollLine{.{}} ** LOG_SCROLLBACK,
    log_count: usize = 0,
    log_write_pos: usize = 0,

    // Status bar content
    provider_name: [64]u8 = undefined,
    provider_len: u8 = 0,
    model_name: [64]u8 = undefined,
    model_len: u8 = 0,
    token_count: u32 = 0,

    // Streaming state
    streaming_active: bool = false,
    spinner_frame: u8 = 0,
    thinking: bool = false,

    pub fn init(term: *Terminal) Renderer {
        const size = term.getSize();
        return .{
            .term = term,
            .size = size,
        };
    }

    /// Set the status bar provider/model info.
    pub fn setStatus(self: *Renderer, provider: []const u8, model: []const u8) void {
        const plen: u8 = @intCast(@min(provider.len, 64));
        @memcpy(self.provider_name[0..plen], provider[0..plen]);
        self.provider_len = plen;

        const mlen: u8 = @intCast(@min(model.len, 64));
        @memcpy(self.model_name[0..mlen], model[0..mlen]);
        self.model_len = mlen;
    }

    /// Update token count for status bar.
    pub fn setTokenCount(self: *Renderer, count: u32) void {
        self.token_count = count;
    }

    /// Handle terminal resize.
    pub fn resize(self: *Renderer) void {
        self.size = self.term.getSize();
    }

    /// Full screen redraw.
    pub fn draw(self: *Renderer) !void {
        try self.term.hideCursor();
        try self.drawStatusBar();
        try self.drawChatArea();
        try self.drawSeparator();
        try self.drawLogPanel();
        try self.term.showCursor();
    }

    /// Draw the status bar at row 0.
    fn drawStatusBar(self: *Renderer) !void {
        try self.term.moveTo(0, 0);
        try self.term.clearLine();

        const provider = self.provider_name[0..self.provider_len];
        const model = self.model_name[0..self.model_len];

        var out_buf: [4096]u8 = undefined;
        var bw = self.term.file.writer(&out_buf);
        const w = &bw.interface;

        // Inverted style for status bar
        try w.writeAll("\x1b[7m");
        try w.print(" {s}", .{provider});
        if (model.len > 0) {
            try w.print(" | {s}", .{model});
        }
        if (self.token_count > 0) {
            try w.print(" | {d} tokens", .{self.token_count});
        }
        if (self.thinking) {
            const spinners = [_]u8{ '|', '/', '-', '\\' };
            try w.print(" {c} thinking...", .{spinners[self.spinner_frame % 4]});
        }
        // Pad to fill width
        // Calculate how many chars we've written (approximate)
        try w.writeAll("\x1b[0m");
        try w.flush();
    }

    /// Row where the separator between chat and log panel sits.
    fn separatorRow(self: *Renderer) u16 {
        // H - 2 - LOG_PANEL_HEIGHT - 1 = H - 2 - 3 - 1 = H - 6
        // but guard against tiny terminals
        if (self.size.rows < 2 + LOG_PANEL_HEIGHT + 2) return 1;
        return self.size.rows - 1 - LOG_PANEL_HEIGHT - 1;
    }

    /// Draw the chat area (rows 1 to separatorRow-1).
    fn drawChatArea(self: *Renderer) !void {
        if (self.size.rows < 2 + LOG_PANEL_HEIGHT + 3) return;
        const sep = self.separatorRow();
        const chat_rows: usize = @as(usize, sep) - 1; // rows 1..sep-1
        const cols: usize = @as(usize, self.size.cols);

        // Collect visible wrapped lines from scrollback
        var display_lines: [256]DisplayLine = undefined;
        var display_count: usize = 0;

        // Walk backwards through scrollback to fill display
        var remaining = chat_rows;
        var idx: usize = self.line_count;
        while (idx > 0 and remaining > 0) {
            idx -= 1;
            const ring_idx = if (self.line_count <= MAX_SCROLLBACK)
                idx
            else
                (self.write_pos + MAX_SCROLLBACK - (self.line_count - idx)) % MAX_SCROLLBACK;

            const line = &self.lines[ring_idx];
            const text = line.text();
            const wrapped = wrapCount(text, cols);

            if (wrapped <= remaining) {
                remaining -= wrapped;
                if (display_count < display_lines.len) {
                    display_lines[display_count] = .{
                        .text = text,
                        .is_user = line.is_user,
                        .is_raw = line.is_raw,
                    };
                    display_count += 1;
                }
            } else {
                break;
            }
        }

        // Render from top (display_lines are in reverse order)
        var row: u16 = 1;
        var di = display_count;
        while (di > 0) {
            di -= 1;
            const dl = display_lines[di];
            row = try self.renderWrappedLine(row, dl.text, dl.is_user, dl.is_raw, cols);
        }

        // Clear remaining chat rows up to the separator
        while (row < sep) {
            try self.term.moveTo(row, 0);
            try self.term.clearLine();
            row += 1;
        }
    }

    const DisplayLine = struct {
        text: []const u8,
        is_user: bool,
        is_raw: bool = false,
    };

    fn renderWrappedLine(self: *Renderer, start_row: u16, text: []const u8, is_user: bool, is_raw: bool, cols: usize) !u16 {
        if (cols == 0) return start_row;

        // Raw lines: write verbatim (text already contains ANSI escapes)
        if (is_raw) {
            try self.term.moveTo(start_row, 0);
            try self.term.clearLine();
            var out_buf2: [4096]u8 = undefined;
            var bw2 = self.term.file.writer(&out_buf2);
            const w2 = &bw2.interface;
            try w2.writeAll(text);
            try w2.flush();
            return start_row + 1;
        }

        var row = start_row;
        var pos: usize = 0;

        while (pos <= text.len) {
            try self.term.moveTo(row, 0);
            try self.term.clearLine();

            const chunk_end = @min(pos + cols, text.len);
            const chunk = text[pos..chunk_end];

            if (is_user) {
                // Muted orange via 256-color palette (color 172)
                var out_buf2: [4096]u8 = undefined;
                var bw2 = self.term.file.writer(&out_buf2);
                const w2 = &bw2.interface;
                try w2.writeAll("\x1b[38;5;172m");
                try w2.writeAll(chunk);
                try w2.writeAll("\x1b[0m");
                try w2.flush();
            } else {
                var out_buf2: [4096]u8 = undefined;
                var bw2 = self.term.file.writer(&out_buf2);
                const w2 = &bw2.interface;
                try w2.writeAll("\x1b[90m  "); // grey + 2-space indent
                try w2.writeAll(chunk);
                try w2.writeAll("\x1b[0m");
                try w2.flush();
            }

            row += 1;
            pos = chunk_end;
            if (pos >= text.len) break;
        }

        // At minimum, advance one row even for empty text
        if (text.len == 0) {
            try self.term.moveTo(start_row, 0);
            try self.term.clearLine();
            return start_row + 1;
        }

        return row;
    }

    /// Draw separator between chat area and log panel.
    fn drawSeparator(self: *Renderer) !void {
        if (self.size.rows < 2 + LOG_PANEL_HEIGHT + 2) return;
        const sep_row = self.separatorRow();
        try self.term.moveTo(sep_row, 0);
        try self.term.clearLine();

        var out_buf: [256]u8 = undefined;
        var bw = self.term.file.writer(&out_buf);
        const w = &bw.interface;
        try w.writeAll("\x1b[2m");
        const width = @min(@as(usize, self.size.cols), 256);
        for (0..width) |_| {
            try w.writeAll("\xe2\x94\x80"); // ─ (U+2500) UTF-8: 3 bytes
        }
        try w.writeAll("\x1b[0m");
        try w.flush();
    }

    /// Draw the log panel (LOG_PANEL_HEIGHT rows above the input line).
    fn drawLogPanel(self: *Renderer) !void {
        if (self.size.rows < 2 + LOG_PANEL_HEIGHT + 2) return;
        const start_row = self.size.rows - 1 - LOG_PANEL_HEIGHT;
        const cols: usize = @as(usize, self.size.cols);

        // Determine which log lines to show (most recent LOG_PANEL_HEIGHT)
        const show_count = @min(self.log_count, LOG_PANEL_HEIGHT);

        var row = start_row;
        // Render blank rows first if we have fewer log lines than panel height
        const blank_rows = LOG_PANEL_HEIGHT - @as(u16, @intCast(show_count));
        for (0..blank_rows) |_| {
            try self.term.moveTo(row, 0);
            try self.term.clearLine();
            row += 1;
        }

        // Render the most recent log lines
        if (show_count > 0) {
            var i: usize = show_count;
            while (i > 0) {
                i -= 1;
                const ring_idx = if (self.log_count <= LOG_SCROLLBACK)
                    self.log_count - show_count + (show_count - 1 - i)
                else
                    (self.log_write_pos + LOG_SCROLLBACK - show_count + (show_count - 1 - i)) % LOG_SCROLLBACK;

                const line = &self.log_lines[ring_idx];
                const text = line.text();

                try self.term.moveTo(row, 0);
                try self.term.clearLine();

                var out_buf: [4096]u8 = undefined;
                var bw = self.term.file.writer(&out_buf);
                const w = &bw.interface;
                // Dim style (ANSI dim + grey 242)
                try w.writeAll("\x1b[2;38;5;242m");
                const truncated = text[0..@min(text.len, cols)];
                try w.writeAll(truncated);
                try w.writeAll("\x1b[0m");
                try w.flush();

                row += 1;
            }
        }
    }

    /// Append a line to the log panel ring buffer.
    pub fn appendLog(self: *Renderer, text: []const u8) void {
        const copy_len: u16 = @intCast(@min(text.len, MAX_LINE_CHARS));
        self.log_lines[self.log_write_pos] = .{
            .len = copy_len,
        };
        @memcpy(self.log_lines[self.log_write_pos].buf[0..copy_len], text[0..copy_len]);
        self.log_write_pos = (self.log_write_pos + 1) % LOG_SCROLLBACK;
        if (self.log_count < LOG_SCROLLBACK) self.log_count += 1;
    }

    /// Append a line to the scrollback buffer.
    pub fn appendLine(self: *Renderer, text: []const u8, is_user: bool) void {
        const copy_len: u16 = @intCast(@min(text.len, MAX_LINE_CHARS));
        self.lines[self.write_pos] = .{
            .len = copy_len,
            .is_user = is_user,
        };
        @memcpy(self.lines[self.write_pos].buf[0..copy_len], text[0..copy_len]);
        self.write_pos = (self.write_pos + 1) % MAX_SCROLLBACK;
        if (self.line_count < MAX_SCROLLBACK) self.line_count += 1;
    }

    /// Append a raw line (pre-styled with ANSI escapes, rendered verbatim).
    pub fn appendRawLine(self: *Renderer, text: []const u8) void {
        const copy_len: u16 = @intCast(@min(text.len, MAX_LINE_CHARS));
        self.lines[self.write_pos] = .{
            .len = copy_len,
            .is_raw = true,
        };
        @memcpy(self.lines[self.write_pos].buf[0..copy_len], text[0..copy_len]);
        self.write_pos = (self.write_pos + 1) % MAX_SCROLLBACK;
        if (self.line_count < MAX_SCROLLBACK) self.line_count += 1;
    }

    /// Append multiple lines by splitting on newlines.
    pub fn appendText(self: *Renderer, text: []const u8, is_user: bool) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            self.appendLine(line, is_user);
        }
    }

    /// Begin streaming: append an empty line that will be extended.
    pub fn beginStreaming(self: *Renderer) void {
        self.streaming_active = true;
        self.appendLine("", false);
    }

    /// Append a streaming chunk to the current (last) scrollback line.
    /// If the chunk contains newlines, splits into new lines.
    pub fn appendStreamChunk(self: *Renderer, chunk: []const u8) void {
        if (!self.streaming_active) {
            self.beginStreaming();
        }

        var remaining = chunk;
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
                self.extendCurrentLine(remaining[0..nl_pos]);
                self.appendLine("", false);
                remaining = remaining[nl_pos + 1 ..];
            } else {
                self.extendCurrentLine(remaining);
                break;
            }
        }
    }

    fn extendCurrentLine(self: *Renderer, text: []const u8) void {
        if (self.line_count == 0) return;
        const idx = if (self.write_pos == 0) MAX_SCROLLBACK - 1 else self.write_pos - 1;
        const line = &self.lines[idx];
        const space: usize = MAX_LINE_CHARS - @as(usize, line.len);
        const copy_len: u16 = @intCast(@min(text.len, space));
        @memcpy(line.buf[line.len .. line.len + copy_len], text[0..copy_len]);
        line.len += copy_len;
    }

    /// End streaming mode.
    pub fn endStreaming(self: *Renderer) void {
        self.streaming_active = false;
    }

    /// Show thinking indicator.
    pub fn showThinking(self: *Renderer) void {
        self.thinking = true;
    }

    /// Hide thinking indicator.
    pub fn hideThinking(self: *Renderer) void {
        self.thinking = false;
        self.spinner_frame = 0;
    }

    /// Advance spinner frame (call periodically).
    pub fn tickSpinner(self: *Renderer) void {
        self.spinner_frame +%= 1;
    }

    /// Show a tool call in the chat area.
    pub fn showToolCall(self: *Renderer, name: []const u8, status: []const u8) void {
        var buf: [MAX_LINE_CHARS]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "[tool: {s}] {s}", .{ name, status }) catch return;
        self.appendLine(text, false);
    }

    /// Get the input row (last row of terminal).
    pub fn inputRow(self: *Renderer) u16 {
        return self.size.rows - 1;
    }
};

/// Count how many display rows a line of `len` characters occupies
/// when wrapped at `cols` columns.
fn wrapCount(text: []const u8, cols: usize) usize {
    if (cols == 0) return 1;
    if (text.len == 0) return 1;
    return (text.len + cols - 1) / cols;
}

// -- tests ------------------------------------------------------------------

test "wrapCount empty" {
    try std.testing.expectEqual(@as(usize, 1), wrapCount("", 80));
}

test "wrapCount short" {
    try std.testing.expectEqual(@as(usize, 1), wrapCount("hello", 80));
}

test "wrapCount exact" {
    try std.testing.expectEqual(@as(usize, 1), wrapCount("12345678", 8));
}

test "wrapCount wrap" {
    try std.testing.expectEqual(@as(usize, 2), wrapCount("123456789", 8));
}

test "wrapCount multiple wraps" {
    try std.testing.expectEqual(@as(usize, 3), wrapCount("12345678901234567", 8));
}

test "Renderer.appendLine basic" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.appendLine("hello", false);
    try std.testing.expectEqual(@as(usize, 1), r.line_count);
    try std.testing.expectEqualStrings("hello", r.lines[0].text());
}

test "Renderer.appendLine ring wraps" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    for (0..MAX_SCROLLBACK + 5) |i| {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "line-{d}", .{i}) catch unreachable;
        r.appendLine(text, false);
    }
    try std.testing.expectEqual(@as(usize, MAX_SCROLLBACK), r.line_count);
}

test "Renderer.appendText splits on newlines" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.appendText("line1\nline2\nline3", false);
    try std.testing.expectEqual(@as(usize, 3), r.line_count);
    try std.testing.expectEqualStrings("line1", r.lines[0].text());
    try std.testing.expectEqualStrings("line2", r.lines[1].text());
    try std.testing.expectEqualStrings("line3", r.lines[2].text());
}

test "Renderer.appendStreamChunk extends line" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.beginStreaming();
    r.appendStreamChunk("hel");
    r.appendStreamChunk("lo");
    r.endStreaming();
    // beginStreaming appends one empty line, then chunks extend it
    try std.testing.expectEqual(@as(usize, 1), r.line_count);
    try std.testing.expectEqualStrings("hello", r.lines[0].text());
}

test "Renderer.appendStreamChunk with newlines" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.beginStreaming();
    r.appendStreamChunk("first\nsecond");
    r.endStreaming();
    try std.testing.expectEqual(@as(usize, 2), r.line_count);
    try std.testing.expectEqualStrings("first", r.lines[0].text());
    try std.testing.expectEqualStrings("second", r.lines[1].text());
}

test "Renderer.setStatus stores values" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.setStatus("anthropic", "claude-3");
    try std.testing.expectEqualStrings("anthropic", r.provider_name[0..r.provider_len]);
    try std.testing.expectEqualStrings("claude-3", r.model_name[0..r.model_len]);
}

test "Renderer.showToolCall appends formatted line" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.showToolCall("shell", "running");
    try std.testing.expectEqual(@as(usize, 1), r.line_count);
    const text = r.lines[0].text();
    try std.testing.expect(std.mem.indexOf(u8, text, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "running") != null);
}

test "Renderer.thinking state" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.showThinking();
    try std.testing.expect(r.thinking);
    r.tickSpinner();
    try std.testing.expectEqual(@as(u8, 1), r.spinner_frame);
    r.hideThinking();
    try std.testing.expect(!r.thinking);
    try std.testing.expectEqual(@as(u8, 0), r.spinner_frame);
}

test "Renderer.inputRow" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.size = .{ .cols = 80, .rows = 24 };
    try std.testing.expectEqual(@as(u16, 23), r.inputRow());
}

test "ScrollLine.text returns correct slice" {
    var sl = ScrollLine{};
    sl.buf[0] = 'h';
    sl.buf[1] = 'i';
    sl.len = 2;
    try std.testing.expectEqualStrings("hi", sl.text());
}

test "Renderer.appendLog basic" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.appendLog("tool failed: timeout");
    try std.testing.expectEqual(@as(usize, 1), r.log_count);
    try std.testing.expectEqualStrings("tool failed: timeout", r.log_lines[0].text());
}

test "Renderer.appendLog ring wraps" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    for (0..LOG_SCROLLBACK + 5) |i| {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "log-{d}", .{i}) catch unreachable;
        r.appendLog(text);
    }
    try std.testing.expectEqual(@as(usize, LOG_SCROLLBACK), r.log_count);
}

test "Renderer.separatorRow accounts for log panel" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.size = .{ .cols = 80, .rows = 24 };
    // separator = H - 1 - LOG_PANEL_HEIGHT - 1 = 24 - 1 - 3 - 1 = 19
    try std.testing.expectEqual(@as(u16, 19), r.separatorRow());
}

test "Renderer.separatorRow guards tiny terminal" {
    var term = Terminal.init();
    var r = Renderer.init(&term);
    r.size = .{ .cols = 80, .rows = 5 };
    // Too small: returns 1
    try std.testing.expectEqual(@as(u16, 1), r.separatorRow());
}
