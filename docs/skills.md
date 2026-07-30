# Skills

Design notes for pith's skill support: what a skill is, where skills are found on disk, how they
reach the model, and how the implementation fits the module boundaries. The implemented first
version follows the concrete shape described here.

A **skill** is an on-demand instruction file. Its name and one-line description are always in front
of the model; the full body loads only when a task matches. This is _progressive disclosure_: a
large library of specialized workflows stays available at roughly a hundred tokens each, and the
expensive detail is paid for only when used. The format is the open
[Agent Skills standard](https://agentskills.io/specification), the same one Claude Code, the Claude
Agent SDK, and pi implement, so the core `SKILL.md` format is portable across harnesses even where
their scan directories and extensions differ.

## What a skill is

A skill is a directory containing a `SKILL.md` file; everything else in the directory is freeform
(helper scripts, reference docs, assets), referenced from the body by relative path. `SKILL.md` is
YAML frontmatter followed by a Markdown body:

```markdown
---
name: pdf-tools
description:
  Extract text and tables from PDFs, fill forms, merge files. Use when working with PDF documents.
---

# PDF Tools

## Usage

...
```

Frontmatter fields, per the standard:

| Field                      | Required | Constraint                                                                              |
| -------------------------- | -------- | --------------------------------------------------------------------------------------- |
| `name`                     | yes      | ≤ 64 chars; lowercase `a-z`, `0-9`, hyphens; no leading/trailing or consecutive hyphens |
| `description`              | yes      | ≤ 1024 chars; states _what_ the skill does and _when_ to use it                         |
| `license`                  | no       | license name or reference to a bundled file                                             |
| `compatibility`            | no       | ≤ 500 chars; environment requirements                                                   |
| `metadata`                 | no       | arbitrary key-value map (author, version, …)                                            |
| `allowed-tools`            | no       | space-separated pre-approved tools — **experimental**                                   |
| `disable-model-invocation` | no       | when true, hide from the model; user must invoke explicitly                             |

The body is the tier-2 payload — keep it under ~5k tokens and push detail into referenced files.
`version` is not a first-class field; it lives inside `metadata`. The standard says `name` must
equal the parent directory; pi deliberately relaxes this for shared directories, and pith should do
the same (warn, don't reject).

## Where to look

Each harness scans its own directories plus a cross-harness convention:

| Harness                 | User-level                                 | Project-level                                    |
| ----------------------- | ------------------------------------------ | ------------------------------------------------ |
| Claude Code / Agent SDK | `~/.claude/skills/`                        | `.claude/skills/` (cwd + ancestors to repo root) |
| Cross-harness standard  | `~/.agents/skills/`                        | `.agents/skills/` (cwd + ancestors)              |
| pi                      | `~/.pi/agent/skills/`, `~/.agents/skills/` | `.pi/skills/`, `.agents/skills/`                 |

pith uses the shared, cross-harness locations rather than a pith-specific directory. This convention
is not part of the format spec — that only defines `SKILL.md` — but comes from the standard's
client-implementation guide, which points every tool at a common `.agents/skills/` path so a skill
is written once and found by any harness that follows it. pith scans two:

- **User:** `~/.agents/skills/`
- **Project:** `.agents/skills/`, searched in the working directory and its ancestors up to the git
  repo root (or filesystem root outside a repo)

Keeping skills out of `~/.pith/` is deliberate, not just convenient: `~/.pith/` holds pith-private
state (config, auth tokens), whereas skills are portable artifacts meant to be shared, so they
belong in the common location. No pith-only skill directory is provided; if a private namespace is
ever needed, a `~/.pith/skills/` can be added then.

Discovery rule: a directory containing a `SKILL.md` is a skill; scan recursively so nested skills
are found. Loose `*.md` files directly under a skills directory are ignored — only `SKILL.md`
directories count — matching how the shared dirs behave in other harnesses.

**Precedence and collisions.** Resolve to a flat map keyed by `name`. Project beats user — a
`.agents/skills/` skill shadows a same-named one in `~/.agents/skills/`, the local-overrides-global
rule the client-implementation guide specifies — and within one scope, first found wins; warn on any
shadow. (Claude Code inverts this, personal over project, to stop a cloned repo shadowing a trusted
personal skill; pith has no trust boundary between the two and keeps the least-surprise
local-overrides-global rule.)

**Trust.** A skill can instruct the model to take any action and may ship code the model runs. pith
has no trust mechanism and adds none: skills load unconditionally, project-level (`.agents/skills/`)
the same as user-level. Loading a skill only reads text into context; a bundled script runs only if
the model invokes it through the normal `bash` tool, like any other command. Responsibility for what
sits in a project's `.agents/skills/` therefore rests with whoever opens the repo.

## How skills reach the model

Progressive disclosure has three tiers:

1. **Metadata — always loaded.** At startup pith scans the locations and injects each skill's
   `name`, `description`, and `SKILL.md` path into the system prompt — typically an XML block, the
   shape pi and Claude Code use and the standard's integration guide illustrates. Roughly ~100
   tokens per skill. The path is what makes tier 2 work: the model reads that file when it judges
   the skill relevant.
2. **Body — on trigger.** When the model judges a skill relevant to the task, it loads the full
   `SKILL.md` and follows it. Activation is the model's own judgement against the descriptions, not
   harness-side keyword matching — which is why the description must name both what and when.
3. **Resources — as needed.** The body points at bundled scripts and reference files by relative
   path; those load only when the model reads or runs them.

pith already has the pieces for tiers 2 and 3: the model pulls a body with the existing `read` tool
using the path from the catalog, and runs a bundled script with `bash`, so no new tool is strictly
required. Models do not always take the hint, so pith also offers explicit invocation — `/skill:name`,
matching pi — which loads the body into the conversation on demand and appends any trailing
arguments. The transcript records a compact `[skill] name` marker, followed by the trailing task as
a user block when present; the full body stays in model history without filling the display. This is
not a plain command-registry entry: the registry matches the first token exactly, so
runtime-discovered skill names need _prefix dispatch_ — a `skill:` handler that reads the remainder
as the skill name and looks it up in the registry. A dedicated "load skill" tool is a possible
refinement but not needed for a first version.

## Implementation shape

Mapped onto the existing architecture and its one-way module boundary (`lib/ai` and `lib/terminal`
never import each other or `src/`):

- **A skills module in `lib/ai`** (provider-neutral), re-exported from `lib/ai/root.zig` so its
  tests are wired for `test-audit.sh`. It owns:
  - **Frontmatter parsing.** pith has no YAML dependency and adds none. A hand-rolled parser reads
    the flat scalar keys (`name`, `description`, …) between the leading `---` fences, including
    quoted descriptions (with the standard escapes, `\uXXXX` among them) and block scalars (`>`/`|`,
    with their indentation and chomping indicators).
  - **Validation, lenient.** An over-long or malformed `name`, a name that differs from its
    directory, or an over-long `description` produces a warning but still loads the skill (the
    catalog truncates that description to the standard limit). An absent or invalid `name` falls
    back to the parent directory name. A skill is skipped only when it could neither be disclosed
    nor invoked: a missing or empty `description`, or a fallback directory name that is itself not a
    valid skill name.
  - **A registry** keyed by `name`, holding at least `name`, `description`, and the absolute
    `SKILL.md` path; the body is read lazily at activation.
- **Discovery and wiring in `src`.** Only the app knows `$HOME` and the working directory and owns
  the `Agent`, so `App` resolves the scan set, invokes the loader, and builds the tier-1 XML block.
  The base system prompt remains a compiled-in constant; `App` builds and **owns** the combined
  prompt for the agent's lifetime because the agent borrows it.
- **Invocation surface.** Prefix dispatch for `skill:` — not a static registry entry, since skill
  names are discovered at runtime — loads a skill body on request. The existing `read`/`bash` tools
  handle model-driven activation and tier-3 resources.

## Scope

Deliberately out of a first version: single-file `*.md` skills and any bridge for pointing at
another tool's directories such as `~/.claude/skills` (both widen discovery without changing the
mechanism); `allowed-tools` gating (experimental even upstream); Claude Code's many extensions
(`when_to_use`, `context: fork`, `paths`, hooks, `${SKILL_DIR}` substitution); and the Claude
_API_'s container-hosted skills, which are a different delivery path from filesystem skills. The
core deliverable is the open standard: discover the two shared directories, parse frontmatter,
advertise name and description, and let the model pull the rest.

## Sources

- Agent Skills standard — <https://agentskills.io/specification>,
  <https://agentskills.io/client-implementation/adding-skills-support.md>
- Anthropic, _Equipping agents for the real world with Agent Skills_ —
  <https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills>
- Claude Code skills — <https://docs.claude.com/en/docs/claude-code/skills>
- Claude Agent SDK skills — <https://docs.claude.com/en/api/agent-sdk/skills>
- Agent Skills overview — <https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview>
- pi skills documentation — <https://github.com/badlogic/pi-mono>
  (`packages/coding-agent/docs/skills.md`)
