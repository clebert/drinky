# Renderer architecture for pith

The plan for the TUI, distilled from the pi study (`pi-tui-internals.md`) and the width research
(`text-width.md`).

## Two possible renderer models

- **Line/string model (pi's way).** Components emit already-styled strings; the renderer diffs
  lines and never models cells. Width is needed for layout and truncation, not for painting —
  painting is "clear line, print string." Least code. Ideal for a chat/log + input UI.
- **Cell-grid model (lazygit / notcurses / vaxis way).** A 2D array of `{codepoint, style}` cells;
  components draw into rects; the renderer diffs cells. More code, better for overlapping windows
  and true full-screen apps, and it forces you to solve width for every single cell.

**Choice: line/string model, rendered inline (no alternate screen), with a line diff wrapped in
synchronized output.** This is the least code for the target UI and gives the natural
"scrolls with history" feel.

## Rough module layout

Native-only to start; grow as needed.

- **Terminal layer** (~150–300 LOC): termios raw mode, `SIGWINCH`, size via `TIOCGWINSZ`, a
  buffered writer, and cleanup on exit/panic (restore cursor + mode). Enable bracketed paste and
  synchronized output (`ESC [ ? 2026 h/l`).
- **Input layer** (~300–500 LOC): read stdin into a ring buffer; an incremental parser turns bytes
  into key events. This is the deceptively large part — a key or paste can split across reads.
- **Width layer**: `displayWidth(str)`, `truncate(str, width)`, `wrap(str, width)`, all skipping
  ANSI escapes. Backed first by a hand-rolled `wcwidth` table (zero deps); optionally `zg` later.
- **Render layer** (~200–400 LOC): hold `previous_lines`; diff against the new lines; move the
  cursor and rewrite only the changed span; wrap the burst in synchronized output.
- **Components**: start with a scrollable log and a one-line input. The multiline editor (cursor,
  word navigation, kill-ring, undo) is the biggest single component — defer it.

## The traps beyond width

- **Incremental input parsing** — partial reads splitting a key or paste is the classic bug.
- **Synchronized output** (`ESC [ ? 2026 h/l`) — cheap, supported by Ghostty, kills flicker. Do it
  from day one.
- **Clean teardown** on panic and signals — restore raw mode and show the cursor, or the terminal
  is left wrecked.
- **Resize** — full redraw and rewrap on `SIGWINCH`.
- **Wrapping while preserving ANSI** across the line break.

## Note on Zig 0.16 std

`std.Io.Terminal` exists but is limited to color detection and `setColor` — not a full raw-mode TUI.
Raw mode, size queries, and input parsing are ours to write (via `std.posix` termios / ioctl). The
new `std.Io` model (`std.Io.File.stdout().writer(io, &buffer)`, buffered `.interface`) is what the
scaffold's `main` already uses.
