# Drinky

A dependency-free terminal coding agent.

<img src="www/drinky.png" alt="Drinky" width="400">

Drinky can read, search, and change files or run commands in the working directory. The conversation
stays in the terminal scrollback. Drinky saves no conversation to resume. `/handoff` carries the
current task into a new conversation. It leaves out tool calls and reasoning, so it usually works
even after a context overflow.

Drinky supports Anthropic, OpenAI, xAI, OpenRouter, DeepSeek, and Gemini Enterprise Agent Platform
(Vertex AI). It learns models from the providers and uses public metadata for prices and model
capabilities.

Drinky is a single Zig program. Instruction files and skills define how the agent works. The model
can read the command, config, and key reference through the `describe_drinky` tool.

## Build and run

Drinky requires Zig 0.17.0, a POSIX system, and the `HOME` variable. A terminal with the Kitty
keyboard protocol and grapheme cluster processing gives the best experience.

```sh
zig build -Doptimize=safe
./zig-out/bin/drinky
```

Type `/` to list the commands. Ask Drinky about its commands, key bindings, or config.

## Accounts

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

Use `/login` to sign in or switch accounts. Use `/model` to select a model.

Drinky is not affiliated with the providers.

## Instructions and skills

Drinky reads each `AGENTS.md` file from the Git root down to the working directory. It finds skills
in `~/.agents/skills/` and in each `.agents/skills/` directory on that path, and loads a skill on
demand.

The `required_skills` config key pairs a path pattern with a skill. Drinky sends the skill to the
model when a tool first touches a matching file. It refuses a write or an edit of that file until
the conversation holds the skill.

## Headless mode

Use `drinky run` to answer a prompt without a terminal. A run reads the prompt from stdin and writes
the final reply to stdout. It uses the instructions and tools of a terminal session. The command
`drinky models` lists the values of the `--model` flag.

```sh
./zig-out/bin/drinky run --model openai-plan/gpt-5.5 --effort high <<'EOF'
Review the uncommitted changes.
EOF
```

The model can start a run through the bash tool, for example to review its work as a second agent.
The session total then includes the available costs of the run.

## MCP

A local MCP client can control running Drinky instances. For example, a ChatGPT voice chat can
delegate project work to Drinky through the Codex runtime of the ChatGPT desktop app.

Type `/mcp` in an instance to turn MCP access to that instance on or off. Access starts off unless
the config file turns it on. The client starts `drinky mcp` as its stdio server. The server speaks
MCP `2026-07-28` and finds each instance with MCP access, so one server entry covers all instances.

The client can read the state, send messages, load skills, cancel work, clear the conversation,
fetch a model list, and select the model and the effort. It cannot rewind the conversation, prepare
a handoff, or sign in.

## Config file

The optional `~/.drinky/config.json` file controls instructions, required skills, request and
command limits, the default effort, and interface settings. The `describe_drinky` reference
documents each key, so Drinky can explain the file.

## Rex and Herdr

Drinky reports its state through the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status) (OSC 7501) and
to [Herdr](https://herdr.dev). A terminal such as [Rex](https://www.superlogical.com/) can then show
when Drinky works, waits for the user, or has a result.

## Security

Drinky has no permission gate or sandbox. Use a container for an untrusted repository. MCP access
lets any process of the same user submit work to the instance.

## License

Drinky is available under the [MIT License](LICENSE).
