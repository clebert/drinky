# Drinky

A dependency-free terminal coding agent you can read end to end.

Give Drinky a prompt in the terminal. The model can read, search, and change files or run commands
in the working directory. Drinky talks to:

- Anthropic
- OpenAI
- xAI
- OpenRouter
- DeepSeek
- Gemini Enterprise Agent Platform (Vertex AI)
- [DwarfStar](https://github.com/antirez/ds4) (local)

Drinky is a single Zig program. It needs no Node.js runtime or third-party package tree, so a
complete review covers Drinky and the Zig standard library. Use Drinky as it is, or fork it and add
the features your workflow needs.

## Highlights

1. **Terminal-native:** The conversation stays in the normal scrollback. A session is the process,
   and Drinky saves no conversation to resume.
2. **One job:** An agent loop and a small set of tools, with no sub-agents and no workflow mode.
3. **Small system prompt:** The compiled prompt states the mechanics. Your instruction files and
   skills carry every rule about how to work.
4. **Self-describing:** The model can read every command, config key, and key binding of Drinky, so
   it can maintain your config file for you.
5. **No compiled-in models:** Every model comes from the provider at runtime, and every limit and
   price from the provider or the public metadata.

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

An account reads `vendor-product`, and a model under it reads `account/model`, as in
`anthropic-plan/claude-opus-4-8`. A `-key` suffix marks a credential that an environment variable
holds or names. The local `ds4` account is the exception: it has no product and no credential.

| Account              | Credential                                                   |
| -------------------- | ------------------------------------------------------------ |
| `anthropic-plan`     | Claude Pro or Max login                                      |
| `anthropic-api`      | Anthropic Console login, which mints and stores an API key   |
| `anthropic-api-key`  | `ANTHROPIC_API_KEY`                                          |
| `openai-plan`        | ChatGPT login                                                |
| `openai-api-key`     | `OPENAI_API_KEY`                                             |
| `xai-plan`           | SuperGrok or X Premium login with a device code              |
| `xai-api-key`        | `XAI_API_KEY`                                                |
| `openrouter-api`     | OpenRouter login, which mints and stores an API key          |
| `openrouter-api-key` | `OPENROUTER_API_KEY`                                         |
| `deepseek-api-key`   | `DEEPSEEK_API_KEY`                                           |
| `google-cloud-key`   | `GOOGLE_APPLICATION_CREDENTIALS` and `GOOGLE_CLOUD_LOCATION` |
| `ds4`                | none                                                         |

Run `/login` to sign in with an account that has no `-key` suffix. A successful sign-in opens its
model or author list. The first row fetches or refreshes that list. Drinky puts the cursor on the
remembered model or OpenRouter author when that row is available. Only an active model appears as
current. Set the variable of a `-key` account by hand. For `google-cloud-key`, set the Agent
Platform service account key file in `GOOGLE_APPLICATION_CREDENTIALS`. Set `GOOGLE_CLOUD_LOCATION`
to `eu`, `us`, or `global`. For `ds4`, set `DS4_BASE_URL` to the local base URL, ending at `/v1`.

Drinky is not affiliated with Anthropic, OpenAI, xAI, OpenRouter, DeepSeek, Google, or DwarfStar.

## Cost display

The status line shows the session cost as an estimate, as in `~$0.42`, and the tilde marks it.
Drinky prices the tokens of the session at the public rates of the model. When a reply states its
charge, as an OpenRouter reply does, Drinky takes that charge. The figure is informational, and it
is not a bill. A subscription account pays no per-token price at all, and Drinky still prints the
figure as an orientation about the weight of a session. Drinky never sees the bill.

The context gauge, the quota window, and the credit pool are different. Each one reports what the
provider states.

## Slash commands

A line that starts with a slash runs in Drinky and reaches no model. Type `/` or `/help` to open the
complete command list. Drinky refuses an unknown command, an unknown skill, and a command with an
argument. A second Enter then sends the refused line to the model as a message.

## Herdr

Inside a [Herdr](https://herdr.dev) pane, Drinky reports its state over the Herdr socket, so Herdr
can notify you when a turn ends. The status line leaves the directory and the branch to the Herdr
pane label. This needs no setup.

## Config file

The `~/.drinky/config.json` file is optional. It controls instruction files, request and bash
limits, required skills, a default effort level, and the interface. Drinky reads the file only at
startup and never writes it. You can keep it in version control.

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
