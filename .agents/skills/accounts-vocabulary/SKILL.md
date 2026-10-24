---
name: accounts-vocabulary
description:
  Account and model terms for code and documents. Load before you change or review accounts, models,
  credentials, public metadata, provider terminology, vendor terminology, or platform terminology.
---

# Account and model vocabulary

## Models

- **author**: The slug before the slash in an OpenRouter model id, as in `openai` of
  `openai/gpt-5.6-sol`. OpenRouter keeps `provider` for the company that serves a request.
- **public metadata**: The price, window, effort, thinking, and tool facts of a model. Drinky stores
  them in `metadata.json`. Never write **OpenRouter** for that source.

`OpenRouter` names the provider alone.

## Accounts

An account identifier reads `vendor-product`, as in `anthropic-plan`. A `-key` suffix marks a
credential that an environment variable holds or names, as in `anthropic-api-key`. An identifier
without it signs in through an OAuth login. The `id` field of a table row is the only spelling of an
identifier. A model under an account reads `account/model`.

- **vendor**: The `Account.Vendor` tag: `anthropic`, `openai`, `xai`, `openrouter`, `deepseek`, or
  `google`.
- **plan**: A consumer subscription, as in Claude Pro or Max, ChatGPT, and SuperGrok.
- **api**: The developer API of the vendor, billed per token.
- **cloud**: The cloud platform of the vendor, as in a Google Cloud project on Gemini Enterprise
  Agent Platform (Vertex AI).
- **Agent Platform**: The short form of Gemini Enterprise Agent Platform. This Google Cloud platform
  was Vertex AI. Use the full name with `(Vertex AI)` on the first mention in a document. Never
  write **Gemini Enterprise** alone. That name identifies another Google product.
