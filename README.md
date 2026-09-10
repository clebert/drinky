# Drinky

A dependency-free terminal coding agent you can read end to end.

Give Drinky a prompt in the terminal. The model can read, search, and change files or run commands
in the working directory. Drinky talks to:

- Anthropic
- OpenAI
- xAI
- OpenRouter
- Gemini Enterprise Agent Platform (Vertex AI)

Drinky is a single Zig program. It needs no Node.js runtime or third-party package tree, so a
complete review covers Drinky and the Zig standard library. Use Drinky as it is, or fork it and add
the features your workflow needs.

## Highlights

1. **Terminal-native:** The conversation stays in the normal scrollback. A session is the process,
   and Drinky saves no conversation to resume.
2. **Telegram remote control:** Attach a bot and drive the session from its chat, while the terminal
   shows the work.
3. **One job:** An agent loop and seven tools, with no sub-agents and no workflow mode.
4. **Small system prompt:** The compiled prompt states the mechanics. Your instruction files and
   skills carry every rule about how to work.
5. **Self-describing:** The model can read every command, setting, and key binding of Drinky, so it
   can maintain your config for you.
6. **No compiled-in models:** Every model, limit, and price comes from the provider at runtime.

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

## Sign in

An account reads `vendor-product-source`, and a model under it reads `account/model`, as in
`anthropic-sub-login/claude-opus-4-8`.

| Account                | Credential                                                   |
| ---------------------- | ------------------------------------------------------------ |
| `anthropic-sub-login`  | Claude Pro or Max login                                      |
| `anthropic-api-login`  | Anthropic Console login, which mints and stores an API key   |
| `anthropic-api-key`    | `ANTHROPIC_API_KEY`                                          |
| `openai-sub-login`     | ChatGPT login                                                |
| `openai-api-key`       | `OPENAI_API_KEY`                                             |
| `xai-sub-login`        | SuperGrok or X Premium login with a device code              |
| `xai-api-key`          | `XAI_API_KEY`                                                |
| `openrouter-api-login` | OpenRouter login, which mints and stores an API key          |
| `openrouter-api-key`   | `OPENROUTER_API_KEY`                                         |
| `google-cloud-keyfile` | `GOOGLE_APPLICATION_CREDENTIALS` and `GOOGLE_CLOUD_LOCATION` |

Run `/login` to sign in with a `login` account. Set the variable of a `key` account by hand. For
`google-cloud-keyfile`, set `GOOGLE_APPLICATION_CREDENTIALS` to an Agent Platform service account
key file and `GOOGLE_CLOUD_LOCATION` to `eu`, `us`, or `global`.

Drinky is not affiliated with Anthropic, OpenAI, xAI, OpenRouter, or Google.

## Slash commands

A line that starts with a slash runs in Drinky and reaches no model. Type `/` or `/help` to open the
complete command list.

- `/effort` — set the reasoning effort.
- `/login` — sign in or switch the account.
- `/model` — switch the model.
- `/new` — clear the conversation.
- `/remote` — attach a Telegram bot.
- `/skill` — pick a skill.
- `/skill:name` — load a skill.
- `/sources` — show the loaded instruction files and skills.
- `/status` — state the session.
- `/system` — show the complete system prompt.

## Telegram remote control

Create a bot with BotFather, run `/remote`, and paste the token. Drinky shows a pairing code, and
the private chat that sends it binds to the bot. A saved bot attaches with one pick.

While a bot is attached, the chat holds the input and the terminal shows the work. A message from
the chat runs as a prompt, or queues as steering during a turn. The chat mirrors every answer and
event, and one message per turn shows the state and holds a `Cancel turn` button. `/new`, `/effort`,
`/model`, `/help`, `/skill`, and `/status` run from the chat, and the other commands run in the
terminal alone. Every exit key in the terminal detaches the bot.

> On macOS, run `caffeinate -is` so the Mac stays awake.

The bot tokens live in the owner-only `~/.drinky/remote.json`, and Drinky talks to the Telegram Bot
API directly.

## Herdr

Inside a [Herdr](https://herdr.dev) pane, Drinky reports its state over the Herdr socket, so Herdr
can notify you when a turn ends or fails. The status line leaves the directory and the branch to the
Herdr pane label. This needs no setup.

## Configuration

The `~/.drinky/config.json` file is optional. It controls instruction files, request and bash
limits, required skills, a default effort level, and interface settings. Drinky reads the file only
at startup and never writes it. You can keep it in version control.

The config file holds no secrets. Credentials, project state, and cached model information live in
separate files under `~/.drinky/`.

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
