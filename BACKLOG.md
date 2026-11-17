# Backlog

This file holds the open direction of Drinky. An open item states what Drinky lacks and holds the
facts that an implementer cannot re-derive from the code. A request of the user starts its work. An
item names a trigger when an event must come first, such as a trace that the work needs. A line
leaves this file when its work lands.

`TODO.md` is the inbox. It is git-ignored, and the user writes loose notes into it. Shape a note
into an item only when the user asks for it. Interview the user first with the `interview` skill,
and never invent a priority or a trigger. Delete the note from `TODO.md` once its item stands here.
An idea is one line. It is a placeholder against loss, and it leaves when it becomes an open item or
when the user drops it.

## Open items

- A failed test shows no stack trace, because `build.zig` sets `strip = true` for each test module.
  It also sets the strip for the generators of `zig build unicode` and `zig build commonmark`. Zig
  0.17.1 fixes the MachO unwinder panic on macOS 27.0. That panic hung a generator without the
  strip, so the generators no longer need it. A defect of Zig 0.17.1 blocks the removal of the strip
  for the test modules. `std.debug.captureCurrentStackTrace` does not block cancellation. The
  capture locks the mutex of `std.debug.SelfInfo`, and that lock can consume a pending cancel. The
  stack iterator catches `error.Canceled` and continues with the frame pointers. The test allocator
  records a stack at each allocation. The test runner builds `std.testing.io` on that allocator, so
  a separate allocator in a test does not prevent the defect. Without the strip, two cancel tests of
  `Session` fail in about one of three runs. A Debug build of Drinky records stacks through the same
  allocator, so it can lose a cancel too. The pull request
  [ziglang/zig#36010](https://codeberg.org/ziglang/zig/pulls/36010) adds the missing cancel
  protection. Trigger: a Zig release that fixes the defect.
- An unauthorized failure of `/gist` does not reject the credential. The page only shows the
  failure, and the next turn rejects the credential. When a turn fails as unauthorized, the
  controller calls `rejectCredential`, which can sign out and report that no account remains. The
  terminal then opens the sign-in picker. The terminal cannot show that picker over an open result
  page. The command needs a design for a sign-out while its page is open first.
- The start of Drinky reads the config file and the instruction files and scans the skill
  directories without a time limit. A file system call that does not return stops the start. A
  pending macOS privacy prompt causes such a call. The tools and the skill file reads already stop
  such a call after their time limit when the call accepts a cancel.
- Drinky has no QwenCloud account. QwenCloud offers the OpenAI Responses protocol at
  `/compatible-mode/v1/responses`, the Anthropic Messages protocol at `/apps/anthropic`, and a model
  list at `/compatible-mode/v1/models`. QwenCloud has no OAuth, so each account takes a key in the
  key step. The Token Plan subscription uses `https://token-plan.maas.qwencloudapi.com` and keys
  with the prefix `sk-sp-`. Its terms allow only interactive use in coding tools. A pay-as-you-go
  key starts with `sk-` or `sk-ws-` and works only in its region, such as
  `https://ap-southeast-1.maas.qwencloudapi.com`. The two kinds of key do not work on the endpoint
  of the other kind. The Responses API truncates an input above about 80% of the context window
  without an error. The `auto` model of the Token Plan routes each request to a model that the
  server selects. Source: <https://docs.qwencloud.com/llms.txt>.
- Drinky sends no message while a turn runs. The controller refuses the message as `busy`, and the
  draft stays. The MCP tool `send_message` gets the same refusal. A message cannot steer the running
  turn or wait for the next turn. `Turn` already adds a queued required skill as a user message at a
  round boundary. A user message can join the conversation at the same point. A waiting message must
  survive a cancel. The design must define how Esc, `/rewind`, and Ctrl+N treat a waiting message.
- Drinky has no sandbox outside macOS. Linux has Landlock since Linux 5.13. Source:
  <https://docs.kernel.org/userspace-api/landlock.html>. The Zig standard library has the Landlock
  system call numbers but no wrappers. Landlock limits the calling thread and its children. An
  unprivileged process must set `no_new_privs` before it applies the rules. The `bash` tool already
  runs its own setup between `fork` and `execve`, so the rules can apply there. The available access
  rights grow with the ABI version of the kernel, so the rules must adapt to that version. A kernel
  without Landlock needs a fallback without a sandbox. CI runs on `ubuntu-latest`, so CI can run the
  Linux tests. Zig skips the analysis of a branch for another system. A macOS host checks the Linux
  code only with `zig build test -Dtarget=x86_64-linux`, and it cannot run those tests.
- Drinky sends no image to a model. The `read` tool refuses a binary file, so the model cannot
  inspect a screenshot or a rendered result. Each wire documents an image in a tool result. In
  Messages, the `tool_result` content takes `image` blocks. Source:
  <https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls>. In Responses,
  the `output` of `function_call_output` takes an array of image objects. Source:
  <https://developers.openai.com/api/docs/guides/function-calling>. The ChatGPT plan backend takes
  an image in a tool result too. The Codex client sends it there in
  `codex-rs/core/src/tools/handlers/view_image.rs` of `openai/codex`. The xAI, OpenRouter, and
  DeepSeek accounts need their own check. In Gemini 3, a `functionResponse` part takes nested
  `inlineData` parts with PNG, JPEG, or WebP data. This feature is a preview. Source:
  <https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tools/function-calling>.
  The source of the public metadata lists the input types of each model in
  `architecture.input_modalities` of <https://openrouter.ai/api/v1/models>. Some models list only
  `text`. The public metadata does not hold the input types yet. `Tool.Output.content` holds only
  text, so every layer changes. The Zig standard library has no image decoder, so Drinky cannot
  scale an image down. Drinky can read the dimensions from the file header and refuse an image above
  the limit. Anthropic accepts at most 8000×8000 px. Above 20 images in one request, a stricter
  limit applies. Drinky sends every image again with each request, so a long session reaches that
  limit. Source: <https://platform.claude.com/docs/en/build-with-claude/vision>.
- Drinky reads the config file, the instruction files, and the skill list only at startup. A new
  skill or a config change takes effect only after a restart. A clear of the conversation can read
  them again. The clears are `/new`, a clear through MCP, and the apply of a gist. A change of the
  system prompt during a conversation invalidates the Anthropic prompt cache of the system prompt
  and of all messages. Source:
  <https://platform.claude.com/docs/en/build-with-claude/prompt-caching>. The `interface` keys set
  the initial values of `/verbose` and `/mcp`. A reload must keep or reset these session values by
  an explicit rule. `Harness.init` builds the config, the discovery, and the system prompt once.
  Each part that copied an old value must take the new value. The missing time limit of the start
  discovery applies to each reload too.
- A rewind keeps the file changes of the turns that it drops. The removal of a canceled turn keeps
  them too. Drinky can save a snapshot of the work tree before each turn. A rewind can then offer a
  restore as a separate choice. A temporary index through `GIT_INDEX_FILE`, `git add -A`, and
  `git write-tree` records new files and leaves the index of the user unchanged. The restore must
  also leave that index unchanged. `git stash create` leaves out untracked files, so it cannot
  remove a file that a turn created. A snapshot holds no ignored file and no change outside the Git
  root. Outside a repository, Drinky has no snapshot. The snapshot needs the `git` program, so
  Drinky must turn the restore off without it. A restore overwrites the manual changes of the user
  after the turn, so its confirmation must list the changed files. Each snapshot writes the large
  untracked files that `.gitignore` does not cover into `.git/objects`. The snapshot needs a size
  limit.
- Drinky does not start when a sandbox denies the metadata of a parent directory of the working
  directory. The start in `src/main.zig` calls `std.Io.Dir.realPathFileAbsoluteAlloc`, which then
  returns `error.Unexpected`. Drinky prints only `error: Unexpected`, without a path or a cause.
  `std.process.currentPathAlloc` and `pwd -P` still return the canonical path. A `sandbox-exec`
  profile reproduces the defect. It denies `file-read*` for `/private/tmp` and allows it again for
  the working directory below. A `file-read-metadata` rule for each parent directory lets Drinky
  start. A rule for the `.git` path of each parent directory does not. An isolated evaluation folder
  or the sandbox of another tool causes such a denial.

## Ideas

- Drinky loads each instruction file and each skill in every environment. A condition on an
  environment variable can limit a file to Rex (`REX_SESSION`) or Herdr (`HERDR_ENV`). All Rex and
  Herdr instructions then move to such files.
- A retry wait shows no progress. The frame can empty over the delay that the `attempt_failed` event
  holds. Retries are rare, so the gain is small.
- An MCP client cannot list, write, apply, or delete gists. Only the terminal uses gists.
- The instructions do not tell the agent to use Rex tabs. Inside Rex, the agent can open a visual
  preview or a test script in a separate Rex tab without a request. The rule fits a Rex-only
  instruction file from the idea above.
- A `--readonly` flag can block every write of the tools. Drinky then also leaves out the `write`
  and `edit` tools.
- An `--offline` flag can block the network of the commands. A nested `drinky run` then fails, so
  the review and second-opinion skills stop working.
- The sandbox has a fixed list of writable caches: `~/.cache/zig` and `~/.npm`. A config key can add
  more directories.
