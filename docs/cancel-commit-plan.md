# Plan: cancel/commit semantics (backlog items 1–4)

Working planning doc for the cancel cluster in `BACKLOG.md`. Disposable — fold into
commits/`FEATURES.md` as phases land, then delete. Rebased onto the post-0a item model:
history is a flat `std.ArrayList(llm.Item)`, the Agent no longer folds (the Anthropic
serializer merges a same-role run into one message envelope), and turn rollback is a plain
truncation.

Phases, in dependency order:

1. Commit partial turns to history on cancel
2. Show only committed content in the transcript
3. Account cancelled turns' token cost
4. Offer partial reasoning as a citation + define editor composition on cancel

## Shared foundation: one source of truth

The joined `agent.items` decides everything. `cancelTurn` cancels-then-joins the worker
(`future.cancel(io)`, `App.zig:507`) before any teardown, so once it returns `agent.items` and
`agent.stats` are final and safe to read from the consumer thread.

- `turn_base` = `agent.items.items.len` captured in `runTurn` just before spawning the worker
  (nothing is running, so the read is safe). `runTurn` captures no base today — Phase 2 adds it.
  It mirrors the `base` the Agent already captures in `run` (`Agent.zig:139`).
- The prompt is exactly **one** appended `message{user}` item (no folding), so the in-`run`
  "nothing committed" boundary is `items.len == base + 1`, and the consumer-side oracle after
  join is simply `items.len == turn_base` (fully rolled back) vs `> turn_base` (at least one
  complete round committed). No block-count bookkeeping — that complexity died with the fold.

## Key facts established from the code

- `Agent.run` (`Agent.zig:138`) captures `base = items.items.len` (`:139`), appends the prompt as
  one user item (`appendUser`, `:141`/`:263`, no fold), and rolls back with a single
  `errdefer self.items.shrinkRetainingCapacity(base)` (`:140`). **This errdefer fires on
  `error.Canceled` today**, so a cancelled turn's items are currently dropped back to base —
  exactly the behavior Phase 1 changes. `reportAndReset` (`:258`) and the API-error path use the
  same shrink-to-base rollback.
- `readReply` (`Agent.zig:286`) builds the reply into a **local arena** item list via the flush
  helpers and commits it to history only at the end: `toOwnedSlice` (`:365`) then
  `self.items.appendSlice(self.gpa, reply)` (`:367`). A cancel mid-stream throws before `:367`, so
  a partial assistant reply is never committed — no empty reasoning `blob` or truncated
  `arguments_json` reaches history. The "last complete round" boundary holds for free. The
  returned slice is arena-owned, so it stays valid while `runTools` appends to `self.items`.
- `drainSteering` (`Agent.zig:158`) joins the queued messages and appends them as a **separate**
  `message{user}` item (`:167`); it no longer folds into a trailing user message. Consecutive user
  items are legal — the Anthropic serializer merges a same-role run, and OpenAI needs no merge.
  This is why C1 dissolves (below).
- `runTools` (`Agent.zig:385`) counts the reply's `tool_call` items (`:386`), runs mutating tools
  inline in call order and read-only tools concurrently (`:418`), then collects into an arena
  `[]llm.Item` of `tool_result`s (`:429`) and appends them with
  `self.items.appendSlice(self.gpa, results)` (`:442`). Bookkeeping: `dispatched` (calls started,
  `:406`), `collected` (results built, `:407`). The collect loop arena-copies each result's
  `content` then frees the tool's gpa-owned copy (`:437`). The `errdefer` (`:410`) cancels the
  group and frees the content of finished-but-uncollected calls (`calls[collected..dispatched]`) —
  it appends nothing. Note the arena `results` is allocated at `:429`, *after* `group.await`, so a
  cancel during dispatch or await hits the errdefer with `results` not yet allocated. And
  `error.Canceled` can surface at several `try` points after the reply commits — `onToolStart`/
  `onToolResult` (each a cancellable channel `putOne`), an inline `tool.run` (`:421`), `group.await`
  (`:426`), and `try call.result` (`:432`) — while a concurrent call's `call.result` is defined
  only once the group is cancelled/joined.
- Stream usage: `anthropic/Transport` accumulates into its `usage` field from `message_start`
  (input/cache, `:178`) and the stop event (`message_delta`, output, `:191`), surfacing the total
  **only** via the `.stop` event. `provider.Stream.usageSoFar()` (`provider.zig:106`, a 0a
  addition) exposes the running total mid-stream. `recordUsage` (`Agent.zig:271`) is called only
  from the `.stop` arm of `readReply` (`:341`); a cancel never reaches `.stop`.
- `runTurnWorker` (`App.zig:342`) pushes `.turn_ended` on success or a non-cancel error but
  **nothing** on `error.Canceled`/`error.Closed` (`:345`). `cancelTurn` (`App.zig:503`) owns
  teardown: cancel+join the worker (`:507`), recall pending steering into the editor
  (`takeSteering`/`appendToEditor`, `:511`), then `session.abortTurn`.
- `session.abortTurn` (`Session.zig:287`) ends any open streamed message (`endMessage`), tears
  down turn chrome and flips `mode` to `.prompt` (`endTurn`), and appends a `feedback` "cancelled"
  block. It does **not** remove the optimistically-appended user block. After the mode flip,
  `applyStreamEvent` early-returns on `!animating()` (`Session.zig:166`) and drops any still-queued
  events. See R1/Phase 2.
- `App.submit` (`App.zig:546`) appends the user block optimistically
  (`transcript.append(.user, …)`, `:557`) then calls `runTurn`. The user block's index is **not
  tracked**. `Transcript` tracks `message_start` (`Transcript.zig:24`) — the first streamed
  *assistant* block, used by `discardMessage` (`:83`) to drop the contiguous partial-reply tail —
  but has **no** user-block index and no analog to the Agent's `base`. Rewinding the prompt needs
  new transcript state.

---

## Phase 1 — Commit partial turns to history on cancel

Scope: `lib/ai/Agent.zig` only. `error.Canceled`-specific; every other error path keeps today's
full rollback. **C1 (alternation-preserving fold) is gone** — the Agent no longer folds, so the
old "fold the prompt / fold-aware rollback" work dissolves. The one structural subtlety that
remains is C2: the `runTools` cancel rebuild must be region-aware to close every dangling
`tool_call` without a double-free.

### 1a. Error-kind split in `run`

Replace the single `errdefer self.items.shrinkRetainingCapacity(base)` with an explicit `catch` on
the round loop:

- `error.Canceled`: if `items.len == base + 1` (only the prompt — no complete round committed),
  the turn contributed nothing usable → `shrinkRetainingCapacity(base)` (drops the prompt too;
  Phase 2 returns it to the editor). Otherwise **keep** the committed rounds and re-raise
  `error.Canceled`.
- any other error: `shrinkRetainingCapacity(base)` and re-raise (today's behavior).
  `reportAndReset` already shrinks and returns without error, so the `catch` never fires for
  reported API errors — matching today.
- `error.Closed` (shutdown): treat as non-cancel — full rollback; the process is exiting.

Rollback is a plain truncation — the prompt is one item and history is a flat item list, so there
is no fold to reverse or block-count to restore. Arena item strings are abandoned on truncation,
not freed — matches today.

### 1b. Close a dangling `tool_call` in `runTools` on cancel (region-aware, C2)

Once `readReply` has committed the reply (`:367`) and it holds ≥1 `tool_call`, **any**
`error.Canceled` raised in `runTools` — at `handler.onToolStart`/`onToolResult` (cancellable
channel writes), an inline `tool.run`, `group.await`, or `try call.result` — leaves committed
`tool_call` items that need matching `tool_result`s, or the conversation is invalid (both providers
reject a dangling call). So frame the rebuild as "any post-commit cancel," not a two-point check.
On `error.Canceled`, **first cancel and join the group** (so every dispatched call's `call.result`
is defined — a concurrent call's is `undefined` until then), then build a `tool_result` for
**every** `tool_call`. Allocate the full `count`-sized set in the cancel path (the collect-loop
`results` may not exist yet — it is allocated at `:429`, after `group.await`). Fill it region-aware
over `collected`/`dispatched`:

- `[0..collected)` — already built during collection; the tool's content is already freed. Reuse
  the items as-is; never re-read `call.result`.
- `[collected..dispatched)` — after the join, `call.result` is defined: on success build the real
  `tool_result` and free the content (a mutating tool that already applied on disk keeps a truthful
  result, not a false "cancelled"); on error synthesize an `is_error` "cancelled" `tool_result`.
- `[dispatched..count)` — never ran; `call.result` is `undefined`: "cancelled" `tool_result` only,
  never read.

Then `self.items.appendSlice(self.gpa, results)` and return `error.Canceled`. **This path
supersedes the existing `errdefer` (`:410`), it must not compound it:** that errdefer also fires on
the `return error.Canceled` and frees `calls[collected..dispatched]` content, so freeing the same
content in the rebuild double-frees. Make the errdefer cancel-aware — e.g. advance `collected` to
`dispatched` as the rebuild consumes and frees each, so the errdefer's slice is empty on return —
or fold the group-cancel/join and the frees into one cancel branch. Other (non-cancel) errors keep
today's reap-and-free (the whole turn rolls back upstream).

Mutating calls run inline in call order, so a cancel stops before later mutating calls start; the
rebuilt set still covers every `tool_call`'s `call_id`. Reasoning stays at the head of the
committed assistant run (untouched here).

### Tests

- Kept-cancel (one complete round) **then a new prompt** → history holds consecutive user items;
  the Anthropic serializer merges them into one envelope (guards the no-fold path).
- Cancel during round-0 `fetchReply` (before any commit) → `items` truncates to `base`.
- Cancel during `runTools`, one finished + one unfinished mutating call → reply kept, both
  `tool_call`s closed (real result for the finished one, "cancelled" for the other); no leak, no
  double-free (guards C2).
- Reported API error and `error.Closed` still fully roll back to `base`.

**Test harness is real work (W1/R3):** the scripted stream is not cancellable and there is no
fake-tool seam — `runTools` calls the real tool registry, and `fetchReply` targets the Anthropic
client with `undefined` auth, which is why existing tests call `readReply` directly and never drive
`run`/`fetchReply`/`runTools`. Phase 1 must first add a scripted stream that yields `error.Canceled`
at a chosen event and a way to exercise `runTools` in isolation (a crafted reply plus a
cancellable/fake tool, or a tool-injection seam on `tool.Context`). Size Phase 1 to include this.

### Follow-through

- Rewrite the DONE **Streaming cancellation** `BACKLOG.md` entry and its matching `FEATURES.md`
  line — the invariant "a mid-turn cancel drops the partial assistant message" is now false for a
  cancel that already committed rounds.

---

## Phase 2 — Show only committed content in the transcript

Scope: `src/App.zig`, `src/Session.zig`, `src/Transcript.zig`. Uses the Phase 1 oracle
(`agent.items.len` vs `turn_base`).

### 2a. Reconcile against committed state, not against `message_start`

`message_start` is a consumer-thread fact and "mid-`readReply`" is a worker-thread fact; they are
coupled only through the async channel, so between the worker committing a reply (`Agent.zig:367`)
and the consumer applying the resulting `.tool_start`, `message_start` is non-null over an
**already-committed** reply. A cancel observed in that window would make a naive `discardMessage`
drop a committed reply's transcript blocks — divergence (W2). So `cancelTurn`, after join, first
**drains and applies every pending stream event** (the worker is done, so no more will arrive)
while `mode` is still `.turn` — before `abortTurn` flips it to `.prompt` and `applyStreamEvent`
starts dropping events (`Session.zig:166`). After that catch-up, `message_start` is non-null
**iff** the final state truly ends in an uncommitted partial, and `discardMessage` is exact.

The drain must reach **both** the channel and the current batch. The consumer applies events in
coalesced batches (`runLoop` drains up to a full batch per `get`, `App.zig:238`), and `cancelTurn`
is invoked from *within* that loop while handling the `esc`/`ctrl-c` `.keys` event — so a
`.tool_start` later in the same batch is not applied yet and is invisible to a channel-only drain.
Apply the batch's remaining events (while `mode` is still `.turn`) as well as anything left on the
channel before `abortTurn` flips the mode; otherwise the straggler is applied afterward, dropped at
`Session.zig:166`, and `message_start` still points at a committed reply — the exact W2 divergence.

### 2b. Rewind by the oracle

Add the missing transcript state: capture `transcript_start = transcript.entries.len` and an owned
copy of the prompt **before** the optimistic `transcript.append(.user, …)` — on *both*
optimistic-append paths, `submit` (`App.zig:557`) and `startSteeringTurn` (`App.zig:495`), or
centralize the append+capture so a steering-started turn can't `rewindTo` a stale index. Store
`turn_base` and `turn_prompt: ?[]u8` on `App` (set in `runTurn`/`submit`/`startSteeringTurn`) and
`transcript_start` on the turn mode.
Free `turn_prompt` on **every** turn-end path — normal `.turn_ended`, error, cancel — not only
cancel (S3).

Then in `cancelTurn` (after the 2a drain):

- **Nothing committed** (`agent.items.len == turn_base`): `transcript.rewindTo(transcript_start)`
  (a small generalization of `discardMessage`: shrink + free tail + `endMessage`) drops the user
  block and the partial run together; return `turn_prompt` to the editor via the Phase 4 composer;
  no "cancelled" feedback block (nothing remains to annotate).
- **Committed rounds** (`> turn_base`): `transcript.discardMessage()` drops only the in-flight
  partial (exact after 2a); keep the committed blocks; append the "cancelled" feedback block.

Today `abortTurn` unconditionally does `endMessage` + a "cancelled" feedback block; Phase 2 makes
that path oracle-driven and adds the `rewindTo` branch.

### 2c. Optional: display synthesized tool_results

In the committed case where `runTools` was cancelled, append cancelled `tool_result` display blocks
for the unfinished tools, mirroring Phase 1b's history results so the transcript matches history.
Defer if scope-tight (R5).

### Tests

- Committed-rounds cancel with a `.tool_start` still queued → after drain, the committed reply is
  kept (guards W2), the in-flight partial dropped.
- Nothing-committed cancel → transcript rewound to `transcript_start`; prompt available for the
  editor.
- Cancel of a **steering-started** turn (`startSteeringTurn`) → rewinds its own `transcript_start`,
  not a stale one.
- Cancel landing inside `drainSteering` (the combined user item is appended at `Agent.zig:167`
  before `onSteering` at `:168`) → history keeps the steering item while the display mirror still
  shows it queued; the oracle and transcript/history sync stay correct in that window.
- `Transcript.rewindTo` unit test.

---

## Phase 3 — Account cancelled turns' token cost

Scope: `lib/ai/Agent.zig`, `src/App.zig` (the accessor already exists).

- **Accessor exists.** `provider.Stream.usageSoFar()` (`provider.zig:106`) already returns the
  `llm.Usage` accumulated so far — added in 0a, so the old field/method name collision (W3) is
  already resolved. Mid-stream only input/cache are populated; `output` stays 0 until the stop
  event — so this captures the input/cache the provider bills, not streamed output.
- **Fold on cancel.** Split `fetchReply`'s `readReply` `catch` so `error.Canceled` (not
  `error.Closed`) calls `self.recordUsage(model, stream.usageSoFar())` before returning — read
  before the `defer stream.deinit()`. Mutually exclusive with the `.stop` fold per attempt (`.stop`
  returns normally; each retry has a fresh stream), so no double count (R4).
- **Surface to the UI.** The worker emits no `.usage` on cancel, so `cancelTurn` (worker joined)
  syncs the shown stats from `agent.stats`.

### Tests

- `usageSoFar()` returns input/cache after `message_start`, before `.stop` (extend the Transport
  usage tests).
- `Agent`: cancel mid-stream records the stream's usage into `stats` exactly once.

---

## Phase 4 — Partial-reasoning citation + editor composition

Scope: `src/App.zig`, `src/Session.zig`, a keybinding/affordance. Builds on Phases 1–2.

### Citation

Before the partial is dropped (before `discardMessage`/`rewindTo` in `cancelTurn`, after the 2a
drain), snapshot the partial streamed reasoning/answer — the text of the transcript blocks from
`message_start` to the tail — into an owned `?[]u8` on `Session` (freed/replaced on the next cancel
or turn). Then offer to fold it into the next prompt as a quoted citation.

Open (decision needed): the affordance. Candidate default — a dedicated key in prompt mode that
inserts the snapshot as a `> `-quoted block at the caret (opt-in, non-noisy). Alternatives: a
yes/no on cancel, or a slash command. Also: scope (thinking vs. answer) and truncation.

### Editor composition on cancel

Up to four writers target the editor on cancel: (a) in-progress typing, (b) recalled steering
(`takeSteering`/`appendToEditor`, today), (c) the returned prompt (Phase 2), (d) the citation
(opt-in). Replace the blind `appendToEditor` calls with one composer:

- Order: returned prompt → blank line → recalled steering → blank line → in-progress typing. This
  prepends, changing today's append-after-typing semantics (S4), so the composer **replaces**
  `appendToEditor` rather than wrapping it.
- The citation is the model's words — inserted quoted and only on the explicit opt-in, not
  auto-mixed.
- Never clobber in-progress typing; caret at the end.

Open (decision needed): exact order/separators, and whether the citation prepends or stands as a
separate quoted region.

### Tests

- Cancel mid-reasoning snapshots the partial; the opt-in inserts it quoted.
- Composer assembles prompt + steering + typing in order, caret at end, empty sources skipped.

---

## Risks / open questions

- **C1 dissolved.** Alternation is no longer the Agent's job — the serializer merges a same-role
  run — so the old fold + fold-aware rollback is gone. History may legally hold consecutive user
  items (a kept-cancel `tool_result` run followed by the next prompt).
- **R1/W2 — reconciliation must drain first.** Not optional: because `message_start` can be
  non-null over a committed reply, Phase 2 must drain+apply pending events before reconciling (2a) —
  including the current batch's un-applied events, not just the channel, since `cancelTurn` runs
  mid-batch.
- **R3/W1 — Phase 1 test harness.** A cancellable scripted stream + a `runTools`/tool seam do not
  exist; building them is part of Phase 1.
- **R4 — usage double-count.** Impossible: `.stop` and the cancel fold are mutually exclusive per
  attempt.
- **R5 — synthesized-`tool_result` display.** Whether to mirror cancelled tool results in the
  transcript (2c) or keep history-only.
- **R6 — Phase 4 UX decisions.** Affordance and composition order (above).
- **S3 — lifetimes.** `turn_prompt` owned copy must be freed on every turn-end path. Post-join
  reads of `agent.items`/`agent.stats` in `cancelTurn` are race-free (cancel joins first). Arena
  item strings on rollback are abandoned, not freed (matches today).

## Verdict

Architecture and sequencing sound; Phase 2's oracle correctly depends on Phase 1. The 0a reshape
already paid down the biggest complication: C1 is gone and rollback is a plain truncation, so
Phase 1 is now the error-kind split (1a) plus the region-aware `runTools` rebuild (C2, 1b) plus the
test harness (W1). Start with Phase 1.
