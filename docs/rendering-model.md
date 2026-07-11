# Rendering Model

How an inline terminal interface projects a larger, durable application state onto a bounded window.
This defines what the renderer must do and the guarantees it makes; it prescribes no data structures
or algorithms.

## Model and view

State is split into two layers.

- The **model** is the durable source of truth: the full content history and all components. It
  changes only in response to application events and is never mutated by rendering.
- The **view** projects the model onto the terminal. It holds no authoritative state — only what is
  needed to draw a frame and to diff it against the previous one.

A **component** is a stateful element with its own lifecycle, and may represent ongoing work that
completes asynchronously. A component's existence and progress belong to the model, not the view.
Whether a component is currently drawn has no bearing on whether it is alive: content outside the
drawn region keeps running and keeps updating its state.

## The window

The view maintains a bounded **window**: the most recent content, sized in **pages**, where one page
is the current terminal height. The window is the renderer's working set — what it tracks and can
redraw — so it bounds repaint cost and memory however far the content grows. Only the window's last
page occupies the viewport; its earlier pages sit above it, in the terminal's scrollback. The
window's page count is configurable and may change on request; a terminal resize instead redefines
the page, changing the window's height in rows.

The window bounds what the renderer redraws, not how far the terminal can scroll: content that
scrolls out is left in the terminal's own scrollback rather than erased, so reachable history is at
least the window and may be more. A reset trims it back to the window; as long as nothing forces one
— no change outside the viewport, no resize, no change to its page count — scrollback grows as far
as the terminal allows.

Rendering is **inline**: the window is drawn into the terminal's normal buffer, and the terminal
scrolls through the drawn content. The view is always anchored to the newest content and keeps no
scroll position of its own. Because of that anchoring, any repaint returns the terminal to the
newest content: a user who has scrolled up is snapped back the next time the interface updates,
wherever the change occurred.

Projection from model to window is a pure function of the model, the terminal dimensions, and the
window's page count. It lays out only the content that falls inside the window and can be recomputed
at any time without side effects.

## Repainting

Given a new window, the renderer applies the smallest correct update.

- **Incremental** — when every changed line is within the viewport, appending new content being the
  common case: reposition there and reprint from the first changed line down.
- **Reset** — when any changed line falls above the viewport, or the terminal or the window's page
  count changed: clear the terminal, including its scrollback, and reprint the whole window.

Every repaint is emitted atomically, so no partial frame is ever visible. Layout is display-width
aware: a glyph may occupy more than one column, a line wider than the terminal wraps onto several
physical rows, and all cursor motion is counted in physical rows so wrapping never desynchronizes
the cursor.

The interface may hold one active text-input caret. After every repaint the hardware cursor is
restored to that caret, so typing is unaffected by updates elsewhere on screen; when no input is
focused, the cursor is hidden.

## Frames

The view repaints on a **tick**: a frame produced on demand, rate-limited to a target frame rate. An
event schedules the next tick; every event arriving before it fires coalesces into that one frame;
when no event occurs, no tick fires and the renderer stays idle. Keyboard input is one such event,
so the frame rate is also the input echo rate: the delay between a keystroke and its character
appearing is at most one frame interval, and the rate must be high enough that typing stays fluid
even under sustained fast input. Animation is no exception: a self-animating element schedules its
own periodic events, each rendered through the same path and active only while it animates — so even
animation leaves an idle interface inert.

## Allocation

Producing a frame allocates no memory: buffers are sized to the window and reused. Only structural
changes — a terminal resize, or a change to the window's page count — may resize those buffers.

## Invariants

- Rendering never mutates the model.
- Projection from model to window is pure and can be recomputed at any time.
- A component's lifecycle is independent of whether it is drawn.
- The renderer's working set is bounded to the window; repaint cost and memory are bounded
  regardless of model size.
- The view is always anchored to the newest content and holds no scroll position of its own.
- The steady-state render path performs no allocation.
- Frames are rate-limited, event-driven, and coalesced; an idle interface is inert, and input echoes
  within one frame interval.
- No partial frame is ever visible, and wrapping never desynchronizes the cursor.
- After every repaint the cursor is restored to the active input caret, or hidden when none is
  focused.
