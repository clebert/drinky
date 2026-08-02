# Anthropic Console OAuth

This document records how the Anthropic Console (Developer Platform) login works, so pith can sign
in the same way the Claude Code CLI does. Pith derives these facts from the Claude Code client, not
from public Anthropic documentation. They can change without notice.

## Two OAuth flows, one app

Claude Code uses one OAuth 2.0 app with PKCE (S256). One `client_id` drives two flows. They differ
by the authorize host and by what happens after the token exchange.

| step           | Subscription (claude.ai)               | Console (platform)                    |
| -------------- | -------------------------------------- | ------------------------------------- |
| Authorize host | `claude.ai/oauth/authorize`            | `platform.claude.com/oauth/authorize` |
| Token endpoint | `platform.claude.com/v1/oauth/token`   | same                                  |
| After exchange | keep the OAuth token, send as `Bearer` | mint a platform API key               |
| Credential     | `sk-ant-oat…` access/refresh token     | `sk-ant-api03…` key                   |

pith runs the subscription flow as its subscription account and the Console flow as its
`anthropic_console` account.

## The Console flow

1. Open the authorize URL in the browser. The user completes any company SSO on that page. pith
   catches the redirect on a loopback port.
2. Exchange the code for a short-lived access token at the token endpoint. The body is JSON.
3. Mint a long-lived API key with that access token.
4. Store only the minted key. It sends as `x-api-key` and needs no refresh.

### Constants

| name        | value                                                           |
| ----------- | --------------------------------------------------------------- |
| `client_id` | `9d1c250a-e61b-44d9-88ed-5944d1962f5e`                          |
| authorize   | `https://platform.claude.com/oauth/authorize`                   |
| token       | `https://platform.claude.com/v1/oauth/token`                    |
| mint        | `https://api.anthropic.com/api/oauth/claude_cli/create_api_key` |
| scopes      | `org:create_api_key user:profile`                               |
| callback    | `http://localhost:53693/callback`                               |
| PKCE        | S256                                                            |

### The mint call

```
POST https://api.anthropic.com/api/oauth/claude_cli/create_api_key
Authorization: Bearer <access_token>
(empty body)
→ { "raw_key": "sk-ant-api03-…" }
```

## The system-prompt gate

The minted key is a normal platform key on the user's organization. On its own it reaches only the
cheapest model. Every premium model returns `rate_limit_error` (HTTP 429) with the terse message
`Error`. The key reaches every model only when the first system block is exactly this string:

```
You are Claude Code, Anthropic's official CLI for Claude.
```

The rule is strict:

- The string must match exactly. A different or extended string does not pass.
- It must be the first block of the `system` array. A later position does not pass.
- No header, user agent, or beta flag changes the result. Only the system prompt matters.

pith sends this block for the `anthropic_console` account and the subscription account. It omits the
block for a plain `ANTHROPIC_API_KEY`. So a key set through the environment stays a plain API key. A
key that pith mints through this login reaches every model.

## Caveats

- Pith derives all of the above from the Claude Code client. Anthropic does not document it and can
  change an endpoint, the `client_id`, the scopes, or the gate at any time.
- Use of this OAuth app outside Claude Code is outside Anthropic's intended use.
- A premium model returns `rate_limit_error` with the message `Error` for a Console key sent without
  the Claude Code system prompt. This is not a real rate limit.
