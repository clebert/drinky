//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types, so the agent loop and tools depend only on
//! this module — never on a specific provider. Pure data: no state, no I/O.

const std = @import("std");

/// A configured account: a vendor crossed with the billing product that
/// authorizes its requests. The auth *mechanism* — an API key or an OAuth
/// subscription — is data held by `provider.Credentials`, not part of the
/// identity. This is the tag `provider.Client`/`Stream` key on, and the origin
/// stamped on stored reasoning so only the exact account that produced a blob
/// replays it. Declaration order is the startup preference — a vendor's
/// subscription precedes its API key, so a subscription is chosen over a paid key
/// when both are authenticated.
pub const Account = enum {
    /// Claude Pro/Max subscription OAuth, authorized with a `Bearer` token and
    /// the Claude Code identity headers.
    anthropic_subscription,
    /// Per-token platform API, authorized with `x-api-key`.
    anthropic_api,
    /// ChatGPT (Codex) subscription OAuth.
    openai_subscription,
    /// Per-token platform API, authorized with a `Bearer` key.
    openai_api,

    /// Whether this account authenticates with an interactive OAuth subscription
    /// login (as opposed to an environment API key), so it can be logged in and
    /// out mid-session.
    pub fn isSubscription(self: Account) bool {
        return switch (self) {
            .anthropic_subscription, .openai_subscription => true,
            .anthropic_api, .openai_api => false,
        };
    }

    /// The human-readable label, e.g. "anthropic subscription".
    pub fn label(self: Account) []const u8 {
        return switch (self) {
            .anthropic_subscription => "anthropic subscription",
            .anthropic_api => "anthropic api",
            .openai_subscription => "openai subscription",
            .openai_api => "openai api",
        };
    }

    /// The environment variable that supplies an API account's key, or null for a
    /// subscription (whose credential comes from an interactive login, not the
    /// environment).
    pub fn apiKeyEnv(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api => "ANTHROPIC_API_KEY",
            .openai_api => "OPENAI_API_KEY",
            .anthropic_subscription, .openai_subscription => null,
        };
    }
};

/// The vendor axis: whose wire protocol and model table an account uses. Both
/// accounts of a vendor share one serializer and one set of models, so the model
/// table and the serializers key on this rather than on the full account.
pub const Provider = enum { anthropic, openai };

/// The vendor an account belongs to.
pub fn provider(account: Account) Provider {
    return switch (account) {
        .anthropic_api, .anthropic_subscription => .anthropic,
        .openai_api, .openai_subscription => .openai,
    };
}

pub const Role = enum { user, assistant };

/// A named reasoning-effort level passed through to the provider, which picks
/// the actual thinking depth itself (Anthropic maps it to `output_config.effort`
/// under adaptive thinking; OpenAI to its reasoning-effort control). `off` turns
/// reasoning off; the rest match Anthropic's effort ladder.
pub const Effort = enum { off, low, medium, high, xhigh, max };

/// One entry in the flat, ordered conversation history. Every provider
/// translates its wire format to and from this list; the agent loop appends
/// items in the exact order the model produced them (reasoning first, then text
/// and tool calls interleaved as streamed) and a provider serializer replays
/// them one-item-one-block, sharing a role envelope over a run of same-role
/// items but never reordering or concatenating.
pub const Item = union(enum) {
    /// A user or assistant text turn.
    message: Message,
    /// One run of model reasoning (assistant-only).
    reasoning: Reasoning,
    /// The model asking to call a tool (assistant-only).
    tool_call: ToolCall,
    /// The outcome of a tool call, fed back on the input side.
    tool_result: ToolResult,

    pub const Message = struct {
        role: Role,
        text: []const u8,
    };

    /// A run of model reasoning, carried back verbatim on later turns so the
    /// provider accepts the tool calls that followed it.
    pub const Reasoning = struct {
        /// Human-visible reasoning/summary; empty when redacted or none.
        text: []const u8,
        /// Opaque token round-tripped unchanged so the provider can verify the
        /// reasoning: Anthropic `signature` / redacted `data`, or OpenAI
        /// `encrypted_content`. Never cross-fed between providers.
        blob: []const u8,
        /// The reasoning was withheld by the provider's safety filter; `text` is
        /// empty and `blob` holds its encrypted payload.
        redacted: bool = false,
        /// OpenAI reasoning-item id, needed to replay the item under
        /// `store:false`; empty for Anthropic.
        id: []const u8 = "",
        /// Which account produced `blob`: a serializer replays a blob only for
        /// the exact active account and drops any other reasoning item whole,
        /// since neither a foreign vendor's signature nor another account's token
        /// can be verified here.
        origin: Account,
    };

    pub const ToolCall = struct {
        /// Unified call key: Anthropic `tool_use.id` == OpenAI `call_id`.
        call_id: []const u8,
        name: []const u8,
        /// Raw JSON object for the arguments; empty means an empty object.
        arguments_json: []const u8,
    };

    pub const ToolResult = struct {
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const Parameter,
};

pub const Parameter = struct {
    name: []const u8,
    type: Type,
    description: []const u8,
    required: bool = false,

    pub const Type = enum { string, integer, boolean };
};

pub const Request = struct {
    model: []const u8,
    tokens_max: u32,
    system: []const u8,
    items: []const Item,
    tools: []const Tool,
    effort: Effort = .off,
};

/// Token counts for one assistant message. `input` is uncached prompt tokens;
/// the full billed prompt is `input + cache_read + cache_write`.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    /// Field-wise sum, for accumulating several messages' usage.
    pub fn plus(self: Usage, other: Usage) Usage {
        return .{
            .input = self.input + other.input,
            .output = self.output + other.output,
            .cache_read = self.cache_read + other.cache_read,
            .cache_write = self.cache_write + other.cache_write,
        };
    }
};

/// A decoded fragment of a streamed assistant reply.
pub const Event = union(enum) {
    text: []const u8,
    /// A chunk of streamed reasoning text.
    thinking: Thinking,
    /// The opaque blob closing the current reasoning run, carried back verbatim.
    thinking_blob: Blob,
    /// A complete redacted reasoning block: its opaque encrypted payload.
    thinking_redacted: Blob,
    tool_use: struct { call_id: []const u8, name: []const u8 },
    input_json: []const u8,
    stop: Stop,

    /// A reasoning text delta tagged with its reasoning-item id (empty for
    /// Anthropic; OpenAI's server-assigned `reasoning.id`).
    pub const Thinking = struct {
        id: []const u8 = "",
        text: []const u8,
    };

    /// An opaque reasoning blob (signature, redacted payload, or encrypted
    /// content) tagged with its reasoning-item id (empty for Anthropic).
    pub const Blob = struct {
        id: []const u8 = "",
        blob: []const u8,
    };

    /// End of an assistant message: why it ended, and its cumulative usage.
    pub const Stop = struct {
        reason: ?[]const u8,
        usage: Usage,
    };
};

test provider {
    try std.testing.expectEqual(Provider.anthropic, provider(.anthropic_api));
    try std.testing.expectEqual(Provider.anthropic, provider(.anthropic_subscription));
    try std.testing.expectEqual(Provider.openai, provider(.openai_api));
    try std.testing.expectEqual(Provider.openai, provider(.openai_subscription));
}

test "account subscription flag and label" {
    try std.testing.expect(Account.anthropic_subscription.isSubscription());
    try std.testing.expect(Account.openai_subscription.isSubscription());
    try std.testing.expect(!Account.anthropic_api.isSubscription());
    try std.testing.expect(!Account.openai_api.isSubscription());
    try std.testing.expectEqualStrings("openai subscription", Account.openai_subscription.label());
    try std.testing.expectEqualStrings("anthropic api", Account.anthropic_api.label());
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", Account.anthropic_api.apiKeyEnv().?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", Account.openai_api.apiKeyEnv().?);
    try std.testing.expect(Account.anthropic_subscription.apiKeyEnv() == null);
}
