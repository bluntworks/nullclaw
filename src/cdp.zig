//! CDP (Chrome DevTools Protocol) WebSocket transport.
//!
//! Raw TCP connection with RFC 6455 WebSocket framing for localhost-only
//! Chrome DevTools communication. Uses `websocket.buildFrame` and
//! `websocket.parseFrameHeader` for frame I/O.

const std = @import("std");
const builtin = @import("builtin");
const websocket = @import("websocket.zig");
const json_util = @import("json_util.zig");

const log = std.log.scoped(.cdp);

/// Slot for a pending JSON-RPC response. The sender creates and inserts
/// this into the pending map; the reader thread signals it when a matching
/// response arrives.
pub const ResponseSlot = struct {
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    result: ?ResponseResult = null,
};

pub const ResponseResult = union(enum) {
    ok: []const u8,
    err: []const u8,
};

/// CDP WebSocket connection over raw TCP (no TLS — Chrome DevTools is localhost).
pub const CdpConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    next_id: std.atomic.Value(u64),
    pending: std.AutoHashMapUnmanaged(u64, *ResponseSlot),
    pending_mu: std.Thread.Mutex,
    reader_thread: ?std.Thread,
    closed: std.atomic.Value(bool),
    timeout_ns: u64,

    /// Connect to a Chrome DevTools WebSocket endpoint via raw TCP + HTTP Upgrade.
    pub fn connectWs(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
        timeout_secs: u16,
    ) !*CdpConnection {
        if (builtin.is_test) return error.TestSkipped;

        const addr_list = try std.net.getAddressList(allocator, host, port);
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.DnsResolutionFailed;

        const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
        errdefer stream.close();

        // HTTP Upgrade handshake (RFC 6455)
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        var req_buf: [2048]u8 = undefined;
        var req_fbs = std.io.fixedBufferStream(&req_buf);
        const rw = req_fbs.writer();
        try rw.print("GET {s} HTTP/1.1\r\n", .{path});
        try rw.print("Host: {s}:{d}\r\n", .{ host, port });
        try rw.writeAll("Upgrade: websocket\r\n");
        try rw.writeAll("Connection: Upgrade\r\n");
        try rw.print("Sec-WebSocket-Key: {s}\r\n", .{key_b64});
        try rw.writeAll("Sec-WebSocket-Version: 13\r\n");
        try rw.writeAll("\r\n");

        const req = req_fbs.getWritten();
        try stream.writeAll(req);

        // Read HTTP 101 response
        var resp_buf: [2048]u8 = undefined;
        var resp_len: usize = 0;
        var headers_complete = false;
        while (resp_len < resp_buf.len) {
            const n = stream.read(resp_buf[resp_len .. resp_len + 1]) catch
                return error.WsHandshakeFailed;
            if (n == 0) return error.WsHandshakeFailed;
            resp_len += 1;
            if (resp_len >= 4 and
                resp_buf[resp_len - 4] == '\r' and
                resp_buf[resp_len - 3] == '\n' and
                resp_buf[resp_len - 2] == '\r' and
                resp_buf[resp_len - 1] == '\n')
            {
                headers_complete = true;
                break;
            }
        }
        if (!headers_complete) return error.WsHandshakeFailed;
        const resp = resp_buf[0..resp_len];
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101"))
            return error.WsHandshakeFailed;

        // Verify Sec-WebSocket-Accept
        const expected = websocket.WsClient.computeAcceptKey(&key_b64);
        if (std.mem.indexOf(u8, resp, &expected) == null)
            return error.WsHandshakeFailed;

        const conn = try allocator.create(CdpConnection);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .stream = stream,
            .next_id = std.atomic.Value(u64).init(1),
            .pending = .{},
            .pending_mu = .{},
            .reader_thread = null,
            .closed = std.atomic.Value(bool).init(false),
            .timeout_ns = @as(u64, timeout_secs) * std.time.ns_per_s,
        };

        conn.reader_thread = std.Thread.spawn(.{}, readerLoop, .{conn}) catch null;

        return conn;
    }

    /// Send a CDP method call and wait for the response.
    pub fn send(
        self: *CdpConnection,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: ?[]const u8,
    ) ![]const u8 {
        if (self.closed.load(.acquire)) return error.ConnectionClosed;

        const id = self.next_id.fetchAdd(1, .monotonic);

        // Build JSON-RPC message
        const msg = if (params_json) |p|
            try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p })
        else
            try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
        defer allocator.free(msg);

        // Create response slot
        var slot = ResponseSlot{};
        {
            self.pending_mu.lock();
            defer self.pending_mu.unlock();
            self.pending.put(self.allocator, id, &slot) catch return error.OutOfMemory;
        }
        defer {
            self.pending_mu.lock();
            defer self.pending_mu.unlock();
            _ = self.pending.remove(id);
        }

        // Build and send WebSocket frame
        var frame_buf: [65536]u8 = undefined;
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);
        const frame_len = websocket.buildFrame(&frame_buf, .text, msg, mask_key) catch
            return error.FrameBuildFailed;
        self.stream.writeAll(frame_buf[0..frame_len]) catch
            return error.ConnectionClosed;

        // Wait for response with timeout
        slot.mu.lock();
        defer slot.mu.unlock();

        while (slot.result == null) {
            slot.cond.timedWait(&slot.mu, self.timeout_ns) catch {
                return error.Timeout;
            };
        }

        return switch (slot.result.?) {
            .ok => |data| data,
            .err => |_| error.CdpError,
        };
    }

    /// Convenience: run a JavaScript expression via Runtime.evaluate.
    pub fn runJs(self: *CdpConnection, allocator: std.mem.Allocator, expression: []const u8) ![]const u8 {
        // Escape the expression for embedding in JSON
        const escaped = try jsonEscape(allocator, expression);
        defer allocator.free(escaped);
        const params = try std.fmt.allocPrint(allocator, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
        defer allocator.free(params);
        return self.send(allocator, "Runtime.evaluate", params);
    }

    /// Background reader thread: reads WebSocket frames and routes responses.
    fn readerLoop(self: *CdpConnection) void {
        var buf: [65536]u8 = undefined;
        var buf_len: usize = 0;

        while (!self.closed.load(.acquire)) {
            // Read available data
            const n = self.stream.read(buf[buf_len..]) catch |err| {
                if (self.closed.load(.acquire)) break;
                log.warn("CDP reader error: {}", .{err});
                break;
            };
            if (n == 0) break;
            buf_len += n;

            // Process complete frames
            while (buf_len >= 2) {
                const header = websocket.parseFrameHeader(buf[0..buf_len]) catch break;
                const total_len = header.header_bytes + @as(usize, @intCast(header.payload_len));
                if (buf_len < total_len) break;

                // Extract payload
                const payload_start = header.header_bytes;
                const payload_end = payload_start + @as(usize, @intCast(header.payload_len));
                const payload = buf[payload_start..payload_end];

                // Unmask if masked (server usually doesn't mask, but handle it)
                if (header.masked and header.payload_len > 0) {
                    const mask_start = header.header_bytes - 4;
                    const mask_key: [4]u8 = buf[mask_start..][0..4].*;
                    websocket.applyMask(payload, mask_key);
                }

                switch (header.opcode) {
                    .text => {
                        self.routeResponse(payload);
                    },
                    .ping => {
                        // Reply with pong
                        var pong_buf: [128]u8 = undefined;
                        var mask: [4]u8 = undefined;
                        std.crypto.random.bytes(&mask);
                        const pong_len = websocket.buildFrame(&pong_buf, .pong, payload, mask) catch 0;
                        if (pong_len > 0) {
                            self.stream.writeAll(pong_buf[0..pong_len]) catch {};
                        }
                    },
                    .close => {
                        self.closed.store(true, .release);
                        // Shift remaining data
                        const remaining = buf_len - total_len;
                        if (remaining > 0) {
                            std.mem.copyForwards(u8, buf[0..remaining], buf[total_len..buf_len]);
                        }
                        buf_len = remaining;
                        self.signalAllPending();
                        return;
                    },
                    else => {},
                }

                // Shift remaining data
                const remaining = buf_len - total_len;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, buf[0..remaining], buf[total_len..buf_len]);
                }
                buf_len = remaining;
            }
        }
        self.signalAllPending();
    }

    /// Route a JSON-RPC response to the correct pending slot.
    fn routeResponse(self: *CdpConnection, payload: []const u8) void {
        // Parse just the "id" field from the response
        const id = extractJsonId(payload) orelse return;

        // Dupe the payload for the waiting thread
        const data = self.allocator.dupe(u8, payload) catch return;

        self.pending_mu.lock();
        defer self.pending_mu.unlock();

        if (self.pending.get(id)) |slot| {
            slot.mu.lock();
            defer slot.mu.unlock();

            // Check for error in response
            if (std.mem.indexOf(u8, payload, "\"error\"") != null) {
                slot.result = .{ .err = data };
            } else {
                slot.result = .{ .ok = data };
            }
            slot.cond.signal();
        } else {
            self.allocator.free(data);
        }
    }

    /// Signal all pending slots (on disconnect/close).
    fn signalAllPending(self: *CdpConnection) void {
        self.pending_mu.lock();
        defer self.pending_mu.unlock();

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            slot.mu.lock();
            defer slot.mu.unlock();
            if (slot.result == null) {
                slot.result = .{ .err = "" };
            }
            slot.cond.signal();
        }
    }

    pub fn deinit(self: *CdpConnection) void {
        self.closed.store(true, .release);

        // Send WS close frame
        var close_buf: [16]u8 = undefined;
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        const close_len = websocket.buildFrame(&close_buf, .close, &.{}, mask) catch 0;
        if (close_len > 0) {
            self.stream.writeAll(close_buf[0..close_len]) catch {};
        }

        // Join reader thread
        if (self.reader_thread) |t| t.join();

        // Free any remaining response data in pending slots
        self.pending_mu.lock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const slot = entry.value_ptr.*;
            if (slot.result) |r| {
                const data = switch (r) {
                    .ok => |d| d,
                    .err => |d| d,
                };
                if (data.len > 0) self.allocator.free(data);
            }
        }
        self.pending.deinit(self.allocator);
        self.pending_mu.unlock();

        self.stream.close();
        self.allocator.destroy(self);
    }
};

/// Extract the "id" field from a JSON-RPC response without full parsing.
fn extractJsonId(json: []const u8) ?u64 {
    // Look for "id": or "id" : pattern
    const id_key = "\"id\"";
    const idx = std.mem.indexOf(u8, json, id_key) orelse return null;
    var pos = idx + id_key.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}

    // Parse number
    const start = pos;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    if (pos == start) return null;

    return std.fmt.parseInt(u64, json[start..pos], 10) catch null;
}

/// Escape a string for embedding in a JSON string value.
fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, input.len);

    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var escape_buf: [6]u8 = undefined;
                    const slice = std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, slice);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────────

test "extractJsonId parses id from response" {
    try std.testing.expectEqual(@as(?u64, 1), extractJsonId("{\"id\":1,\"result\":{}}"));
    try std.testing.expectEqual(@as(?u64, 42), extractJsonId("{\"id\":42,\"result\":{}}"));
    try std.testing.expectEqual(@as(?u64, 100), extractJsonId("{\"id\": 100, \"result\":{}}"));
}

test "extractJsonId returns null for missing id" {
    try std.testing.expect(extractJsonId("{\"result\":{}}") == null);
    try std.testing.expect(extractJsonId("{}") == null);
}

test "extractJsonId returns null for non-numeric id" {
    try std.testing.expect(extractJsonId("{\"id\":\"abc\"}") == null);
}

test "jsonEscape escapes special characters" {
    const allocator = std.testing.allocator;

    const escaped = try jsonEscape(allocator, "hello \"world\"\nnewline\\back");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline\\\\back", escaped);
}

test "jsonEscape handles empty string" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, "");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("", escaped);
}

test "jsonEscape handles tabs and carriage returns" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, "a\tb\rc");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\tb\\rc", escaped);
}

test "jsonEscape handles control characters" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, &[_]u8{0x01});
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("\\u0001", escaped);
}

test "ResponseSlot signal and wait" {
    var slot = ResponseSlot{};

    // Simulate response arrival
    slot.mu.lock();
    slot.result = .{ .ok = "test" };
    slot.cond.signal();
    slot.mu.unlock();

    // Verify result
    slot.mu.lock();
    defer slot.mu.unlock();
    try std.testing.expect(slot.result != null);
    switch (slot.result.?) {
        .ok => |data| try std.testing.expectEqualStrings("test", data),
        .err => unreachable,
    }
}

test "ResponseSlot defaults to null" {
    const slot = ResponseSlot{};
    try std.testing.expect(slot.result == null);
}

test "atomic id monotonicity" {
    var counter = std.atomic.Value(u64).init(1);
    const id1 = counter.fetchAdd(1, .monotonic);
    const id2 = counter.fetchAdd(1, .monotonic);
    const id3 = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "json-rpc frame format" {
    // Verify a JSON-RPC message can be framed
    const msg = "{\"id\":1,\"method\":\"Page.navigate\",\"params\":{\"url\":\"https://example.com\"}}";
    var buf: [256]u8 = undefined;
    const mask: [4]u8 = .{ 0, 0, 0, 0 }; // zero mask for easy verification
    const n = try websocket.buildFrame(&buf, .text, msg, mask);
    try std.testing.expect(n > msg.len); // frame includes header + mask
    // With zero mask, payload is unmodified
    const header = try websocket.parseFrameHeader(buf[0..n]);
    try std.testing.expectEqual(websocket.Opcode.text, header.opcode);
    try std.testing.expect(header.fin);
    try std.testing.expectEqual(@as(u64, msg.len), header.payload_len);
}

test "timeout value from config" {
    const timeout_secs: u16 = 30;
    const timeout_ns: u64 = @as(u64, timeout_secs) * std.time.ns_per_s;
    try std.testing.expectEqual(@as(u64, 30_000_000_000), timeout_ns);
}
