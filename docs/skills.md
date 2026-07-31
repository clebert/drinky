# Skills

Design notes for pith's skill support: what a skill is, where pith finds skills on disk, how they
reach the model, and how the implementation fits the module boundaries. The implemented first
version follows the concrete shape described here.

A **skill** is an on-demand instruction file. Its name and one-line description are always in front
of the model. The full body loads only when a task matches. This is _progressive disclosure_: a
large library of specialized workflows stays available at roughly a hundred tokens each. The
expensive detail is paid for only when used. The format is the open
[Agent Skills standard](https://agentskills.io/specification), the same one Claude Code, the Claude
Agent SDK, and pi implement. The core `SKILL.md` format is therefore portable across harnesses even
where their scan directories and extensions differ.

## What a skill is

A skill is a directory that contains a `SKILL.md` file. Everything else in the directory is
freeform (helper scripts, reference docs, assets). The body references these files by relative
path. `SKILL.md` is YAML frontmatter followed by a Markdown body:

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
| `name`                     | yes      | ≤ 64 chars. Lowercase `a-z`, `0-9`, hyphens. No leading/trailing or consecutive hyphens |
| `description`              | yes      | ≤ 1024 chars. States _what_ the skill does and _when_ to use it                         |
| `license`                  | no       | license name or reference to a bundled file                                             |
| `compatibility`            | no       | ≤ 500 chars. Environment requirements                                                   |
| `metadata`                 | no       | arbitrary key-value map (author, version, …)                                            |
| `allowed-tools`            | no       | space-separated pre-approved tools — **experimental**                                   |
| `disable-model-invocation` | no       | when true, hide from the model. The user must invoke explicitly                         |

The body is the tier-2 payload. Keep it under ~5k tokens and push detail into referenced files.
`version` is not a first-class field. It lives inside `metadata`. The standard says `name` must
equal the parent directory. pi deliberately relaxes this for shared directories, and pith must do
the same (warn, do not reject).

## Where to look

Each harness scans its own directories plus a cross-harness convention:

| Harness                 | User-level                                 | Project-level                                    |
| ----------------------- | ------------------------------------------ | ------------------------------------------------ |
| Claude Code / Agent SDK | `~/.claude/skills/`                        | `.claude/skills/` (cwd + ancestors to repo root) |
| Cross-harness standard  | `~/.agents/skills/`                        | `.agents/skills/` (cwd + ancestors)              |
| pi                      | `~/.pi/agent/skills/`, `~/.agents/skills/` | `.pi/skills/`, `.agents/skills/`                 |

pith uses the shared, cross-harness locations rather than a pith-specific directory. This
convention is not part of the format spec, which only defines `SKILL.md`. It comes from the
standard's client-implementation guide. The guide points every tool at a common `.agents/skills/`
path, so a skill is written once and any harness that follows the convention finds it. pith scans
two:

- **User:** `~/.agents/skills/`
- **Project:** `.agents/skills/`, searched in the working directory and its ancestors up to the git
  repo root (or filesystem root outside a repo)

pith keeps skills out of `~/.pith/` deliberately, not just for convenience: `~/.pith/` holds
pith-private state (config, auth tokens). Skills are portable artifacts meant to be shared, so they
belong in the common location. pith provides no pith-only skill directory. If a private namespace
is ever needed, a `~/.pith/skills/` can be added then.

Discovery rule: a directory that contains a `SKILL.md` is a skill. Scan recursively to find nested
skills. pith ignores loose `*.md` files directly under a skills directory. Only `SKILL.md`
directories count. This matches how the shared dirs behave in other harnesses.

**Precedence and collisions.** Resolve to a flat map keyed by `name`. Project beats user: a
`.agents/skills/` skill shadows a same-named one in `~/.agents/skills/`. This is the
local-overrides-global rule that the client-implementation guide specifies. Within one scope, the
first found wins. Warn on any shadow. (Claude Code inverts this, personal over project, so a cloned
repo cannot shadow a trusted personal skill. pith has no trust boundary between the two and keeps
the least-surprise local-overrides-global rule.)

**Trust.** A skill can instruct the model to take any action and can ship code the model runs. pith
has no trust mechanism and adds none: skills load unconditionally, project-level
(`.agents/skills/`) the same as user-level. When pith loads a skill, it only reads text into
context. A bundled script runs only if the model invokes it through the normal `bash` tool, like
any other command. Responsibility for what sits in a project's `.agents/skills/` therefore rests
with whoever opens the repo.

## How skills reach the model

Progressive disclosure has three tiers:

1. **Metadata — always loaded.** At startup pith scans the locations and injects each skill's
   `name`, `description`, and `SKILL.md` path into the system prompt. This is typically an XML
   block, the shape pi and Claude Code use and the standard's integration guide illustrates.
   Roughly ~100 tokens per skill. The path is what makes tier 2 work: the model reads that file
   when it judges the skill relevant.
2. **Body — on trigger.** When the model judges a skill relevant to the task, it loads the full
   `SKILL.md` and follows it. Activation is the model's own judgement against the descriptions, not
   harness-side keyword matching. This is why the description must name both what and when.
3. **Resources — as needed.** The body points at bundled scripts and reference files by relative
   path. Those load only when the model reads or runs them.

pith already has the pieces for tiers 2 and 3. The model pulls a body with the existing `read` tool
and the path from the catalog, and runs a bundled script with `bash`. No new tool is strictly
required. Models do not always take the hint, so pith also offers explicit invocation:
`/skill:name`, as in pi. This loads the body into the conversation on demand and appends any
trailing arguments. The transcript records a compact `[skill] name` marker, followed by the
trailing task as a user block when present. The full body stays in model history without filling
the display. This is not a plain command-registry entry: the registry matches the first token
exactly, so runtime-discovered skill names need _prefix dispatch_. A `skill:` handler reads the
remainder as the skill name and looks it up in the registry. A dedicated "load skill" tool is a
possible refinement but not needed for a first version.

## Implementation shape

The implementation maps onto the existing architecture and its one-way module boundary (`lib/ai`
and `lib/terminal` never import each other or `src/`):

- **A skills module in `lib/ai`** (provider-neutral). `lib/ai/root.zig` re-exports it so its tests
  are wired for `test-audit.sh`. It owns:
  - **Frontmatter parsing.** pith has no YAML dependency and adds none. A hand-rolled parser reads
    the flat scalar keys (`name`, `description`, …) between the leading `---` fences. It handles
    quoted descriptions (with the standard escapes, `\uXXXX` among them) and block scalars
    (`>`/`|`, with their indentation and chomping indicators).
  - **Validation, lenient.** An over-long or malformed `name`, a name that differs from its
    directory, or an over-long `description` produces a warning but still loads the skill. The
    catalog truncates an over-long `description` to the standard limit. An absent or invalid `name`
    falls back to the parent directory name. pith skips a skill only when it can neither disclose
    nor invoke it: a missing or empty `description`, or a fallback directory name that is itself
    not a valid skill name.
  - **A registry** keyed by `name`. It holds at least `name`, `description`, and the absolute
    `SKILL.md` path. The body loads lazily at activation.
- **Discovery and wiring in `src`.** Only the app knows `$HOME` and the working directory and owns
  the `Agent`. `App` therefore resolves the scan set, invokes the loader, and builds the tier-1 XML
  block. The base system prompt remains a compiled-in constant. `App` builds and **owns** the
  combined prompt for the agent's lifetime because the agent borrows it.
- **Invocation surface.** Prefix dispatch for `skill:` loads a skill body on request. It is not a
  static registry entry, because pith discovers skill names at runtime. The existing `read`/`bash`
  tools handle model-driven activation and tier-3 resources.

## Scope

Several features stay out of a first version deliberately. Single-file `*.md` skills and any
bridge that points at another tool's directories, such as `~/.claude/skills`, both widen discovery
without changing the mechanism. `allowed-tools` gating is experimental even upstream. Claude Code's
many extensions stay out (`when_to_use`, `context: fork`, `paths`, hooks, `${SKILL_DIR}`
substitution). The Claude _API_'s container-hosted skills are a different delivery path from
filesystem skills. The core deliverable is the open standard: discover the two shared directories,
parse frontmatter, advertise name and description, and let the model pull the rest.

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
