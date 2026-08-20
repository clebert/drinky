# Anthropic Prompt Caching

This document explains prompt caching on Anthropic's Messages API. It covers how the API reports the
numbers and how to interpret them over a whole conversation. It is a reference for the token
accounting behind our usage and cost figures, not an API integration guide.

## The three token buckets

Every request sends the entire prompt: system instructions, tool definitions, and all messages. A
_cache breakpoint_ is a point in the prompt marked with `cache_control`. The API caches the prefix
up to and including that point. Anthropic splits the prompt's tokens into three non-overlapping
buckets in the usage report:

| field                         | meaning                                                     | billed        |
| ----------------------------- | ----------------------------------------------------------- | ------------- |
| `cache_read_input_tokens`     | prefix that matched an existing cache entry                 | 0.1×          |
| `cache_creation_input_tokens` | new tokens written to the cache this request                | 1.25× (5-min) |
| `input_tokens`                | tokens neither read nor written (after the last breakpoint) | 1.0×          |

Multipliers are relative to the model's base input-token price. The cache-write figure is the
5-minute TTL (see Pricing). The three buckets are exactly additive:

```
total prompt tokens = cache_read_input_tokens
                    + cache_creation_input_tokens
                    + input_tokens
```

If both cache fields are zero, nothing was cached on that request.

## Uncached scraps (`input_tokens`)

`input_tokens` is the most easily misread field. It counts only the tokens that were **neither read
from nor written to the cache**. Equivalently, these are the tokens that fall **after the last cache
breakpoint**. It is **not** "what the user typed", and **not** the system prompt or tools.

When a cache breakpoint sits at the very end of the prompt, `input_tokens` is ≈ 0. Everything up to
the breakpoint is either a cache read (the matching prefix) or a cache write (the new delta). A
nonzero `input_tokens` means there is uncached content past the last breakpoint. This is typically
the newest user message, when the breakpoint sits before it. In that case `input_tokens` roughly
tracks the size of that trailing content and is unstable turn to turn. Do not surface it as a
headline number.

A small new segment appended _before_ the breakpoint does **not** fall through to `input_tokens`. If
the cumulative prefix at the breakpoint meets the model's minimum, that increment is written to the
cache (billed as a cache write). This holds even if the increment is only a handful of tokens. There
is no per-increment minimum.

Turn by turn:

- **Turn 1:** Nothing is cached yet. The prefix up to the breakpoint is a cache write. Cache read
  is 0. `input_tokens` covers anything after the breakpoint.
- **Turn 2:** The earlier prefix matches, so cache read covers it. The new delta up to the
  breakpoint is a cache write. `input_tokens` is again only what follows the breakpoint.
- **Later turns:** Cache read dominates. Cache write is the per-turn delta up to the breakpoint.
  `input_tokens` is the trailing uncached content.

## Minimum cacheable prefix

A prefix is only cached if it reaches a model-dependent minimum token count. Shorter prompts process
normally without caching and without error. The minimum applies to the **total prefix length** up to
a breakpoint, not to each incremental addition. Once the cumulative prefix meets the minimum, even a
few new tokens before the breakpoint are written to the cache.

| minimum tokens | models (subset)                                                        |
| -------------- | ---------------------------------------------------------------------- |
| 512            | Fable 5, Opus 5, Mythos 5                                              |
| 1,024          | Opus 4.8, Sonnet 5, Sonnet 4.6, Sonnet 4.5, Opus 4.1, Opus 4, Sonnet 4 |
| 2,048          | Mythos Preview, Opus 4.7, Haiku 3.5                                    |
| 4,096          | Opus 4.6, Opus 4.5, Haiku 4.5                                          |

The minimums do not follow a simple rule. They are not "Haiku vs the rest" (Haiku 4.5 is 4,096 while
Sonnet 4.6 and Opus 4.8 are 1,024). They do not track version numbers (Opus 4.8 is 1,024 while the
older Opus 4.5 and 4.6 are 4,096). Check the value for the exact model in use.

## Cache lifetime (TTL)

The default cache lifetime is **5 minutes**. It is a **sliding window**: each cache hit refreshes
the timer for free, so an actively used prefix stays alive indefinitely. An entry only expires after
an idle gap longer than the TTL.

A **1-hour** TTL is available with a `ttl` field:

```json
{ "cache_control": { "type": "ephemeral", "ttl": "1h" } }
```

`"ephemeral"` is the only supported cache type. When you mix TTLs in one request, the 1-hour blocks
must appear before the 5-minute blocks.

When an entry expires, the next request simply re-writes it: that turn shows a new cache write and a
lower cache read. Expiry needs no special handling. The usage report already reflects it.

## Pricing

All multipliers are relative to the model's base input-token price:

| operation                 | multiplier |
| ------------------------- | ---------- |
| cache write, 5-minute TTL | 1.25×      |
| cache write, 1-hour TTL   | 2×         |
| cache read (hit)          | 0.1×       |

A cache read saves 90% of the input price for those tokens. A cache write costs an extra 25% up
front (5-minute TTL). A cache write only pays off if the segment is read back at least once before
it expires. If a segment is written and then expires before any read, the write is a net loss (1.25×
paid, never recovered at 0.1×).

Net savings over a session, versus the same tokens sent with no caching:

```
saved ≈ 0.90 × input_rate × cache_read_tokens
      − 0.25 × input_rate × cache_write_tokens
```

The 0.25 write term assumes the 5-minute TTL. A 1-hour write's premium is 1.0× of the base input
price. This stays honest under bursty use. When writes recur without matching reads (for example
after cache expirations), the savings figure shrinks because the cache genuinely helped less.

## Cache keying and invalidation

- A cache entry is keyed by a **cumulative hash of the exact prefix bytes** ending at the
  breakpoint. A change to any block at or before the breakpoint changes the hash and causes a miss
  on the next request.
- Entries are **isolated between organizations**, and (on the Claude API) between workspaces within
  an organization.
- Invalidation follows a hierarchy: tools → system → messages. A change to the tool definitions
  invalidates the entire cache.

## Switching models mid-conversation

Anthropic's docs describe hash-based prefix keying and org/workspace isolation but do not state
per-model keying verbatim. In practice, a model switch behaves as a cache miss, because different
models tokenize differently and have different minimums. The switch has these effects:

- **One expensive rewrite turn.** The first request on the new model has no cache read and re-writes
  the whole prefix as a cache write (1.25×). Reuse resumes from the next turn. The old model's
  entries expire unused.
- **The context-window denominator changes.** The same conversation can jump from a small fraction
  of a 1M window to a large fraction of a 200K window. The switch alone causes the jump.
- **Cost accounting stays correct** if each message is priced with the model that produced it.
  Cumulative cost then blends both models accurately. Cumulative cache-effectiveness figures also
  blend, and the single rewrite turn dents them.

## Interpreting cumulative usage over a session

- Cumulative totals sum whatever the API reports per request, so TTL effects (expiry, refresh) are
  already included. TTL effects need no separate logic.
- Cumulative figures cannot attribute a specific miss to expiry versus a genuine prefix change. That
  detail only exists in per-request numbers.
- The authentication method does not reveal billing. A login via a subscription account does not
  guarantee subscription-rate billing. Some subscriptions (for example enterprise arrangements) are
  billed at API rates. Public API prices are therefore the only defensible estimate. Read any
  displayed cost as an API-equivalent estimate, not a guaranteed charge.

## Sources

- Anthropic prompt caching documentation:
  <https://docs.claude.com/en/docs/build-with-claude/prompt-caching> (`docs.anthropic.com` redirects
  to the same page). Model lists and per-model minimums reflect the page as of 2026-08-02 and change
  as models are added or retired. The multipliers (1.25× / 2× / 0.1×) and the usage-field
  definitions are the stable, authoritative parts.
