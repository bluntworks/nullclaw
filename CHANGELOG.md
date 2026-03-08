# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [CalVer](https://calver.org/) versioning (YYYY.M.D).

## [Unreleased]

### Added

- **TUI mode** for the agent REPL (`nullclaw agent --tui`): full-screen terminal interface with alt screen, status bar, scrollback chat area, and styled output — built from scratch using ANSI escape codes with zero external dependencies
  - Line editor with cursor movement (arrows, Home/End), history navigation (Up/Down), and emacs-style key bindings (Ctrl+A/E/K/U/W)
  - Streaming display: LLM response chunks render in real-time into the chat area
  - Persistent command history shared with the standard REPL (`~/.nullclaw_history`)
  - SIGWINCH-based terminal resize handling
  - Color scheme: muted orange for user messages, grey indented text for AI responses, inverted status bar showing provider/model/token count
  - ~22 KB binary size increase, no heap allocation in the input/render hot path
- Shared color/style module (`src/tui/style.zig`): `Style` struct, `Color` enum, `shouldColorize()` — doctor.zig now imports from here
- `docker-compose.local.yml` for local development builds with SQLite memory and bind-mounted data directory

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
