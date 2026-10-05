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

- A failed turn offers no retry. A turn that failed after it committed work left the caption
  `Failed turn` above the editor. Ctrl+N then sent a `<retry_request>` that named the failure. The
  request asked the model to continue from the last committed checkpoint. The transcript showed the
  note `Drinky asked the model to continue from the committed work.` in place of the request. A
  failed retry attempt offered the retry again. Esc or a new turn dismissed the offer, and Herdr
  read the wait as `blocked`. The user wants the offer back when the core makes it cheap. A turn
  that failed before its first commit keeps its user message in the conversation too. The session
  appends the message before the turn starts, and the editor holds no copy of it.
- A canceled turn that committed work stays in the conversation as it is. Under the caption
  `Canceled turn`, Ctrl+N removed the turn from the conversation and the transcript. It kept the
  events of the session. It returned the prompt and the committed steering messages to the editor as
  editable text. A turn that ran `write`, `edit`, or `bash` warned first and removed on the second
  press. Esc kept the turn, and a new turn or `/new` dropped the offer. The user wants the removal
  back when the core makes it cheap.
- Drinky needs a terminal. A headless mode answers one prompt with no terminal: text in, text out,
  with flags for the model and the effort. It is the base for any agent that Drinky drives itself.
  Trigger: the first agent that Drinky drives itself.
- Drinky keeps no principal marker and settles no session on a reread of the credential file. A
  login saved the account and organization ids of the Anthropic OAuth profile and the user id of the
  xAI id token. A stored token of the same principal counted as a rotation, and a token of another
  or an unknown principal counted as a replacement. A replacement before a model request or a model
  fetch ended the turn. It dropped the model list, the reasoning, and the usage evidence of the
  account, and asked for a new model. `/login` reread the credential file first. A sign-in from
  another instance showed in the picker, and a rotation moved the active client to the new token. A
  replacement dropped the evidence, and a sign-out of the active account handed the session to the
  next one. Drinky reported an unreadable file or entry, and the list kept the last read. A login
  with a failed save did not follow the store. The reread before a refresh stays, and it takes any
  newer stored token as it is.
- Drinky shows no notice when it cannot save a refreshed credential. The fresh token serves the
  session, and the next token request tries the save again. After a restart, a refresh token that
  the server rotated away forces a new sign-in, and no text names the cause. A notice needs a path
  from the credential to the client. Trigger: a sign-in that a lost refresh token forces after a
  restart.
- A failed test shows no stack trace, because `build.zig` sets `strip = true` for each test module.
  On macOS 27.0, the MachO unwinder of Zig 0.16.0 panics with `switch on corrupt value` at
  `std/debug/SelfInfo/MachO.zig:390`. The test allocator records a stack at each allocation, so a
  test hits that panic. The panic handler then waits on the lock of the unwinder, and the test
  hangs. A Debug build of Drinky records stacks through the same allocator and can hang too.
  Trigger: a Zig release whose unwinder reads the unwind data of macOS 27.0.

## Ideas

- Restart the same prompt in a new session.
