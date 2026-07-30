# Project Instructions and the System Prompt

Research and design notes for pith's `AGENTS.md` support: what is portable, where pith should look,
how project instructions should reach the model, and how they fit with skills and future custom
system prompts. The proposed first version is deliberately narrower than pi: it implements the open
project convention without inventing a pith-specific global convention.

## Recommendation

- Treat exact-case `AGENTS.md` as the portable project artifact. Load the applicable chain from the
  Git repository root through the startup working directory, ordered broad-to-specific.
- Do not discover `~/.agents/AGENTS.md` or `~/.pith/AGENTS.md`. Neither is a cross-harness standard;
  `.agents` is shared for **skills**, not for global project instructions.
- Do not load `CLAUDE.md` by default. It is a useful vendor compatibility file, but `AGENTS.md` is
  the interoperable contract and Claude Code documents how a `CLAUDE.md` can import or link to it.
  If a searched directory has no `AGENTS.md` but does have `CLAUDE.md` or the likely misspelling
  `AGENT.md`, warn at startup and explain that the file was ignored.
- Keep a concise, pith-owned core first in the system prompt. Follow it with optional trusted user
  additions, generated environment data, repository-controlled project instructions, and the skill
  catalog. Project instructions should not be prepended ahead of the harness core.
- Use Markdown for authored instructions and XML-style elements only as generated delimiters around
  dynamic data. Escape both paths and file contents. XML improves structure; it is not a security
  boundary.
- Do not auto-discover pi-style `SYSTEM.md` or `APPEND_SYSTEM.md` files. When custom-system support
  lands, expose replacement and append **paths explicitly in `~/.pith/config.json`**. This gives
  personal customization without presenting a pith-only filename as a portable standard.

This design intentionally chooses only `AGENTS.md`, not `CLAUDE.md`, and includes project context
after the core rather than prepending repository text ahead of it. The matching backlog item uses the
same contract so implementation has one source of truth.

## What the AGENTS.md convention defines

`AGENTS.md` is an open ecosystem convention stewarded by the Agentic AI Foundation under the Linux
Foundation. It is not a versioned schema or an RFC. Its portable core is small:

- the filename is `AGENTS.md`;
- the content is ordinary Markdown with no required headings or frontmatter;
- a repository-level file supplies broad instructions;
- another `AGENTS.md` in a nested directory applies more specifically to that subtree; and
- when applicable files conflict, the file closest to the edited file takes precedence.

The convention does **not** define a user-global path, project-root detection, case aliases, size
limits, XML wrapping, loading time, or error behavior. Harnesses therefore agree on the repository
artifact but differ substantially in discovery:

| Harness | User-level file | Project behavior |
| --- | --- | --- |
| OpenAI Codex | `~/.codex/AGENTS.md` (with an override variant) | Git/project root through cwd; broad-to-specific; 32 KiB aggregate default |
| Claude Code | `~/.claude/CLAUDE.md` | Reads `CLAUDE.md`, not `AGENTS.md`; nested files are loaded when files in their subtree are read |
| Gemini CLI | `~/.gemini/GEMINI.md` | Uses `GEMINI.md` by default; `AGENTS.md` can be configured as a context filename; nested context is loaded on access |
| pi | `~/.pi/agent/AGENTS.md` | At startup, walks every filesystem ancestor through cwd; accepts `AGENTS.md` or `CLAUDE.md` |

There is consequently no portable equivalent of `~/.agents/AGENTS.md`. The Agent Skills
specification and client guide establish shared `.agents/skills/` locations for `SKILL.md`
packages; they do not generalize `.agents/` into a home for every agent resource.

## Where pith should look

At startup:

1. Canonicalize the working directory and require its absolute path to be valid UTF-8. If it is not,
   fail startup with a safely rendered diagnostic because neither the JSON request nor the mandatory
   Environment section can carry the path losslessly.
2. Find the nearest ancestor containing a `.git` directory or `.git` file. That directory is the
   project root, including for a Git worktree.
3. Examine each directory on the path from that root through the working directory, inclusive.
4. Load at most one exact-case `AGENTS.md` from each directory.
5. Where that directory has no `AGENTS.md`, detect exact-case `CLAUDE.md` and `AGENT.md` files and
   emit a startup warning for each; do not load their contents.
6. Render retained files from root to cwd, so broad guidance appears before specific guidance.

If no Git root is found, inspect only the working directory. Walking to the filesystem root would
silently turn `~/AGENTS.md` into a user-global file for every project below the home directory and
could inherit unrelated instructions from a parent checkout. A future explicit workspace-root
setting can support non-Git trees without making that inference.

Exact case is part of the contract. On a case-insensitive filesystem, discovery should enumerate the
directory and verify the basename rather than letting an `open("AGENTS.md")` call accidentally accept
`agents.md` or `AGENTS.MD`.

Compatibility warnings are local to each searched directory: an `AGENTS.md` elsewhere in the chain
does not suppress a warning for a nested `CLAUDE.md` or `AGENT.md`. Warn only for a regular file or a
symlink to one, and only when the exact-case `AGENTS.md` directory entry is absent in that same
directory. Entry presence suppresses compatibility warnings even when that canonical file is later
skipped as unreadable, invalid, or oversized; its own skip warning explains the real problem. This
avoids duplicate diagnostics and a false warning for the normal Claude bridge where `AGENTS.md` and
`CLAUDE.md` intentionally coexist.

Suggested diagnostics are:

```text
instructions: /path/CLAUDE.md is ignored; pith loads AGENTS.md (add or link one here)
instructions: /path/AGENT.md is ignored; did you mean AGENTS.md?
```

### Scope and precedence

Each file is intended to apply to the subtree rooted at its containing directory. Pith should state
the complete intended hierarchy:

1. Provider restrictions, tool availability, permissions, and other constraints enforced in code.
2. The pith core and any explicitly configured user system additions.
3. The current user's explicit task.
4. Applicable project instructions, with a deeper `AGENTS.md` winning over a broader one within the
   deeper directory's scope.
5. Skill guidance, which supplements the task and project rather than overriding them.

Only the first level is mechanically enforced. Core and project text currently share one model
system/developer instruction, while the user's task has its provider-defined user role. The remaining
precedence is harness-owned guidance and therefore best-effort model behavior, not an authority or
security boundary. Ordering alone cannot guarantee that a model resolves every contradiction.

The first version should not recursively scan every descendant. Its startup chain is a cwd-scoped
approximation matching Codex and pi: starting above a nested `AGENTS.md` misses it when work later
enters that subtree, while starting inside a subtree leaves its instructions in the prompt even if a
tool later addresses a sibling or an absolute path outside that subtree. Full edited-file semantics
require target-aware, just-in-time discovery or another scoped-context mechanism. Loading every
descendant up front would add irrelevant context and blur scope, so defer that mechanism rather than
hiding the limitation.

### Input bounds and diagnostics

Project instructions must be bounded and inspectable. Initial pith limits should be:

- 32 KiB per file;
- 64 KiB total source content; and
- 32 loaded files.

These are pith limits, not part of the convention. Never cut a file in the middle. Collect and budget
candidates nearest-first so the most specific whole files survive an aggregate overflow, then render
the retained set broad-to-specific. Ignore empty files. Skip and warn about files that are unreadable,
oversized, contain NUL, are not valid UTF-8, or whose absolute source path is not valid UTF-8.
Diagnostics for an invalid path must use a safely rendered representation.

Follow an `AGENTS.md` symlink when its target exists, is a regular file, and its canonical path remains
inside the project root (or inside cwd when there is no Git root). Skip and warn on a dangling link,
a non-file target, or a target outside that boundary.

Working-directory acquisition, canonicalization, and UTF-8 validation are startup prerequisites and
fail startup on error. After those succeed, discovery problems are nonfatal except cancellation and
allocation failure. An unexpected error while inspecting a possible `.git` marker emits a warning and
treats that directory as the traversal boundary rather than risking inheritance from above it.
Startup should show the absolute path of every loaded file and every skipped-file warning; otherwise
users cannot tell which instructions the model received.

## System prompt structure

The current core in `src/App.zig` is one dense sentence. It says “You are pith,” then repeats details
already present in the provider-supplied tool schemas (`find` uses globs, `grep` is literal,
`edit.old_text` must be unique, and so on). There are two reasons to revise it:

- tool behavior has a single authoritative description in each tool schema and should not drift in a
  second hand-maintained list; and
- the Anthropic subscription transport must prepend its provider-required Claude Code identity, so
  “operating inside pith” avoids competing identity claims better than “You are pith.”

A sufficient default core is:

```markdown
# Pith

You are a coding assistant operating inside pith, a terminal coding-agent harness.

Follow the user's request and the applicable project instructions. Inspect relevant files before
editing them, use the available tools according to their schemas, and be concise. After changing
files, report what changed, the checks you ran, and any unresolved issues.
```

The complete provider-neutral pith prompt should be assembled once, in this order:

1. **Core** — the compiled default above, or a future explicitly configured replacement.
2. **User system additions** — future explicitly configured append files, in configured order.
3. **Environment** — the absolute cwd and detected repository root.
4. **Project instructions** — generated explanation plus applicable `AGENTS.md` files,
   broad-to-specific.
5. **Skills** — the existing progressive-disclosure explanation and `<available_skills>` catalog.

This keeps stable, application-controlled text first and changing context near the end, matching
OpenAI's recommended identity/instructions/context ordering. It also gives automatic prefix caches a
stable beginning. Pith currently sends its complete prompt as one cache-controlled Anthropic system
block, so ordering does not preserve a partial Anthropic system cache when later bytes change; the
prompt is nevertheless immutable during a session, which preserves normal turn-to-turn hits. Splitting
provider blocks solely for cross-project cache reuse is outside this feature.

The Environment section is always present. When no Git root was detected, emit an empty
`<repository_root />` element; `working_directory` always contains the XML-escaped absolute cwd.
Omit the Project instructions and Skills headings and elements when those sections are empty; the
default core must remain the exact prefix of the composed prompt.

### Markdown plus XML-style delimiters

Markdown headings and bullets are best for the short, authored core. XML-style elements are useful
for generated, repeated records whose boundaries and source paths matter. A composed prompt should
have this shape:

```markdown
# Pith

You are a coding assistant operating inside pith, a terminal coding-agent harness.

Follow the user's request and the applicable project instructions. Inspect relevant files before
editing them, use the available tools according to their schemas, and be concise. After changing
files, report what changed, the checks you ran, and any unresolved issues.

## Environment

<environment>
  <working_directory>/workspace/project/package</working_directory>
  <repository_root>/workspace/project</repository_root>
</environment>

## Project instructions

The following repository-controlled defaults apply to the working directory and are listed
broad-to-specific. Pith's core and configured system additions take precedence. The user's explicit
task wins over conflicting project guidance; when project files conflict, the more specific file
wins within its subtree. Skill guidance is supplemental.

<project_context>
  <project_instructions path="/workspace/project/AGENTS.md">
# Repository instructions
...
  </project_instructions>
  <project_instructions path="/workspace/project/package/AGENTS.md">
# Package instructions
...
  </project_instructions>
</project_context>

## Skills

The following skills provide specialized instructions. Skill guidance is supplemental: it does not
override the pith core, configured system additions, the user's task, or applicable project
instructions. When a task matches a skill's description, read its SKILL.md at the listed location
before proceeding.

<available_skills>
  <skill>
    <name>example</name>
    <description>When and why to use this skill.</description>
    <location>/absolute/path/example/SKILL.md</location>
  </skill>
</available_skills>
```

All generated values must be XML-escaped, including the full Markdown content inside each
`<project_instructions>` element. Preserve line breaks and other whitespace. Escaping prevents file
content such as `</project_instructions>` from forging the generated structure; CDATA and Markdown
fences merely replace that problem with their own closable delimiter. Models understand the escaped
entities, while the wrappers remain unambiguous.

Do not over-tag the authored prose and do not treat tags as authority. Natural-language prompt
injection remains natural language after XML escaping.

## AGENTS.md versus custom system files

Three resources serve different purposes:

| Resource | Owner and scope | Intended authority |
| --- | --- | --- |
| Core system prompt | pith, or an explicit user replacement | Harness-wide behavior |
| User system append | User, explicitly configured | Personal behavior layered onto the core |
| `AGENTS.md` | Repository, directory-scoped | Project defaults and workflows |

`AGENTS.md` is enough for project conventions, commands, architecture, and contribution rules. It is
not a good substitute for a trusted personal rule that should apply to every repository, and a full
system replacement is too costly when the user only wants to add one rule. An append facility is
therefore useful, but pi's automatically discovered `APPEND_SYSTEM.md` filename is not necessary.

When the existing **Custom system prompt** backlog item is implemented, prefer explicit config such
as:

```json
{
  "system_prompt": {
    "path": "/path/to/custom-core.md",
    "append_paths": ["/path/to/personal-instructions.md"]
  }
}
```

Relative paths, if accepted, should resolve against the directory containing
`~/.pith/config.json`, never against the project cwd. A configured `path` replaces only the authored
core; append files follow it; generated environment, project-context, and skill sections remain.
Missing or invalid explicitly configured files should be reported as configuration errors rather
than silently falling back.

Do not auto-load any of these:

- `~/.pith/AGENTS.md`;
- `~/.agents/AGENTS.md`;
- `~/.pith/SYSTEM.md` or `~/.pith/APPEND_SYSTEM.md`; or
- project-local `.pith/SYSTEM.md` or `.pith/APPEND_SYSTEM.md`.

Pith-specific configuration belongs in `~/.pith/config.json`; portable repository guidance belongs
in `AGENTS.md`. Keeping that boundary explicit avoids creating a second “standard.”

## Compatibility with CLAUDE.md

Pith should not treat `CLAUDE.md` as a default fallback. Loading both files creates duplicates;
choosing one silently introduces precedence rules; and a `CLAUDE.md` may contain Claude-specific
imports or behavior. Repositories that support both conventions can keep `AGENTS.md` canonical and
use Claude Code's documented bridge:

```markdown
<!-- CLAUDE.md -->
@AGENTS.md
```

A symlink is another option. If `CLAUDE.md` exists without `AGENTS.md` in a searched directory, pith
warns at startup so the missing bridge is visible rather than silently discarding project guidance.
The same migration warning applies to singular `AGENT.md`, which is likely a typo. Neither file is
loaded. If real demand appears, pith can later expose an explicit list of fallback filenames in
config. That is compatibility configuration, not part of the portable default.

## Trust and security

An `AGENTS.md` is repository-controlled text deliberately supplied as model instructions. A
malicious file can ask the model to run commands, expose credentials, or ignore the user's goal.
Reading the file does not itself execute anything, but pith currently has no permission gate or
sandbox, so the resulting model actions have the same power as every other tool call.

The first implementation can load project instructions unconditionally under the same broad trust
assumption as project skills. This is materially stronger automatic exposure because `AGENTS.md` is
eagerly inserted while a skill body is loaded lazily. The implementation must:

- display every loaded source;
- perform no include expansion or command substitution;
- keep tool permissions and future approvals outside the prompt;
- avoid reading symlink targets outside the project boundary; and
- document that opening an untrusted repository requires an external container or sandbox.

A future project-trust feature may gate executable configuration, extensions, hooks, or system-prompt
replacement. It does not make repository prose safe, and XML labels do not lower the API authority of
text placed in a system/developer instruction.

## Implementation shape

Keep filesystem policy provider-neutral and prompt wording application-owned:

- **`lib/ai/instructions.zig`** returns and owns one discovery result: the optional canonical project
  root, project instruction entries (`path`, containing directory/scope, and content), limits, and
  diagnostics. Re-export it from `lib/ai/root.zig` so its tests are reachable by `test-audit.sh`.
- **`src/system_prompt.zig`** is the pure composer for the pith-owned string. It receives the core,
  cwd, discovery result, and raw visible skill metadata; it alone owns section ordering and all XML
  escaping.
- **`lib/ai/skills.zig`** should expose raw visible metadata rather than own global composition
  through `Registry.systemPrompt(base)`.
- **`src/App.zig`** remains the composition root: resolve cwd, discover skills and instructions,
  build and own the immutable prompt, pass the borrowed slice to `ai.Agent`, and surface diagnostics.
- **Provider adapters** remain unchanged. Anthropic receives the composed string as its pith-owned
  system block (beside any provider-required header); OpenAI receives the same bytes as
  `instructions`.

Build the prompt once at startup. Do not stat or reread context files on every model round. A future
explicit reload changes prompt identity and cache behavior and should be designed together with
session semantics rather than added implicitly here.

Important tests include:

- Git root through cwd ordering, including a `.git` file;
- no discovery above the nearest Git root, cwd-only behavior and an empty root element outside Git,
  and safe rejection of a non-UTF-8 cwd;
- exact filename casing and no `CLAUDE.md` fallback;
- same-directory warnings for otherwise-ignored `CLAUDE.md` and `AGENT.md`, including suppression
  when canonical `AGENTS.md` coexists;
- deeper-file precedence and nearest-first retention under the aggregate cap;
- whole-file size, count, UTF-8, NUL, empty-file, unreadable-file, invalid-path, and deterministic
  symlink behavior;
- absolute source paths and XML escaping of paths and contents;
- exact prompt ordering with every combination of empty project and skill sections; and
- the byte-for-byte default core as the composed prompt's prefix.

## First-version scope

The implementation based on this document should include startup discovery, diagnostics, bounded
loading, centralized prompt composition, and the revised core. Defer descendant just-in-time loading,
custom base/append config, trust UI, reload, import syntax, configurable fallback filenames, and
non-Git workspace-root configuration.

## Sources

Sources checked 2026-07-30:

- AGENTS.md open convention — <https://agents.md/>
- OpenAI Codex, _Custom instructions with AGENTS.md_ —
  <https://developers.openai.com/codex/guides/agents-md>
- Anthropic, _How Claude remembers your project_ — <https://code.claude.com/docs/en/memory>
- Gemini CLI, _Provide context with GEMINI.md files_ —
  <https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md>
- pi coding agent, context and system-prompt files —
  <https://github.com/earendil-works/pi/blob/v0.83.0/packages/coding-agent/README.md#context-files>
- Agent Skills specification — <https://agentskills.io/specification>
- OpenAI, _Prompt engineering: message formatting with Markdown and XML_ —
  <https://developers.openai.com/api/docs/guides/prompt-engineering#message-formatting-with-markdown-and-xml>
- Anthropic, _Prompting best practices_ —
  <https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/system-prompts>
- OpenAI, _Safety in building agents_ —
  <https://developers.openai.com/api/docs/guides/agent-builder-safety>
