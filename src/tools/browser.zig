const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const browser_session_mod = @import("../browser_session.zig");
const BrowserSessionManager = browser_session_mod.BrowserSessionManager;
const config_types = @import("../config_types.zig");
const net_security = @import("../net_security.zig");
const policy_mod = @import("../security/policy.zig");

/// Browser tool — browse web pages via Chrome DevTools Protocol.
/// Supports navigate, click, type, read, screenshot, scroll, wait,
/// run_js, back, and close actions.
pub const BrowserTool = struct {
    session_manager: *BrowserSessionManager,
    config: *const config_types.BrowserConfig,
    autonomy: policy_mod.AutonomyLevel = .supervised,
    workspace_dir: []const u8 = ".",

    pub const tool_name = "browser";
    pub const tool_description = "Browse web pages via headless Chrome. Actions: navigate, click, type, read, screenshot, scroll, wait, run_js, back, close.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["open","navigate","click","type","read","screenshot","scroll","wait","run_js","back","close"],"description":"Browser action to perform"},"url":{"type":"string","description":"URL to navigate to"},"selector":{"type":"string","description":"CSS selector or text for click/type/wait"},"text":{"type":"string","description":"Text to type into element"},"direction":{"type":"string","enum":["up","down","left","right"],"description":"Scroll direction"},"amount":{"type":"integer","description":"Scroll amount in pixels (default 300)"},"expression":{"type":"string","description":"JavaScript expression for run_js"},"timeout_ms":{"type":"integer","description":"Timeout in ms for wait (default 5000)"},"session":{"type":"string","description":"Named session (default: default)"}},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *BrowserTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *BrowserTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        // "open" is an alias for "navigate" (backward compat)
        const effective_action = if (std.mem.eql(u8, action, "open")) "navigate" else action;

        if (std.mem.eql(u8, effective_action, "navigate")) {
            return self.executeNavigate(allocator, args);
        } else if (std.mem.eql(u8, effective_action, "click")) {
            return self.executeCdpAction(allocator, args, .click);
        } else if (std.mem.eql(u8, effective_action, "type")) {
            return self.executeCdpAction(allocator, args, .type_text);
        } else if (std.mem.eql(u8, effective_action, "read")) {
            return self.executeCdpAction(allocator, args, .read);
        } else if (std.mem.eql(u8, effective_action, "screenshot")) {
            return self.executeCdpAction(allocator, args, .screenshot);
        } else if (std.mem.eql(u8, effective_action, "scroll")) {
            return self.executeCdpAction(allocator, args, .scroll);
        } else if (std.mem.eql(u8, effective_action, "wait")) {
            return self.executeCdpAction(allocator, args, .wait);
        } else if (std.mem.eql(u8, effective_action, "run_js")) {
            return self.executeCdpAction(allocator, args, .run_js);
        } else if (std.mem.eql(u8, effective_action, "back")) {
            return self.executeCdpAction(allocator, args, .back);
        } else if (std.mem.eql(u8, effective_action, "close")) {
            const session_name = root.getString(args, "session") orelse "default";
            self.session_manager.closeSession(session_name);
            return ToolResult.ok("Session closed");
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Unknown browser action '{s}'", .{action});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }
    }

    /// Navigate action with SSRF protection.
    fn executeNavigate(self: *BrowserTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse
            return ToolResult.fail("Missing 'url' parameter for navigate action");

        // SSRF protection (skip if yolo)
        if (self.autonomy != .yolo) {
            const host = net_security.extractHost(url) orelse
                return ToolResult.fail("Invalid URL: cannot extract host");

            if (net_security.isLocalHost(host))
                return ToolResult.fail("Blocked: localhost URLs are not allowed (set autonomy.level=yolo to override)");

            if (!net_security.hostMatchesAllowlist(host, self.config.allowed_domains))
                return ToolResult.fail("Blocked: host not in allowed_domains list");

            // Require HTTPS unless yolo
            if (!std.mem.startsWith(u8, url, "https://"))
                return ToolResult.fail("Only https:// URLs are allowed (set autonomy.level=yolo to override)");
        }

        if (builtin.is_test) {
            const msg = try std.fmt.allocPrint(allocator, "Navigated to {s}", .{url});
            return ToolResult{ .success = true, .output = msg };
        }

        const session_name = root.getString(args, "session") orelse "default";
        const session = self.session_manager.getOrCreate(session_name) catch |err| {
            return ToolResult.fail(switch (err) {
                error.TooManySessions => "Too many browser sessions open. Close a session first.",
                error.ChromeNotFound => "Chrome/Chromium not found. Install Chrome or set browser.native_chrome_path in config.",
                else => "Failed to start browser session",
            });
        };

        const output = browser_session_mod.cmdNavigate(session, allocator, url) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Navigation failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return ToolResult{ .success = true, .output = output };
    }

    const CdpAction = enum { click, type_text, read, screenshot, scroll, wait, run_js, back };

    /// Execute a CDP action on an existing session.
    fn executeCdpAction(self: *BrowserTool, allocator: std.mem.Allocator, args: JsonObjectMap, action: CdpAction) !ToolResult {
        // Validate required parameters before acquiring session
        switch (action) {
            .click => if (root.getString(args, "selector") == null)
                return ToolResult.fail("Missing 'selector' parameter for click action"),
            .type_text => {
                if (root.getString(args, "selector") == null)
                    return ToolResult.fail("Missing 'selector' parameter for type action");
                if (root.getString(args, "text") == null)
                    return ToolResult.fail("Missing 'text' parameter for type action");
            },
            .wait => if (root.getString(args, "selector") == null)
                return ToolResult.fail("Missing 'selector' parameter for wait action"),
            .run_js => if (root.getString(args, "expression") == null)
                return ToolResult.fail("Missing 'expression' parameter for run_js action"),
            else => {},
        }

        if (builtin.is_test) {
            return ToolResult.fail("CDP actions require a running browser (not available in test mode)");
        }

        const session_name = root.getString(args, "session") orelse "default";
        const session = self.session_manager.getOrCreate(session_name) catch
            return ToolResult.fail("No browser session available. Use 'navigate' first.");

        const output = switch (action) {
            .click => blk: {
                break :blk browser_session_mod.cmdClick(session, allocator, root.getString(args, "selector").?) catch
                    return ToolResult.fail("Click action failed");
            },
            .type_text => blk: {
                break :blk browser_session_mod.cmdType(session, allocator, root.getString(args, "selector").?, root.getString(args, "text").?) catch
                    return ToolResult.fail("Type action failed");
            },
            .read => blk: {
                break :blk browser_session_mod.cmdReadPage(session, allocator) catch
                    return ToolResult.fail("Read action failed");
            },
            .screenshot => blk: {
                break :blk browser_session_mod.cmdScreenshot(session, allocator, self.workspace_dir) catch
                    return ToolResult.fail("Screenshot action failed");
            },
            .scroll => blk: {
                const direction = root.getString(args, "direction") orelse "down";
                const amount = root.getInt(args, "amount") orelse 300;
                break :blk browser_session_mod.cmdScroll(session, allocator, direction, amount) catch
                    return ToolResult.fail("Scroll action failed");
            },
            .wait => blk: {
                const timeout_ms: u64 = if (root.getInt(args, "timeout_ms")) |t|
                    @intCast(@max(0, t))
                else
                    5000;
                break :blk browser_session_mod.cmdWait(session, allocator, root.getString(args, "selector").?, timeout_ms) catch
                    return ToolResult.fail("Wait timed out");
            },
            .run_js => blk: {
                break :blk browser_session_mod.cmdRunJs(session, allocator, root.getString(args, "expression").?) catch
                    return ToolResult.fail("JavaScript execution failed");
            },
            .back => blk: {
                break :blk browser_session_mod.cmdBack(session, allocator) catch
                    return ToolResult.fail("Back navigation failed");
            },
        };
        return ToolResult{ .success = true, .output = output };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

fn testTool() BrowserTool {
    // In tests, session_manager won't be called (is_test guard skips CDP ops).
    // Use undefined ptr — safe because test-mode returns before dereferencing.
    return .{
        .session_manager = undefined,
        .config = &config_types.BrowserConfig{},
    };
}

test "browser tool name" {
    var bt = testTool();
    const t = bt.tool();
    try std.testing.expectEqualStrings("browser", t.name());
}

test "browser missing action parameter" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "browser navigate missing url" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "browser open is alias for navigate" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"open\", \"url\": \"https://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);
}

test "browser navigate SSRF blocks localhost" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"https://localhost/admin\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "localhost") != null);
}

test "browser navigate SSRF blocks private IP" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"https://127.0.0.1/secret\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "localhost") != null);
}

test "browser navigate blocks http" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"http://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "https") != null);
}

test "browser navigate yolo allows http" {
    var bt = testTool();
    bt.autonomy = .yolo;
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"http://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
}

test "browser navigate allows https" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"https://example.com\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
}

test "browser unknown action" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"fly\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "fly") != null);
}

test "browser click requires selector" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"click\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "selector") != null);
}

test "browser type requires selector and text" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"type\", \"selector\": \"#input\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "text") != null);
}

test "browser wait requires selector" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"wait\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "selector") != null);
}

test "browser run_js requires expression" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"run_js\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null);
}

test "browser schema has new actions" {
    var bt = testTool();
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "run_js") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "back") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "close") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "screenshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "open") != null);
}

test "browser description mentions headless" {
    var bt = testTool();
    const t = bt.tool();
    const desc = t.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "Browse") != null or std.mem.indexOf(u8, desc, "browse") != null or std.mem.indexOf(u8, desc, "web") != null);
}

test "browser tool schema has url" {
    var bt = testTool();
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "url") != null);
}

test "browser tool schema has action" {
    var bt = testTool();
    const t = bt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
}

test "browser tool execute with empty json" {
    var bt = testTool();
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "browser navigate allowlist blocks unlisted host" {
    const domains = [_][]const u8{"allowed.com"};
    var cfg = config_types.BrowserConfig{};
    cfg.allowed_domains = &domains;
    var bt = BrowserTool{
        .session_manager = undefined,
        .config = &cfg,
    };
    const t = bt.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"navigate\", \"url\": \"https://blocked.com/page\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "allowed_domains") != null);
}
