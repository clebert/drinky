# Drinky

Drinky is a Zig coding agent that keeps the conversation in the terminal scrollback.

## Layers

`build.zig` declares the module graph, and a module imports only what the build names. `src` imports
`application`, `terminal`, and `markdown`. `lib/providers` and `lib/tools` import `lib/core`.
`lib/accounts` imports `lib/core` and `lib/providers`. `lib/application` imports `core`,
`providers`, `tools`, and `accounts`. No library imports `src`. The frontend test build adds the
infrastructure modules for its existing fakes.

- `lib/terminal` owns keyboard input, screen output, and the device seam. It knows no model and no
  provider.
- `lib/markdown` imports `std` alone. It parses Markdown and exposes source offsets. It knows no
  terminal, role, or URL limit. It holds the CommonMark test corpus and its license notice.
- `lib/core` imports `std` alone. It owns the neutral conversation, session, provider seam, tool
  seam, retry policy, and shared actor helpers. It names no vendor. Account identifiers and
  reasoning payloads stay opaque.
- `lib/providers` implements the provider seam. It owns the HTTP transport, SSE engine, credential
  seam, and one dialect per wire: Responses, Messages, and Gemini. A dialect builds requests,
  classifies failures, and decodes frames into core events. A per-account switch is a dialect
  option.
- `lib/tools` implements the tool seam. It owns the tool registry and required-skill checks. Tool
  outputs separate model content from the conditions and measures that a client shows.
- `lib/accounts` owns the account table, credentials, sign-in flows, model catalog, public metadata,
  usage sources, and saved state.
- `lib/application` owns the shared controller, workflows, canonical transcript, work state,
  generated results, turn boundaries, accounts, saved choices, and statistics. It owns their
  lifetimes. The controller validates commands and owns the workflow rules. Work stays exclusive
  across turns, asides, sign-ins, and model fetches. Record changes use stable ids. Events and
  snapshots carry typed facts, not terminal layout, navigation, editor instructions, control
  bindings, or text for the user. The `interface` preferences are the exception. The application
  also owns the config, discovery, shared model instructions, and tools. Config schemas, defaults,
  validation, and neutral descriptions stay with the application.
- `src` owns the native clients, terminal controls, editor, pages, drafts, confirmation policy, and
  text for the user. The terminal loop hosts the controller. Each native client supplies the words
  of every typed fact. The screen keeps a disposable presentation copy. Native clients use only
  public application commands, queries, and events for application operations.
- `src/ui/role.zig` maps a role to terminal colors. A widget names a role and writes no color of its
  own.

The controller has no loop task, but its calls can perform synchronous I/O. One host task serializes
controller calls. The session and account registry post owned mail to the mailbox of the host. The
mailbox must accept posts from concurrent tasks. `Controller.receive` takes ownership of each mail.
The host closes its mailbox before controller destruction. It releases any remaining mail with the
controller allocator. Event callbacks borrow their data, and a sink copies data that it retains. A
sink must not call the controller from an event callback. The host records a continuation from an
event and runs it after the controller call returns. A response and a query result borrow controller
memory until the next controller call. The host copies that data before it calls the controller
again.

A loop task lends state to its child task and touches none of it until the child ends. The child
returns its result with its end. A lock guards state that the tasks of two actors share.

## Skills

Read `.agents/skills/architecture/SKILL.md` to plan, change, or review module ownership, public
contracts, actors, concurrency, timeouts, frontend behavior or text, or billing.

Read `.agents/skills/accounts-vocabulary/SKILL.md` before you change or review accounts, models,
credentials, public metadata, provider terminology, vendor terminology, or platform terminology.

## Interface

These rules outrank existing behavior and repository precedent.

### Product guarantees

- An exit ends one operation or interaction. It reaches no enclosing operation or interaction.
- Drinky destroys no user work without an explicit decision. Each frontend owns its confirmation
  controls.
- A failure is not a decision. Every draft and user message survives a failure. Out of memory is the
  exception. It ends Drinky, and the draft is lost.
- `user_note` is the role of a message that Drinky writes for the user. An event reports session
  state. A user message holds typed text or a handoff that the user applied.

### Terminal policies

- Equivalent UI elements must share a semantic renderer across the transcript, pages, and status
  surfaces. The shared renderer must own the roles, symbols, metadata order, and width reductions.
- An exit is Esc, Ctrl+C, or Ctrl+D. No exit reaches past the step, the page, or the turn that holds
  it.
- If a key press has another meaning, Drinky warns first. A second press of the same key confirms
  the action.
- `/verbose` toggles the displayed detail, even during a turn. It clears terminal scrollback and
  repaints the complete transcript without a warning.

## Code

- Drinky has no dependency but the Zig standard library. `build.zig.zon` names no package.
- Write no comment. A name or a test carries the intent, and a fact that matters goes into a test, a
  name, or the chat.
- Less code is better. Add a seam only when a second implementation or a test fake exists.
- Before you write a helper, search the modules that the build lets the module import. Share code
  within its responsibility boundary. Semantic ownership takes priority over the removal of
  duplicate code. Do not move presentation code into the application or core solely to share it.
- Production code holds no option, entry point, mode, or global that only a test uses. A test fakes
  the clock through an `Io` and the network through a `Transport`. A size cap stays an option when
  no test can reach its production value.
- A fact that crosses a module boundary carries the data needed to interpret its meaning. A client
  must not infer a missing cause or target. A client can use the originating request to choose its
  words. Do not add redundant fields solely to select those words.
- An event sink takes `*const Event`, returns nothing, and copies what it keeps.
- Allocation failure is fatal to the process. Application boundaries must call
  `core.fatal.outOfMemory`. The panic ends every controller in the process. A callback or task must
  call the same function when it cannot propagate the error.
- Only reads of optional caches, saved choices, and display metadata can treat other errors as
  missing data. Every other reader keeps its error contract.
- The module graph is the architecture. A new module gets its row in `build.zig` and its line in the
  Layers section of this file.
- The development tools of the Zig code are the Zig toolchain alone. `zig fmt` formats every Zig
  file, and the check accepts no unformatted file.
- Follow `.agents/skills/zig-style/SKILL.md` for every Zig file.
- Write each vendor, wire, or sign-in rule as an exhaustive switch over its enum.

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
- Prefer tests that reach state through commands, events, keys, and options, with a hand-written
  fake. Read state through public functions when you test a module boundary.
- Use no network and no sleep. A test takes `std.testing.io`. Build an `Io` only to set a limit or
  to control the clock.
- Run `std.testing.checkAllAllocationFailures` on `core.testing.no_resize_allocator`.
- A fake that waits for a cancel waits on an event that no task sets. The test checks that the
  cancel ended the wait.
- A test that changes with every implementation change tests the implementation. Delete it or move
  it to the boundary.
- A test can call a private pure function to verify meaningful behavior without a large fixture. Do
  not copy the implementation to compute the expected result.
- A test name states the behavior that its body checks.
- Put the shared test code of a module into its `testing.zig`. Put a private rig, fixture, or fake
  after the first test of its file.
- Zig runs a test only when an import chain from a module root reaches its file. The check counts
  the declared tests against the tests that ran, so an unreachable test fails the check.
- Note the runtime of each test binary when you start a feature, and compare it when the feature is
  complete. Investigate a repeatable increase of more than one second. A test that waits on the wall
  clock is the usual cause. Remove unnecessary waits and setup, not assertions or useful cases.

## Decisions

- Report decisions that affect behavior, public contracts, scope, or significant trade-offs.
- Record unfinished work that the user requested in `BACKLOG.md`. Name a trigger only when an event
  must come first.
- A control that a user sets is never code without a caller. Do not reduce its range silently. A
  range reduction requires an explicit user decision and a compatibility assessment.
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
- Keep text timeless and impersonal. Use no personal attribution or reference to a development chat.
  Technical names and dates can state required facts.

These rules do not apply to a literal technical identifier or a schema. Preserve the meaning and the
terminal-width limits when you reword a text.

## Name

Use `drinky` for a machine-parsed name and format it as code. Use `Drinky` for the product in prose
and in user-facing text, and never start a sentence with lowercase `drinky`. Reserve `DRINKY` for an
environment variable.

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

Add checks for mechanical errors when detection is reliable and the maintenance cost is
proportionate. Run them through `scripts/check.sh`.
