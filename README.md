# Drinky

A dependency-free terminal coding agent.

<img src="www/drinky.png" alt="Drinky" width="400">

Drinky can read, search, and change files or run commands in the working directory. The conversation
stays in the terminal scrollback. Drinky saves no conversation to resume.

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

## Headless mode

Use `drinky run` to answer a prompt without a terminal. A run reads the prompt from stdin and writes
the final reply to stdout. It uses the instructions and tools of a terminal session.

```sh
./zig-out/bin/drinky run --model openai-plan/gpt-5.5 --effort high <<'EOF'
Review the uncommitted changes.
EOF
```

A run through the bash tool adds its available costs to the parent session total after each model
attempt. It adds no transcript summary. Keep the bash invocation open with `wait` for background
runs.

Use `drinky models` to list the saved models of signed-in accounts.

## Config file

The optional `~/.drinky/config.json` file controls instructions, request limits, and interface
settings. Drinky reads it at startup and does not change it. The config file holds no secrets.
Credentials and remembered model choices live under `~/.drinky/`.

## Herdr

Drinky reports its state to [Herdr](https://herdr.dev), so a pane can notify when a turn ends.

## Security

Drinky has no permission gate or sandbox. Use a container for an untrusted repository.

## License

Drinky is available under the [MIT License](LICENSE).
