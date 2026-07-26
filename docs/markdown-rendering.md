# Markdown Rendering

How pith should style streamed assistant answers and reasoning as markdown — the feature, the
constraints it must respect, and a design that fits pith's renderer. This is an implementation spec:
it prescribes the styling and the shape of the code, and names the exact seams to build on. It does
not dictate every line.

## Goal

Today `.model` (answer) and `.thinking` (reasoning) transcript blocks are rendered as raw UTF-8:
`paint.wrapped` hard-wraps the bytes and opens one SGR style for the whole block (`null` for
answers, `.dim` for reasoning). Markdown markers reach the screen verbatim — a reply shows literal
`**bold**`, `## Heading`, and ` ```code``` ` fences.

We want the model's markdown to render as styled terminal text: headings stand out, code blocks read
as code, lists and quotes are shaped, and inline emphasis is applied — the same polish pi gives its
output, built inside pith's own renderer with no new dependency.

Scope is the two model-authored block kinds only: `.model` and `.thinking`. User messages, tool
results, notices, and the intro keep their current painters untouched. Reasoning gets the same
markdown treatment as answers, tinted (see [Reasoning](#reasoning)).

## How pi does it (reference)

pi is the model to match on _look_, not on _mechanism_. It runs the `marked` lexer over the text,
walks the token tree by hand, and emits ANSI lines coloured from a theme; code blocks are
syntax-highlighted with highlight.js. pith reproduces the look with a hand-rolled single-pass
renderer and no lexer library, and defers syntax highlighting.

pi's element-by-element styling, distilled (dark theme):

| Element             | pi styling                                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------------------------- |
| H1                  | heading colour, **bold**, underline; no `#` prefix                                                                    |
| H2                  | heading colour, **bold**; no `#` prefix                                                                               |
| H3–H6               | heading colour, bold, with a literal `### ` marker kept                                                               |
| Bold `**`           | bold (`1m`)                                                                                                           |
| Italic `*` `_`      | italic (`3m`)                                                                                                         |
| Strikethrough `~~`  | strikethrough (`9m`)                                                                                                  |
| Inline code `` ` `` | accent colour, no background                                                                                          |
| Fenced code block   | ` ``` ` fence lines in a muted border colour; each body line indented two spaces, coloured as code; **no background** |
| Blockquote `>`      | each line prefixed `│ ` in a muted colour; body italic in a muted colour; content width reduced by 2                  |
| List (unordered)    | `- ` marker in accent colour; 4-space indent per nesting depth                                                        |
| List (ordered)      | `N. ` marker in accent colour (respects `start`)                                                                      |
| Task item           | `[x] ` / `[ ] ` after the marker                                                                                      |
| Horizontal rule     | a run of `─` (capped ~80 cols) in a muted colour                                                                      |
| Link                | text in link colour + underline; OSC-8 hyperlink when supported, else ` (url)` appended                               |
| Table               | box-drawing table, bold header cells                                                                                  |
| HTML                | rendered as escaped plain text                                                                                        |

pi's dark palette values, for reference: heading `#f0c674`, inline code `#8abeb7`, code-block body
`#b5bd68`, code-block/quote/hr borders `#808080`, list bullet `#8abeb7`, link `#81a2be`, link url
`#666666`. Reasoning text is tinted `#808080` and italicised.

## pith's constraints

These are the load-bearing invariants a markdown renderer must not break. They shape the design more
than the styling does.

1. **Measure/render parity.** `block.Entry.rows(columns)` must return _exactly_ the number of
   physical rows `block.Entry.render` emits at that width. `layout.project` windows on this count
   and `Sink.end` asserts it (`self.frame.rows.items.len < self.rows_max`, and
   `columns_written <= columns` per row). A renderer that reflows text — stripping `**`, indenting
   list bodies, boxing code — must measure the _displayed_ form, not the source bytes. The current
   `.model`/`.thinking` path gets parity for free because both `rows` and `render` are driven by the
   same `terminal.width.wrapper`; a markdown renderer forfeits that and must re-establish it
   deliberately.

2. **Styles are compile-time SGR.** `Sink.sgr` takes a `comptime` sequence and rejects anything that
   is not one complete `ESC [ … m`. Runtime-computed escapes are impossible by construction. Every
   markdown style is therefore a `color.Style` enum case whose literal SGR lives in `color.apply`
   (`src/ui/color.zig`). The full style set must be fixed up front; you cannot synthesise a colour
   from parsed text.

3. **No allocation in the render path.** The test _"a clipped block streams into a warmed frame
   without allocating"_ (`src/ui/block.zig`) arms a failing allocator and renders a `.model` block.
   The markdown renderer for `.model` must not heap-allocate while rendering. That rules out
   building an intermediate parsed tree or a `[]Line` per frame. Parse and emit in a single
   streaming pass, the way `paint.wrapped` and `paint.box` already stream rows straight into the
   sink.

4. **Streaming, partial input.** Blocks grow token-by-token via `Transcript.appendStream`; layout is
   recomputed every frame over the whole block bytes, and a retry can drop a partial message. The
   renderer runs on incomplete markdown constantly — an unterminated ` ``` `, a half-typed `**bold`,
   a heading with no trailing newline yet. It must render partial input sanely and never assert or
   miscount. Prefer pi's approach of tolerating trailing partial fences rather than flickering.

5. **Keep the line/string render model.** `BACKLOG.md` ("Richer UI components") states the render
   model stays line/string-based. The design below honours that: a "row" is still emitted as a
   sequence of `text` calls into one `begin`/`end`, not a retained widget tree.

6. **Clip support.** Every painter drops its top `skip` rows so a clipped block never materialises
   its hidden top (`Placement.skip`). The markdown renderer must advance its per-row line counter
   and skip rows below `placement.skip` exactly like `paint.framedRow` does.

## Recommended architecture

A new app-level module `src/ui/markdown.zig`, invoked from `block.Entry.render`/`rows` for the
`.model` and `.thinking` variants in place of `terminal.width.rows` and `paint.wrapped`. It belongs
in `src/ui/` (not `lib/terminal/`): it depends on `color.Style` and the app palette, and the
terminal engine must stay ignorant of the app.

The module exposes two entry points that mirror the block contract:

```zig
/// Physical rows the markdown in `text` occupies at `columns`.
pub fn rows(text: []const u8, columns: usize) usize;

/// Compose the markdown in `text` through `placement`, tinted by `tint`
/// (null for answers, a muted style for reasoning).
pub fn render(placement: *const paint.Placement, tint: ?color.Style, text: []const u8) !void;
```

### Parity by shared traversal

Do not write two independent passes and hope they agree — parity slips become row-count assertion
failures. Instead write the markdown walk _once_, parameterised over an **emitter** chosen at
comptime, so `rows` and `render` execute identical control flow and can never diverge:

```zig
fn walk(comptime Emitter: type, emitter: *Emitter, text: []const u8, columns: usize) !void { … }

const Counter = struct {                // used by rows()
    count: usize = 0,
    fn beginRow(self: *Counter) void {}
    fn span(self: *Counter, style: ?color.Style, bytes: []const u8) !void {}
    fn endRow(self: *Counter) void { self.count += 1; }
};

const Painter = struct {                // used by render()
    placement: *const paint.Placement,
    tint: ?color.Style,
    line: usize,
    // Gate the whole row on the clip, exactly like paint.framedRow: when
    // line < placement.skip, emit nothing (no begin/span/end) and only
    // advance line, so a clipped block never materialises its hidden top.
    // Otherwise beginRow → sink.begin(); span →
    // color.apply(style)+sink.text(bytes)+color.apply(.reset); endRow →
    // sink.end({ .id = placement.id, .line }); line += 1.
};
```

`rows` runs `walk(Counter, …)` and returns the count; `render` runs `walk(Painter, …)`. `Counter`
allocates nothing and neither does `Painter` (spans reference slices of `text`, static literals, or
a marker formatted into a stack buffer — see [Span text](#span-text-stays-borrowed)), satisfying
constraint 3. The wrap/format logic — where a row breaks, what prefix a list item carries, which
style a span takes — lives once in `walk`, so measure and render are the same computation with
different side effects.

Parity is then structural, not a coincidence of matching arithmetic: `walk` alone decides every row
break, both emitters merely follow, and `Sink.text` clamps every write to the remaining width (it
never overflows a row or splits one `begin`/`end` across two physical rows). So the number of `end`
calls equals `Counter.count` equals the physical-row count regardless of whether `walk`'s width math
is flawless — imperfect math costs layout quality, never a parity assertion. `Entry.rows` is
non-fallible, so `markdown.rows` wraps `walk(Counter, …)` in `catch unreachable`; a `Counter` has no
sink and cannot fail.

`span` styling composes exactly as the existing painters do: within one row, emit
`color.apply(style)` → `sink.text(bytes)` → `color.apply(.reset)` per styled run, allowing several
styled runs between one `begin` and `end` (this is how `paint.box` already layers background +
foreground + reset in a single row). When a `tint` is set it substitutes each span's foreground
colour while its attributes still apply — see [Reasoning](#reasoning) for the exact rule.

### Span text stays borrowed

Inline markers are stripped by _slicing_, not copying: the span for `**bold**` is the source slice
between the markers; inline code is the slice between backticks. Most synthetic prefixes (`"- "`,
`"│ "`, the code-block indent, a rule fill) are static string literals. The one runtime prefix is
the ordered-list marker `N. ` (and its `start`-based renumbering); it is still allocation-free —
format it into a stack buffer, as `paint.ruleRow` already does with `var buffer: [32]u8`, or slice
the digits from the source. Nothing reaches for an allocator. `sink.text` canonicalises any stray
control bytes in the borrowed source, so model text still can never emit escapes (an existing
guarantee in `FEATURES.md`).

### Width-aware wrapping across spans

The one genuinely new mechanic is wrapping a logical line that carries inline style across physical
rows while preserving each span's style. `terminal.width.wrapper` wraps a single flat slice; it does
not know about spans. `walk` tracks the current display column and, when the next unit would
overflow `columns`, closes the row and reopens it continuing the same style context. Break on `\n`
and on width, never inside a grapheme cluster.

No new engine helper is needed: `terminal.width.truncate(span, n)` already returns the longest
grapheme-boundary prefix of `span` fitting `n` columns — `prefix.len` is the byte count and
`span[prefix.len..]` is the tail to carry to the next row. Do not reach into `width`'s private
`displayUnit`. Observe two disciplines the existing painters already follow:

- **Measure each span exactly as the sink accounts it.** Emit one `text` call per span; `Sink.text`
  writes a zero-width `U+200B` between consecutive calls to keep separately measured fragments from
  fusing into one grapheme (the "canonical text boundaries survive separate sink writes" behaviour),
  and that joiner is written but not counted. So measure each span with `ofText` and sum — never
  measure a concatenated logical line as one `ofText` and then emit it as several `text` calls,
  which would under-count at emoji-ZWJ or combining seams. The zero-width joiner does not affect
  `columns_written`, so it never trips `Sink.end`'s `columns_written <= columns` assertion.
- **Saturate, never assume.** A cluster wider than the whole budget survives `truncate` as a
  one-column replacement, so `ofText(truncate(x, n))` can exceed `n`; measure the _shown_ slice and
  subtract with `-|`, as `notice` and `boxLine` do.

**Guaranteed forward progress.** A prefix (a `│ ` quote border, a list marker, a nesting indent) can
equal or exceed the width — at `columns = 2` a blockquote's 2-column prefix leaves a `2 -| 2 = 0`
body budget, and a naive "while body remains, place `truncate(body, 0)`" loop makes zero progress
and hangs. No existing painter subtracts a prefix, so there is no precedent to copy, yet the
narrow-width tests below (widths 16, 3, 2 with list and quote fixtures) drive straight into it.
`walk` must give the body a budget of `@max(columns -| prefix_width, 1)` (or otherwise consume at
least one source cluster per row), so every row advances. Parity still holds because `walk` drives
both passes identically; the rule only prevents the hang and a possible row overflowing the prefix.

## Palette additions

Add these `color.Style` cases and their SGR in `src/ui/color.zig`, values taken from pi's dark
theme. Reuse existing entries where a colour already matches, to keep the palette small:

| Purpose                   | Style               | SGR                      | Note                  |
| ------------------------- | ------------------- | ------------------------ | --------------------- |
| Bold                      | `bold`              | `\x1b[1m`                | new                   |
| Italic                    | `italic`            | `\x1b[3m`                | new                   |
| Heading                   | `heading`           | `\x1b[38;2;240;198;116m` | new (`#f0c674`)       |
| Code-block body           | `code_block`        | `\x1b[38;2;181;189;104m` | new (`#b5bd68`)       |
| Link text                 | `link`              | `\x1b[38;2;129;162;190m` | new (`#81a2be`)       |
| Inline code, list bullet  | `accent_foreground` | `\x1b[38;2;138;190;183m` | **reuse** (`#8abeb7`) |
| Fence border, quote, rule | `muted_foreground`  | `\x1b[38;2;128;128;128m` | **reuse** (`#808080`) |
| Underline (H1, links)     | `underline`         | `\x1b[4m`                | new                   |

Combined looks (H1 = heading + bold + underline) emit several `color.apply` calls before the text
and a single `.reset` after — `Sink` permits stacking SGRs within a row.

## Markdown subset and styling

Support this subset; match the [reference table](#how-pi-does-it-reference) for each. Deliberately
**out of scope**: syntax highlighting inside code blocks (no highlight.js equivalent; render the
body in one `code_block` colour — this is exactly pi's fallback for unknown languages), tables
(defer; box-drawing tables are a large amount of width math for rare model output), and OSC-8
hyperlinks (render links as styled text, optionally with a trailing ` (url)`).

- **Headings** `#`…`######`: H1 heading+bold+underline, H2 heading+bold, H3–H6 heading+bold with the
  literal `### ` marker retained. No leading `#` on H1/H2. A blank row follows unless the next block
  is already blank.
- **Bold / italic / strikethrough**: inline, markers stripped, styled as above. Nesting (bold inside
  a heading) is not required in phase 1.
- **Inline code** `` `…` ``: accent colour, markers stripped, no background.
- **Fenced code blocks** ` ``` `: opening and closing fence lines in `muted_foreground` (keep the
  ` ``` ` and any language tag visible), each body line prefixed with a two-space indent and
  coloured `code_block`. No wrapping inside a code block beyond hard width truncation — code lines
  that exceed the width are truncated, not re-wrapped, to preserve alignment. Tolerate a missing
  closing fence (streaming): treat end-of-text as the close.
- **Blockquotes** `>`: each physical row prefixed `│ ` in `muted_foreground`; body italic in
  `muted_foreground`; wrap width reduced by the 2-column prefix.
- **Lists**: unordered `- `, ordered `N. ` (respect `start`), marker in `accent_foreground`; nesting
  indent 4 spaces per depth; continuation (wrapped) rows indent to the marker width. Task items add
  `[x] `/`[ ] `.
- **Horizontal rule** `---`/`***`/`___`: a `─` run to the width (cap ~80) in `muted_foreground`.
- **Links** `[t](u)`: text in `link` colour, underlined; if the display text differs from the URL,
  append ` (url)` in `muted_foreground`.
- **Paragraphs / soft breaks**: plain text wrapped to width; a blank line between paragraphs.

## Reasoning

`.thinking` currently renders whole-block `.dim`. Give it the same markdown rendering as `.model`,
but tinted so the reasoning reads as a muted, coherent block while still showing structure. Define
the tint precisely, because a naive "tint as base, element style on top, then reset" would let each
element's own foreground (heading/code/link/accent) override the tint and paint colourful headings
inside reasoning — the opposite of muted. The rule: **when `tint` is set it replaces every span's
foreground colour**, so heading, code, link, and accent spans all render in `tint`
(`muted_foreground`, matching pi's `thinkingText` `#808080`); attribute styles (bold, italic,
underline) and the structural prefixes/indents still apply on top, so a heading is still bold, a
list still has its bullet, a quote still has its border — just uniformly grey. Concretely, a span
carries an element foreground and a set of attributes; `tint` substitutes the foreground and leaves
the attributes. Note this changes `.thinking` from today's `.dim` _attribute_ to a grey _foreground_
— intended. Reasoning is also italicised wholesale (as pi does): the `Painter` applies italic
(`\x1b[3m`) to every reasoning span on top of the tint, so a reasoning block reads as uniformly
grey, italic, and structured. Markdown italic inside reasoning is then italic-on-italic — a visual
no-op, which is fine. The redacted-thinking placeholder (`[redacted thinking]`) is not markdown and
stays as-is.

## Integration

- `src/ui/block.zig`: in `Entry.rows`, replace the `.thinking, .model => terminal.width.rows(...)`
  arm with `markdown.rows(text.items, @max(columns, 1))`. In `Entry.render`, replace the two
  `paint.wrapped` arms with `markdown.render(placement, tint, text.items)` (`tint` null for
  `.model`, `.muted_foreground` for `.thinking`).
- The block-variant parity test already covers `.model`/`.thinking` with wrapping and blank lines;
  extend its fixtures with markdown-bearing text (headings, a fenced block, a list, inline emphasis)
  so parity is checked against real markdown at the narrow test widths (16, 3, 2). The narrow widths
  are the sharp edge: a two-column window with a list prefix or quote border must still yield the
  row count `rows` predicts and must not overflow `Sink.end`'s assertion.
- The "clipped block streams into a warmed frame without allocating" test guards constraint 3, but
  its fixture is plain `numberedLines` text — a `walk` that allocates only for a code block, nested
  list, or ordered-list renumbering would pass it untested. Extend that test (or add a sibling) so
  the block rendered under the failing allocator contains a heading, a fenced code block, and a
  nested list.
- Update `FEATURES.md`: the two lines under _The interface_ about answer/reasoning blocks should say
  the answer and reasoning render markdown. Tick any matching `BACKLOG.md` item if one is added.

## Testing

- **Parity** is the primary contract: every fixture must pass `rows(cols) == painted rows` at
  several widths including 1–3 columns. Model this on the existing block parity test.
- **Element rendering**: assert the emitted bytes contain the expected SGR for each element (a
  heading row carries `\x1b[1m` and the heading colour; a code fence body carries the code colour
  and the two-space indent; a list row carries the bullet in accent). Mirror the style of the "error
  feedback paints the red style and prefix" test.
- **Partial input**: render an unterminated code block, a dangling `**`, and a heading with no
  trailing newline; assert no panic and a sensible row count.
- **Clip**: a tall markdown block clipped by `skip` shows its bottom rows only, like the existing
  clip test.
- `markdown.zig`'s tests run because `block.zig` imports it and `block.zig` is reachable from
  `main.zig`; do **not** re-export `markdown` from `src/ui/root.zig` (re-exports are public-API
  only, and `markdown` is consumed solely by `block.zig`). `scripts/test-audit.sh` fails CI if a
  test file is unreachable or the ran/declared counts differ. After the work: `zig build`,
  `zig fmt --check build.zig src lib scripts`, `sh scripts/test-audit.sh`.

## Phasing

The value and the risk are unevenly distributed; ship in two phases so parity is proven on the easy
cases before the fiddly ones.

- **Phase 1 — block-level, whole-row styles.** Headings, fenced code blocks, blockquotes, lists,
  horizontal rules, plain paragraphs. Every physical row takes a single style (or a prefix + single
  style), so parity reduces to counting wrapped rows with adjusted widths — close to today's model
  and cheap to get right. This alone removes the ugliest artifacts (raw fences, `#` headings, bare
  `-` bullets).
- **Phase 2 — inline spans.** Bold, italic, strikethrough, inline code, links within a line. This is
  where multi-span rows and style-preserving wrapping come in. Land it behind the same parity tests,
  extended with inline fixtures.

## Decisions

Settled with the user; these fix scope, not architecture.

1. **Inline styling is in scope.** Build both phases in one effort: land phase 1 (block-level) as a
   checkpoint, then phase 2 (inline bold/italic/strikethrough/inline-code/links) on that proven
   foundation. See [Phasing](#phasing).
2. **Reasoning is tinted grey and italicised wholesale.** `tint = .muted_foreground` substitutes
   every span's foreground and the `Painter` also applies italic to every reasoning span. See
   [Reasoning](#reasoning).
3. **Tables deferred; links as styled text; OSC-8 deferred.** A table falls through to paragraph
   rendering (its `|`/`---` lines show as plain text). Links render as `link`-coloured underlined
   text with a trailing ` (url)` when the visible text differs from the URL. No OSC-8 clickable
   hyperlink: that would require extending the `Sink`'s SGR-only trusted-control boundary to pass a
   runtime URL, a separate, security-relevant feature.
4. **Reasoning gets full markdown structure via the shared renderer.** `.model` and `.thinking` call
   the same `markdown.render`, differing only by `tint` (and the always-on reasoning italic). There
   is no second, flatter renderer to build or keep in sync.
