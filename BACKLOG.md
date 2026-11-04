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
- `/gists` scans at most 4096 entries of `~/.drinky/gists/` in directory order, not by age. Past
  that limit, gists leave the list without a notice, and the newest gists can be among them. Each
  save creates a file, and a gist stays until a deletion, so the count only grows.

## Ideas

- Drinky loads each instruction file and each skill in every environment. A condition on an
  environment variable can limit a file to Rex (`REX_SESSION`) or Herdr (`HERDR_ENV`). All Rex and
  Herdr instructions then move to such files.
- A retry wait shows no progress. The frame can empty over the delay that the `attempt_failed` event
  holds. Retries are rare, so the gain is small.
- An MCP client cannot list, write, apply, or delete gists. Only the terminal uses gists.
- The `Received` value of a work row counts only kept work. A streamed call adds no bytes until it
  finishes, and a discard or a cancel can lower the value. A value that counts every received byte
  and never decreases needs a count in the application. The application then also needs the run
  boundary that the client uses. In verbose mode, the work row shows only while a tool call is
  unfinished. Its `Received` and `Time` values also include the thinking before the call. The values
  then look like measures of that call. A separate meaning in verbose mode changes the values at a
  `/verbose` toggle during a run.
- The instructions do not tell the agent to use Rex tabs. Inside Rex, the agent can open a visual
  preview or a test script in a separate Rex tab without a request. The rule fits a Rex-only
  instruction file from the idea above.
