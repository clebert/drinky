# Drinky

A terminal-native coding agent that keeps the conversation in normal scrollback.

Give Drinky a prompt. The model can read, search, and change files or run commands in the working
directory. Drinky is written in Zig and has no third-party dependencies.

## Features

- Drinky streams the conversation into normal scrollback and reserves full-window pages for
  temporary views.
- Drinky accepts steering during a turn and keeps completed work visible after a cancellation or
  retry.
- Drinky connects to Anthropic and OpenAI through a subscription login or an API key.
- Drinky loads repository instructions and skills on demand, and can require skills for selected
  paths.

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
- `/new` clears the conversation. `/system` shows the complete system prompt.

## Configuration

The `~/.drinky/config.json` file is optional. Ask Drinky to maintain the file directly. The agent
can describe the harness itself: every command, every setting with its type, default, and meaning,
the keys of the prompt and of a running turn, and the files that Drinky discovers. Drinky applies
changes at the next start.

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
