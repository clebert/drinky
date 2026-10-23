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

- Drinky has no headless HTTP endpoint with JSON commands and events. The endpoint must adapt the
  existing application contract with conversion and transport code. It must add no application
  workflow or runtime export. The endpoint hosts the passive controller on its own task, like
  `App.zig`. It owns the request ids, the event sequence, and the event buffer of each browser. A
  browser that misses an event requests a snapshot. It sends no command until that snapshot arrives.
  The browser owns its confirmation policy, and the endpoint keeps no confirmation state. A slow
  browser must not block the sink of the controller. Records, result waits, and the quota age use
  the awake clock and the boot clock of the controller. The endpoint needs the current reading of
  each clock in every snapshot, so a browser can compute its offset. The design must decide whether
  more than one browser can attach to one controller. The browser words the typed refusals, notices,
  and record events, because `src/wording.zig` serves only the native clients. A record event can
  hold a path or a name that is not valid UTF-8, so the conversion must escape it. The HTTP host
  must supply its output instructions and reference text through `Frontend`. It must not reuse the
  native terminal descriptions.
- `drinky run` shows no token totals or per-run cost. Internal cost reports update only the parent
  session total.
- A run that outlives its bash invocation cannot report later costs. Keep the invocation open with
  `wait` to collect them.
- A failed test shows no stack trace, because `build.zig` sets `strip = true` for each test module.
  It also sets the strip for the generators of `zig build unicode` and `zig build commonmark`.
  Without it, a generator hangs at its first allocation. Two defects of Zig 0.17.0 block the removal
  of the strip. On macOS 27.0, the MachO unwinder panics with `switch on corrupt value` at
  `std/debug/SelfInfo/MachO.zig:406`. The compact unwind data holds an arm64 mode that the unwinder
  does not know. The test allocator records a stack at each allocation, so a test hits that panic.
  The panic handler then waits on the lock of the unwinder, and the test hangs. Also,
  `std.debug.captureCurrentStackTrace` does not block cancellation, so a stack capture in the test
  allocator can consume a pending cancel. Without the strip, two cancel tests of `Session` fail in
  about one of three runs. A Debug build of Drinky records stacks through the same allocator, so it
  can hang or lose a cancel too. Trigger: a Zig release that fixes both defects.
- An unauthorized failure of `/handoff` or `/tldr` does not reject the credential. The page only
  shows the failure, and the next turn rejects the credential. When a turn fails as unauthorized,
  the controller calls `rejectCredential`, which can sign out and report that no account remains.
  The terminal then opens the sign-in picker. The terminal cannot show that picker over an open
  result page. Both commands need a design for a sign-out while their page is open first.
- The start of Drinky reads the config file and the instruction files and scans the skill
  directories without a time limit. A file system call that does not return stops the start. A
  pending macOS privacy prompt causes such a call. The tools and the skill file reads already stop
  such a call after their time limit when the call accepts a cancel.
- Drinky calls `std.unicode.utf8Decode` at six sites. Zig 0.17.0 deprecates the function but names
  no successor, and the standard library still calls it. Trigger: a Zig release that names a
  successor or removes the function.

## Ideas
