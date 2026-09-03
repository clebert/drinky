# Backlog

Four sections in priority order: bugs, improvements, features, ideas. A fix to existing behavior
outranks a new capability. Inside a section the top entry is the next one to do.

An entry is one line: a bold subject, an em dash, and one sentence. An italic note can follow it.
The note holds only what the implementer cannot re-derive from the code: an external constraint, a
decision already taken, or a dependency on another entry. Module layout and extension seams live in
`AGENTS.md`.

## How to maintain this file

- `TODO.md` is the inbox. It is git-ignored, and the user writes loose notes into it.
- Change this file only when the user asks for it, or to remove an entry that you landed. Never add,
  reorder, or reword an entry as a side task.
- Interview the user before you write. Use the `interview` skill and its form. Ask one question per
  message, and ask as many as you need. Stop when nothing is unclear. Never invent a priority.
- Delete an entry when it lands, and update `FEATURES.md`. Git history keeps the entry.
- Delete a promoted note from `TODO.md`, so the inbox holds unshaped notes alone.
- A feature line is the sentence that goes into `FEATURES.md` once it lands.
- An idea is one short line and carries no note. It is a placeholder against loss, not a plan.

## Bugs

## Improvements

- **Remove the bash deny list** — the `bash.deny` key, the check in the bash tool, and the
  `Denied commands` section of the system prompt go. _A pattern list states a boundary that a script
  or a `bash -c` passes, so Drinky states only a restriction that it can hold. The prose rule in an
  instruction file carries the habit guidance instead._
- **Show a model that no source describes** — such a model takes a disabled picker row that names
  what it lacks, and its selection opens the hint for the config key. _`Catalog.merge` returns null
  and the caller drops the model today, so it leaves the picker with no line. A picker row carries
  the selection role or the muted role alone, so the row needs a third role. The hint names the
  config key of the model metadata feature, so land that feature first._

## Features

- **Telegram remote control** — a session binds to a configured Telegram bot, so the user can send
  messages and run commands from a phone. _Drinky polls `getUpdates` with a long timeout and adds no
  dependency. A bot binds to one session, because an update offset is consume-once. A picker maps to
  an inline keyboard, so no command needs an argument grammar. A configured chat id gates every
  update, because the bot name is public and the session holds a bash tool._
- **Model metadata in the config** — the config describes a model that no provider and no OpenRouter
  entry describes, so the user can unblock any model. _The provider wins every field it states, the
  config wins over OpenRouter, and OpenRouter fills the rest. A later step can let Drinky write the
  entry for the user._
- **Read-only mode** — `/mode` switches between `Full` and `Read-only`, and the read-only mode sends
  no tool that changes the system, so the model never sees `write`, `edit`, or `bash`. _The system
  prompt core states the active mode in one sentence. The status line shows `Mode: Read-only` like
  the effort, a muted label and a value in the normal intensity. Nothing persists the mode, so every
  session starts in the full mode. A switch keeps the conversation and accepts one cold cache.
  Verify against each provider that a history with a call to a tool that the list no longer names
  passes, and clear the conversation on the switch otherwise._
- **Diff tool** — a `diff` tool shows the changes of the working tree against `HEAD` or the index as
  a unified diff, in the full mode and the read-only mode alike. _Drinky runs the git binary with a
  fixed argv and no shell, `--no-pager diff --no-ext-diff --no-textconv`, an optional `--cached`,
  and a path after `--`, so no flag of the model reaches git. Untracked files need a second step,
  because `git diff` skips them._
- **Fetch tool** — a `fetch` tool reads a web page or a file by URL with GET alone, turns HTML into
  text, and pages the result like `read`. _The HTTP client of the standard library serves it, so it
  adds no dependency. It follows a bounded number of redirects and caps the body. It reaches what
  the machine reaches, the same as `curl` in bash today. Search needs an external API and a key, so
  it stays out._
- **Headless mode** — Drinky answers one prompt with no terminal: text in, text out, with flags for
  the model and the effort level. _This is the base for any agent that Drinky drives itself._

## Ideas

- Restart the same prompt in a new session.
- Show tokens per second during a turn.
- Keep the request prefix byte-stable, so a local server reuses its prompt cache.
