# Backlog

This file holds the open direction of Drinky. An open item states what Drinky lacks, holds the facts
that an implementer cannot re-derive from the code, and names the trigger that makes the work due. A
line leaves this file when its trigger fires.

`TODO.md` is the inbox. It is git-ignored, and the user writes loose notes into it. Shape a note
into an item only when the user asks for it. Interview the user first with the `interview` skill,
and never invent a priority or a trigger. Delete the note from `TODO.md` once its item stands here.
An idea is one line without a trigger. It is a placeholder against loss, and it leaves when it
becomes an open item or when the user drops it.

## Open items

- Drinky can abort after a sleep or a network change of macOS while a Telegram bot is attached. One
  terminal trace names errno 49, and one crash report names `EBADF` with `SIGABRT`. Their relation
  stays unproven. A fix in the standard library outranks a workaround in Drinky. Trigger: another
  occurrence with its terminal trace, its exit status, and its crash report.
- A reasoning passage of `anthropic-api/claude-fable-5-1` showed three blank rows where one
  paragraph separator belongs. A transcript copy cannot tell doubled block-boundary newlines from an
  invisible Unicode byte. Trigger: a capture of the raw SSE frames of such a passage.
- A model that no source describes leaves the picker with no row, because `Catalog.merge` returns
  null and the caller drops the model. A disabled row that names what the model lacks needs a third
  row role beside selection and muted, and its hint names the config key of the model metadata.
  Trigger: the model metadata in the config.
- The config describes no model. A `models` entry describes a model that no provider and no
  OpenRouter entry describes, so the user can unblock any model. The provider wins every field it
  states, the config wins over OpenRouter, and OpenRouter fills the rest. The `provider` field of an
  entry names a provider or a configured server, so one flat array serves both, and the other fields
  take the names of the `models.json` shape. A later step can let Drinky write the entry for the
  user. Trigger: a model of daily use that no source describes.
- The config names no server. A `servers` entry names a server that speaks Chat Completions, so
  Drinky talks to a model on llama.cpp, Ollama, vLLM, or a cloud endpoint with a key. One account
  with the label "OpenAI Compatible" covers every server, and the server name prefixes the model
  name, as in `ollama/qwen3:32b`. A metadata entry of a server model holds the server name in
  `provider` and the bare id in `name`. A `servers` entry holds a name, a base URL up to `/v1`, and
  an optional `api_key_env`, so the file holds no secret. The load refuses a server that has the
  name of a provider. The fetch reads `/v1/models` for the id alone, visits every server in parallel
  inside one window, keeps every list that arrived, and names each server that did not. The stream
  carries reasoning as `reasoning_content` on llama.cpp, vLLM, and DeepSeek, as `reasoning` on
  Ollama, or as inline `<think>` tags, and the decoder reads all three. The replay sends the text
  back under the field name of the stream, and it covers only the messages after the latest user
  message, because the vendors that document interleaved thinking ask for that scope. A tag stream
  goes back inside `content` with its tags. The replay keys on the server and not on the account,
  because one account spans every server. The wire sends `reasoning_effort` only when the request
  names a level. The account goes first among the accounts without a login. A server states no
  window, so this item needs the model metadata in the config. Trigger: an account row that the
  config supplies.
- Drinky needs a terminal. A headless mode answers one prompt with no terminal: text in, text out,
  with flags for the model and the effort. It is the base for any agent that Drinky drives itself.
  Trigger: the first agent that Drinky drives itself.
- `/prompt` opens the prompt history as an editable picker in the terminal and as an inline keyboard
  in Telegram, where a selection starts its saved prompt at once. Plain Telegram messages that start
  a turn enter the history, and steering messages and skill commands stay out. Trigger: the return
  of the prompt history.
- A canceled turn in Telegram offers `Revise`, which removes that turn from the conversation and
  waits for the next Telegram message. The offer has no `Keep` button, so a new message or `/new`
  keeps the canceled turn and dismisses the offer. The chat keeps the original messages and
  reactions, and the canceled summary states `Removed from conversation`. A stale tap reports that
  the revision is unavailable. After `write`, `edit`, or `bash`, the first tap warns that tool
  changes stay, and the second tap removes the turn. Trigger: the return of the removal of a
  canceled turn.
- The retry adds no jitter, so two sessions that fail together repeat together. Trigger: an account
  that limits the rate of a burst.
- The transport reads the seconds form of `Retry-After` alone, so a date form falls back to the
  backoff. Trigger: a reply that states a date.

## Ideas

- Restart the same prompt in a new session.
- Show tokens per second during a turn.
- Keep the request prefix byte-stable, so a local server reuses its prompt cache.
- Read the window of a server model from the native endpoint of its server.
- Run the FrontierHarness Eval tasks through a Harbor agent adapter.
- Let the user add optional task text after a skill selection in Telegram.
- Name an OpenRouter preset as a model.
- Send the OpenRouter app attribution headers behind an opt-in.
- State the dropped rows when a chat keyboard cannot hold a whole picker.
