# Rendering Model

This document describes how an inline terminal interface projects a larger, durable application
state onto a bounded window. It defines what the renderer must do and the guarantees it makes. It
prescribes no data structures or algorithms.

## Model and view

State is split into two layers.

- The **model** is the durable source of truth: the full content history and all components. It
  changes only in response to application events. Rendering never mutates it.
- The **view** projects the model onto the terminal. It holds no authoritative state. It holds only
  what is needed to draw a frame and to diff it against the previous one.

A **component** is a stateful element with its own lifecycle. It can represent ongoing work that
completes asynchronously. A component's existence and progress belong to the model, not the view.
Whether a component is currently drawn has no bearing on whether it is alive. Content outside the
drawn region still runs and still updates its state.

## The window

The view maintains a bounded **window**: the most recent content, sized in **pages**, where one page
is the current terminal height. The window is the renderer's working set — what it tracks and can
redraw — so it bounds repaint cost and memory however far the content grows. Only the window's last
page occupies the viewport. Its earlier pages sit above it, in the terminal's scrollback. The
window's page count is configurable and can change on request. A terminal resize instead redefines
the page, which changes the window's height in rows.

The window bounds what the renderer redraws, not how far the terminal can scroll. Content that
scrolls out is left in the terminal's own scrollback rather than erased. Reachable history is
therefore at least the window and can be more. A reset trims it back to the window. A change outside
the viewport, a resize, or a change to the window's page count forces a reset. Until a reset occurs,
scrollback grows as far as the terminal allows.

Rendering is **inline**: the window is drawn into the terminal's normal buffer, and the terminal
scrolls through the drawn content. The view is always anchored to the newest content and keeps no
scroll position of its own. Because of that anchoring, any repaint returns the terminal to the
newest content. A user who has scrolled up is snapped back the next time the interface updates,
wherever the change occurred.

Projection from model to window is a pure function of the model, the terminal dimensions, and the
window's page count. It lays out only the content that falls inside the window and can be recomputed
at any time without side effects.

## Repainting

Given a new window, the renderer applies the smallest correct update.

- **Incremental**: when every changed line is within the viewport. Appended new content is the
  common case. Reposition to the first changed line and reprint from there down.
- **Reset**: when any changed line falls above the viewport, or the terminal or the window's page
  count changed. Clear the terminal, including its scrollback, and reprint the whole window.

Every repaint is emitted atomically, so no partial frame is ever visible. Layout is display-width
aware. A glyph can occupy more than one column. A line wider than the terminal wraps onto several
physical rows. All cursor motion is counted in physical rows, so wrapping never desynchronizes the
cursor.

The interface can hold one active text-input caret. After every repaint the hardware cursor is
restored to that caret, so typing is unaffected by updates elsewhere on screen. When no input is
focused, the cursor is hidden.

## Frames

The view repaints on a **tick**: a frame produced on demand, rate-limited to a target frame rate. An
event schedules the next tick. Every event that arrives before it fires coalesces into that one
frame. When no event occurs, no tick fires and the renderer stays idle. Keyboard input is one such
event, so the frame rate is also the input echo rate. The delay between a keystroke and its echoed
character is at most one frame interval. The rate must be high enough that typing stays fluid even
under sustained fast input. Animation is no exception. A self-animating element schedules its own
periodic events, each rendered through the same path and active only while it animates. Even
animation therefore leaves an idle interface inert.

Ticks land on a fixed grid. Each deadline is one interval after the previous deadline, not one
interval after the previous frame ended. The work of a frame therefore falls inside its own interval
and does not add to it. A frame that keeps to its budget holds the target rate exactly. Two
conditions set the grid again to the current time: a frame that overruns its slot, and a wake from
an idle channel. The loop then carries no backlog of missed deadlines, and an idle wait does not
count as lateness.

The timer waits on the deadline itself, not on a duration. A duration wait starts the clock again at
the moment the loop arms the timer, so the cost to arm the timer adds to the interval. An operating
system with an absolute sleep waits once and wakes on the deadline. An operating system without one
wakes late, and the grid corrects for that. The lateness moves the phase of one frame and leaves the
next deadline in place.

The correction is large. macOS has no absolute sleep and it coalesces its timers, so a 16 ms wait
wakes about 3.3 ms late. A loop that measures the next interval from the wake adds that lateness to
every frame and settles at a 19.5 ms period. The grid shortens the next wait instead, so the period
holds at 16 ms and only the phase moves.

A tick that finds no change paints nothing. A quantized animation step reaches the same cell on two
ticks in a row, so a skipped frame is correct and is not a defect.

## Working memory

The view's working memory consists of the buffers where it composes and diffs frames. It is bounded
to the window and reused across frames rather than rebuilt each time. It grows only to fit: a
terminal resize, a change to the window's page count, or the largest frame it has had to lay out. It
is not released between frames, so a steady interface settles at a bounded footprint that does not
grow with the model.

## Invariants

- Rendering never mutates the model.
- Projection from model to window is pure and can be recomputed at any time.
- A component's lifecycle is independent of whether it is drawn.
- The renderer's working set is bounded to the window. Repaint cost and memory are bounded
  regardless of model size.
- The view is always anchored to the newest content and holds no scroll position of its own.
- The view's working memory is reused across frames rather than rebuilt each time.
- Frames are rate-limited, event-driven, and coalesced. An idle interface is inert. Input echoes
  within one frame interval.
- Ticks hold a fixed rate. The cost of a frame falls inside its interval, and does not add to it.
- No partial frame is ever visible. Wrapping never desynchronizes the cursor.
- After every repaint the cursor is restored to the active input caret. When no input is focused,
  the cursor is hidden.
