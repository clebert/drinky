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
  On macOS 27.0, the MachO unwinder of Zig 0.16.0 panics with `switch on corrupt value` at
  `std/debug/SelfInfo/MachO.zig:390`. The test allocator records a stack at each allocation, so a
  test hits that panic. The panic handler then waits on the lock of the unwinder, and the test
  hangs. A Debug build of Drinky records stacks through the same allocator and can hang too.
  Trigger: a Zig release whose unwinder reads the unwind data of macOS 27.0.

## Ideas

- Restart the same prompt in a new session.
