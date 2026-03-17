# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [CalVer](https://calver.org/) versioning (YYYY.M.D).

## [Unreleased]

### Added

- **Claude CLI provider enhancements** (`src/providers/claude_cli.zig`): research-grade headless mode for using Claude Code as an LLM backend
  - Session continuity via `--resume` — multi-turn conversations without resending history
  - System prompt passthrough via `--system-prompt` flag (first call only; session retains it)
  - Configurable tool control: `allowed_tools` / `disallowed_tools` mapped to `--allowedTools` / `--disallowedTools`
  - Streaming support: `supports_streaming` and `stream_chat` vtable entries with `stream-json` output parsing
  - Token usage extraction from CLI result events (`input_tokens`, `output_tokens`)
  - New `ClaudeCliConfig` struct in `config_types.zig` with fields: `allowed_tools`, `disallowed_tools`, `max_turns`, `effort`, `max_budget_usd`, `skip_permissions`
  - Config wired through `ProviderEntry.claude_cli`, `getProviderClaudeCliConfig()` accessor, JSON parse/save, and `RuntimeProviderBundle`
- **CDP browser automation** (`src/cdp.zig`, `src/browser_session.zig`): Chrome DevTools Protocol transport over raw TCP WebSocket, with background reader thread and JSON-RPC request/response routing
  - Browser tool rewritten with 11 CDP-backed actions: `navigate`, `click`, `type`, `read`, `screenshot`, `scroll`, `wait`, `run_js`, `back`, `close`, plus `open` as backward-compatible alias
  - Session manager supporting multiple named sessions with configurable limits (`max_sessions`)
  - Chrome auto-detection across macOS, Linux, Windows; `CHROME_PATH` env and `native_chrome_path` config override
  - SSRF protection on navigate: localhost/private IP blocking, domain allowlist, HTTPS requirement (bypassed by `autonomy.level = yolo`)
  - Screenshot output uses `[IMAGE:path]` format compatible with multimodal vision pipeline
  - New `BrowserConfig` fields: `viewport_width`, `viewport_height`, `timeout_secs`, `idle_timeout_secs`, `max_sessions`
  - `process_util.isInterrupted()` accessor for cooperative cancellation in wait/poll loops
  - Wired at all 5 tool creation callsites (agent CLI, channel loop, gateway, channel mode, TUI mode)
- **TUI log panel**: 3-line diagnostic panel at the bottom of TUI mode showing tool calls, errors, and provider failures in dim grey text (50-entry ring buffer, resize-aware)
- **web_search scoped logging**: `std.log.scoped(.web_search)` warnings on individual provider failures and all-providers-failed (stderr, for non-TUI modes)
- **TUI mode** (`src/tui/`): full-screen terminal interface with alt screen, status bar, scrollback chat area, and styled output — built from scratch using ANSI escape codes with zero external dependencies
  - Line editor with cursor movement (arrows, Home/End), history navigation (Up/Down), and emacs-style key bindings (Ctrl+A/E/K/U/W)
  - Streaming display: LLM response chunks render in real-time into the chat area
  - Persistent command history shared with the standard REPL (`~/.nullclaw_history`)
  - SIGWINCH-based terminal resize handling
  - Color scheme: muted orange for user messages, grey indented text for AI responses, inverted status bar showing provider/model/token count
  - ~22 KB binary size increase, no heap allocation in the input/render hot path
  - **Not yet wired to CLI** — `--tui` flag removed from `cli.zig`; TUI library exists but has no entry point
- Shared color/style module (`src/tui/style.zig`): `Style` struct, `Color` enum, `shouldColorize()` — doctor.zig now imports from here
- `docker-compose.local.yml` for local development builds with SQLite memory and bind-mounted data directory

### Changed

- Reverted `src/agent/cli.zig` to upstream: removed `--tui` flag, TUI streaming callbacks, TagFilter wrapping, and tool call display in CLI sink (TUI integration to be re-approached)

### Fixed

- Venice provider base URL (`https://api.venice.ai` → `https://api.venice.ai/api/v1`)

## [2026.3.7]

### Security

- Docker mount path validation: reject traversal sequences, system directories, and colons
- Constant-time pairing code comparison to prevent timing attacks

### Added

- `yolo` autonomy level for unrestricted mode

### Changed

- `/think on` as alias for medium autonomy (#330)

### Fixed

- Slack markdown-to-mrkdwn conversion (#325)
- Telegram empty draft rejection (#329)
- Reasoning parameter hardening (#318)
