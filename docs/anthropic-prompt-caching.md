# Anthropic Prompt Caching

How prompt caching works on Anthropic's Messages API, how the numbers are reported, and how to
interpret them over a whole conversation. This is a reference for understanding the token accounting
behind our usage and cost figures — not an API integration guide.

## The three token buckets

Every request sends the entire prompt: system instructions, tool definitions, and all messages. A
_cache breakpoint_ is a point in the prompt marked with `cache_control`; the prefix up to and
including that point is what gets cached. Anthropic splits the prompt's tokens into three
non-overlapping buckets in the usage report:

| field                         | meaning                                                          | billed        |
| ----------------------------- | ---------------------------------------------------------------- | ------------- |
| `cache_read_input_tokens`     | prefix that matched an existing cache entry                      | 0.1×          |
| `cache_creation_input_tokens` | new tokens written to the cache this request                     | 1.25× (5-min) |
| `input_tokens`                | tokens neither read nor written — i.e. after the last breakpoint | 1.0×          |

Multipliers are relative to the model's base input-token price (the cache-write figure is the
5-minute TTL; see Pricing). The three buckets are exactly additive:

```
total prompt tokens = cache_read_input_tokens
                    + cache_creation_input_tokens
                    + input_tokens
```

If both cache fields are zero, nothing was cached on that request.

## Uncached scraps (`input_tokens`)

`input_tokens` is the most easily misread field. It counts only the tokens that were **neither read
from nor written to the cache** — equivalently, the tokens that fall **after the last cache
breakpoint**. It is **not** "what the user typed", and **not** the system prompt or tools.

When a cache breakpoint sits at the very end of the prompt, everything up to it is either a cache
read (the matching prefix) or a cache write (the new delta), so `input_tokens` is ≈ 0. A nonzero
`input_tokens` means there is uncached content past the last breakpoint — typically the newest user
message, when the breakpoint is placed before it. In that case `input_tokens` roughly tracks the
size of that trailing content and is unstable turn to turn, so it should not be surfaced as a
headline number.

Appending a small new segment _before_ the breakpoint does **not** fall through to `input_tokens`:
as long as the cumulative prefix at the breakpoint meets the model's minimum, that increment is
written to the cache (billed as a cache write), even if it is only a handful of tokens. There is no
per-increment minimum.

Turn by turn:

- **Turn 1:** nothing cached yet → the prefix up to the breakpoint is a cache write, cache read is
  0, and `input_tokens` covers anything after the breakpoint.
- **Turn 2:** the earlier prefix matches → cache read covers it; the new delta up to the breakpoint
  is a cache write; `input_tokens` is again only what follows the breakpoint.
- **Later turns:** cache read dominates, cache write is the per-turn delta up to the breakpoint, and
  `input_tokens` is the trailing uncached content.

## Minimum cacheable prefix

A prefix is only cached if it reaches a model-dependent minimum token count. Shorter prompts process
normally without caching and without error. The minimum applies to the **total prefix length** up to
a breakpoint, not to each incremental addition — once the cumulative prefix clears the threshold,
even a few new tokens before the breakpoint are written to the cache.

| minimum tokens | models (subset)                                                        |
| -------------- | ---------------------------------------------------------------------- |
| 512            | Fable 5, Mythos 5                                                      |
| 1,024          | Opus 4.8, Sonnet 5, Sonnet 4.6, Sonnet 4.5, Opus 4.1, Opus 4, Sonnet 4 |
| 2,048          | Mythos Preview, Opus 4.7, Haiku 3.5                                    |
| 4,096          | Opus 4.6, Opus 4.5, Haiku 4.5                                          |

The minimums do not follow a simple rule. They are not "Haiku vs the rest" (Haiku 4.5 is 4,096 while
Sonnet 4.6 and Opus 4.8 are 1,024), and they do not track version numbers (Opus 4.8 is 1,024 while
the older Opus 4.5 and 4.6 are 4,096). Check the value for the exact model in use.

## Cache lifetime (TTL)

The default cache lifetime is **5 minutes**. It is a **sliding window**: each cache hit refreshes
the timer for free, so an actively used prefix stays alive indefinitely. An entry only expires after
an idle gap longer than the TTL.

A **1-hour** TTL is available by adding a `ttl` field:

```json
{ "cache_control": { "type": "ephemeral", "ttl": "1h" } }
```

`"ephemeral"` is the only supported cache type. When mixing TTLs in one request, the 1-hour blocks
must appear before the 5-minute blocks.

When an entry expires, the next request simply re-writes it: that turn shows a new cache write and a
lower cache read. No special handling is needed to account for expiry — the usage report already
reflects it.

## Pricing

All multipliers are relative to the model's base input-token price:

| operation                 | multiplier |
| ------------------------- | ---------- |
| cache write, 5-minute TTL | 1.25×      |
| cache write, 1-hour TTL   | 2×         |
| cache read (hit)          | 0.1×       |

A cache read saves 90% of the input price for those tokens; a cache write costs an extra 25% up
front (5-minute TTL). Caching a segment only pays off if it is read back at least once before it
expires. If a segment is written and then expires before any read, caching it was a net loss (1.25×
paid, never recovered at 0.1×).

Net savings over a session, versus sending the same tokens with no caching:

```
saved ≈ 0.90 × input_rate × cache_read_tokens
      − 0.25 × input_rate × cache_write_tokens
```

The 0.25 write term assumes the 5-minute TTL; a 1-hour write's premium is 1.0× of the base input
price. This stays honest under bursty use: when writes recur without matching reads (for example
after cache expirations), the savings figure shrinks — because caching genuinely helped less.

## Cache keying and invalidation

- A cache entry is keyed by a **cumulative hash of the exact prefix bytes** ending at the
  breakpoint. Changing any block at or before the breakpoint changes the hash and misses on the next
  request.
- Entries are **isolated between organizations**, and (on the Claude API) between workspaces within
  an organization.
- Invalidation follows a hierarchy: tools → system → messages. Modifying tool definitions
  invalidates the entire cache.

## Switching models mid-conversation

Anthropic's docs describe hash-based prefix keying and org/workspace isolation but do not state
per-model keying verbatim. In practice, switching models behaves as a cache miss — different models
tokenize differently and have different minimums — with these effects:

- **One expensive rewrite turn.** The first request on the new model has no cache read and re-writes
  the whole prefix as a cache write (1.25×). Reuse resumes from the next turn; the old model's
  entries expire unused.
- **The context-window denominator changes.** The same conversation can jump, say, from a small
  fraction of a 1M window to a large fraction of a 200K window, purely from the switch.
- **Cost accounting stays correct** if each message is priced with the model that produced it;
  cumulative cost then blends both models accurately. Cumulative cache-effectiveness figures also
  blend, and the single rewrite turn dents them.

## Interpreting cumulative usage over a session

- Cumulative totals sum whatever the API reports per request, so TTL effects (expiry, refresh) are
  already baked in — no separate TTL logic is needed to account for them.
- Cumulative figures cannot attribute a specific miss to expiry versus a genuine prefix change; that
  detail only exists in per-request numbers.
- Authentication method does not reveal billing. Logging in via a subscription account does not
  guarantee subscription-rate billing — some subscriptions (for example enterprise arrangements) are
  billed at API rates. Public API prices are therefore the only defensible estimate, and any
  displayed cost should be read as an API-equivalent estimate rather than a guaranteed charge.

## Sources

- Anthropic prompt caching documentation:
  <https://docs.claude.com/en/docs/build-with-claude/prompt-caching> (`docs.anthropic.com` redirects
  to the same page). Model lists and per-model minimums reflect the page as of 2026-07-10 and change
  as models are added or retired; the multipliers (1.25× / 2× / 0.1×) and the usage-field
  definitions are the stable, authoritative parts.
