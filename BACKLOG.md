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

- **Show a model that no source describes** — such a model takes a disabled picker row that names
  what it lacks, and its selection opens the hint for the config key. _`Catalog.merge` returns null
  and the caller drops the model today, so it leaves the picker with no line. A picker row carries
  the selection role or the muted role alone, so the row needs a third role. The hint names the
  config key of the model metadata feature, so land that feature first._

## Features

- **Model metadata in the config** — the config describes a model that no provider and no OpenRouter
  entry describes, so the user can unblock any model. _The provider wins every field it states, the
  config wins over OpenRouter, and OpenRouter fills the rest. The `provider` field of an entry names
  a provider or a configured server, so one flat `models` array serves both. The other fields of an
  entry take the names of the `models.json` shape. A later step can let Drinky write the entry for
  the user._
- **OpenAI-compatible servers** — the config names servers that speak Chat Completions, so Drinky
  talks to a model on llama.cpp, Ollama, vLLM, or a cloud endpoint with a key. _One account with the
  label "OpenAI Compatible" covers every server. The server name prefixes the model name, as in
  `ollama/qwen3:32b`. A metadata entry of a server model holds the server name in `provider` and the
  bare id in `name`. A `servers` entry holds a name, a base URL up to `/v1`, and an optional
  `api_key_env`, so the file holds no secret. The load refuses a server that has the name of a
  provider. The fetch reads `/v1/models` for the id alone. It visits every server in parallel inside
  one window. It keeps every list that arrived and names each server that did not. The stream
  carries reasoning as `reasoning_content` on llama.cpp, vLLM, and DeepSeek, as `reasoning` on
  Ollama, or as inline `<think>` tags. The decoder reads all three. This replay sends the text back
  under the field name of the stream. It covers only the messages after the latest user message,
  because the vendors that document interleaved thinking ask for that scope. A tag stream goes back
  inside `content` with its tags. The replay keys on the server, not on the account, because one
  account spans every server. The wire sends `reasoning_effort` only when the request names a level.
  The account goes first among the accounts without a login. This entry depends on the metadata
  entry, because a server states no window._
- **Headless mode** — Drinky answers one prompt with no terminal: text in, text out, with flags for
  the model and the effort level. _This is the base for any agent that Drinky drives itself._
- **Telegram remote control** — a session attaches to a Telegram bot, so the user drives it from the
  chat while the terminal shows the work. _`docs/telegram-remote.md` holds the decisions and the
  phases. Drinky adds no dependency._

## Ideas

- Restart the same prompt in a new session.
- Show tokens per second during a turn.
- Keep the request prefix byte-stable, so a local server reuses its prompt cache.
- Read the window of a server model from the native endpoint of its server.
- Run the FrontierHarness Eval tasks through a Harbor agent adapter.
