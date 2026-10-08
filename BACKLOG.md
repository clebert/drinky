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

- `drinky run` reports no usage. The parent agent and the user see neither the tokens nor the cost
  of a run.
- A failed test shows no stack trace, because `build.zig` sets `strip = true` for each test module.
  Two defects of Zig 0.17.0 block the removal of the strip. On macOS 27.0, the MachO unwinder panics
  with `switch on corrupt value` at `std/debug/SelfInfo/MachO.zig:406`. The compact unwind data
  holds an arm64 mode that the unwinder does not know. The test allocator records a stack at each
  allocation, so a test hits that panic. The panic handler then waits on the lock of the unwinder,
  and the test hangs. Also, `std.debug.captureCurrentStackTrace` does not block cancellation, so a
  stack capture in the test allocator can consume a pending cancel. Without the strip, two cancel
  tests of `Session` fail in about one of three runs. A Debug build of Drinky records stacks through
  the same allocator, so it can hang or lose a cancel too. Trigger: a Zig release that fixes both
  defects.
- The Markdown renderer can close an emphasis run inside a code span. `closerAt` in
  `src/ui/markdown.zig` searches the raw text for the closer. So a bold run that holds `**` in a
  code span ends at that code span. The backticks after it then pair wrongly, and the rest of the
  line shows stray backticks and code in the wrong ranges. CommonMark gives a code span precedence
  over emphasis. `linkAt` also searches its `]` and `)` closers in the raw text.
- Drinky has no `zig build check` step, so `scripts/check.sh` runs the checks outside the build
  graph. The step can replace the script, and CI can then run `zig build check --summary all`.
  `b.addFmt` runs `zig fmt --check`. Run steps run the comment scan and the width scan. A system
  command runs the scan for an allocation-failure check without `core.testing.no_resize_allocator`.
  A system command runs Prettier through `npx`, and only `check` depends on it. `build.zig` cannot
  compare the count of tests that ran with the declared tests. The test runner of Zig 0.17.0 accepts
  only `--listen=-`, `--seed`, and `--cache-dir`, so it cannot list its tests. A new Zig program
  must run each test binary and read its line `All {d} tests passed.`. It prints the runtime of each
  binary and compares the sum with the `test` declarations. The Checks section of `AGENTS.md` and
  the CI workflow change with the script.
- Drinky calls `std.unicode.utf8Decode` at six sites. Zig 0.17.0 deprecates the function but names
  no successor, and the standard library still calls it. Trigger: a Zig release that names a
  successor or removes the function.

## Ideas
