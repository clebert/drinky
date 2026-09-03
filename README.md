# Drinky

A dependency-free coding agent you can own end to end.

Give Drinky a prompt in the terminal. The model can read, search, and change files or run commands
in the working directory. Drinky talks to Anthropic and OpenAI, through a subscription login, an
Anthropic Console login, or an API key, and to Gemini on Google Vertex AI through a service account
key file.

## Philosophy

Drinky is a dependency-free Zig program. It needs no Node.js runtime or third-party package tree. A
complete review covers Drinky and the Zig standard library.

Drinky does one job: it runs an agent loop with a small set of file and shell tools. It ships no
sub-agents, no workflow mode, and no opinion about how the model does its work. Those rules live in
your instruction files, where you can read and change them.

Use Drinky as it is, or fork it and add the features your workflow needs.

## Highlights

1. **Terminal-native:** The conversation stays in the normal scrollback. A session is the process,
   and Drinky saves no conversation to resume.
2. **One job:** An agent loop and seven tools, with no sub-agents and no workflow mode.
3. **Small system prompt:** The compiled prompt states the mechanics. Your instruction files and
   skills carry every rule about how to work.
4. **Self-describing:** The model can read every command, setting, and key binding of Drinky, so it
   can maintain your config for you.
5. **No compiled-in models:** Every model, limit, and price comes from the provider at runtime.

See [`FEATURES.md`](FEATURES.md) for the complete capability overview.

## Build and run

Drinky requires Zig 0.16.0, a POSIX system, and the `HOME` variable. A terminal with the Kitty
keyboard protocol and grapheme cluster processing gives the best experience. The project uses
[Ghostty](https://ghostty.org/) for development and testing.

Build and run the `ReleaseSafe` executable:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/drinky
```

Run `/login` to sign in with a subscription account or an Anthropic Console account. The Console
login mints an API key in the browser and stores it, so no environment variable is needed. You can
also set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` by hand. For Gemini on Google Vertex AI, set
`GOOGLE_APPLICATION_CREDENTIALS` to a service account key file and `GOOGLE_CLOUD_LOCATION` to `eu`,
`us`, or `global`. Drinky serves Gemini 3 and later.

Inside a [Herdr](https://herdr.dev) pane, Drinky reports its state over the Herdr socket, so Herdr
can notify you when a turn ends or fails. The status line leaves the directory and the branch to the
Herdr pane label. This needs no setup.

## Slash commands

A line that starts with a slash runs in Drinky and reaches no model. Type `/` or `/help` to open the
complete command list. You can also ask Drinky to explain its commands, keys, and settings.

- `/login` signs in. `/model` and `/effort` change the model and the reasoning effort.
- `/skill` picks a discovered skill. `/skill:name` loads one skill with an optional task.
- `/new` clears the conversation. `/system` shows the complete system prompt.

## Configuration

The `~/.drinky/config.json` file is optional. It controls instruction files, request and bash
limits, required skills, a default effort level, and interface settings. Drinky reads the file only
at startup and never writes it. You can keep it in version control.

Ask the model to explain or maintain the file.

The config file holds no secrets. Credentials, project state, and cached model information live in
separate files under `~/.drinky/`.

## Provider access

API-key accounts use the public provider APIs. Subscription accounts use unsupported provider
interfaces that can change or stop working. The Anthropic Console account sits between them. Its key
bills at API rates and uses the public API, but the login that mints it is unsupported. See the
implementation notes for [Anthropic](lib/ai/anthropic/root.zig) and
[OpenAI](lib/ai/openai/oauth.zig).

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
