# How pi's TUI renderer works

Notes from reading the `@earendil-works/pi-tui` source. This is the reference we are learning from,
not a spec to copy verbatim.

## The core surprise: it is all strings

pi has no cell grid and no attribute buffer. The entire rendering model is arrays of strings.

A component is just:

```
render(width) -> string[]   // one already-styled line per element, each visible width <= width
handleInput(data)
invalidate()
```

"Given a width, produce N lines of text with ANSI escapes baked in." Styling (SGR colors, bold)
lives inline inside the strings. After each line, pi appends a full SGR reset and an OSC 8 reset, so
styles never bleed across lines. There is no `{rune, style}` cell model anywhere.

## It renders inline, not on the alternate screen

This is the biggest architectural decision and the main thing that separates pi from a full-screen
TUI like lazygit or vim.

Terminal setup is only: raw mode, hide cursor, bracketed paste (`ESC [ ? 2004 h`), and optional
Kitty keyboard protocol negotiation. There is **no** `ESC [ ? 1049 h` alternate-screen switch.

The UI is a live region at the bottom of the normal terminal buffer that scrolls up into scrollback
like ordinary CLI output. lazygit takes the opposite route: alt-screen plus a full-screen cell grid.

## The repaint is a line diff

pi keeps `previousLines: string[]`. Each frame:

1. Ask the root component for `newLines = render(width)`.
2. Walk both arrays and find `firstChanged` / `lastChanged`.
3. Move the cursor with `ESC [ n A` / `ESC [ n B` and `\r`, clear each changed line with
   `ESC [ 2 K`, and rewrite only the changed span.
4. Wrap the whole burst in **synchronized output** (`ESC [ ? 2026 h` ... `ESC [ ? 2026 l`) so there
   is no flicker.

A full redraw (`ESC [ 2 J`, `ESC [ H`, `ESC [ 3 J`) happens only when:

- the terminal width changed (wrapping is now different), or
- the terminal height changed, or
- content scrolled above the visible viewport, or
- content shrank below the previous max and there are no overlays.

Rendering only the changed span (not everything to the end) is what makes a one-line spinner update
cheap and flicker-free.

## The line-fits-width invariant is enforced hard

Before writing any line, pi asserts `visibleWidth(line) <= width`. On violation it writes a crash
log and throws, with a message telling the component author to use `visibleWidth()` /
`truncateToWidth()`. Every component owns its own truncation and wrapping. This is why width math is
load-bearing everywhere — see `text-width.md`.

## Input parsing is a whole subsystem

pi's key parser is ~1200 lines. It handles arrow/function-key escape sequences, the Kitty keyboard
protocol plus a `modifyOtherKeys` fallback, bracketed paste, and — importantly — an incremental
buffer, because a single multibyte key or a paste can arrive split across separate stdin reads. Do
not underestimate this part.

## What to take from pi

- The line/string component model (no cell grid) is the right call for a chat/log + input UI.
- Inline rendering (no alt-screen) gives the natural "scrolls with history" feel.
- Line diff + synchronized output is a small amount of code for flicker-free updates.
- Width measurement and per-line truncation are mandatory, not optional.
