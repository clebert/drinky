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
- The start of Drinky reads the config file and the instruction files and scans the skill
  directories without a time limit. A file system call that does not return stops the start. A
  pending macOS privacy prompt causes such a call. The tools and the skill file reads already stop
  such a call after their time limit when the call accepts a cancel.
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

## Ideas

- Drinky loads each instruction file and each skill in every environment. A condition on an
  environment variable can limit a file to Rex (`REX_SESSION`) or Herdr (`HERDR_ENV`). All Rex and
  Herdr instructions then move to such files.
- The instructions do not tell the agent to use Rex tabs. Inside Rex, the agent can open a visual
  preview or a test script in a separate Rex tab without a request. The rule fits a Rex-only
  instruction file from the idea above.
- A `--readonly` flag can block every write of the tools. Drinky then also leaves out the `write`
  and `edit` tools.
- The sandbox has a fixed list of writable caches: `~/.cache/zig` and `~/.npm`. A config key can add
  more directories.
