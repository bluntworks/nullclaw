//! TUI module — terminal user interface for the agent REPL.
//!
//! Provides a proper interactive terminal experience with line editing,
//! history navigation, styled output, and streaming display. Activated
//! via `nullclaw agent --tui`.
//!
//! No external dependencies; built entirely on ANSI escape codes and
//! Zig std lib. No heap allocation in the hot path (input/render).

pub const terminal = @import("terminal.zig");
pub const style = @import("style.zig");
pub const input = @import("input.zig");
pub const line_editor = @import("line_editor.zig");
pub const renderer = @import("renderer.zig");

pub const Terminal = terminal.Terminal;
pub const Size = terminal.Size;
pub const Style = style.Style;
pub const Color = style.Color;
pub const Key = input.Key;
pub const LineEditor = line_editor.LineEditor;
pub const Renderer = renderer.Renderer;

test {
    @import("std").testing.refAllDecls(@This());
}
