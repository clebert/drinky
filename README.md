# Drinky

A terminal-native coding agent that keeps the conversation in normal scrollback.

Give Drinky a prompt. The model can read, search, and change files or run commands in the working
directory. Drinky talks to Anthropic and OpenAI, through a subscription login or an API key. Drinky
is written in Zig.

## Philosophy

Drinky has no third-party dependencies, so a human or a model can review the program and the Zig
standard library. Drinky keeps core rules in every session. It adds detailed harness guidance and
complete skill instructions only when a task needs them. This design keeps more context available
for the task.

## Features

- `/review` reviews every pending change from `HEAD` in bounded rounds. A reviewer finds defects, a
  judge settles them, and a fixer applies them. Each role can run its own account, model, and effort
  level. An empty editor lets the rounds run unattended, and typed text holds the review at the next
  boundary. The settlement of the judge waits for a read, and Esc finishes the review.
- Drinky streams the conversation into normal scrollback and reserves full-window pages for
  temporary views.
- Drinky accepts steering during a turn. A cancellation or a failure keeps the finished work. One
  key continues a failed turn.
- A path pattern can require a skill. Drinky sends the whole skill file on the first touch. It
  refuses a change to a matching file until the whole skill file stands in the conversation.
- Drinky describes itself. The model answers a question about the commands, the keys, and the
  settings from a generated document, never from memory.

See [`FEATURES.md`](FEATURES.md) for the complete capability overview.

## Build and run

Drinky requires Zig 0.16.0, a POSIX system, and the `HOME` variable. Drinky works best in a modern
terminal. The project uses [Ghostty](https://ghostty.org/) for development and testing.

Build the `ReleaseSafe` executable, then run it:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/drinky
```

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. You can also use `/login` for a subscription account.

## Slash commands

A line that starts with a slash runs in Drinky and reaches no model. Type `/` or `/help` for the
complete list. Each row names one command and states what it does, and Enter runs the picked one.
You can also ask Drinky to explain its own commands, keys, and settings.

- `/login` signs in. `/model` and `/effort` change the model and the reasoning effort.
- `/skill` picks a discovered skill. `/skill:name` loads one skill with an optional task.
- `/review` reviews the pending changes in bounded rounds with a reviewer, a judge, and a fixer.
- `/new` clears the conversation. `/system` shows the complete system prompt.

## Configuration

The `~/.drinky/config.json` file is optional. Ask the model to maintain the file directly. The model
can describe the harness itself: every command, every setting with its type, default, and meaning,
the keys of the prompt, of a running turn, and of a review, and the files that Drinky discovers.
Drinky applies changes at the next start.

Drinky reads `config.json` and never writes it, so the file stays yours. You can keep it in version
control. The machine-specific data lives in separate files. `~/.drinky/auth.json` holds the
credentials, and `~/.drinky/state.json` holds the last account, model, and effort level.
`~/.drinky/models.json` holds the model list of each account, and `~/.drinky/metadata.json` holds
the public facts of a vendor. The state file remembers the three choices per project, so a model
switch touches no configuration.

Drinky compiles no model in. It learns every model, limit, effort level, and price from the provider
and from OpenRouter, and it makes no request until you ask for one. Fetch a list from `/model`, then
pick the model to run.

## Provider access

API keys use the public provider APIs. Subscription login uses unsupported provider interfaces that
can change or stop working. See the [Anthropic implementation note](lib/ai/anthropic/root.zig) and
the [OpenAI implementation note](lib/ai/openai/oauth.zig).

Drinky is not affiliated with Anthropic or OpenAI.

## Security

The `AGENTS.md` files and the skills in a repository are model instructions. Drinky has no
permission gate or sandbox. Open an untrusted repository in a container.

## Name and inspiration

Drinky takes its name from Homer Simpson's drinking bird, which repeatedly presses `Y` on his remote
nuclear plant workstation.

Drinky takes inspiration for its terminal rendering model from
[pi](https://github.com/earendil-works/pi-mono).

## License

Drinky is available under the [MIT License](LICENSE).
