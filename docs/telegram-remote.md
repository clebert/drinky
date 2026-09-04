# Telegram remote control

A session binds to a Telegram bot, so the user drives it from a phone. While the bot is attached,
the phone is the one input device. It sends messages, runs commands, and acts on a turn. The
terminal shows everything, takes no input but a detach, and keeps the process and the credentials.

This document holds the decisions and the plan. `BACKLOG.md` holds the entry until the work lands.
`FEATURES.md` gets the user-facing lines when it does. Delete this document when phase 3 lands,
because the tests and `FEATURES.md` then define the behavior, and the Git history keeps the plan.

## Decisions

### One input device

- While a bot is attached, the terminal editor is inactive. It shows the caption
  `Remote: @bot · Esc: Detach`. Enter shows the notice `The phone holds the input. Esc detaches.`
- Every exit key detaches: Esc, Ctrl+C, and Ctrl+D. No exit reaches past the attach, so a quit takes
  one more press after the detach, like a quit from a page. Every other key does nothing.
- The terminal never cancels a turn, never retries one, and never runs a command while attached. The
  transcript still shows every message, every tool box, and every event.
- The detach hands the session to the terminal in the state it is in. That state is a running turn
  with its queue, a waiting retry with its caption, or the idle prompt. A queued phone message stays
  queued, and Ctrl+P recalls it like a typed one.
- The attach takes the state the same way. A retry that waits at the attach sends its `Failed turn`
  message to the phone, and the editor shows the attach caption alone.
- A credential rejection during a turn detaches with its `Error:` event, and the login picker opens
  in the terminal as today. The phone cannot repair that state, because `/login` is terminal-only,
  and it learns why from the last message.
- The editor is empty at the attach, because the `/remote` line was its last content.
- The attach and the detach events bracket every phone message in the transcript, so a phone message
  is a plain user box. A `/new` while attached records the event `New conversation · Remote: @bot`
  as the first entry, so the bracket holds.

### Scope on the phone

- The phone gets messages, the slash commands, and the turn actions: cancel, retry, dismiss, and
  withdraw steering. It gets neither quit nor clear.
- These commands refuse on the phone with a notice that names the terminal: `/login`, `/logout`,
  `/remote`, `/sources`, and `/system`.
- `/new`, `/effort`, `/model`, `/help`, and `/skill` run on the phone. `/model` steps through the
  provider and the account, so the phone changes the account there. A `/new` while attached records
  the event `New conversation · Remote: @bot`, and the phone gets it as the first message of the new
  mirror.
- A command from the phone during a turn refuses with a notice, like a command in the terminal.
- A refused command line gets the refusal as a reply, and the user sends the text again without the
  slash.
- A notice that a phone action causes goes to the phone: as a toast after a tap, and as a reply
  after a message. A refusal for a signed-out session or a missing model is such a notice.
- A non-text update, such as a photo, a sticker, or a voice note, gets one reply:
  `Drinky reads text alone.`

### Attach and detach

- The terminal command `/remote` attaches a bot. No session binds at startup.
- Its `/help` summary reads "attach a Telegram bot".
- The picker lists the saved bots, then an `Add a bot` row and a `Remove a bot` row. A pick of a bot
  attaches it. The remove row appears while a bot is saved, so a picker with no saved bot holds the
  `Add a bot` row alone.
- The `Remove a bot` row opens a second list of the saved bots, and one pick removes the bot with an
  event. One pick is the decision, because `/logout` drops a credential the same way and BotFather
  restores a token.
- Drinky stores the bots in `~/.drinky/remote.json`, an owner-only keyed store like `auth.json`. An
  entry holds the token, the bot id, the username, and the chat id. The config file holds no bot
  entry, because the token is a secret.
- No event, notice, or error text names the token.
- The `Add a bot` row switches the editor into a token prompt state with the caption
  `Bot token · Enter: Save · Esc: Cancel`. Enter hands the text to the command, and it never reaches
  a model.
- Drinky proves the token with `getMe` and names the bot by its username. A rejected token keeps the
  prompt state and shows a notice.
- A new bot binds its chat through a pairing code. The `/remote` picker stays open with no rows and
  states `Send the code X7KQ4M2P to @bot`, like the model fetch states its wait. Beside the code it
  shows the link `https://t.me/bot?start=X7KQ4M2P` as a terminal hyperlink, so one click from a host
  with Telegram Desktop sends the code. A typed code and a `/start` with the code both bind. The
  private chat that sends the code within five minutes binds. The bind saves the bot and attaches
  it. An exit cancels the pairing alone, and an event records the result. Drinky ignores a message
  from a group, and it counts as neither a bind nor a wrong code.
- The code has eight symbols from `23456789ABCDEFGHJKMNPQRSTUVWXYZ`, the 31 symbols without `0`,
  `O`, `1`, `I`, and `L`. Three wrong codes from any private chat end the pairing with an `Error:`
  event, because the bot name is public.
- A saved bot with a chat id attaches without a pairing.
- The attach event names the bot and the state of the session: the place, the context gauge, the
  model with its account, and the effort. It takes the words and the order of the status line:
  `Remote: @bot · ~/work/drinky (main) · Context: 45% · claude-opus-4-8 (Anthropic Subscription) · Effort: high`.
  The place takes its full form, because the phone has no column budget. The phone chat keeps the
  messages of every earlier attach. This one line tells the user the place of the session and
  whether it holds a conversation. An empty conversation reads `Context: 0%`, and the gauge takes
  the other forms of the status line, `Context: Unknown` and `Context: 206k`. A signed-out session
  reads `Account: Signed out` in place of the model, the account, and the effort. A missing model
  reads `No model` in place of the model.
- The bound chat id gates every update. An update from another chat drops in silence.
- At the attach Drinky confirms the updates from before that moment with `offset=-1` and sends no
  reply.
- The long poll has its own timeout of `request.connect_timeout_ms` minus five seconds, with a floor
  of one second, so the response head arrives inside the head window.
- The attach calls `deleteWebhook` first, because an active webhook blocks every `getUpdates`.
- A failed poll or send retries with a backoff and stays attached. Drinky records one `Error:` event
  at the first failure and one `Event:` at the recovery. A network failure and a 5xx are such
  failures. A 429 is a wait of `retry_after` seconds, not a failure, and it records nothing.
- Any other 4xx is permanent, so the send gets no retry, and one `Error:` event records it. A `400`
  for the entity parse sends the same block again as plain text without a parse mode, so the ordered
  queue never stalls on one block. Any other 4xx on the poll detaches with an `Error:` event,
  because a repeat of the same request cannot succeed.
- An event that a mirror send caused stays in the terminal. The mirror records it and moves its
  cursor past it in one step, so no block needs a mark and a failure cannot feed itself.
- A `401 Unauthorized` on any call while attached or during a pairing means a revoked token. It
  detaches at once with an `Error:` event that names `Remove a bot` as the repair. A `403 Forbidden`
  means that the user blocked the bot, and it detaches the same way, because the phone has left.
- A `409 Conflict` means that another instance polls the same bot. The instance that receives it
  detaches at once with an `Error:` event, so the newer attach wins. During a pairing it ends the
  pairing the same way.
- The detach freezes the chat. Drinky removes every open keyboard, drops every pending phone state,
  sends the detach event as the last message, and sends nothing after that. A frozen chat keeps its
  last reactions, so a 👀 can stay on a message that the terminal takes over.
- The detach cancels a pending poll like the exit does, and the consumer drops a phone update that
  arrives after the detach.
- The exit of Drinky detaches first, so the detach event is the last message. Then it cancels the
  poll and drains the send queue for at most five seconds. That bound covers the keyboard removals
  and the detach event at one send per second.

### Mirror

- The phone sees each committed transcript block once, except a reasoning block and a tool box. The
  activity message is the substitute for both. An answer block, an event, the head line of a loaded
  skill, and the line of a retry attempt go out. Its own messages already stand in the chat, and the
  terminal sends none while attached.
- The mirror starts at the attach event, so the history before it stays in the terminal, and the
  attach event is the first message of the mirror. Its session state stands in the chat before the
  first turn. `/new` clears the transcript, and the mirror starts over at the `New conversation`
  event.
- An answer block goes out when it commits, as one message with the formatted text. Nothing streams
  to the phone, and a canceled block never reaches it.
- A block above 4096 characters continues in a new message. The split works on the rendered HTML,
  never on the Markdown source, so every part parses on its own. It falls between two top-level
  elements, else on a line, else on a character inside a text node, never inside a tag or a
  character reference like `&amp;`. A part closes every open tag at its end, and the next part opens
  them again, so a code block continues as a code block. Telegram counts the limit after the entity
  parse, so the tags are free.
- Every message goes out with `disable_notification`, except the last message that the mirror sends
  at the end of a completed or failed turn. The phone rings once per turn, for the final answer
  block or the `Error:` event. The last answer block closes at the receipt of the turn, so the
  mirror sends it and sees the turn end in one step. A canceled turn ends in silence, because the
  phone canceled it. An edit never notifies, so the summary is silent. A completed turn whose last
  round holds no text sends no last message, so it ends in silence too. Such a turn is rare, and the
  summary still shows its end.
- An event goes as one message with its `Event:` or `Error:` label. A model, effort, or account
  change is such an event, so the phone learns each setting change from it. The skill head line
  `Skill: name · File: path` goes as one italic message.
- A second renderer turns the Markdown into Telegram HTML: bold, italic, code, pre, and links. A
  heading becomes a bold line. A table becomes a `pre` block.
- One activity message per turn shows the current state: `Thinking`, `Writing`, or `Running: bash`,
  with the call count. It edits on a state change alone. At the end of the turn it loses its buttons
  and becomes a one-line summary with the tool count, the time, the context gauge, and the cost:
  `Tools: 12 calls · Time: 2m 14s · Context: 45% · ~$0.42`. A canceled turn opens the summary with
  `Canceled`, and a failed turn with `Failed`. The gauge and the cost take the text of the status
  line, so the gauge reads `Context: Unknown` after a model switch and `Context: 206k` without a
  known window.
- The phone gets no typing indicator and no pinned status. The activity message is the one live
  element, and its summary is the status line of the chat. It goes out at the turn start, so it
  stands above the answer blocks of its turn as the header of the turn.

### Message states

- A reaction on a phone message shows its transcript state. No message from the bot carries one.
- The reactions are 👀 received and not yet committed, 👍 committed, and 👎 dropped. A message with
  no reaction is one that Drinky has not received. Telegram allows a fixed emoji list for a bot, and
  that list holds neither ✅ nor ❌.
- A phone message gets 👀 on arrival. The receipt of the turn names how many leading queued messages
  it committed, and that count splits them: the committed ones get 👍, the rest get 👎. A batch that
  the turn took and a failed request rolled back is not committed, so it gets 👎.
- The prompt of a turn gets 👍 when the turn commits any round. The receipt states that fact as a
  history end past its base.
- A message that arrives during a turn queues as steering. The turn takes the whole queue at one
  tool round.
- The activity message holds one `Withdraw` button for the whole turn. One tap drops the whole
  queue, like Ctrl+P, and a tap on an empty queue answers the toast `Nothing queued.` The 👀
  reactions show which messages are not yet committed.
- A phone message that the turn did not commit gets 👎 at the end of the turn or at the withdraw.
  Its text fills no editor, because the chat still holds it. The return to the editor that a typed
  message takes today does not run while attached.
- A canceled or failed turn follows the same rule. Its uncommitted phone messages get 👎. The prompt
  of a turn that fails before its first commit is such a message.

### Turn actions

- The activity message holds a `Cancel turn` button beside `Withdraw`, set once at the turn start.
  The first tap changes the label to `Tap again to cancel`, and the second tap cancels. The label
  stays until the second tap or the end of the turn, so the keyboard changes on the arm and at the
  end alone.
- A failed turn that committed work sends one `Failed turn` message with `Try again` and `Dismiss`
  buttons. One tap each, like Ctrl+N and Esc. The message loses its buttons after the tap, and also
  when a new message starts a turn, because the start of any turn drops the retry.

### Pickers on the phone

- A picker is an inline keyboard under one message, one button per row, and a `✓` on the current
  row. A stepped picker edits the same message per step and adds `‹ Back` and `Cancel` buttons.
- The `/help` keyboard lists the commands that run on the phone alone.
- Drinky edits a picker message on its pick, to state the result and remove the keyboard, and at the
  detach, because a tap after the detach gets no answer at all. A newer picker, `/new`, and the
  start of a turn make it stale instead, and a stale tap answers the toast `This list is closed.`
  The keyboard stays in the chat history, like in most bots.
- The model step lists the cached models alone and has no fetch row. A refetch happens at the
  terminal. An account with no cached list answers with a notice that names the terminal.
- A skill row loads the skill with no task at once. A typed `/skill:name task` line carries a task.
- The bot registers the commands that run on the phone with `setMyCommands`, each with its `/help`
  summary.

## Telegram facts

- The Bot API is HTTPS with JSON. `getUpdates` with a long `timeout` polls, and the `offset` is
  consume-once. A call with `offset=-1` returns the newest waiting update alone and confirms the
  rest, so the next poll starts after it. `allowed_updates` limits the poll to `message` and
  `callback_query`.
- A concurrent `getUpdates` from another client gets `409 Conflict`. An active webhook gets the same
  answer, and `deleteWebhook` removes it.
- A malformed HTML text gets `400 Bad Request` with `can't parse entities`, and a retry of the same
  bytes fails the same way.
- A message holds 4096 characters after the entity parse. The chat allows about one message or edit
  per second, and a 429 answer carries `retry_after` in seconds.
- A message with `disable_notification` arrives without a sound, and an edit never notifies.
- `editMessageText` fails with `message is not modified` on an identical edit, and the client treats
  that answer as success.
- `callback_data` holds at most 64 bytes. Every `callback_query` needs an `answerCallbackQuery`, and
  that answer can carry a toast of 200 characters. A query expires after a few seconds, so the
  answer goes out before any slow work.
- A command name for `setMyCommands` is `[a-z0-9_]` with 1 to 32 characters, so `/skill:name` is not
  registered and still arrives as text.
- A user who never talked to a bot must press `Start` first, which sends `/start`. The link
  `https://t.me/<bot>?start=<payload>` opens the chat and sends `/start <payload>` on that one tap.
  The payload holds up to 64 characters from `A-Z`, `a-z`, `0-9`, `_`, and `-`.
- A bot never learns that the user deleted a message. An `edited_message` update reports an edit,
  and Drinky ignores it.
- A bot reacts to a message with `setMessageReaction` from a fixed emoji list.
- Drinky uses these HTML tags: `b`, `i`, `code`, `pre`, `a`, and `blockquote`. The parse mode knows
  no heading and no table.
- A user message above 4096 characters arrives as several messages, and each one is a prompt or a
  steering message of its own.

## Architecture

- A new `src/remote/` subsystem holds the Telegram client, the mirror, the store, and the HTML
  renderer. It depends on `lib/ai` for the HTTP helpers and the JSON store, and on
  `src/ui/markdown.zig` for the parse. `lib/ai` and `lib/terminal` know nothing of it.
  `lib/ai/json.zig` is not exported today, so the client uses `std.json` or `root.zig` adds the
  export.
- The attach is not a variant of the session `Mode`, because a turn runs while attached. It is a
  second axis: one flag that the input loop checks before the mode. While the flag is set, an exit
  key detaches and Enter shows the notice.
- The remote runs as two tasks beside the input reader and the turn worker. The poller runs the long
  poll and pushes a new `UiEvent` variant into the same queue that the keys use, so the render
  consumer stays single-threaded. The sender drains the client queue. A long poll blocks the poller
  for its whole timeout, so every send needs the second task.
- The mirror is a cursor over the committed transcript entries. After each change of the transcript
  it sends every new block once, and it reads no streaming event. A change to the streaming protocol
  cannot reach it. The session already tracks the committed frontier of a turn as its transcript
  checkpoint, and the cursor rests on it.
- The activity message reads the state of the live tail that the session already keeps: thinking,
  writing, or a running tool with its count. No new hook enters the turn worker.
- The mirror and the activity logic run on the render consumer, after it applies each event. They
  hand every send to the client queue. The poller and the sender read no session state.
- The `/remote` command lives in `lib/ai/command/` and returns outcomes. New `Outcome` variants name
  the actions, and the app owns the network, like it owns the OAuth flow of `login`. The command
  context carries the saved bot names for the picker rows.
- A phone message enters the app through the same path as an Enter in the editor, so every refusal
  and every steering rule applies once. It never reads or writes the editor.
- A `callback_data` value carries an id alone, never text. The open picker lives on the session,
  keyed by message id.
- The remote keeps one phone message id per entry of `Session.steering`. The receipt of a turn
  already carries `steering_committed_count` for the editor, and the same count splits the ids into
  committed and dropped. No count of its own, and nothing outside `src/` changes. A second list in
  lockstep with the drafts drifts on the first push, drop, or recall that touches one list alone, so
  the id belongs on the steering entry itself, as an optional field beside the draft.
- The Telegram client owns the rate limit. One queue per chat spaces the sends, an edit of a message
  replaces an older pending edit of the same message, and a 429 waits the named seconds.
- A send returns a local handle at once, and the message id arrives later on the sender. An edit, a
  keyboard change, and a reaction name the handle, and the queue holds each one behind the send of
  its handle. The render consumer never waits for Telegram.
- The tests run the client against an in-process HTTP server. No test reaches the network.

## Phases

### Phase 1: Transport and `/remote`

- The `remote.json` store with a bot entry: token, bot id, username, and chat id.
- The Telegram client with the methods of this phase: `getMe`, `deleteWebhook`, `getUpdates`, and
  `sendMessage`. Each later phase adds the methods it uses, so no method lands unused.
- The `/remote` picker with the bot rows, the `Add a bot` row, the `Remove a bot` row, and the
  second list of the remove row.
- The token prompt state of the editor.
- The pairing wait inside the picker with the code and the link, the five-minute window, the private
  chat rule, the wrong-code bound, and the result event. A saved chat id skips the pairing.
- The poller and the sender: the poll with its own timeout, the chat id gate, the drop of the
  updates from before the attach, the backoff, the failure and recovery events, the permanent 4xx
  rule, and the detach on a 401, a 403, and a 409.
- The detach on a credential rejection.
- The attach state: the inactive editor with its caption, the Enter notice, the detach on every exit
  key, the attach event with the session state, and the detach event.
- The exit that detaches first, cancels the poll, and drains the send queue within a bound.
- A phone message runs as a prompt, and its refusals reach the phone as replies. Every command line
  from the phone refuses with a notice in this phase.
- A phone message during a turn queues as steering, and an uncommitted one drops at the end of the
  turn and fills no editor. The button and the reactions come later.
- The reply to a non-text update.

### Phase 2: Mirror

- The client methods `editMessageText` and `setMessageReaction`.
- The mirror cursor: the answer blocks, the events, the skill head line, and the retry attempt line,
  as plain text with the split above 4096 characters, silent except the last message of a completed
  or failed turn.
- The activity message with the state, the call count, and the summary at the end.
- The 👀, 👍, and 👎 reactions on phone messages, split by the receipt of the turn.
- As the last step, the HTML renderer over the Markdown parser, the split that closes and reopens
  the open tags, and the plain-text resend after an entity parse failure, with their own tests.

### Phase 3: Phone input

- The client methods `editMessageReplyMarkup`, `answerCallbackQuery`, and `setMyCommands`.
- The `Cancel turn` and `Withdraw` keyboard of the activity message, set at the turn start, with the
  two-tap cancel and the `Nothing queued.` toast.
- The `Failed turn` message with `Try again` and `Dismiss`, also for a retry that waits at the
  attach.
- The phone commands as inline keyboards, the stepped `/model` picker with `‹ Back` and `Cancel`,
  the stale-tap toast, and the skill row. The terminal-only commands keep their refusal.
- Toasts for the notices that a tap causes.
- `setMyCommands` at the attach.

## Documents to update on landing

- Delete the entry from `BACKLOG.md` and this document when phase 3 lands.
- Add the lines to `FEATURES.md` with each phase, because the file states what Drinky does after
  every commit. A `Remote` section holds one sentence per capability.
- Add the `/remote` command and the phone rules to `README.md` when phase 3 lands, because the file
  describes the stable product.
- `describe_drinky` lists the command from the code, so it needs no edit.
