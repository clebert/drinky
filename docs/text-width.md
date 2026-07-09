# The text display-width problem

The single hardest primitive in a TUI is: how many terminal columns does a string occupy when
printed? Everything else (wrapping, truncation, cursor placement) depends on it. This is hard for
everyone, because correct answers require Unicode data.

## What "width" actually needs

- **Grapheme cluster segmentation** — a user-perceived character can be many codepoints (base +
  combining marks, ZWJ emoji sequences, flags).
- **East Asian Width** — CJK ideographs, fullwidth forms, etc. are 2 cells wide.
- **Zero-width** — combining marks, control and default-ignorable codepoints are 0 cells.
- **Emoji presentation** — variation selector-16 (`U+FE0F`) forces emoji (2 cells); VS15
  (`U+FE0E`) forces text (1 cell); skin-tone modifiers and ZWJ sequences collapse to one 2-cell
  cluster.

## Even pi cannot do this from the runtime alone

pi's `visibleWidth` uses the JS runtime's `Intl.Segmenter` for grapheme clustering **plus** a
Unicode data-table dependency (`get-east-asian-width`) **plus** `\p{...}` property regexes and an
RGI_Emoji regex. It strips ANSI escapes first, has an ASCII fast path, and caches results. The
takeaway: correct width is impossible without Unicode tables.

## The situation in Zig

- **Zig std gives you UTF-8 decode/encode only.** `std.unicode` has no grapheme segmentation, no
  East Asian Width, and no display-width function. The stdlib does not solve this.
- **The correct dependency is `zg`** (Codeberg `atman/zg`, formerly ziglyph, which is now
  deprecated in its favor). It exposes `Graphemes` + `DisplayWidth`, bundles the Unicode 16 tables
  inline, and in recent versions needs no allocator — `DisplayWidth.strWidth(s)` is effectively a
  free function. Its "terminal of record" is Ghostty, which matches our target exactly. Pin the tag
  to the Zig version (zg v0.16.x targets Zig 0.15.2+; use an older zg tag for older Zig).
- **The zero-dependency shortcut exists, with a catch:** hand-roll a `wcwidth`-style interval table
  that returns 0/1/2 per codepoint (one file plus a generated table, like Ghostty's own
  `src/unicode`). Tiny and fast. Trade-off: no grapheme clustering, so ZWJ emoji, VS16, and
  combining sequences mis-count; and the table goes stale each Unicode release.

## The nuance that helps us: match the terminal, not the abstract spec

Modern terminals themselves use **per-codepoint** width tables by default. Ghostty/kitty only switch
to grapheme-cluster width when DEC private mode **2027** is negotiated (or kitty's newer text-sizing
protocol is used). So if we target Ghostty in its default mode, a per-codepoint `wcwidth` table
**agrees with what the terminal actually does** — summing per-codepoint widths is the correct
answer there. Grapheme-cluster width only becomes both necessary and correct once mode 2027 is
enabled.

## Decision for pith

Start with a **hand-rolled `wcwidth` interval table** — zero dependencies, agrees with default-mode
terminals, roughly one small module plus generated data. Correct for ASCII, Latin, code, and CJK. It
mis-measures emoji; accept that for now.

If/when emoji correctness matters, add **`zg`** as the one dependency worth taking. Do not try to
out-engineer Unicode by hand.

Wherever width is computed: strip ANSI escapes before measuring, and remember width is needed in
three places — wrapping, truncation, and computing the cursor column.

## Sources

- Zig `std.unicode` (0.14.0 / 0.15.1): only `utf8*` / `utf16*` / `wtf8*`; no grapheme/width.
- `zg`: <https://codeberg.org/atman/zg> — modules `Graphemes`, `DisplayWidth`; Unicode 16.0.0;
  build options `cjk`, `c0_width`, `c1_width`; treats Ghostty as terminal of record.
- ziglyph deprecation notice: <https://codeberg.org/dude_the_builder/ziglyph>.
- Ghostty width table and its caveat about grapheme-cluster rules / mode 2027:
  <https://github.com/ghostty-org/ghostty> (`src/unicode/main.zig`, `src/terminal/modes.zig`).
- kitty text-sizing protocol (client sends explicit cell counts):
  <https://github.com/kovidgoyal/kitty> (`docs/text-sizing-protocol.rst`).
