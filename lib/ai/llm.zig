//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types, so the agent loop and tools depend only on
//! this module — never on a specific provider. Pure data: no state, no I/O.

const std = @import("std");

/// A configured account: a vendor crossed with the billing product that
/// authorizes its requests. The auth *mechanism* — an API key or an OAuth
/// subscription — is data held by `provider.Credentials`, not part of the
/// identity. This is the tag `provider.Client`/`Stream` key on, and the origin
/// stamped on stored reasoning so only the exact account that produced a blob
/// replays it. At startup any subscription is preferred over any paid API key,
/// across vendors; within a tier, declaration order decides.
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

    /// The vendor this account belongs to.
    pub fn provider(self: Account) Provider {
        return switch (self) {
            .anthropic_api, .anthropic_subscription => .anthropic,
            .openai_api, .openai_subscription => .openai,
        };
    }
};

/// The vendor axis: whose wire protocol and model table an account uses. Both
/// accounts of a vendor share one serializer and one set of models, so the model
/// table and the serializers key on this rather than on the full account.
pub const Provider = enum { anthropic, openai };

pub const Role = enum { user, assistant };

/// A named reasoning-effort level passed through to the provider, which picks
/// the actual thinking depth itself (Anthropic maps it to `output_config.effort`
/// under adaptive thinking; OpenAI to its reasoning-effort control). `none`
/// disables reasoning; the rest match Anthropic's effort ladder.
pub const Effort = enum { none, low, medium, high, xhigh, max };

/// One entry in the flat, ordered conversation history. Every provider
/// translates its wire format to and from this list; the agent loop appends
/// items in the exact order the model produced them (reasoning first, then text
/// and tool calls interleaved as streamed) and a provider serializer replays
/// them one-item-one-block, sharing a role envelope over a run of same-role
/// items but never reordering separate native output items. Content parts inside
/// one native OpenAI message are canonically joined without a separator.
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

    /// A complete run of model reasoning, carried back verbatim on later turns.
    /// The replay union's tag is also the exact account that produced its proof,
    /// so a serializer cannot mistake foreign reasoning for local history.
    pub const Reasoning = struct {
        replay: Replay,

        pub const Replay = union(Account) {
            anthropic_subscription: Anthropic,
            anthropic_api: Anthropic,
            openai_subscription: OpenAi,
            openai_api: OpenAi,

            pub fn dupe(
                self: *const Replay,
                gpa: std.mem.Allocator,
            ) !Replay {
                return switch (self.*) {
                    inline .anthropic_subscription, .anthropic_api => |proof, tag| switch (proof) {
                        .signature => |signature| signature: {
                            const text_copy = try gpa.dupe(u8, signature.text);
                            errdefer gpa.free(text_copy);
                            const proof_copy = try gpa.dupe(u8, signature.signature);
                            break :signature @unionInit(Replay, @tagName(tag), .{
                                .signature = .{
                                    .text = text_copy,
                                    .signature = proof_copy,
                                },
                            });
                        },
                        .redacted => |data| @unionInit(
                            Replay,
                            @tagName(tag),
                            .{ .redacted = try gpa.dupe(u8, data) },
                        ),
                    },
                    inline .openai_subscription, .openai_api => |proof, tag| openai: {
                        const text_copy = try gpa.dupe(u8, proof.text);
                        errdefer gpa.free(text_copy);
                        const id_copy = try gpa.dupe(u8, proof.id);
                        errdefer gpa.free(id_copy);
                        const content_copy = try gpa.dupe(u8, proof.encrypted_content);
                        break :openai @unionInit(Replay, @tagName(tag), .{
                            .text = text_copy,
                            .id = id_copy,
                            .encrypted_content = content_copy,
                        });
                    },
                };
            }

            pub fn deinit(self: *const Replay, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    inline .anthropic_subscription, .anthropic_api => |proof| switch (proof) {
                        .signature => |signature| {
                            gpa.free(signature.text);
                            gpa.free(signature.signature);
                        },
                        .redacted => |data| gpa.free(data),
                    },
                    inline .openai_subscription, .openai_api => |proof| {
                        gpa.free(proof.text);
                        gpa.free(proof.id);
                        gpa.free(proof.encrypted_content);
                    },
                }
            }
        };

        pub const Anthropic = union(enum) {
            signature: Signature,
            redacted: []const u8,
        };

        pub const Signature = struct {
            text: []const u8,
            signature: []const u8,
        };

        pub const OpenAi = struct {
            text: []const u8,
            id: []const u8,
            encrypted_content: []const u8,
        };
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
    effort: Effort = .none,
    /// A stable per-conversation key a provider may use to improve prompt-cache
    /// routing; empty to send none. OpenAI combines it with the prompt-prefix
    /// hash to keep a session's growing requests on one cache; Anthropic ignores
    /// it (its caching is driven by explicit breakpoints).
    cache_key: []const u8 = "",
};

/// Token counts for one assistant message. `input` is uncached prompt tokens;
/// the full billed prompt is `input + cache_read + cache_write`.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    /// Field-wise sum, for accumulating several messages' usage. Saturating: the
    /// counts arrive from the provider stream unchecked, so a hostile or buggy
    /// response must skew a gauge, never overflow a total.
    pub fn plus(self: *const Usage, other: *const Usage) Usage {
        return .{
            .input = self.input +| other.input,
            .output = self.output +| other.output,
            .cache_read = self.cache_read +| other.cache_read,
            .cache_write = self.cache_write +| other.cache_write,
        };
    }
};

test "accumulated usage saturates rather than overflowing on absurd counts" {
    // A provider reports counts as JSON integers, so one message can claim up to
    // maxInt(i64) per field: three of them must not wrap the per-model total.
    const absurd: Usage = .{
        .input = std.math.maxInt(i64),
        .output = std.math.maxInt(i64),
        .cache_read = std.math.maxInt(i64),
        .cache_write = std.math.maxInt(i64),
    };
    var total: Usage = .{};
    for (0..3) |_| total = total.plus(&absurd);
    const ceiling = std.math.maxInt(u64);
    try std.testing.expectEqual(ceiling, total.input);
    try std.testing.expectEqual(ceiling, total.output);
    try std.testing.expectEqual(ceiling, total.cache_read);
    try std.testing.expectEqual(ceiling, total.cache_write);
}

/// A decoded part of a streamed assistant reply. Display deltas are kept
/// separate from completed conversation items: transports own their native
/// block/item lifecycles and emit an `item` only after the wire closes it.
pub const Event = union(enum) {
    /// Display-only streamed answer text.
    text: []const u8,
    /// Display-only streamed reasoning text.
    thinking: []const u8,
    /// One complete native assistant output item in wire order. Its slices borrow
    /// the stream and remain valid until the next read or stream teardown. OpenAI
    /// message content parts are canonically joined without a separator.
    item: Output,
    stop: Stop,

    /// A completed assistant-only item before history ownership and exact-account
    /// reasoning provenance are attached by the Agent.
    pub const Output = union(enum) {
        message: []const u8,
        reasoning: Reasoning,
        tool_call: Item.ToolCall,
    };

    /// A complete reasoning run before exact-account provenance is attached by
    /// the Agent. The union makes redacted text and provider-proof mixtures
    /// unrepresentable.
    pub const Reasoning = union(enum) {
        signature: Item.Reasoning.Signature,
        redacted: []const u8,
        encrypted: Item.Reasoning.OpenAi,

        pub fn replay(
            self: *const Reasoning,
            account: Account,
        ) ?Item.Reasoning.Replay {
            return switch (account) {
                inline .anthropic_subscription, .anthropic_api => |tag| switch (self.*) {
                    .signature => |signature| if (signature.signature.len != 0)
                        @unionInit(
                            Item.Reasoning.Replay,
                            @tagName(tag),
                            .{ .signature = signature },
                        )
                    else
                        null,
                    .redacted => |data| if (data.len != 0)
                        @unionInit(
                            Item.Reasoning.Replay,
                            @tagName(tag),
                            .{ .redacted = data },
                        )
                    else
                        null,
                    .encrypted => null,
                },
                inline .openai_subscription, .openai_api => |tag| switch (self.*) {
                    .encrypted => |encrypted| if (encrypted.id.len != 0 and
                        encrypted.encrypted_content.len != 0)
                        @unionInit(Item.Reasoning.Replay, @tagName(tag), encrypted)
                    else
                        null,
                    .signature, .redacted => null,
                },
            };
        }

        pub fn isRedacted(self: *const Reasoning) bool {
            return self.* == .redacted;
        }
    };

    /// Authoritative end of an assistant message, carrying its cumulative usage,
    /// whether the provider completed or truncated the response, and any wire
    /// outcome that makes the reply locally unretainable.
    pub const Stop = struct {
        usage: Usage,
        status: Status = .complete,
        rejection: ?Rejection = null,

        pub const Rejection = enum {
            /// Malformed or incomplete output that a whole-request retry may fix.
            invalid,
            /// A valid provider outcome the neutral conversation model cannot retain.
            unsupported,
        };
    };

    /// A terminal response's completeness. `complete` is a clean finish;
    /// `truncated` is a token or context cutoff whose reply so far still stands
    /// but is retainable only when it holds no tool call. Resumable or refused
    /// outcomes ride `Stop.rejection` as unsupported instead.
    pub const Status = enum { complete, truncated };
};

test "reasoning proofs bind only to compatible exact accounts" {
    const signature: Event.Reasoning = .{ .signature = .{
        .text = "hmm",
        .signature = "sig",
    } };
    const anthropic_replay = signature.replay(.anthropic_api).?;
    try std.testing.expectEqual(Account.anthropic_api, std.meta.activeTag(anthropic_replay));
    try std.testing.expectEqualStrings("hmm", anthropic_replay.anthropic_api.signature.text);
    try std.testing.expectEqualStrings("sig", anthropic_replay.anthropic_api.signature.signature);
    try std.testing.expect(signature.replay(.openai_api) == null);

    const encrypted: Event.Reasoning = .{ .encrypted = .{
        .text = "hmm",
        .id = "rs_1",
        .encrypted_content = "enc",
    } };
    const openai_replay = encrypted.replay(.openai_subscription).?;
    try std.testing.expectEqual(Account.openai_subscription, std.meta.activeTag(openai_replay));
    try std.testing.expectEqualStrings("rs_1", openai_replay.openai_subscription.id);
    try std.testing.expectEqualStrings("hmm", openai_replay.openai_subscription.text);
    try std.testing.expect(encrypted.replay(.anthropic_subscription) == null);

    const redacted: Event.Reasoning = .{ .redacted = "secret" };
    try std.testing.expectEqualStrings(
        "secret",
        redacted.replay(.anthropic_subscription).?.anthropic_subscription.redacted,
    );
}

test "Account.provider maps each account to its vendor" {
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_subscription.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_api.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_subscription.provider());
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
