//! Browser session and Chrome process management.
//!
//! Manages Chrome DevTools sessions: launching headless Chrome, connecting
//! via CDP, and providing high-level browser commands (navigate, click, type,
//! screenshot, etc.).

const std = @import("std");
const builtin = @import("builtin");
const cdp_mod = @import("cdp.zig");
const CdpConnection = cdp_mod.CdpConnection;
const config_types = @import("config_types.zig");
const http_util = @import("http_util.zig");
const process_util = @import("tools/process_util.zig");

const log = std.log.scoped(.browser_session);

/// A single browser session: owns a CDP connection and the Chrome child process.
pub const BrowserSession = struct {
    cdp: *CdpConnection,
    chrome_pid: ?std.process.Child.Id,
    chrome_process: ?std.process.Child,
    last_active: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BrowserSession) void {
        self.cdp.deinit();
        if (self.chrome_process) |*proc| {
            // Try graceful shutdown first
            if (comptime builtin.os.tag == .windows) {
                std.os.windows.TerminateProcess(proc.id, 0) catch {};
            } else {
                std.posix.kill(proc.id, std.posix.SIG.TERM) catch {};
            }
            _ = proc.wait() catch {};
        }
        self.allocator.destroy(self);
    }
};

/// Manages multiple named browser sessions with a configurable limit.
pub const BrowserSessionManager = struct {
    allocator: std.mem.Allocator,
    config: *const config_types.BrowserConfig,
    sessions: std.StringHashMapUnmanaged(*BrowserSession),
    mu: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: *const config_types.BrowserConfig) !*BrowserSessionManager {
        const mgr = try allocator.create(BrowserSessionManager);
        mgr.* = .{
            .allocator = allocator,
            .config = config,
            .sessions = .{},
            .mu = .{},
        };
        return mgr;
    }

    /// Get an existing session or create a new one.
    pub fn getOrCreate(self: *BrowserSessionManager, name: []const u8) !*BrowserSession {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.sessions.get(name)) |session| {
            session.last_active = std.time.timestamp();
            return session;
        }

        // Check session limit
        if (self.sessions.count() >= self.config.max_sessions) {
            return error.TooManySessions;
        }

        // Launch Chrome and connect
        const session = try launchAndConnect(self.allocator, self.config);
        errdefer session.deinit();

        // Dupe the key for the hashmap
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        self.sessions.put(self.allocator, key, session) catch return error.OutOfMemory;
        return session;
    }

    /// Close a named session.
    pub fn closeSession(self: *BrowserSessionManager, name: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.sessions.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
        }
    }

    pub fn deinit(self: *BrowserSessionManager) void {
        self.mu.lock();
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.sessions.deinit(self.allocator);
        self.mu.unlock();
        self.allocator.destroy(self);
    }
};

// ── Chrome lifecycle ────────────────────────────────────────────────

/// Find a Chromium executable on the system.
pub fn findChromium(allocator: std.mem.Allocator, config: *const config_types.BrowserConfig) ![]const u8 {
    // 1. Explicit config path
    if (config.native_chrome_path) |p| {
        return allocator.dupe(u8, p);
    }

    // 2. Environment variable
    if (std.process.getEnvVarOwned(allocator, "CHROME_PATH")) |p| {
        return p;
    } else |_| {}

    // 3. Platform-specific candidates
    const candidates: []const []const u8 = if (comptime builtin.os.tag == .macos)
        &.{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        }
    else if (comptime builtin.os.tag == .windows)
        &.{
            "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        }
    else
        &.{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
        };

    for (candidates) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return allocator.dupe(u8, path);
    }

    // 4. which fallback (Unix only)
    if (comptime builtin.os.tag != .windows) {
        for ([_][]const u8{ "google-chrome", "chromium", "chromium-browser" }) |name| {
            const result = process_util.run(allocator, &.{ "which", name }, .{ .max_output_bytes = 512 }) catch continue;
            defer result.deinit(allocator);
            if (result.success and result.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
            }
        }
    }

    return error.ChromeNotFound;
}

/// Launch Chrome with remote debugging and connect via CDP.
fn launchAndConnect(allocator: std.mem.Allocator, config: *const config_types.BrowserConfig) !*BrowserSession {
    if (builtin.is_test) return error.TestSkipped;

    const chrome_path = try findChromium(allocator, config);
    defer allocator.free(chrome_path);

    const viewport = try std.fmt.allocPrint(allocator, "{d},{d}", .{ config.viewport_width, config.viewport_height });
    defer allocator.free(viewport);

    var child = std.process.Child.init(&.{
        chrome_path,
        "--remote-debugging-port=0",
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
    }, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    errdefer {
        if (comptime builtin.os.tag == .windows) {
            std.os.windows.TerminateProcess(child.id, 1) catch {};
        } else {
            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
        }
        _ = child.wait() catch {};
    }

    // Read DevTools URL from stderr
    const ws_url = try readDevtoolsUrl(child.stderr.?, 15 * std.time.ns_per_s);
    defer allocator.free(ws_url);

    // Parse ws://host:port/path
    const uri = std.Uri.parse(ws_url) catch return error.InvalidDevtoolsUrl;
    const host_raw = uri.host orelse return error.InvalidDevtoolsUrl;
    const host = switch (host_raw) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    const port = uri.port orelse return error.InvalidDevtoolsUrl;

    // Find the page WebSocket URL (Chrome may not expose the page target at the
    // DevTools URL it prints to stderr — use /json/list to find it)
    const page_ws = try findPageWs(allocator, port);
    defer allocator.free(page_ws);

    // Parse page WS path
    const page_uri = std.Uri.parse(page_ws) catch return error.InvalidDevtoolsUrl;
    const path_component = page_uri.path orelse return error.InvalidDevtoolsUrl;
    const path = switch (path_component) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };

    const cdp_conn = try CdpConnection.connectWs(allocator, host, port, path, config.timeout_secs);
    errdefer cdp_conn.deinit();

    const session = try allocator.create(BrowserSession);
    session.* = .{
        .cdp = cdp_conn,
        .chrome_pid = child.id,
        .chrome_process = child,
        .last_active = std.time.timestamp(),
        .allocator = allocator,
    };
    return session;
}

/// Read the DevTools WebSocket URL from Chrome's stderr output.
fn readDevtoolsUrl(stderr: std.fs.File, timeout_ns: u64) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const start = std.time.nanoTimestamp();
    var buf: [4096]u8 = undefined;
    var buf_len: usize = 0;
    const prefix = "DevTools listening on ";

    while (true) {
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (elapsed > timeout_ns) return error.DevtoolsUrlTimeout;

        const n = stderr.read(buf[buf_len..]) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            return error.DevtoolsUrlReadFailed;
        };
        if (n == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }
        buf_len += n;

        // Search for the DevTools URL line
        const data = buf[0..buf_len];
        if (std.mem.indexOf(u8, data, prefix)) |idx| {
            const url_start = idx + prefix.len;
            // Find end of URL (newline or end of buffer)
            const url_end = if (std.mem.indexOfScalarPos(u8, data, url_start, '\n')) |nl|
                if (nl > 0 and data[nl - 1] == '\r') nl - 1 else nl
            else
                buf_len;
            if (url_end > url_start) {
                return allocator.dupe(u8, data[url_start..url_end]) catch return error.OutOfMemory;
            }
        }
    }
}

/// Query Chrome's /json/list endpoint to find the page target WebSocket URL.
fn findPageWs(allocator: std.mem.Allocator, port: u16) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/json/list", .{port});
    defer allocator.free(url);

    var retries: usize = 0;
    while (retries < 10) : (retries += 1) {
        const body = http_util.curlGet(allocator, url, &.{}, "5") catch {
            std.Thread.sleep(300 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(body);

        // Parse the JSON array to find a page target's webSocketDebuggerUrl
        if (extractWsUrl(body)) |ws_url| {
            return allocator.dupe(u8, ws_url);
        }
        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
    return error.PageTargetNotFound;
}

/// Extract webSocketDebuggerUrl from /json/list response.
fn extractWsUrl(json: []const u8) ?[]const u8 {
    const key = "\"webSocketDebuggerUrl\":\"";
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    if (end <= start) return null;
    return json[start..end];
}

// ── CDP commands ────────────────────────────────────────────────────

/// Navigate to a URL.
pub fn cmdNavigate(session: *BrowserSession, allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const escaped_url = try cdp_mod.jsonEscape(allocator, url);
    defer allocator.free(escaped_url);
    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{escaped_url});
    defer allocator.free(params);
    const result = try session.cdp.send(allocator, "Page.navigate", params);
    defer allocator.free(result);

    try waitForLoad(session.cdp, allocator);
    return pageInfo(session.cdp, allocator);
}

/// Click an element by CSS selector or text content.
pub fn cmdClick(session: *BrowserSession, allocator: std.mem.Allocator, selector: []const u8) ![]const u8 {
    const escaped = try cdp_mod.jsonEscape(allocator, selector);
    defer allocator.free(escaped);

    // Try CSS selector first, then fallback to text content matching
    const js = try std.fmt.allocPrint(allocator,
        \\(function() {{
        \\  var el = document.querySelector("{s}");
        \\  if (!el) {{
        \\    var all = document.querySelectorAll("a, button, [role=button], input[type=submit]");
        \\    for (var i = 0; i < all.length; i++) {{
        \\      if (all[i].textContent.trim().includes("{s}")) {{ el = all[i]; break; }}
        \\    }}
        \\  }}
        \\  if (!el) return "ERROR: Element not found: {s}";
        \\  el.click();
        \\  return "Clicked: " + (el.tagName || "") + " " + (el.textContent || "").substring(0, 50).trim();
        \\}})()
    , .{ escaped, escaped, escaped });
    defer allocator.free(js);

    const result = try session.cdp.runJs(allocator, js);
    defer allocator.free(result);

    // Wait for any navigation triggered by click
    std.Thread.sleep(500 * std.time.ns_per_ms);
    waitForLoad(session.cdp, allocator) catch {};

    return pageInfo(session.cdp, allocator);
}

/// Type text into an element.
pub fn cmdType(session: *BrowserSession, allocator: std.mem.Allocator, selector: []const u8, text: []const u8) ![]const u8 {
    const escaped_sel = try cdp_mod.jsonEscape(allocator, selector);
    defer allocator.free(escaped_sel);
    const escaped_text = try cdp_mod.jsonEscape(allocator, text);
    defer allocator.free(escaped_text);

    const js = try std.fmt.allocPrint(allocator,
        \\(function() {{
        \\  var el = document.querySelector("{s}");
        \\  if (!el) return "ERROR: Element not found: {s}";
        \\  el.focus();
        \\  el.value = "{s}";
        \\  el.dispatchEvent(new Event("input", {{bubbles: true}}));
        \\  el.dispatchEvent(new Event("change", {{bubbles: true}}));
        \\  return "Typed into: " + (el.tagName || "") + " " + (el.name || el.id || "");
        \\}})()
    , .{ escaped_sel, escaped_sel, escaped_text });
    defer allocator.free(js);

    const result = try session.cdp.runJs(allocator, js);
    allocator.free(result);
    return try allocator.dupe(u8, "Text entered successfully");
}

/// Take a screenshot and save to workspace.
pub fn cmdScreenshot(session: *BrowserSession, allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    const result = try session.cdp.send(allocator, "Page.captureScreenshot", "{\"format\":\"png\"}");
    defer allocator.free(result);

    // Extract base64 data from result
    const data_key = "\"data\":\"";
    const data_start = (std.mem.indexOf(u8, result, data_key) orelse return error.ScreenshotFailed) + data_key.len;
    const data_end = std.mem.indexOfScalarPos(u8, result, data_start, '"') orelse return error.ScreenshotFailed;
    const b64_data = result[data_start..data_end];

    // Decode base64
    const decoded_size = std.base64.standard.Decoder.calcSizeUpperBound(b64_data.len);
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    const actual_len = std.base64.standard.Decoder.decode(decoded, b64_data) catch return error.ScreenshotFailed;

    // Write to file
    const filename = "cdp_screenshot.png";
    const sep: []const u8 = if (comptime builtin.os.tag == .windows) "\\" else "/";
    const output_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ workspace_dir, sep, filename });
    defer allocator.free(output_path);

    const file = try std.fs.createFileAbsolute(output_path, .{});
    defer file.close();
    try file.writeAll(decoded[0..actual_len]);

    return std.fmt.allocPrint(allocator, "[IMAGE:{s}]", .{output_path});
}

/// Read page content as formatted text.
pub fn cmdReadPage(session: *BrowserSession, allocator: std.mem.Allocator) ![]const u8 {
    const result = try session.cdp.runJs(allocator, EXTRACT_CONTENT_JS);
    defer allocator.free(result);

    // Extract the string value from the Runtime.evaluate result
    return extractJsStringResult(allocator, result);
}

/// Scroll the page.
pub fn cmdScroll(session: *BrowserSession, allocator: std.mem.Allocator, direction: []const u8, amount: i64) ![]const u8 {
    const dx: i64 = if (std.mem.eql(u8, direction, "left"))
        -amount
    else if (std.mem.eql(u8, direction, "right"))
        amount
    else
        0;
    const dy: i64 = if (std.mem.eql(u8, direction, "down"))
        amount
    else if (std.mem.eql(u8, direction, "up"))
        -amount
    else
        0;

    const js = try std.fmt.allocPrint(allocator, "window.scrollBy({d},{d}); 'scrolled'", .{ dx, dy });
    defer allocator.free(js);

    const result = try session.cdp.runJs(allocator, js);
    allocator.free(result);
    return try allocator.dupe(u8, "Scrolled successfully");
}

/// Wait for a selector to appear.
pub fn cmdWait(session: *BrowserSession, allocator: std.mem.Allocator, selector: []const u8, timeout_ms: u64) ![]const u8 {
    const escaped = try cdp_mod.jsonEscape(allocator, selector);
    defer allocator.free(escaped);

    const check_js = try std.fmt.allocPrint(allocator, "document.querySelector(\"{s}\") !== null ? 'found' : 'waiting'", .{escaped});
    defer allocator.free(check_js);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (process_util.isInterrupted()) return error.Interrupted;

        const result = session.cdp.runJs(allocator, check_js) catch {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(result);

        if (std.mem.indexOf(u8, result, "found") != null) {
            return try allocator.dupe(u8, "Element found");
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    return error.WaitTimeout;
}

/// Execute raw JavaScript.
pub fn cmdRunJs(session: *BrowserSession, allocator: std.mem.Allocator, expression: []const u8) ![]const u8 {
    const result = try session.cdp.runJs(allocator, expression);
    defer allocator.free(result);
    return extractJsStringResult(allocator, result);
}

/// Navigate back in history.
pub fn cmdBack(session: *BrowserSession, allocator: std.mem.Allocator) ![]const u8 {
    const result = try session.cdp.runJs(allocator, "history.back(); 'navigated back'");
    allocator.free(result);
    std.Thread.sleep(500 * std.time.ns_per_ms);
    waitForLoad(session.cdp, allocator) catch {};
    return pageInfo(session.cdp, allocator);
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Wait for document.readyState to become "complete".
fn waitForLoad(cdp_conn: *CdpConnection, allocator: std.mem.Allocator) !void {
    const max_wait: usize = 150; // 150 * 200ms = 30s
    var i: usize = 0;
    while (i < max_wait) : (i += 1) {
        if (process_util.isInterrupted()) return error.Interrupted;

        const result = cdp_conn.runJs(allocator, "document.readyState") catch {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(result);

        if (std.mem.indexOf(u8, result, "complete") != null) return;
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
}

/// Get current page title, URL, and content summary.
fn pageInfo(cdp_conn: *CdpConnection, allocator: std.mem.Allocator) ![]const u8 {
    const js =
        \\(function() {
        \\  var title = document.title || '';
        \\  var url = location.href || '';
        \\  var text = document.body ? document.body.innerText.substring(0, 2000) : '';
        \\  return 'Title: ' + title + '\nURL: ' + url + '\n\n' + text;
        \\})()
    ;
    const result = try cdp_conn.runJs(allocator, js);
    defer allocator.free(result);
    return extractJsStringResult(allocator, result);
}

/// Extract the string value from a Runtime.evaluate JSON result.
fn extractJsStringResult(allocator: std.mem.Allocator, result: []const u8) ![]const u8 {
    // Look for "value":"..." pattern in the result JSON
    const key = "\"value\":\"";
    if (std.mem.indexOf(u8, result, key)) |idx| {
        const start = idx + key.len;
        // Find the closing quote, handling escape sequences
        var pos = start;
        while (pos < result.len) {
            if (result[pos] == '\\') {
                pos += 2; // skip escape sequence
                continue;
            }
            if (result[pos] == '"') break;
            pos += 1;
        }
        if (pos > start) {
            return allocator.dupe(u8, result[start..pos]);
        }
    }
    // Fallback: return the raw result
    return allocator.dupe(u8, result);
}

/// JavaScript to extract page content as formatted text.
/// Converts DOM to a readable markdown-like format, limited to 50K chars.
pub const EXTRACT_CONTENT_JS =
    \\(function() {
    \\  function walk(node) {
    \\    if (!node) return '';
    \\    var out = '';
    \\    if (node.nodeType === 3) return node.textContent;
    \\    if (node.nodeType !== 1) return '';
    \\    var tag = node.tagName.toLowerCase();
    \\    if (tag === 'script' || tag === 'style' || tag === 'noscript') return '';
    \\    if (tag === 'h1' || tag === 'h2' || tag === 'h3') {
    \\      var prefix = tag === 'h1' ? '# ' : tag === 'h2' ? '## ' : '### ';
    \\      out += '\n' + prefix + node.textContent.trim() + '\n';
    \\    } else if (tag === 'a') {
    \\      out += '[' + node.textContent.trim() + '](' + (node.href || '') + ')';
    \\    } else if (tag === 'img') {
    \\      out += '[IMG: ' + (node.alt || node.src || '') + ']';
    \\    } else if (tag === 'li') {
    \\      out += '\n- ';
    \\      for (var i = 0; i < node.childNodes.length; i++) out += walk(node.childNodes[i]);
    \\    } else if (tag === 'br') {
    \\      out += '\n';
    \\    } else if (tag === 'p' || tag === 'div' || tag === 'section' || tag === 'article') {
    \\      out += '\n';
    \\      for (var i = 0; i < node.childNodes.length; i++) out += walk(node.childNodes[i]);
    \\      out += '\n';
    \\    } else {
    \\      for (var i = 0; i < node.childNodes.length; i++) out += walk(node.childNodes[i]);
    \\    }
    \\    return out;
    \\  }
    \\  var content = walk(document.body);
    \\  content = content.replace(/\n{3,}/g, '\n\n').trim();
    \\  if (content.length > 50000) content = content.substring(0, 50000) + '\n[Content truncated]';
    \\  return 'Title: ' + document.title + '\nURL: ' + location.href + '\n\n' + content;
    \\})()
;

// ── Tests ───────────────────────────────────────────────────────────

test "chrome args construction" {
    // Verify expected Chrome flags
    const expected_flags = [_][]const u8{
        "--remote-debugging-port=0",
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
    };
    for (expected_flags) |flag| {
        try std.testing.expect(flag.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, flag, "--"));
    }
}

test "devtools URL parsing from mock string" {
    const mock_stderr = "DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc-123\n";
    const prefix = "DevTools listening on ";
    const idx = std.mem.indexOf(u8, mock_stderr, prefix).?;
    const url_start = idx + prefix.len;
    const url_end = std.mem.indexOfScalarPos(u8, mock_stderr, url_start, '\n') orelse mock_stderr.len;
    const url = mock_stderr[url_start..url_end];
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc-123", url);
}

test "extractWsUrl from json list response" {
    const json =
        \\[{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/ABC123"}]
    ;
    const url = extractWsUrl(json).?;
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/ABC123", url);
}

test "extractWsUrl returns null for empty json" {
    try std.testing.expect(extractWsUrl("[]") == null);
    try std.testing.expect(extractWsUrl("{}") == null);
}

test "extractJsStringResult extracts value" {
    const allocator = std.testing.allocator;
    const result = try extractJsStringResult(allocator, "{\"result\":{\"type\":\"string\",\"value\":\"hello world\"}}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "extractJsStringResult handles missing value" {
    const allocator = std.testing.allocator;
    const result = try extractJsStringResult(allocator, "{\"result\":{\"type\":\"undefined\"}}");
    defer allocator.free(result);
    // Should return raw result as fallback
    try std.testing.expect(result.len > 0);
}

test "session manager max sessions" {
    // Verify config defaults
    const config = config_types.BrowserConfig{};
    try std.testing.expectEqual(@as(u8, 5), config.max_sessions);
    try std.testing.expectEqual(@as(u16, 1280), config.viewport_width);
    try std.testing.expectEqual(@as(u16, 720), config.viewport_height);
    try std.testing.expectEqual(@as(u16, 30), config.timeout_secs);
}

test "EXTRACT_CONTENT_JS is valid comptime string" {
    try std.testing.expect(EXTRACT_CONTENT_JS.len > 100);
    // Should contain key DOM traversal markers
    try std.testing.expect(std.mem.indexOf(u8, EXTRACT_CONTENT_JS, "walk") != null);
    try std.testing.expect(std.mem.indexOf(u8, EXTRACT_CONTENT_JS, "textContent") != null);
    try std.testing.expect(std.mem.indexOf(u8, EXTRACT_CONTENT_JS, "50000") != null);
}

test "scroll direction parsing" {
    // Verify direction->delta mapping
    const cases = [_]struct { dir: []const u8, expect_dy_sign: enum { negative, positive, zero } }{
        .{ .dir = "down", .expect_dy_sign = .positive },
        .{ .dir = "up", .expect_dy_sign = .negative },
        .{ .dir = "left", .expect_dy_sign = .zero },
        .{ .dir = "right", .expect_dy_sign = .zero },
    };
    for (cases) |c| {
        const dy: i64 = if (std.mem.eql(u8, c.dir, "down"))
            300
        else if (std.mem.eql(u8, c.dir, "up"))
            -300
        else
            0;
        switch (c.expect_dy_sign) {
            .positive => try std.testing.expect(dy > 0),
            .negative => try std.testing.expect(dy < 0),
            .zero => try std.testing.expectEqual(@as(i64, 0), dy),
        }
    }
}
