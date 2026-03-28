const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");

const log = std.log.scoped(.claude_cli);

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;
const StreamCallback = root.StreamCallback;
const StreamChunk = root.StreamChunk;
const StreamChatResult = root.StreamChatResult;
const TokenUsage = root.TokenUsage;

/// Provider that delegates to the `claude` CLI (Claude Code).
///
/// Supports session continuity (via `--resume`), streaming (`stream-json`),
/// system prompt passthrough (`--system-prompt`), and configurable tool
/// control (`--allowedTools` / `--disallowedTools`).
pub const ClaudeCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    session_id: ?[]const u8 = null,
    config: config_types.ClaudeCliConfig = .{},
    max_turns_buf: [16]u8 = undefined,
    budget_buf: [24]u8 = undefined,

    const DEFAULT_MODEL = "claude-opus-4-6";
    const CLI_NAME = "claude";
    const TIMEOUT_NS: u64 = 120 * std.time.ns_per_s;
    const MAX_OUTPUT: usize = 4 * 1024 * 1024; // 4 MB

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !ClaudeCliProvider {
        try checkCliAvailable(allocator, CLI_NAME);
        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
        };
    }

    /// Create a Provider vtable interface.
    pub fn provider(self: *ClaudeCliProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .supports_streaming = supportsStreamingImpl,
        .stream_chat = streamChatImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        const result = try self.runClaude(allocator, message, effective_model, system_prompt);
        return result.content;
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        const prompt = extractLastUserMessage(request.messages) orelse return error.NoUserMessage;
        const system_prompt = extractSystemPrompt(request.messages);

        // Only pass system prompt on first call (no session yet).
        const sys = if (self.session_id == null) system_prompt else null;
        const result = try self.runClaude(allocator, prompt, effective_model, sys);
        return ChatResponse{
            .content = result.content,
            .model = try allocator.dupe(u8, effective_model),
            .usage = result.usage,
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "claude-cli";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
    }

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!StreamChatResult {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const prompt = extractLastUserMessage(request.messages) orelse return error.NoUserMessage;
        const system_prompt = extractSystemPrompt(request.messages);
        const sys = if (self.session_id == null) system_prompt else null;

        // Build argv with streaming flags
        var argv_buf: [32][]const u8 = undefined;
        const argv = try self.buildArgv(&argv_buf, prompt, effective_model, sys, true);

        if (@import("builtin").is_test) {
            return StreamChatResult{ .content = try allocator.dupe(u8, "test-stream"), .model = try allocator.dupe(u8, effective_model) };
        }

        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        // Read all stdout, then parse and emit stream events
        const stdout_result = child.stdout.?.readToEndAlloc(allocator, MAX_OUTPUT) catch |err| {
            _ = child.wait() catch {};
            return err;
        };
        defer allocator.free(stdout_result);

        const stderr_result = child.stderr.?.readToEndAlloc(allocator, MAX_OUTPUT) catch "";
        defer if (stderr_result.len > 0) allocator.free(stderr_result);

        const term = try child.wait();

        var accumulated: std.ArrayList(u8) = .empty;
        defer accumulated.deinit(allocator);
        var usage = TokenUsage{};
        var new_session_id: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, stdout_result, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const type_val = obj.get("type") orelse continue;
            if (type_val != .string) continue;

            if (std.mem.eql(u8, type_val.string, "content_block_delta")) {
                if (obj.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("text")) |text| {
                            if (text == .string) {
                                try accumulated.appendSlice(allocator, text.string);
                                callback(callback_ctx, StreamChunk.textDelta(text.string));
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, type_val.string, "result")) {
                if (obj.get("session_id")) |sid| {
                    if (sid == .string) {
                        new_session_id = try allocator.dupe(u8, sid.string);
                    }
                }
                if (obj.get("result")) |result_val| {
                    if (result_val == .string and accumulated.items.len == 0) {
                        try accumulated.appendSlice(allocator, result_val.string);
                        callback(callback_ctx, StreamChunk.textDelta(result_val.string));
                    }
                }
                usage = parseUsageFromObject(obj);
            }
        }

        callback(callback_ctx, StreamChunk.finalChunk());

        // Capture session_id
        if (new_session_id) |sid| {
            if (self.session_id) |old| self.allocator.free(old);
            self.session_id = sid;
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0 and accumulated.items.len == 0) {
                    if (stderr_result.len > 0) log.err("claude-cli stderr: {s}", .{stderr_result});
                    return error.CliProcessFailed;
                }
            },
            else => {
                if (accumulated.items.len == 0) {
                    if (stderr_result.len > 0) log.err("claude-cli stderr: {s}", .{stderr_result});
                    return error.CliProcessFailed;
                }
            },
        }

        const content = try allocator.dupe(u8, accumulated.items);
        return StreamChatResult{
            .content = content,
            .usage = usage,
            .model = try allocator.dupe(u8, effective_model),
        };
    }

    // ── Internal helpers ─────────────────────────────────────────────

    /// Parsed result from a Claude CLI invocation.
    const ClaudeResult = struct {
        content: []const u8,
        session_id: ?[]const u8 = null,
        usage: TokenUsage = .{},
    };

    /// Run the claude CLI and parse stream-json output.
    fn runClaude(self: *ClaudeCliProvider, allocator: std.mem.Allocator, prompt: []const u8, model: []const u8, system_prompt: ?[]const u8) !ClaudeResult {
        var argv_buf: [32][]const u8 = undefined;
        const argv = try self.buildArgv(&argv_buf, prompt, model, system_prompt, false);

        if (@import("builtin").is_test) {
            return ClaudeResult{ .content = try allocator.dupe(u8, "test-response") };
        }

        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout_result = child.stdout.?.readToEndAlloc(allocator, MAX_OUTPUT) catch |err| {
            _ = child.wait() catch {};
            return err;
        };
        defer allocator.free(stdout_result);

        const stderr_result = child.stderr.?.readToEndAlloc(allocator, MAX_OUTPUT) catch "";
        defer if (stderr_result.len > 0) allocator.free(stderr_result);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    if (stderr_result.len > 0) log.err("claude-cli stderr: {s}", .{stderr_result});
                    return error.CliProcessFailed;
                }
            },
            else => {
                if (stderr_result.len > 0) log.err("claude-cli stderr: {s}", .{stderr_result});
                return error.CliProcessFailed;
            },
        }

        var result = try parseStreamJson(allocator, stdout_result);

        // Capture session_id for subsequent calls
        if (result.session_id) |sid| {
            if (self.session_id) |old| self.allocator.free(old);
            self.session_id = sid;
            // Don't let caller free our session_id
            result.session_id = null;
        }

        return result;
    }

    /// Build the CLI argument vector based on config and state.
    pub fn buildArgv(self: *ClaudeCliProvider, buf: [][]const u8, prompt: []const u8, model: []const u8, system_prompt: ?[]const u8, streaming: bool) ![]const []const u8 {
        var i: usize = 0;

        buf[i] = CLI_NAME;
        i += 1;
        buf[i] = "-p";
        i += 1;
        buf[i] = prompt;
        i += 1;
        buf[i] = "--output-format";
        i += 1;
        buf[i] = if (streaming) "stream-json" else "json";
        i += 1;

        // Claude CLI requires --verbose when using stream-json with -p
        if (streaming) {
            buf[i] = "--verbose";
            i += 1;
        }

        buf[i] = "--model";
        i += 1;
        buf[i] = model;
        i += 1;

        // Session resume
        if (self.session_id) |sid| {
            buf[i] = "--resume";
            i += 1;
            buf[i] = sid;
            i += 1;
        }

        // System prompt (first call only)
        if (system_prompt) |sys| {
            buf[i] = "--system-prompt";
            i += 1;
            buf[i] = sys;
            i += 1;
        }

        // Tool control
        for (self.config.allowed_tools) |tool| {
            if (i + 2 > buf.len) break;
            buf[i] = "--allowedTools";
            i += 1;
            buf[i] = tool;
            i += 1;
        }
        for (self.config.disallowed_tools) |tool| {
            if (i + 2 > buf.len) break;
            buf[i] = "--disallowedTools";
            i += 1;
            buf[i] = tool;
            i += 1;
        }

        // Max turns
        if (self.config.max_turns > 0) {
            buf[i] = "--max-turns";
            i += 1;
            buf[i] = std.fmt.bufPrint(&self.max_turns_buf, "{d}", .{self.config.max_turns}) catch unreachable;
            i += 1;
        }

        // Effort level
        if (self.config.effort) |effort| {
            buf[i] = "--effort";
            i += 1;
            buf[i] = effort;
            i += 1;
        }

        // Max budget
        if (self.config.max_budget_usd > 0) {
            buf[i] = "--max-budget-usd";
            i += 1;
            buf[i] = std.fmt.bufPrint(&self.budget_buf, "{d}", .{self.config.max_budget_usd}) catch unreachable;
            i += 1;
        }

        // Skip permissions
        if (self.config.skip_permissions) {
            buf[i] = "--dangerously-skip-permissions";
            i += 1;
        }

        return buf[0..i];
    }

    /// Parse claude stream-json output lines for a result event.
    pub fn parseStreamJson(allocator: std.mem.Allocator, output: []const u8) !ClaudeResult {
        var lines = std.mem.splitScalar(u8, output, '\n');
        var session_id: ?[]const u8 = null;
        var usage = TokenUsage{};

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            if (obj.get("type")) |type_val| {
                if (type_val != .string) continue;

                if (std.mem.eql(u8, type_val.string, "result")) {
                    // Capture session_id
                    if (obj.get("session_id")) |sid| {
                        if (sid == .string) {
                            if (session_id) |old| allocator.free(old);
                            session_id = try allocator.dupe(u8, sid.string);
                        }
                    }

                    // Capture usage
                    usage = parseUsageFromObject(obj);

                    // Extract result text
                    if (obj.get("result")) |result_val| {
                        if (result_val == .string) {
                            const content = try allocator.dupe(u8, result_val.string);
                            return ClaudeResult{
                                .content = content,
                                .session_id = session_id,
                                .usage = usage,
                            };
                        }
                    }
                }
            }
        }
        if (session_id) |sid| allocator.free(sid);
        return error.NoResultInOutput;
    }

    /// Health check: run `claude --version` and verify exit code 0.
    fn healthCheck(allocator: std.mem.Allocator) !void {
        try checkCliVersion(allocator, CLI_NAME);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Shared helpers
// ════════════════════════════════════════════════════════════════════════════

/// Check if a CLI tool is available in PATH using `which`.
fn checkCliAvailable(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const argv = [_][]const u8{ "which", cli_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return error.CliNotFound;
    };
    allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CliNotFound;
        },
        else => return error.CliNotFound,
    }
}

/// Run `<cli> --version` and verify exit code 0.
fn checkCliVersion(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const argv = [_][]const u8{ cli_name, "--version" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return error.CliNotFound;
    };
    allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CliNotFound;
        },
        else => return error.CliNotFound,
    }
}

/// Extract the content of the last user message from a message slice.
fn extractLastUserMessage(messages: []const ChatMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}

/// Extract the first system message from a message slice.
pub fn extractSystemPrompt(messages: []const ChatMessage) ?[]const u8 {
    for (messages) |msg| {
        if (msg.role == .system) return msg.content;
    }
    return null;
}

/// Parse usage/token counts from a Claude CLI JSON result object.
fn parseUsageFromObject(obj: std.json.ObjectMap) TokenUsage {
    var usage = TokenUsage{};
    if (obj.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("input_tokens")) |v| {
                if (v == .integer) usage.prompt_tokens = @intCast(v.integer);
            }
            if (u.object.get("output_tokens")) |v| {
                if (v == .integer) usage.completion_tokens = @intCast(v.integer);
            }
            usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
        }
    }
    return usage;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "ClaudeCliProvider.getNameImpl returns claude-cli" {
    const vtab = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtab.getName(@ptrCast(&dummy)));
}

test "extractLastUserMessage finds last user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("first"),
        ChatMessage.assistant("ok"),
        ChatMessage.user("second"),
    };
    const result = extractLastUserMessage(&msgs);
    try std.testing.expectEqualStrings("second", result.?);
}

test "extractLastUserMessage returns null for no user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.assistant("ok"),
    };
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "extractLastUserMessage empty messages" {
    const msgs = [_]ChatMessage{};
    try std.testing.expect(extractLastUserMessage(&msgs) == null);
}

test "extractSystemPrompt finds system message" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("You are helpful"),
        ChatMessage.user("hello"),
    };
    try std.testing.expectEqualStrings("You are helpful", extractSystemPrompt(&msgs).?);
}

test "extractSystemPrompt returns null when no system" {
    const msgs = [_]ChatMessage{
        ChatMessage.user("hello"),
        ChatMessage.assistant("hi"),
    };
    try std.testing.expect(extractSystemPrompt(&msgs) == null);
}

test "extractSystemPrompt empty messages" {
    const msgs = [_]ChatMessage{};
    try std.testing.expect(extractSystemPrompt(&msgs) == null);
}

test "parseStreamJson extracts result" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
        \\{"type":"result","result":"Hello from Claude CLI!"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result.content);
    if (result.session_id) |sid| std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("Hello from Claude CLI!", result.content);
}

test "parseStreamJson captures session_id" {
    const input =
        \\{"type":"result","result":"hello","session_id":"sess-42"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result.content);
    defer if (result.session_id) |sid| std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("sess-42", result.session_id.?);
}

test "parseStreamJson captures usage" {
    const input =
        \\{"type":"result","result":"hi","usage":{"input_tokens":100,"output_tokens":50}}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result.content);
    if (result.session_id) |sid| std.testing.allocator.free(sid);
    try std.testing.expectEqual(@as(u32, 100), result.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), result.usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), result.usage.total_tokens);
}

test "parseStreamJson no result returns error" {
    const input =
        \\{"type":"start","session_id":"abc123"}
        \\{"type":"content","content":"partial"}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles empty input" {
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, "");
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "parseStreamJson handles invalid json lines gracefully" {
    const input =
        \\not json at all
        \\{"type":"result","result":"found it"}
    ;
    const result = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result.content);
    if (result.session_id) |sid| std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("found it", result.content);
}

test "parseStreamJson skips result with non-string value" {
    const input =
        \\{"type":"result","result":42}
    ;
    const result = ClaudeCliProvider.parseStreamJson(std.testing.allocator, input);
    try std.testing.expectError(error.NoResultInOutput, result);
}

test "ClaudeCliProvider vtable has correct function pointers" {
    const vtab = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vtab.getName(@ptrCast(&dummy)));
    try std.testing.expect(!vtab.supportsNativeTools(@ptrCast(&dummy)));
    try std.testing.expect(vtab.supports_vision != null);
    try std.testing.expect(!vtab.supports_vision.?(@ptrCast(&dummy)));
    try std.testing.expect(vtab.supports_streaming != null);
    try std.testing.expect(vtab.supports_streaming.?(@ptrCast(&dummy)));
    try std.testing.expect(vtab.stream_chat != null);
}

test "ClaudeCliProvider.init returns CliNotFound for missing binary" {
    const result = checkCliAvailable(std.testing.allocator, "nonexistent_binary_xyzzy_12345");
    try std.testing.expectError(error.CliNotFound, result);
}

test "ClaudeCliProvider default model is claude-opus-4-6" {
    try std.testing.expectEqualStrings("claude-opus-4-6", ClaudeCliProvider.DEFAULT_MODEL);
}

test "buildArgv base flags" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
    };
    prov.config.skip_permissions = false;
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("-p", argv[1]);
    try std.testing.expectEqualStrings("hello", argv[2]);
    try std.testing.expectEqualStrings("--output-format", argv[3]);
    try std.testing.expectEqualStrings("json", argv[4]);
    try std.testing.expectEqualStrings("--model", argv[5]);
    try std.testing.expectEqualStrings("claude-opus-4-6", argv[6]);
    // --verbose is intentionally NOT included
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--verbose"));
    }
}

test "buildArgv with streaming format" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
    };
    prov.config.skip_permissions = false;
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, true);
    try std.testing.expectEqualStrings("stream-json", argv[4]);
    // --verbose must be present when streaming
    var found_verbose = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) found_verbose = true;
    }
    try std.testing.expect(found_verbose);
}

test "buildArgv with session resume" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .session_id = "sess-123",
    };
    prov.config.skip_permissions = false;
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    // Should contain --resume sess-123
    var found_resume = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--resume")) {
            found_resume = true;
            try std.testing.expectEqualStrings("sess-123", argv[idx + 1]);
        }
    }
    try std.testing.expect(found_resume);
}

test "buildArgv with system prompt" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
    };
    prov.config.skip_permissions = false;
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", "Be helpful", false);
    var found_sys = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--system-prompt")) {
            found_sys = true;
            try std.testing.expectEqualStrings("Be helpful", argv[idx + 1]);
        }
    }
    try std.testing.expect(found_sys);
}

test "buildArgv with allowed and disallowed tools" {
    const allowed = [_][]const u8{ "WebSearch", "Read" };
    const disallowed = [_][]const u8{"Bash"};
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .config = .{
            .allowed_tools = &allowed,
            .disallowed_tools = &disallowed,
            .skip_permissions = false,
        },
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    var allowed_count: usize = 0;
    var disallowed_count: usize = 0;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--allowedTools")) allowed_count += 1;
        if (std.mem.eql(u8, arg, "--disallowedTools")) disallowed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), allowed_count);
    try std.testing.expectEqual(@as(usize, 1), disallowed_count);
}

test "buildArgv with skip_permissions" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .config = .{ .skip_permissions = true },
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    var found = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--dangerously-skip-permissions")) found = true;
    }
    try std.testing.expect(found);
}

test "buildArgv with max_turns formats numeric value" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .config = .{ .max_turns = 5, .skip_permissions = false },
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    var found = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--max-turns")) {
            found = true;
            try std.testing.expectEqualStrings("5", argv[idx + 1]);
        }
    }
    try std.testing.expect(found);
}

test "buildArgv with effort" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .config = .{ .effort = "high", .skip_permissions = false },
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    var found = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--effort")) {
            found = true;
            try std.testing.expectEqualStrings("high", argv[idx + 1]);
        }
    }
    try std.testing.expect(found);
}

test "buildArgv with max_budget_usd" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
        .config = .{ .max_budget_usd = 1.5, .skip_permissions = false },
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    var found = false;
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--max-budget-usd")) {
            found = true;
            try std.testing.expectEqualStrings("1.5", argv[idx + 1]);
        }
    }
    try std.testing.expect(found);
}

test "buildArgv does not include verbose" {
    var prov = ClaudeCliProvider{
        .allocator = std.testing.allocator,
        .model = "claude-opus-4-6",
    };
    var buf: [32][]const u8 = undefined;
    const argv = try prov.buildArgv(&buf, "hello", "claude-opus-4-6", null, false);
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--verbose"));
    }
}

test "ClaudeCliConfig default values" {
    const cfg = config_types.ClaudeCliConfig{};
    try std.testing.expectEqual(@as(usize, 0), cfg.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.disallowed_tools.len);
    try std.testing.expectEqual(@as(u32, 0), cfg.max_turns);
    try std.testing.expect(cfg.effort == null);
    try std.testing.expectEqual(@as(f64, 0), cfg.max_budget_usd);
    try std.testing.expect(cfg.skip_permissions);
}

test "session_id capture lifecycle" {
    // First call: no session_id, parses one from result
    const input1 =
        \\{"type":"result","result":"hello","session_id":"sess-1"}
    ;
    const result1 = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input1);
    defer std.testing.allocator.free(result1.content);
    try std.testing.expectEqualStrings("sess-1", result1.session_id.?);

    // Simulate storing on provider
    defer std.testing.allocator.free(result1.session_id.?);

    // Second call: new session_id in result
    const input2 =
        \\{"type":"result","result":"world","session_id":"sess-2"}
    ;
    const result2 = try ClaudeCliProvider.parseStreamJson(std.testing.allocator, input2);
    defer std.testing.allocator.free(result2.content);
    defer if (result2.session_id) |sid| std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("sess-2", result2.session_id.?);
}

test "parseUsageFromObject empty" {
    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    const usage = parseUsageFromObject(obj);
    try std.testing.expectEqual(@as(u32, 0), usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 0), usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 0), usage.total_tokens);
}
