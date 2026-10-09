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

Drinky is a single Zig program. It needs no Node.js runtime or third-party package tree, so a
complete review covers Drinky and the Zig standard library. Use Drinky as it is, or fork it and add
the features your workflow needs.

## Highlights

1. **Terminal-native:** The conversation stays in the normal scrollback. A session is the process,
   and Drinky saves no conversation to resume.
2. **One job:** An agent loop and a small set of tools, with no workflow mode. A skill or an
   instruction file can tell an agent to start another agent with `drinky run`.
3. **Small system prompt:** The compiled prompt states the mechanics. Your instruction files and
   skills carry every rule about how to work.
4. **Self-describing:** The model can read every slash command, config key, and key binding of
   Drinky, so it can maintain your config file for you.
5. **No compiled-in models:** Every model comes from the provider at runtime, and every limit and
   price from the provider or the public metadata.

## Build and run

Drinky requires Zig 0.17.0, a POSIX system, and the `HOME` variable. A terminal with the Kitty
keyboard protocol and grapheme cluster processing gives the best experience. The project uses
[Ghostty](https://ghostty.org/) for development and testing.

Build and run the executable in the `safe` optimization mode:

```sh
zig build -Doptimize=safe
./zig-out/bin/drinky
```

## Sign in

An account reads `vendor-product`, and a model under it reads `account/model`, as in
`anthropic-plan/claude-opus-4-8`. A `-key` suffix marks a credential that an environment variable
holds or names.

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

Run `/login` to sign in with an account that has no `-key` suffix. A successful sign-in opens its
model or author list. The first row fetches or refreshes that list. Drinky puts the cursor on the
remembered model or OpenRouter author when that row is available. Only an active model appears as
current. Set the variable of a `-key` account by hand. For `google-cloud-key`, set the Agent
Platform service account key file in `GOOGLE_APPLICATION_CREDENTIALS`. Set `GOOGLE_CLOUD_LOCATION`
to `eu`, `us`, or `global`.

Drinky is not affiliated with Anthropic, OpenAI, xAI, OpenRouter, DeepSeek, or Google.

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

Use `/compact` to toggle Full and Compact transcript modes, even during a turn. Compact mode hides
thinking text behind a summary with received bytes, elapsed time, and status. It removes the padding
inside boxes. The gaps between transcript blocks stay. Each toggle clears terminal scrollback and
repaints the complete transcript without a warning. Full mode restores the thinking text and the box
padding. The transcript keeps thinking after a cancellation or failure, without changing the model
conversation. Compact mode also preserves the complete transcript when an update requires a terminal
reset.

Set `interface.transcript_mode` to `"compact"` or `"full"` in the config file to select the startup
mode. The default is `"full"`. The command changes only the current session and never writes the
config file.

## Headless mode

`drinky run` answers one prompt without a terminal. It reads the prompt from stdin and writes the
text of the final reply to stdout. The `--model` flag takes an `account/model` value. The `--effort`
flag takes `low`, `medium`, `high`, `xhigh`, or `max`, and Drinky uses the nearest level that the
model takes.

```sh
drinky run --model openai-plan/gpt-5.5 --effort high <<'EOF'
Review the uncommitted changes.
EOF
```

`drinky models` lists the `account/model` values of each signed-in account with a saved model list.
Fetch a list with `/model` first. A run uses the config file, the instruction files, the skills, and
the tools of a session. Its skill list leaves out each skill that sets `drinky-run: hidden` in the
block map of its `metadata`. It saves no choice and signs in to no account. A failure of the run
goes to stderr, and the exit code is then 1. A run that stops at a limit also fails, but its last
reply text still reaches stdout. A run drops the start reports of a session, such as an unknown
config key or an instruction file that Drinky cannot read.

Each command of the `bash` tool gets `DRINKY_MODEL` with the `account/model` value of the session.
It also gets `DRINKY_EFFORT` with the effort level that you chose. Both follow `/model` and
`/effort`, so an agent can start a run with its own model and effort.

A run sets `DRINKY_RUN` for its commands, and Drinky refuses to start a run where that variable is
set. An agent can start a reviewer, but the reviewer cannot start another agent.

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
