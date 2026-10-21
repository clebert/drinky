# Drinky

Drinky is a Zig coding agent that keeps the conversation in the terminal scrollback.

## Layers

`build.zig` declares the module graph, and a module imports only what the build names. `src` imports
`application`, `terminal`, and `markdown`. `lib/providers` and `lib/tools` import `lib/core`.
`lib/accounts` imports `lib/core` and `lib/providers`. `lib/application` imports `core`,
`providers`, `tools`, and `accounts`. No library imports `src`. The frontend test build adds the
infrastructure modules for its existing fakes.

- `lib/terminal` owns keyboard input, screen output, and the device seam. It knows no model and no
  provider. `Tty` implements the device seam.
- `lib/markdown` imports `std` alone. It parses Markdown and exposes source offsets. It knows no
  terminal, role, or URL limit. It holds the CommonMark test corpus and its license notice.
- `lib/core` imports `std` alone. It owns the neutral conversation, session, provider seam, tool
  seam, and retry policy. It also holds the shared actor shell, timeout race, error-set check,
  allocation panic, and text helpers. It names no vendor. An account is an opaque id, and a
  reasoning proof holds that id and opaque payload bytes. The session is an actor with one command
  loop and one child task for a turn or an aside. An aside sends one request outside the
  conversation, with no tools and the model and the effort of a turn.
- `lib/providers` implements the provider seam. It owns the HTTP transport, SSE engine, credential
  seam, and one dialect per wire: Responses, Messages, and Gemini. A dialect builds requests,
  classifies failures, and decodes frames into core events. A per-account switch is a dialect
  option.
- `lib/tools` implements the tool seam. It owns the tool registry and required-skill checks. Tool
  outputs separate model content from the conditions and measures that a client shows.
- `lib/accounts` owns the account table, credentials, sign-in flows, model catalog, public metadata,
  usage sources, and saved state. `Client` builds the provider of one row and reports its usage
  source before the stop of every reply. The account registry is an actor with a child task for a
  sign-in or a model fetch. A row is an index into the table.
- `lib/application` owns the shared controller, workflows, canonical transcript, interaction state,
  turn boundaries, accounts, saved choices, statistics, and their lifetimes. The controller exposes
  an opaque handle with commands, synchronous responses, events, and snapshots. Record changes use
  stable ids. No client repeats a turn rule on these records. Apart from the `interface`
  preferences, events and snapshots contain no terminal layout or control bindings. Each frontend
  supplies its confirmation controls. The application also owns the config, discovery, system
  prompt, and tools. Shared reference facts include terminal controls. The public `support`
  namespace exposes helpers without a runtime owner or controller access. `support.outOfMemory`
  exposes `core.fatal.outOfMemory`.
- `src` owns the native clients. The terminal loop hosts the controller and owns keys, editor
  mechanics, focus, and animation. The screen owns a disposable presentation copy and its layout
  caches. It applies interactions and snapshots through one path. A snapshot preserves local
  navigation when the page id or picker id stays unchanged. The presentation copy applies record
  changes by id and groups work runs for display. Native clients use only public application
  commands and events for application operations. Routine repaints use the local copy without a
  snapshot. The UI fits and paints Markdown through one shared layout walk. `Herdr.Endpoint` stays
  terminal integration data.
- `src/ui/role.zig` maps a role to terminal colors. A widget names a role and writes no color of its
  own.

The controller has no loop task, but its calls can perform synchronous I/O. One host task serializes
controller calls. The session and account registry post owned mail to the mailbox of the host. The
mailbox must accept posts from concurrent tasks. `Controller.receive` takes ownership of each mail.
The host closes its mailbox before controller destruction. It releases any remaining mail with the
controller allocator. Event callbacks borrow their data, and a sink copies data that it retains. A
sink must not call the controller from an event callback. A response borrows its editor text until
the next command. The host applies or copies that text before it submits another command. A client
dismisses a notice by its id. Dismissal also withdraws its confirmation. A stale notice id changes
no interaction state.

A loop task lends state to its child task and touches none of it until the child ends. The child
returns its result with its end. A lock guards state that the tasks of two actors share.

A turn and an aside report the final available usage of each model attempt to the controller. The
controller adds each cost to the session total. `lib/application/billing.zig` holds the charge rule.
The runner reports tool costs through its own sink. A `drinky run` under the `bash` tool reports its
costs through a private pipe to that sink. The pipe ends with the `bash` invocation.

## Interface

These rules outrank existing behavior and repository precedent.

- Equivalent UI elements must share a semantic renderer across the transcript, pages, and status
  surfaces. The shared renderer must own the roles, symbols, metadata order, and width reductions.
- An exit ends one thing. An exit is Esc, Ctrl+C, or Ctrl+D. No exit reaches past the step, the
  page, or the turn that holds it.
- Drinky destroys nothing without a decision. If a key press has another meaning, Drinky warns
  first. A second press of the same key confirms the action.
- `/verbose` toggles the displayed detail, even during a turn. It clears terminal scrollback and
  repaints the complete transcript without a warning.
- A failure is not a decision. Every draft and user message survives a failure. Out of memory is the
  exception. It ends Drinky, and the draft is lost.
- `user_note` is the role of a message that Drinky writes for the user. An event reports session
  state. A user message holds typed text or a handoff that the user applied.

## Code

- Drinky has no dependency but the Zig standard library. `build.zig.zon` names no package.
- Write no comment. A name or a test carries the intent, and a fact that matters goes into a test, a
  name, or the chat.
- Less code is better. Delete code without a caller. Add a seam, a pointer with a vtable in the
  shape of `std.mem.Allocator`, only when a second implementation or a test fake exists.
- Before you write a helper, search the modules that the build lets the module import. Move a second
  copy to the lowest module that both callers import.
- Production code holds no option, entry point, mode, or global that only a test uses. A test fakes
  the clock through an `Io` and the network through a `Transport`. A size cap stays an option when
  no test can reach its production value.
- Do not pass the implementation of a contract as `anytype`. A seam or a generic type states the
  contract.
- A branch that no production path reaches is an assert or `unreachable`. It holds no text for the
  user.
- Write a rule for each vendor, wire, or sign-in flow as an exhaustive switch over its enum.
- A seam, a callback, and a timed call declare their error set. Do not widen an error set to
  `anyerror`.
- The type that defines an event owns its `dupe` and its `deinit`. A sink takes `*const Event`,
  returns nothing, and copies what it keeps.
- Allocation failure is fatal to the process. Propagate `error.OutOfMemory` and release partial
  allocations. Application boundaries must call `core.fatal.outOfMemory`. The panic ends every
  controller in the process. A callback or task must call the same function when it cannot propagate
  the error. Never suppress an allocation failure, including during cancellation or cache
  operations. Convert failures from known allocating writers into `error.OutOfMemory`. Keep device
  write failures distinct.
- Only reads of optional caches, saved choices, and display metadata can treat other errors as
  missing data. Every other reader keeps its error contract.
- A cancel must end every wait. Never run the work of a task in place of the task. When
  `io.concurrent` fails, report the failure. A zero window starts the task without a timer.
- The module graph is the architecture. A new module gets its row in `build.zig` and its line in the
  Layers section of this file.
- The development tools of the Zig code are the Zig toolchain alone. `zig fmt` formats every Zig
  file, and the check accepts no unformatted file.
- Follow `.agents/skills/zig-style/SKILL.md` for every Zig file.

## Tests

- Write a test for a contract at a module boundary, for a bug, or for a decision table.
- Test equivalent UI elements across surfaces, severities, and narrow widths. Compare the roles,
  symbols, metadata order, and width reductions.
- Write no test for what the compiler proves or for a framework.
- For a bug, write a regression test first and confirm that the bug causes its failure. Then fix the
  bug. Keep one small regression test at the narrowest public boundary that proves the behavior.
  Consolidate duplicate regression tests. Remove a temporary probe after a permanent test covers its
  behavior.
- Do not require recovery tests for fatal allocation failures. A fix of out-of-memory handling needs
  a test only where `std.testing.checkAllAllocationFailures` covers it. Use exhaustive allocation
  checks for cleanup where functions return `error.OutOfMemory`.
- A test reaches a state through commands, events, keys, and options, with a hand-written fake. It
  reads the state through public functions.
- Use no network and no sleep. A test takes `std.testing.io`. Build an `Io` only to set a limit or
  to control the clock.
- Run `std.testing.checkAllAllocationFailures` on `core.testing.no_resize_allocator`.
- A fake that waits for a cancel waits on an event that no task sets. The test checks that the
  cancel ended the wait.
- A test that changes with every implementation change tests the implementation. Delete it or move
  it to the boundary.
- A test calls a private pure function only when its input and its output are facts outside the
  code. A vendor date and its epoch seconds are such facts. A model before the catalog merge is not
  such a fact. Every other test calls the public function that gives the same fact.
- A test name states the behavior that its body checks.
- Put the shared test code of a module into its `testing.zig`. Put a private rig, fixture, or fake
  after the first test of its file.
- Zig runs a test only when an import chain from a module root reaches its file. The check counts
  the declared tests against the tests that ran, so an unreachable test fails the check.
- Note the runtime of each test binary when you start a feature, and compare it when the feature is
  complete. Investigate a repeatable increase of more than one second. A test that waits on the wall
  clock is the usual cause. Remove unnecessary waits and setup, not assertions or useful cases.

## Decisions

- Report every decision that the code does not force. A cut, a sentinel, a default, a rename, and a
  deferral are decisions.
- Write every deferral into `BACKLOG.md`, and name its trigger when an event must come first.
- A control that a user sets is never code without a caller. Never reduce its range.
- A recommendation names its evidence. A claim about a provider names the field, the endpoint, or
  the document that proves it.

## Review

A finding names a behavior defect, a rule in this file or a skill, or an error of a development
tool. Everything else is not a finding.

## Documents

`README.md`, `BACKLOG.md`, this file, and the skills under `.agents/skills/` are the documents.
Prettier formats every document, and `.prettierrc.json` configures it. `README.md` states the stable
product and stays concise. `BACKLOG.md` holds the open direction, and a line leaves it when its work
lands. `TODO.md` is its inbox, and Git ignores it. When a change alters a fact, update every
document and every text in the code that states the fact.

Write the documents and every text that Drinky shows to the user in ASD-STE100 Simplified Technical
English.

- Use active voice or a direct imperative. Put one topic in each sentence.
- Limit an instruction to 20 words and a description to 25 words.
- Use one noun for one concept. The type names are the vocabulary. Use at most three nouns in a
  chain.
- Keep the articles. Use `must` for a requirement and `can` for a capability.
- Do not use `should`, `may`, `might`, `would`, semicolons, or contractions.
- Prefer a finite verb to an `-ing` form.
- Use a complete sentence, sentence case, and end punctuation for an event, a result, or a required
  action. A label, a metric, or a control hint can be a fragment. Use a colon between a key and its
  value.
- Put a dynamic error name in a complete sentence:
  `Drinky could not open {path} because of error {name}.`
- Every text is timeless and impersonal. Use no name, no date, and no pointer to a session.

These rules do not apply to a literal technical identifier or a schema. Preserve the meaning and the
terminal-width limits when you reword a text.

## Name

Use `drinky` for a machine-parsed name and format it as code. Use `Drinky` for the product in prose
and in user-facing text, and never start a sentence with lowercase `drinky`. Reserve `DRINKY` for an
environment variable.

## Models vocabulary

- **author**: The slug before the slash in an OpenRouter model id, as in `openai` of
  `openai/gpt-5.6-sol`. OpenRouter keeps `provider` for the company that serves a request.
- **public metadata**: The price, window, effort, thinking, and tool facts of a model. Drinky stores
  them in `metadata.json`. Never write **OpenRouter** for that source.

`OpenRouter` names the provider alone.

## Accounts vocabulary

An account identifier reads `vendor-product`, as in `anthropic-plan`. A `-key` suffix marks a
credential that an environment variable holds or names, as in `anthropic-api-key`. An identifier
without it signs in through an OAuth login. The `id` field of a table row is the only spelling of an
identifier. A model under an account reads `account/model`.

- **vendor**: The `Account.Vendor` tag: `anthropic`, `openai`, `xai`, `openrouter`, `deepseek`, or
  `google`.
- **plan**: A consumer subscription, as in Claude Pro or Max, ChatGPT, and SuperGrok.
- **api**: The developer API of the vendor, billed per token.
- **cloud**: The cloud platform of the vendor, as in a Google Cloud project on the Agent Platform.
- **Agent Platform**: The short form of Gemini Enterprise Agent Platform, the Google Cloud platform
  that was Vertex AI. Name it in full with `(Vertex AI)` on the first mention of a document. Never
  write **Gemini Enterprise** alone, because that is another Google product.

## Checks

Run `sh scripts/check.sh` after a change. CI runs the same script and nothing else. The check runs
the test suite in `debug` and `safe` modes. Its summary prints the runtime of each test binary. The
script needs `npx`, which fetches Prettier once into its cache.

`zig run scripts/comment_scan.zig -- --fix build.zig build.zig.zon src lib scripts` removes every
comment, and `zig fmt build.zig build.zig.zon src lib scripts` formats the Zig code.
`zig run scripts/width_scan.zig -- build.zig build.zig.zon src lib scripts` lists every Zig line
over 100 columns and wraps none, because `zig fmt` never wraps a line. `zig build unicode`
regenerates the Unicode data, its test corpus, and its license notice. `zig build commonmark`
regenerates the CommonMark test corpus and its license notice. Both steps use the network, so they
never join the default build.

A rule that a tool can check belongs in `scripts/check.sh`, because an editor setting enforces
nothing. Add a check to `scripts/check.sh` for a problem that occurred.
