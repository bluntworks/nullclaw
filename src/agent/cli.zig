//! CLI entry point — single-message and interactive REPL modes.
//!
//! Extracted from agent/root.zig. Contains `run()` (the main entry point
//! for `nullclaw agent`) and the streaming stdout callback.

const std = @import("std");
const log = std.log.scoped(.agent);
const Config = @import("../config.zig").Config;
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const http_util = @import("../http_util.zig");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const bootstrap_mod = @import("../bootstrap/root.zig");
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const subagent_mod = @import("../subagent.zig");
const subagent_runner = @import("../subagent_runner.zig");
const cli_mod = @import("../channels/cli.zig");
const security = @import("../security/policy.zig");
const auth_mod = @import("../auth.zig");
const onboard = @import("../onboard.zig");
const streaming = @import("../streaming.zig");
const verbose = @import("../verbose.zig");

const Agent = @import("root.zig").Agent;
const tui_mod = @import("../tui/root.zig");

const CliStreamCtx = struct {
    sink: streaming.Sink,
};

fn cliStreamSinkCallback(_: *anyopaque, event: streaming.Event) void {
    if (event.stage == .tool_call) {
        const name = streaming.TagFilter.extractToolName(event.text);
        const args = streaming.TagFilter.extractToolArgs(event.text);
        var buf: [8192]u8 = undefined;
        var bw = std.fs.File.stdout().writer(&buf);
        const wr = &bw.interface;
        wr.print("\n\x1b[44;30m {s} \x1b[0m", .{name}) catch {};
        if (args.len > 0) wr.print(" \x1b[90m{s}\x1b[0m", .{args}) catch {};
        wr.print("\n\n", .{}) catch {};
        wr.flush() catch {};
        return;
    }
    if (event.stage != .chunk or event.text.len == 0) return;
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const wr = &bw.interface;
    wr.print("{s}", .{event.text}) catch {};
    wr.flush() catch {};
}

/// Streaming callback that forwards provider chunks into unified stream sink events.
fn cliStreamCallback(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
    const stream_ctx: *CliStreamCtx = @ptrCast(@alignCast(ctx_ptr));
    streaming.forwardProviderChunk(stream_ctx.sink, chunk);
}

// -- TUI streaming context ------------------------------------------------

const TuiStreamCtx = struct {
    renderer: *tui_mod.Renderer,
    sink: streaming.Sink,
};

fn tuiStreamSinkCallback(ctx: *anyopaque, event: streaming.Event) void {
    const r: *tui_mod.Renderer = @ptrCast(@alignCast(ctx));
    if (event.stage == .tool_call) {
        const name = streaming.TagFilter.extractToolName(event.text);
        const args = streaming.TagFilter.extractToolArgs(event.text);
        var fmt_buf: [4096]u8 = undefined;
        const formatted = if (args.len > 0)
            std.fmt.bufPrint(&fmt_buf, "\x1b[44;30m {s} \x1b[0m \x1b[90m{s}\x1b[0m", .{ name, args }) catch return
        else
            std.fmt.bufPrint(&fmt_buf, "\x1b[44;30m {s} \x1b[0m", .{name}) catch return;
        r.appendRawLine(formatted);
        r.appendLine("", false);

        // Log tool calls to the log panel
        var log_buf: [256]u8 = undefined;
        const log_msg = if (args.len > 0)
            std.fmt.bufPrint(&log_buf, "[tool] {s} {s}", .{ name, args[0..@min(args.len, 128)] }) catch name
        else
            std.fmt.bufPrint(&log_buf, "[tool] {s}", .{name}) catch name;
        r.appendLog(log_msg);

        r.draw() catch {};
        return;
    }
    if (event.stage == .chunk and event.text.len > 0) {
        r.appendStreamChunk(event.text);
        r.draw() catch {};
    } else if (event.stage == .final) {
        r.endStreaming();
        r.hideThinking();
        r.draw() catch {};
    }
}

fn tuiStreamCallback(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
    const stream_ctx: *TuiStreamCtx = @ptrCast(@alignCast(ctx_ptr));
    streaming.forwardProviderChunk(stream_ctx.sink, chunk);
}

fn hasOpenAiCodexCredential(allocator: std.mem.Allocator) bool {
    const token = auth_mod.loadCredential(allocator, providers.openai_codex.CREDENTIAL_KEY) catch return false;
    if (token) |tok| {
        allocator.free(tok.access_token);
        if (tok.refresh_token) |rt| allocator.free(rt);
        allocator.free(tok.token_type);
        return true;
    }
    return false;
}

fn shouldPrintOpenAiCodexHint(default_provider: []const u8, has_codex_credential: bool) bool {
    return has_codex_credential and !std.mem.eql(u8, default_provider, "openai-codex");
}

fn maybePrintAllProvidersFailedHint(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    default_provider: []const u8,
) !void {
    if (!shouldPrintOpenAiCodexHint(default_provider, hasOpenAiCodexCredential(allocator))) return;
    try w.print(
        "Hint: openai-codex is authenticated, but current provider is {s}. Set \"agents.defaults.model.primary\": \"openai-codex/gpt-5.3-codex\" or run with --provider openai-codex --model gpt-5.3-codex.\n",
        .{default_provider},
    );
}

fn maybePrintLastProviderApiError(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    const detail = providers.snapshotLastApiErrorDetail(allocator) catch null;
    if (detail) |msg| {
        defer allocator.free(msg);
        try w.print("Last provider error: {s}\n", .{msg});
    }
}

const ParsedAgentArgs = struct {
    message_arg: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    provider_override: ?[]const u8 = null,
    model_override: ?[]const u8 = null,
    temperature_override: ?f64 = null,
    verbose: bool = false,
    use_tui: bool = false,
};

const AgentArgParseResult = union(enum) {
    ok: ParsedAgentArgs,
    missing_value: []const u8,
    invalid_temperature: []const u8,
};

fn parseAgentArgs(args: []const []const u8) AgentArgParseResult {
    var parsed = ParsedAgentArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            if (i + 1 >= args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.message_arg = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            if (i + 1 >= args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.session_id = args[i];
        } else if (std.mem.eql(u8, arg, "--provider")) {
            if (i + 1 >= args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.provider_override = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (i + 1 >= args.len) return .{ .missing_value = arg };
            i += 1;
            parsed.model_override = args[i];
        } else if (std.mem.eql(u8, arg, "--temperature")) {
            if (i + 1 >= args.len) return .{ .missing_value = arg };
            i += 1;
            const temp = std.fmt.parseFloat(f64, args[i]) catch return .{ .invalid_temperature = args[i] };
            parsed.temperature_override = temp;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            parsed.verbose = true;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            parsed.use_tui = true;
        }
    }
    return .{ .ok = parsed };
}

/// Run the agent in single-message or interactive REPL mode.
/// This is the main entry point called by `nullclaw agent`.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var cfg = Config.load(allocator) catch {
        log.err("No config found. Run `nullclaw onboard` first.", .{});
        return;
    };
    defer cfg.deinit();

    const parsed_args = switch (parseAgentArgs(args)) {
        .ok => |parsed| parsed,
        .missing_value => |opt| {
            log.err("Missing value for {s}", .{opt});
            return;
        },
        .invalid_temperature => |value| {
            log.err("Invalid --temperature value: {s}", .{value});
            return;
        },
    };
    if (parsed_args.provider_override) |provider| {
        cfg.default_provider = provider;
    }
    if (parsed_args.model_override) |model| {
        cfg.default_model = model;
    }
    if (parsed_args.temperature_override) |temp| {
        cfg.default_temperature = temp;
        cfg.temperature = temp;
    }
    if (parsed_args.verbose) {
        log.warn("Verbose flag detected, enabling verbose logging", .{});
        verbose.setVerbose(true);
    }

    cfg.validate() catch |err| {
        Config.printValidationError(err);
        return;
    };

    http_util.setProxyOverride(cfg.http_request.proxy) catch |err| {
        log.err("Invalid http_request.proxy override: {s}", .{@errorName(err)});
        return;
    };
    providers.setApiErrorLimitOverride(cfg.diagnostics.api_error_max_chars) catch |err| {
        log.err("Invalid diagnostics.api_error_max_chars override: {s}", .{@errorName(err)});
        return;
    };

    // Ensure lifecycle parity: seed workspace files on first agent run
    // so prompts always have the expected bootstrap context.
    try onboard.scaffoldWorkspace(allocator, cfg.workspace_dir, &onboard.ProjectContext{}, null);

    var out_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&out_buf);
    const w = &bw.interface;

    const message_arg = parsed_args.message_arg;
    const session_id = parsed_args.session_id;

    // Create a noop observer
    var noop = observability.NoopObserver{};
    const obs = noop.observer();

    // Record agent start
    const start_event = ObserverEvent{ .agent_start = .{
        .provider = cfg.default_provider,
        .model = cfg.default_model orelse "(default)",
    } };
    obs.recordEvent(&start_event);

    // Initialize MCP tools from config
    const mcp_mod = @import("../mcp.zig");
    const mcp_tools: ?[]const tools_mod.Tool = if (cfg.mcp_servers.len > 0)
        mcp_mod.initMcpTools(allocator, cfg.mcp_servers) catch |err| blk: {
            log.warn("MCP: init failed: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (mcp_tools) |mt| allocator.free(mt);

    // Build security policy from config
    var tracker = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
    defer tracker.deinit();

    var policy = security.SecurityPolicy{
        .autonomy = cfg.autonomy.level,
        .workspace_dir = cfg.workspace_dir,
        .workspace_only = cfg.autonomy.workspace_only,
        .allowed_commands = security.resolveAllowedCommands(cfg.autonomy.level, cfg.autonomy.allowed_commands),
        .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
        .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
        .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
        .allow_raw_url_chars = cfg.autonomy.allow_raw_url_chars,
        .tracker = &tracker,
    };

    // Provider runtime bundle (primary provider + reliability wrapper).
    var runtime_provider = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &cfg);
    defer runtime_provider.deinit();
    const resolved_api_key = runtime_provider.primaryApiKey();

    var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{});
    subagent_manager.task_runner = subagent_runner.runTaskWithTools;
    defer subagent_manager.deinit();

    // Optional memory backend.
    var mem_rt = memory_mod.initRuntime(allocator, &cfg.memory, cfg.workspace_dir);
    defer if (mem_rt) |*rt| rt.deinit();
    const mem_opt: ?Memory = if (mem_rt) |rt| rt.memory else null;

    const bootstrap_provider: ?bootstrap_mod.BootstrapProvider = bootstrap_mod.createProvider(
        allocator,
        cfg.memory.backend,
        mem_opt,
        cfg.workspace_dir,
    ) catch null;
    defer if (bootstrap_provider) |bp| bp.deinit();

    // Create tools (with agents config for delegate depth enforcement)
    const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{
        .http_enabled = cfg.http_request.enabled,
        .http_allowed_domains = cfg.http_request.allowed_domains,
        .http_max_response_size = cfg.http_request.max_response_size,
        .http_timeout_secs = cfg.http_request.timeout_secs,
        .web_search_base_url = cfg.http_request.search_base_url,
        .web_search_provider = cfg.http_request.search_provider,
        .web_search_fallback_providers = cfg.http_request.search_fallback_providers,
        .browser_enabled = cfg.browser.enabled,
        .screenshot_enabled = true,
        .mcp_tools = mcp_tools,
        .agents = cfg.agents,
        .fallback_api_key = resolved_api_key,
        .tools_config = cfg.tools,
        .allowed_paths = cfg.autonomy.allowed_paths,
        .policy = &policy,
        .subagent_manager = &subagent_manager,
        .bootstrap_provider = bootstrap_provider,
        .backend_name = cfg.memory.backend,
    });
    defer tools_mod.deinitTools(allocator, tools);

    // Bind memory backend once for this tool set before creating agents.
    tools_mod.bindMemoryTools(tools, mem_opt);

    // Bind MemoryRuntime to memory tools for hybrid search and vector sync.
    if (mem_rt) |*rt| {
        tools_mod.bindMemoryRuntime(tools, rt);
    }

    // Provider interface from runtime bundle (includes retries/fallbacks).
    const provider_i: Provider = runtime_provider.provider();

    const supports_streaming = provider_i.supportsStreaming();

    // Single message mode: nullclaw agent -m "hello"
    if (message_arg) |message| {
        try w.print("Sending to {s}...\n", .{cfg.default_provider});
        if (session_id) |sid| {
            try w.print("Session: {s}\n", .{sid});
        }
        try w.flush();

        var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
        agent.policy = &policy;
        agent.session_store = if (mem_rt) |rt| rt.session_store else null;
        agent.response_cache = if (mem_rt) |*rt| rt.response_cache else null;
        agent.mem_rt = if (mem_rt) |*rt| rt else null;
        if (session_id) |sid| {
            agent.memory_session_id = sid;
        }
        defer agent.deinit();

        // Enable streaming if provider supports it
        var stream_sink_ctx: u8 = 0;
        var tag_filter = streaming.TagFilter.init(.{
            .callback = cliStreamSinkCallback,
            .ctx = @ptrCast(&stream_sink_ctx),
        });
        var stream_ctx = CliStreamCtx{
            .sink = tag_filter.sink(),
        };
        if (supports_streaming) {
            agent.stream_callback = cliStreamCallback;
            agent.stream_ctx = @ptrCast(&stream_ctx);
        }

        const response = agent.turn(message) catch |err| {
            if (err == error.ProviderDoesNotSupportVision) {
                try w.print("Error: The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.\n", .{});
                try w.flush();
                return;
            }
            if (err == error.AllProvidersFailed) {
                try maybePrintLastProviderApiError(allocator, w);
                try maybePrintAllProvidersFailedHint(allocator, w, cfg.default_provider);
                try w.flush();
            }
            return err;
        };
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n", .{});
        } else {
            try w.print("{s}\n", .{response});
        }
        try w.flush();
        return;
    }

    // TUI mode: --tui flag activates full terminal UI
    if (parsed_args.use_tui) {
        return runTui(
            allocator,
            &cfg,
            provider_i,
            supports_streaming,
            tools,
            mem_opt,
            mem_rt,
            obs,
            &policy,
            session_id,
        );
    }

    // Interactive REPL mode
    cfg.printModelConfig();
    try w.print("nullclaw Agent -- Interactive Mode\n", .{});
    try w.print("Provider: {s} | Model: {s}\n", .{
        cfg.default_provider,
        cfg.default_model orelse "(default)",
    });
    if (session_id) |sid| {
        try w.print("Session: {s}\n", .{sid});
    }
    if (supports_streaming) {
        try w.print("Streaming: enabled\n", .{});
    }
    try w.print("Type your message (Ctrl+D or 'exit' to quit):\n\n", .{});
    try w.flush();

    // Load command history
    const history_path = cli_mod.defaultHistoryPath(allocator) catch null;
    defer if (history_path) |hp| allocator.free(hp);

    var repl_history: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        // Save history on exit
        if (history_path) |hp| {
            cli_mod.saveHistory(repl_history.items, hp) catch {};
        }
        for (repl_history.items) |entry| allocator.free(entry);
        repl_history.deinit(allocator);
    }

    // Seed history from file
    if (history_path) |hp| {
        const loaded = cli_mod.loadHistory(allocator, hp) catch null;
        if (loaded) |entries| {
            defer allocator.free(entries);
            for (entries) |entry| {
                repl_history.append(allocator, entry) catch {
                    allocator.free(entry);
                };
            }
        }
    }

    if (repl_history.items.len > 0) {
        try w.print("[History: {d} entries loaded]\n", .{repl_history.items.len});
        try w.flush();
    }

    var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
    agent.policy = &policy;
    agent.session_store = if (mem_rt) |rt| rt.session_store else null;
    agent.response_cache = if (mem_rt) |*rt| rt.response_cache else null;
    agent.mem_rt = if (mem_rt) |*rt| rt else null;
    if (session_id) |sid| {
        agent.memory_session_id = sid;
    }
    defer agent.deinit();

    // Enable streaming if provider supports it
    var stream_sink_ctx: u8 = 0;
    var tag_filter = streaming.TagFilter.init(.{
        .callback = cliStreamSinkCallback,
        .ctx = @ptrCast(&stream_sink_ctx),
    });
    var stream_ctx = CliStreamCtx{
        .sink = tag_filter.sink(),
    };
    if (supports_streaming) {
        agent.stream_callback = cliStreamCallback;
        agent.stream_ctx = @ptrCast(&stream_ctx);
    }

    const stdin = std.fs.File.stdin();
    var line_buf: [4096]u8 = undefined;

    while (true) {
        try w.print("> ", .{});
        try w.flush();

        // Read a line from stdin byte-by-byte
        var pos: usize = 0;
        while (pos < line_buf.len) {
            const n = stdin.read(line_buf[pos .. pos + 1]) catch return;
            if (n == 0) return; // EOF (Ctrl+D)
            if (line_buf[pos] == '\n') break;
            pos += 1;
        }
        const line = line_buf[0..pos];

        if (line.len == 0) continue;
        if (cli_mod.CliChannel.isQuitCommand(line)) return;

        // Append to history
        repl_history.append(allocator, allocator.dupe(u8, line) catch continue) catch {};

        const response = agent.turn(line) catch |err| {
            if (err == error.ProviderDoesNotSupportVision) {
                try w.print("Error: The current provider does not support image input. Switch to a vision-capable provider or remove [IMAGE:] attachments.\n", .{});
            } else if (err == error.AllProvidersFailed) {
                try w.print("Error: {}\n", .{err});
                try maybePrintLastProviderApiError(allocator, w);
                try maybePrintAllProvidersFailedHint(allocator, w, cfg.default_provider);
            } else {
                try w.print("Error: {}\n", .{err});
            }
            try w.flush();
            continue;
        };
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n\n", .{});
        } else {
            try w.print("\n{s}\n\n", .{response});
        }
        try w.flush();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TUI REPL
// ═══════════════════════════════════════════════════════════════════════════

fn runTui(
    allocator: std.mem.Allocator,
    cfg: *Config,
    provider_i: Provider,
    supports_streaming: bool,
    tools: []const Tool,
    mem_opt: ?Memory,
    mem_rt: ?memory_mod.MemoryRuntime,
    obs: Observer,
    policy: *security.SecurityPolicy,
    session_id: ?[]const u8,
) !void {
    var terminal = tui_mod.Terminal.init();
    try terminal.enableRawMode();
    errdefer terminal.cleanup();

    try terminal.enterAltScreen();
    try terminal.clearScreen();
    tui_mod.terminal.Terminal.installResizeHandler();

    var renderer = tui_mod.Renderer.init(&terminal);
    renderer.setStatus(cfg.default_provider, cfg.default_model orelse "(default)");

    // Welcome message in chat area
    renderer.appendLine("nullclaw Agent -- TUI Mode", false);
    renderer.appendLine("", false);
    renderer.appendText(
        "Type your message and press Enter. Ctrl+C or 'exit' to quit.",
        false,
    );
    renderer.appendLine("", false);

    // Load command history
    const history_path = cli_mod.defaultHistoryPath(allocator) catch null;
    defer if (history_path) |hp| allocator.free(hp);

    var repl_history: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        if (history_path) |hp| {
            cli_mod.saveHistory(repl_history.items, hp) catch {};
        }
        for (repl_history.items) |entry| allocator.free(entry);
        repl_history.deinit(allocator);
    }

    if (history_path) |hp| {
        const loaded = cli_mod.loadHistory(allocator, hp) catch null;
        if (loaded) |entries| {
            defer allocator.free(entries);
            for (entries) |entry| {
                repl_history.append(allocator, entry) catch {
                    allocator.free(entry);
                };
            }
        }
    }

    var line_editor = tui_mod.LineEditor{};
    line_editor.setHistory(repl_history.items);
    line_editor.prompt = "> ";

    var agent = try Agent.fromConfig(allocator, cfg, provider_i, tools, mem_opt, obs);
    agent.policy = policy;
    agent.session_store = if (mem_rt) |rt| rt.session_store else null;
    agent.response_cache = null;
    agent.mem_rt = null;
    if (session_id) |sid| {
        agent.memory_session_id = sid;
    }
    defer agent.deinit();

    // Set up streaming (TagFilter strips <tool_call>/<tool_result> XML)
    var tag_filter = streaming.TagFilter.init(.{
        .callback = tuiStreamSinkCallback,
        .ctx = @ptrCast(&renderer),
    });
    var stream_ctx = TuiStreamCtx{
        .renderer = &renderer,
        .sink = tag_filter.sink(),
    };
    if (supports_streaming) {
        agent.stream_callback = tuiStreamCallback;
        agent.stream_ctx = @ptrCast(&stream_ctx);
    }

    // Initial draw
    line_editor.render_row = renderer.inputRow();
    try renderer.draw();
    try line_editor.render(&terminal);

    // Main event loop
    while (true) {
        // Check for resize
        if (tui_mod.terminal.resize_pending.load(.acquire)) {
            tui_mod.terminal.resize_pending.store(false, .release);
            renderer.resize();
            line_editor.render_row = renderer.inputRow();
            try renderer.draw();
            try line_editor.render(&terminal);
        }

        const key = tui_mod.input.readKey() orelse {
            // EOF
            break;
        };

        // Handle Ctrl+C / Ctrl+D
        switch (key) {
            .ctrl_c => break,
            .ctrl_d => break,
            .ctrl_l => {
                // Clear and redraw
                try terminal.clearScreen();
                try renderer.draw();
                try line_editor.render(&terminal);
                continue;
            },
            else => {},
        }

        if (line_editor.handleKey(key)) |line| {
            // Check for quit commands
            if (cli_mod.CliChannel.isQuitCommand(line)) break;

            // Copy line for history and agent
            const line_copy = allocator.dupe(u8, line) catch continue;

            // Show user message in chat area
            renderer.appendLine("", false);
            var user_buf: [tui_mod.line_editor.MAX_LINE + 3]u8 = undefined;
            const user_line = std.fmt.bufPrint(&user_buf, "> {s}", .{line}) catch line;
            renderer.appendLine(user_line, true);
            renderer.appendLine("", false);

            // Add to history
            repl_history.append(allocator, line_copy) catch {};
            line_editor.setHistory(repl_history.items);

            // Clear editor for next input
            line_editor.clear();

            // Show thinking state
            renderer.showThinking();
            try renderer.draw();
            try line_editor.render(&terminal);

            // Run agent turn
            const response = agent.turn(line_copy) catch |err| {
                renderer.hideThinking();
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Error: {}", .{err}) catch "Error";
                renderer.appendLine(err_msg, false);
                renderer.appendLog(err_msg);
                try renderer.draw();
                try line_editor.render(&terminal);
                continue;
            };
            defer allocator.free(response);

            renderer.hideThinking();

            if (!supports_streaming) {
                renderer.appendText(response, false);
            }
            renderer.appendLine("", false);

            try renderer.draw();
            try line_editor.render(&terminal);
        } else {
            // Key didn't produce a line; just re-render the input
            try line_editor.render(&terminal);
        }
    }

    // Cleanup
    terminal.cleanup();
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

fn noopSinkEvent(_: *anyopaque, _: streaming.Event) void {}

test "cliStreamCallback handles empty delta" {
    var sink_ctx: u8 = 0;
    var ctx = CliStreamCtx{
        .sink = .{
            .callback = noopSinkEvent,
            .ctx = @ptrCast(&sink_ctx),
        },
    };
    const chunk = providers.StreamChunk.finalChunk();
    cliStreamCallback(@ptrCast(&ctx), chunk);
}

test "cliStreamCallback text delta chunk" {
    const chunk = providers.StreamChunk.textDelta("hello");
    try std.testing.expectEqualStrings("hello", chunk.delta);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqual(@as(u32, 2), chunk.token_count);
}

test "parseAgentArgs parses provider and model overrides" {
    const args = [_][]const u8{
        "-m",
        "hi",
        "--provider",
        "ollama",
        "--model",
        "llama3.2:latest",
        "--temperature",
        "0.25",
    };
    const parsed = switch (parseAgentArgs(&args)) {
        .ok => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("hi", parsed.message_arg.?);
    try std.testing.expectEqualStrings("ollama", parsed.provider_override.?);
    try std.testing.expectEqualStrings("llama3.2:latest", parsed.model_override.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), parsed.temperature_override.?, 0.000001);
}

test "parseAgentArgs keeps the last override value" {
    const args = [_][]const u8{
        "--provider",
        "openrouter",
        "--provider",
        "anthropic",
        "--model",
        "first",
        "--model",
        "second",
        "--temperature",
        "0.1",
        "--temperature",
        "0.7",
    };
    const parsed = switch (parseAgentArgs(&args)) {
        .ok => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("anthropic", parsed.provider_override.?);
    try std.testing.expectEqualStrings("second", parsed.model_override.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), parsed.temperature_override.?, 0.000001);
}

test "parseAgentArgs returns error for missing option value" {
    const args = [_][]const u8{"--provider"};
    switch (parseAgentArgs(&args)) {
        .missing_value => |opt| try std.testing.expectEqualStrings("--provider", opt),
        else => unreachable,
    }
}

test "parseAgentArgs returns error for invalid temperature value" {
    const args = [_][]const u8{
        "--temperature",
        "hot",
    };
    switch (parseAgentArgs(&args)) {
        .invalid_temperature => |value| try std.testing.expectEqualStrings("hot", value),
        else => unreachable,
    }
}

test "parseAgentArgs recognizes --tui flag" {
    const args = [_][]const u8{ "--tui", "-m", "hi" };
    const parsed = switch (parseAgentArgs(&args)) {
        .ok => |value| value,
        else => unreachable,
    };
    try std.testing.expect(parsed.use_tui);
    try std.testing.expectEqualStrings("hi", parsed.message_arg.?);
}

test "parseAgentArgs defaults use_tui to false" {
    const args = [_][]const u8{ "-m", "hello" };
    const parsed = switch (parseAgentArgs(&args)) {
        .ok => |value| value,
        else => unreachable,
    };
    try std.testing.expect(!parsed.use_tui);
}

test "shouldPrintOpenAiCodexHint true when codex auth exists and provider differs" {
    try std.testing.expect(shouldPrintOpenAiCodexHint("openai", true));
}

test "shouldPrintOpenAiCodexHint false when provider is openai-codex" {
    try std.testing.expect(!shouldPrintOpenAiCodexHint("openai-codex", true));
}

test "shouldPrintOpenAiCodexHint false when codex auth is missing" {
    try std.testing.expect(!shouldPrintOpenAiCodexHint("openai", false));
}
