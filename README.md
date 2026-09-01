# Drinky

A dependency-free coding agent you can own end to end.

Give Drinky a prompt in the terminal. The model can read, search, and change files or run commands
in the working directory. Drinky talks to Anthropic and OpenAI, through a subscription login or an
API key.

## Philosophy

Drinky is a dependency-free Zig program. It needs no Node.js runtime or third-party package tree. A
complete review covers Drinky and the Zig standard library.

Use Drinky as it is, or fork it and add the features your workflow needs.

## Highlights

1. **Terminal-native interface:** The conversation stays in scrollback.
2. **User control:** Steering and failures never discard finished work.
3. **Focused context:** Harness guidance and skill instructions load only when needed.
4. **Dynamic model catalog:** Drinky fetches current model information from providers only when you
   request it.

See [`FEATURES.md`](FEATURES.md) for the complete capability overview.

## Build and run

Drinky requires Zig 0.16.0, a POSIX system, and the `HOME` variable. A modern terminal gives the
best experience. The project uses [Ghostty](https://ghostty.org/) for development and testing.

Build and run the `ReleaseSafe` executable:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/drinky
```

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. You can also use `/login` for a subscription account.

## Slash commands

A line that starts with a slash runs in Drinky and reaches no model. Type `/` or `/help` to open the
complete command list. You can also ask Drinky to explain its commands, keys, and settings.

- `/login` signs in. `/model` and `/effort` change the model and the reasoning effort.
- `/skill` picks a discovered skill. `/skill:name` loads one skill with an optional task.
- `/new` clears the conversation. `/system` shows the complete system prompt.

## Configuration

The `~/.drinky/config.json` file is optional. It controls instruction files, request limits, denied
shell commands, required skills, and interface settings. Drinky reads the file only at startup and
never writes it. You can keep it in version control.

Ask the model to explain or maintain the file. The model can request a generated reference for every
command, setting, key binding, and discovery rule.

The config file holds no secrets. Credentials, project state, and cached model information live in
separate files under `~/.drinky/`.

## Provider access

API-key accounts use the public provider APIs. Subscription accounts use unsupported provider
interfaces that can change or stop working. See the implementation notes for
[Anthropic](lib/ai/anthropic/root.zig) and [OpenAI](lib/ai/openai/oauth.zig).

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
