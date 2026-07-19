# Deep review of `lib/` — 2026-07-18

Multi-agent review of the foundation before session persistence, a bash tool, and subagents land:
27 reviewers over 8 file groups (correctness, concision, tests) plus cross-provider, style, and
FEATURES-drift passes; every finding adversarially verified (three independent refuters for
high-severity bug claims). 183 raw findings → 166 confirmed, 17 refuted; deduped below.

Fix order: (1) Bugs, (2) `Agent.run` fetch seam + Tests, (3) Concision — the provider dedup only
after tests guard it, (4) Comments + Style. Line estimates are the finders'; overlapping
duplication claims double-count somewhat (realistic net win ≈ 1,500 lines).

## Bugs

- [x] `lib/ai/anthropic/Transport.zig:384` **high** — retryAfter reads the response head after readerDecompressing invalidated it
- [x] `lib/ai/auth_store.zig:71` **high** — auth.json rewritten via truncate-then-write; interruption wipes every account's credentials
- [x] `lib/ai/openai/Transport.zig:314` **high** — Same invalidated-head read in the OpenAI transport's retry-after path
- [x] `lib/ai/tool/grep.zig:82` **high** — Non-UTF-8 grep output serializes as a JSON integer array, 400-failing the whole turn
- [x] `lib/ai/Agent.zig:178` **medium** — Cancel racing a round-boundary steering drain silently loses the steering text
- [x] `lib/ai/Agent.zig:374` **medium** — readReply merges adjacent reasoning runs, corrupting blobs and stream order
- [x] `lib/ai/anthropic/Transport.zig:224` **medium** — A data line that fails JSON parsing kills the turn instead of being retried
- [x] `lib/ai/anthropic/oauth.zig:76` **medium** — Callback code/state interpolated into token-exchange JSON unescaped
- [x] `lib/ai/oauth_callback.zig:57` **medium** — OAuth callback accepts exactly one connection; any stray connection defeats a successful login
- [x] `lib/ai/openai/Transport.zig:203` **medium** — Premature stream end mid data-line becomes a non-retryable JSON parse error
- [x] `lib/ai/tool/edit.zig:39` **medium** — edit reads the target file with .unlimited — unbounded allocation
- [x] `lib/ai/tool/read.zig:71` **medium** — First shown line is exempt from the 50 KB cap, so one line can return up to 16 MB
- [x] `lib/terminal/View.zig:321` **medium** — firstChange==null with a nonzero slide takes paintCaretOnly, desyncing cursor_row; a top-trimmed window with unchanged tail reads as "unchanged", leaving stale rows
- [x] `FEATURES.md:141` **low** — Promised retry on any 5xx status; code retries only 500/502/503/504 (+529)
- [x] `lib/ai/anthropic/Transport.zig:267` **low** — Unrecognized frame after terminal delta errors IncompleteReply
- [x] `lib/ai/anthropic/oauth.zig:194` **low** — Unvalidated expires_in can overflow i64 and panic during token exchange/refresh
- [x] `lib/ai/command/login.zig:47` **low** — /login conflates 'authenticated' with 'already-active', diverging from FEATURES
- [x] `lib/ai/command/root.zig:36` **low** — Command-name split treats space/tab but not newline as a delimiter
- [x] `lib/ai/openai/Transport.zig:281` **low** — account_id and token reach request headers unvalidated, unlike ModelCatalog
- [x] `lib/ai/openai/oauth.zig:110` **low** — refresh() builds its JSON body by raw formatting, breaking on tokens needing escaping
- [x] `lib/ai/tool/read.zig:59` **low** — Explicit limit bypasses the 2000-line cap and limit=0 emits a false paging hint
- [x] `lib/ai/tool/grep.zig:78` **low** — grep swallows OutOfMemory as a silent file skip with no incompleteness marker
- [x] `lib/ai/tool/grep.zig:76` **low** — Bytes read from skipped-oversized files are never charged to the 256 MB I/O budget
- [x] `lib/terminal/Input.zig:119` **low** — Unterminated bracketed paste wedges all input forever and grows the pending buffer unboundedly
- [x] `src/layout.zig:37` **low** — idTool overflows usize once a turn shows 253 or more concurrent tool boxes

## Tests

- [x] `lib/ai/Agent.zig:171` **high** — Round bound (50) and clean overrun failure have no test; run() is never driven
- [x] `lib/ai/Agent.zig:211` **high** — fetchReply retry orchestration untested: attempt bound, onStreamReset, retry-after, cancel-not-retried
- [x] `lib/ai/net.zig:102` **high** — No test that a caller cancel surfaces as Canceled, not Timeout, through withTimeout
- [x] `lib/ai/tool/write.zig:29` **high** — Mutating tools (write, edit round-trip, fs.writeFile) have zero end-to-end tests
- [x] `lib/terminal/Input.zig:92` **high** — Malformed/truncated UTF-8 decoding and forward progress are completely untested
- [x] `lib/ai/Accounts.zig:100` **medium** — Cross-vendor startup preference unpinned: a paid Anthropic key beats an OpenAI subscription
- [x] `lib/ai/Agent.zig:280` **medium** — API-error path (rollback + onError, turn ends cleanly) has no test
- [x] `lib/ai/anthropic/Auth.zig:77` **medium** — Auth.zig has zero tests; failed-refresh guarantee unguarded
- [x] `lib/ai/anthropic/Transport.zig:216` **medium** — Cancel-during-read clean-abort path has no test
- [x] `lib/ai/anthropic/Transport.zig:238` **medium** — Mid-stream API error frame (error.ApiError + errorText) untested
- [x] `lib/ai/anthropic/Transport.zig:314` **medium** — send's established-race teardown (ownership-on-failure) untested
- [x] `lib/ai/auth_store.zig:74` **medium** — save/remove/open never exercised; the owner-only (0o600) permission guarantee is unprotected
- [x] `lib/ai/command/login.zig:50` **medium** — Select on an already-logged-in subscription is untested
- [x] `lib/ai/command/model.zig:38` **medium** — No allocation-failure coverage for the picker option builders
- [x] `lib/ai/command/model.zig:47` **medium** — Active-row marking's account comparison is untestable by current test
- [x] `lib/ai/command/root.zig:34` **medium** — Known-command dispatch and select routing have no test anywhere
- [x] `lib/ai/openai/Auth.zig:75` **medium** — Auth.zig has zero tests: failed-refresh-intact and load error paths unpinned
- [x] `lib/ai/openai/Transport.zig:145` **medium** — No test ever consumes the [DONE] compatibility sentinel
- [x] `lib/ai/openai/Transport.zig:195` **medium** — Canceled-vs-ReadFailed refinement in readFailed is untested
- [x] `lib/ai/openai/Transport.zig:252` **medium** — send()'s connect-timeout teardown (established flag) is never tested
- [x] `lib/ai/tool/find.zig:63` **medium** — find's overflow count and too-large-to-scan reports untested
- [x] `lib/ai/tool/grep.zig:106` **medium** — grep's result limit, skips, line cap, and honesty reports untested
- [x] `lib/ai/tool/read.zig:45` **medium** — Cancellation propagation from tool file I/O is completely untested
- [x] `lib/terminal/Emulator.zig:93` **medium** — Emulator models CSI 0 A/B/C as a zero move; real terminals treat 0 as 1, masking the zero-guard
- [x] `lib/terminal/Input.zig:62` **medium** — feed()'s compaction branch (start > 0) is never executed by any test
- [x] `lib/terminal/Resize.zig:39` **medium** — Resize watcher has zero tests for the SIGWINCH-wake and disposition-restore guarantee
- [x] `lib/terminal/View.zig:264` **medium** — The resize fallback (columns/rows change forces a reset) has no test
- [x] `lib/ai/Agent.zig:86` **low** — Per-model stats bound overflow (cumulative totals stay exact past 16) untested
- [x] `lib/ai/Agent.zig:1203` **low** — Reasoning-id threading test duplicates the origin-tagging test's script and asserts (~20 lines)
- [x] `lib/ai/anthropic/Transport.zig:341` **low** — Identity fork (headers, unencoded response, error head) untested
- [x] `lib/ai/anthropic/wire.zig:485` **low** — Two effort-shape tests fully subsumed by the golden byte tests (~59 lines)
- [x] `lib/ai/models.zig:108` **low** — Shipped OpenAI effort maps untested: the none-floor guarantee is only tested on a fabricated map
- [x] `lib/ai/oauth_login.zig:199` **low** — Cancellation test duplicates the callback-error test's exact code path (~13 lines)
- [x] `lib/ai/openai/ModelCatalog.zig:143` **low** — model_count_max envelope bound is untested
- [x] `lib/ai/openai/oauth.zig:295` **low** — jwtExpiryMs crafted-exp overflow guard has no test
- [x] `lib/ai/tool/find.zig:75` **low** — find/grep/read happy-path tests assert live repo layout, not fixtures
- [x] `lib/terminal/Input.zig:225` **low** — Duplicate ctrl-lowercase CSI-u row while the uppercase branch is untested
- [x] `lib/terminal/Tty.zig:122` **low** — Tty.read's timeout-to-null and EndOfStream mapping is untested
- [x] `lib/terminal/Tty.zig:140` **low** — Tty.size's absence-not-default contract has no test
- [x] `lib/terminal/View.zig:137` **low** — No test composes an over-wide row through the Sink
- [x] `lib/terminal/View.zig:763` **low** — Cursor show/hide dedupe (emit only on visibility change) is unasserted
- [x] `lib/terminal/View.zig:824` **low** — Boundary test pins exact ZWB byte layout instead of the non-fusing property
- [x] `lib/terminal/width.zig:441` **low** — test wrap and test rows re-cover equivalence classes already pinned by test wrapper (~29 lines)

## Concision

- [x] `lib/ai/anthropic/Transport.zig:121` **medium** — Entire SSE pull-stream engine duplicated across the two provider Transports (~320 lines)
- [x] `lib/ai/anthropic/Auth.zig:28` **medium** — Auth.zig credential lifecycle is one file duplicated per provider (~150 lines)
- [x] `lib/ai/anthropic/oauth.zig:100` **high** — Bounded token-POST plumbing duplicated across the two oauth modules (~105 lines)
- [x] `lib/ai/tool/walk.zig:75` **high** — Manual failure-routing plumbing in collect replaced by one drain defer (~31 lines)
- [x] `lib/ai/Agent.zig:404` **medium** — readReply's flush epilogue duplicated; 10 loose accumulation locals (~20 lines)
- [x] `lib/ai/anthropic/Transport.zig:452` **medium** — std.json.Value scanning helpers redefined in six provider files (~65 lines)
- [x] `lib/ai/anthropic/Transport.zig:545` **medium** — Nine tests repeat the same 7-11 line Stream field-by-field setup (~50 lines)
- [x] `lib/ai/anthropic/Transport.zig:785` **medium** — ChunkedReader hand-rolls std.testing.Reader's artificial_limit (~34 lines)
- [x] `lib/ai/anthropic/oauth.zig:45` **medium** — PKCE generation duplicated verbatim in both oauth modules (~26 lines)
- [x] `lib/ai/anthropic/wire.zig:181` **medium** — Tool parameters JSON-schema writer duplicated across the wire serializers (~17 lines)
- [x] `lib/ai/auth_store.zig:146` **medium** — serializeWithout is serializeMerged minus two lines; save/remove repeat read/write blocks (~28 lines)
- [x] `lib/ai/command/login.zig:71` **medium** — Three identical 13-line Accounts factories and two 8-line Agent factories in tests (~37 lines)
- [x] `lib/ai/command/outcome.zig:24` **medium** — 10 copies of the feedback-assert switch across the command tests (~47 lines)
- [ ] `lib/ai/command/root.zig:46` **medium** — Name-keyed select dispatch is a round-trip; Pick can carry the select fn directly (~12 lines)
- [x] `lib/ai/oauth_callback.zig:128` **medium** — TimeoutBound and its sleep re-implement net.zig's Select race (~20 lines)
- [x] `lib/ai/openai/Auth.zig:58` **medium** — Four hand-rolled JSON accessor sets duplicated across the openai module (~36 lines)
- [x] `lib/ai/openai/oauth.zig:148` **medium** — awaitTokens is a single-production-use generic wrapper over withTimeout (~36 lines)
- [x] `lib/ai/provider.zig:28` **medium** — Client union duplicates gpa/io/timeouts per arm; Stream and send duplicate per-vendor pairs (~45 lines)
- [x] `lib/terminal/View.zig:288` **medium** — render() repeats `self.front ^= 1; return;` in five branches and clears force_reset twice (~14 lines)
- [x] `lib/terminal/width.zig:49` **medium** — Materializing `wrap` is used only by its own test; all real callers use `wrapper` (~39 lines)
- [x] `lib/ai/Accounts.zig:211` **low** — Shadow replacement list with an applied flag is a clear-on-failure append (~5 lines)
- [x] `lib/ai/Agent.zig:477` **low** — runToolsWith walks the reply twice to count then fill calls (~6 lines)
- [x] `lib/ai/anthropic/Auth.zig:56` **low** — jsonString/jsonInt are byte-identical copies of oauth.zig's (~15 lines)
- [x] `lib/ai/anthropic/Transport.zig:403` **low** — decompressBuffer and json accessors duplicated across the provider (~24 lines)
- [x] `lib/ai/anthropic/oauth.zig:166` **low** — decompressBuffer duplicates Transport.zig's byte-for-byte (~9 lines)
- [x] `lib/ai/command/model.zig:36` **low** — alloc/filled/errdefer options boilerplate copy-pasted into all four pickers (~7 lines)
- [x] `lib/ai/command/root.zig:19` **low** — The args parameter is plumbed to every run handler and ignored by all of them
- [x] `lib/ai/llm.zig:214` **low** — Event.Stop.reason is produced but never consumed (~11 lines)
- [x] `lib/ai/models.zig:46` **low** — EffortMap.resolve's six-arm switch is an inline-else field access (~5 lines)
- [x] `lib/ai/net.zig:44` **low** — delayMs is only called by backoffMs; fold it in (~6 lines)
- [x] `lib/ai/oauth_callback.zig:111` **low** — queryParameter's enum, bufPrint needle, and manual scan collapse; error.BadCallback is dead (~7 lines)
- [x] `lib/ai/oauth_login.zig:6` **low** — Browser.launch's nested fallback is a loop over two launchers
- [x] `lib/ai/openai/ModelCatalog.zig:65` **low** — Credentials struct exists only to shuttle two values between two private fns (~8 lines)
- [x] `lib/ai/openai/Transport.zig:333` **low** — decompressBuffer duplicated verbatim in three openai files (~16 lines)
- [x] `lib/ai/openai/Transport.zig:519` **low** — Ten tests copy-paste the same Stream field-initialization stanza (~43 lines)
- [x] `lib/ai/openai/oauth.zig:21` **low** — pub const redirect_uri is never referenced
- [x] `lib/ai/tool/edit.zig:39` **low** — Copy-pasted Canceled-vs-report catch switch across five tool call sites (~5 lines)
- [x] `lib/ai/tool/glob.zig:51` **low** — match and matchSegment are the same backtracking loop at two granularities (~12 lines)
- [x] `lib/ai/tool/grep.zig:124` **low** — lineContains hand-rolls std.ascii.findIgnoreCase (~11 lines)
- [x] `lib/terminal/Emulator.zig:71` **low** — OSC/DCS/APC/PM/SOS skip branch is unreachable in the test emulator (~10 lines)
- [x] `lib/terminal/Tty.zig:54` **low** — PosixRestore duplicates PosixSetup's restore; one control struct suffices (~8 lines)
- [x] `lib/terminal/Tty.zig:162` **low** — rollbackWith/leaveWith are one-line forwarders around cleanupWith (~7 lines)
- [x] `lib/terminal/View.zig:142` **low** — Sink.spaces duplicates Sink.repeat body byte for byte (~5 lines)
- [x] `lib/terminal/View.zig:467` **low** — Single-use viewportTop helper inlines to one saturating subtraction (~8 lines)
- [x] `lib/terminal/escape.zig:35` **low** — Three identical cursor-motion functions collapse to one with a final-byte parameter (~12 lines)
- [x] `lib/terminal/grapheme.zig:85` **low** — Hand-rolled binary search duplicates std.sort.binarySearch (~8 lines)
- [x] `lib/terminal/grapheme.zig:118` **low** — State.init hand-zeroes five fields instead of using default field values (~6 lines)

## Comments

- [ ] `lib/ai/Agent.zig:1` — Verbose comments throughout Agent.zig (~55 lines)
- [ ] `lib/ai/Steering.zig:1` — Steering header and test narration are 2-3x terse length (~12 lines)
- [ ] `lib/ai/anthropic/Transport.zig:37` — Idle-window/filler rationale restated 4+ times in multi-line paragraphs (~40 lines)
- [ ] `lib/ai/anthropic/wire.zig:70` — Serializer comments restate the same rules two or three times each (~18 lines)
- [ ] `lib/ai/auth_store.zig:82` — The never-wipe-siblings rationale is stated six times (~8 lines)
- [ ] `lib/ai/command/Context.zig:1` — Header speculates about future growth; accounts field doc restates the Accounts type (~5 lines)
- [ ] `lib/ai/command/login.zig:1` — 8-line //! header restates the FEATURES.md /login entry; verbose narration below (~16 lines)
- [ ] `lib/ai/command/logout.zig:1` — 6-line //! header restates the FEATURES.md /logout entry (~7 lines)
- [ ] `lib/ai/command/model.zig:1` — //! header duplicates the FEATURES.md /model entry; collect doc and test comments over-explain (~8 lines)
- [ ] `lib/ai/command/outcome.zig:1` — Multi-sentence ownership paragraphs where one terse line each suffices (~8 lines)
- [ ] `lib/ai/command/root.zig:1` — Doc comments restate signatures: find, run, and half the header (~7 lines)
- [ ] `lib/ai/models.zig:31` — EffortMap's three awkward-ends cases are narrated three times over (~8 lines)
- [ ] `lib/ai/net.zig:1` — Module header and decl docs restate the same rationale up to four times (~15 lines)
- [ ] `lib/ai/openai/wire.zig:32` — Five-line rationale blocks and test comments restating asserts (~12 lines)
- [ ] `lib/ai/tool/root.zig:22` — Barrier rationale stated twice; //! header over-explains the registry (~6 lines)
- [ ] `lib/ai/tool/walk.zig:37` — Verbose doc paragraphs and test narration restate FEATURES.md and the asserts (~26 lines)
- [ ] `lib/terminal/Tty.zig:12` — Multi-sentence comments where one terse WHY sentence carries it (~8 lines)
- [ ] `lib/terminal/View.zig:1` — 44-line module header and multi-sentence field/test comments restate FEATURES.md and the function docs (~40 lines)
- [ ] `lib/terminal/escape.zig:1` — Four files lack the //! module header every other file carries
- [ ] `lib/terminal/width.zig:120` — Verbose doc paragraphs and assert-narrating test comments in width.zig (~13 lines)

## Style & spec drift

- [ ] `FEATURES.md:244` **medium** — OpenAI transport section omits the implemented subscription (Codex) request fork
- [ ] `FEATURES.md:59` **low** — Reset-trigger list omits the external-output invalidation reset
- [ ] `FEATURES.md:133` **low** — Undocumented: effort none drops stored reasoning from Anthropic requests
- [ ] `FEATURES.md:234` **low** — OpenAI decode entry omits streamed API-error surfacing
- [ ] `lib/ai/command/outcome.zig:22` **low** — Same ok/err report enum named Status in commands but Outcome in tools
- [ ] `lib/ai/llm.zig:64` **low** — Account's vendor lookup is a free function while its siblings are methods
- [x] `lib/terminal/width.zig:49` **low** — Allocator/io parameter position drifts from the dominant gpa-first order

## Notes

- `lib/ai/net.zig:95` (withTimeout spawns work before reserving the timer) was contested between
  verifiers; the no-concurrency degrade is documented behavior — won't fix.
- `src/layout.zig:37` sits outside `lib/` but was confirmed in passing and is tracked under Bugs.
- Refuted claims worth remembering as non-bugs: queryParameter substring matching (guarded),
  Resize SIGWINCH use-after-deinit (refuted from std semantics), "steady-state allocates nothing"
  test gap (covered).

Test gaps deliberately left open (each needs a seam or infrastructure not worth its weight yet):

- [ ] `lib/ai/openai/Auth.zig` — failed-refresh-leaves-credential-intact: `oauth.refresh` hits a
  comptime-const token_url; the anthropic side is pinned via its refresh seam.
- [ ] Both transports — the established=true half of send's teardown (timer wins after a full
  connect) needs a real socket plus URL injection.
- [ ] `lib/ai/tool/find.zig` / `grep.zig` — the too-large-to-scan and 256 MB/100k-file budget
  honesty reports sit behind hard-coded consts.

Follow-ups surfaced while fixing:

- [ ] `src/App.zig` — a `.steering_consumed` event enqueued just before a cancel may still be
  dropped app-side; the Agent-side errdefer re-push is fixed, the App path is not verified.
- [ ] `lib/terminal/Input.zig` — a CSI whose final byte never arrives still buffers unboundedly
  (same family as the fixed paste bound; needs an adversarial byte-stream bound).
- [ ] The two transports' `retryable()` now differ in idiom (`@intFromEnum/100 == 5` vs
  `.class() == .server_error`; `.class()` maps out-of-range statuses to server_error) — unify
  when the SSE engine dedups in phase 3.
