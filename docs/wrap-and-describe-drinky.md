# Wrap machinery and the `describe_drinky` tool

**Temporary document. Delete it before you commit the work that it describes.** It holds the
decisions of one interview, because the chat keeps no state.

## Stages

1. Renderer: the wrap in `ui.paint.notice`, the one-row mode of its two exceptions, the six cut
   marks, the caption counters in `ui.Picker`, and the header count in `ui.Page`.
2. Intro line: the segment constant and the re-append after `/new`.
3. Tool and documents: the rename, the document, the system prompt sentence, `README.md`, and
   `FEATURES.md`.

## Intro line

The exact segments, in this order:

```
Enter: Send · Shift+Enter: New line · Esc: Cancel · Ctrl+C: Clear · Ctrl+D: Quit · /help: Commands
```

- The line measures 98 columns. `Ctrl+C twice: Quit` leaves the legend, and the document keeps it.
- The `/help` pointer stays last. It closes the legend, and `Enter: Send` stays first.
- The line wraps. No segment ever goes away.
- A row breaks at a separator first. One separator is a blank, a `·`, and a blank. A break drops all
  three, so no row starts or ends with a separator.
- A piece that is still too wide then breaks between words. So a hint never splits, and a sentence
  never loses its tail. A word wider than the whole row breaks inside itself, as the wrapper does
  today.
- The line re-wraps at every paint, against the current width. Every neighbour block reflows too.
- `/new` re-appends the intro line. It does not re-append the startup counts line.

## One wrap machinery

Every caller of `ui.paint.notice` wraps: the intro line, the startup counts line, every transcript
event, the skill head line, the hint row above the editor, and the picker caption. One rule serves
all of them, because the two break steps above cover a legend and a sentence together. The row
counters must match the render, in `ui.block.Entry.rows`, in `layout.Component.measure`, and in
`ui.Picker.captionRows` with `ui.Picker.rows`. `ui.Picker.titleRows` takes no width today, so it
needs one.

The picker caption takes the same rule as the hint row above the editor, because both occupy the
region above the input. Its title and its key hint each wrap. The comment at `ui/Picker.zig:162`
states the opposite today and must change. A caption that grows adds its rows above the framed list,
which `ui.paint.bodyLimit` bounds on its own.

An error event wraps like every other event. The transcript is the place where the whole sentence
must stay readable.

A notice prefix, such as `Error: `, stands on the first row of one notice only. Every later row
starts at the first column, whether the wrap made it or a line break in the text did. Two prefixes
read as two errors, and an indent puts blanks into a copied line.

Two callers are the exception, and both keep one row and truncate.

The footer notice keeps one row because `layout.Component.measure` reports exactly 1 row for
`.status`. A footer that grows moves the editor, and a moving interface is worse than a cut
sentence.

The steering hint row keeps one row because every row of the steering block keeps one row. Its key
stands first, so a cut takes the explanation and never the key. `ui.paint.steeringRows` therefore
stays the constant count of `messages.len + 1`.

A tool box and the status line stay out. A box keeps one row per line, so its height follows its
state and never the length of its arguments. The status line is the bottom anchor and owns the
shorten-then-drop ladder.

## Every cut marks its cut

`ui.paint.cut` already reserves the column of the mark. These six sites cut silently today, and each
one must take the mark. The column names the call site:

| Site                 | Call site             |
| -------------------- | --------------------- |
| Footer notice        | `ui/status.zig:164`   |
| Steering message row | `ui/paint.zig:662`    |
| Steering hint row    | `ui/paint.zig:675`    |
| Status left line     | `ui/status.zig:202`   |
| Markdown table cell  | `ui/markdown.zig:290` |
| Markdown plain row   | `ui/markdown.zig:798` |

The footer notice and the steering hint row both cut inside `ui.paint.notice`, at
`ui/paint.zig:174`. The wrap must therefore take an explicit one-row mode for those two callers.

A tool box, a picker option, and the short branch already mark the cut. They stay as they are.

A steering message row keeps one row, and it keeps the first line of the queued message alone, as it
works today. The mark then states the width cut. The block stands between the tool boxes and the
editor, and both of those neighbours keep one row per item too.

A long table cell cuts. A wrapped cell needs a grid row as tall as its tallest cell, and the row
counter must agree with the render. A narrow window already falls back to plain text.

A long code row cuts. Code keeps its alignment, and both a cut and a wrap break a copied line.

## Pages

The page header wraps at its separators, like the intro line. A cut header can hide the key that
closes the page. The constant 1 for the header row becomes a width-aware count in `ui.Page`, in
`bodyRows`, in the two body offsets, in the source row line, and in the PgUp and PgDn steps.

The page body already wraps, both rendered and source.

The `/colors` page stays as it is. It is a debugging page, and a clipped sample shows its own cut.
Its rows write span by span, so a mark needs a width budget in every sample function.

## Audit

After this work every element takes one of three patterns. The list is complete, so a later reader
needs no second audit.

- **Wrap**, for text whose meaning needs every word: the intro line, the counts line, every
  transcript event, the skill head line, the hint row above the editor, the picker caption, the page
  header, the user box, the editor rows, the model and reasoning markdown, and the page body.
- **One row and a mark**, for an element whose height must stay stable: the tool box, both steering
  rows, the picker option, the markdown table cell, the markdown code row, and the footer notice.
- **Shorten, then drop**, for a line whose parts differ in value: the status line, and the input
  separator label, which goes from `↑ Hidden: 3` to `↑3` and then away. It works this way today.

The `/colors` page is the one exception. It keeps its silent clip.

A silent clip can hide anywhere, because `terminal.View.Sink.text` fits every write to the columns
that the row has left. A search for a cut function therefore finds no such site. Read the writes.

## The `describe_drinky` tool

`describe_config` becomes `describe_drinky`. It takes no parameter and returns one document with one
section per topic. The host owns the text, as it owns the config document today.

Sections:

- **Commands.** Generated from the registry table in `ai.command`, which already carries a summary
  per command. `/skill:name` takes its task as trailing text.
- **Config keys.** The document that `Config.document` builds today.
- **Key bindings.** The five intro segments, from the same constant. Then the turn controls: Ctrl+P
  recall, Ctrl+N retry, the two-press Esc, and the two-press Ctrl+D. Then the double Ctrl+C rule.
- **Discovery.** `AGENTS.md` from the Git root down to the working directory. Skills in
  `~/.agents/skills/` and in `.agents/skills/` from the Git root down. The `SKILL.md` name, the
  `name` and `description` front matter, and the one-`read` size cap.
- **Repository.** `https://github.com/clebert/drinky`, with the note that the source answers a
  question that the document does not.

The system prompt core takes one sentence: answer a question about Drinky itself from the tool, and
not from memory. A tool description alone does not stop a model from answering from its priors.

The discovery rules cannot live in the config document, because they carry no key. The system prompt
names a discovered path, but never the rule, and both sections disappear in a fresh project.

## Documents

- `README.md` holds a new Slash commands section already. Add one sentence there that Drinky can
  explain its own commands, keys, and settings.
- `README.md` Configuration paragraph names the old, narrower tool. Widen it.
- `FEATURES.md` needs lines for the wrap rule, the cut marks, and the renamed tool. The intro line
  loses `Ctrl+C twice: Quit` there too, and the `/new` line must state that the intro line returns.
