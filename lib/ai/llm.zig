//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types. The agent loop and tools depend only on
//! this module, never on a specific provider. Pure data: no state, no I/O.

const std = @import("std");

/// A configured account: a vendor crossed with the billing product that
/// authorizes its requests. The auth *mechanism* — an API key or an OAuth
/// subscription — is data held by `provider.Credentials`, not part of the
/// identity. This is the tag `provider.Client`/`Stream` key on. It is also the
/// origin stamped on stored reasoning, so only the exact account that produced
/// a blob replays it. At startup any account with a login is preferred over an
/// environment API key, across vendors. Within a tier, declaration order decides.
pub const Account = enum {
    /// Claude Pro/Max subscription OAuth, authorized with a `Bearer` token and
    /// the Claude Code identity headers.
    anthropic_subscription,
    /// Anthropic Console (Developer Platform), authorized with an `x-api-key`
    /// key that an OAuth login mints and stores. It sends the Claude Code system
    /// prompt like the subscription, so it reaches every model.
    anthropic_console,
    /// Per-token platform API, authorized with `x-api-key`.
    anthropic_api,
    /// ChatGPT (Codex) subscription OAuth.
    openai_subscription,
    /// Per-token platform API, authorized with a `Bearer` key.
    openai_api,

    /// Whether this account signs in through an interactive OAuth login (as
    /// opposed to an environment API key). Such an account can be logged in and
    /// out mid-session. The Console account signs in this way even though it
    /// then authorizes with a minted `x-api-key` key.
    pub fn hasLogin(self: Account) bool {
        return switch (self) {
            .anthropic_subscription, .openai_subscription, .anthropic_console => true,
            .anthropic_api, .openai_api => false,
        };
    }

    /// The human-readable label, e.g. "Anthropic Subscription".
    pub fn label(self: Account) []const u8 {
        return switch (self) {
            .anthropic_subscription => "Anthropic Subscription",
            .anthropic_console => "Anthropic Console",
            .anthropic_api => "Anthropic API",
            .openai_subscription => "OpenAI Subscription",
            .openai_api => "OpenAI API",
        };
    }

    /// The environment variable that supplies an API account's key, or null for a
    /// subscription (whose credential comes from an interactive login, not the
    /// environment).
    pub fn apiKeyEnv(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api => "ANTHROPIC_API_KEY",
            .openai_api => "OPENAI_API_KEY",
            .anthropic_subscription, .openai_subscription, .anthropic_console => null,
        };
    }

    /// The vendor this account belongs to.
    pub fn provider(self: Account) Provider {
        return switch (self) {
            .anthropic_api, .anthropic_subscription, .anthropic_console => .anthropic,
            .openai_api, .openai_subscription => .openai,
        };
    }
};

/// The vendor axis: whose wire protocol and model table an account uses. Both
/// accounts of a vendor share one serializer and one set of models. The model
/// table and the serializers key on this rather than on the full account.
pub const Provider = enum { anthropic, openai };

pub const Role = enum { user, assistant };

/// A named reasoning-effort level passed through to the provider, which picks
/// the actual thinking depth itself. Anthropic maps it to
/// `output_config.effort` under adaptive thinking. OpenAI maps it to its
/// reasoning-effort control. `none` disables reasoning when the model permits
/// it. Otherwise, the model map folds `none` onto the minimum level.
pub const Effort = enum { none, low, medium, high, xhigh, max };

/// One entry in the flat, ordered conversation history. Every provider
/// translates its wire format to and from this list. The agent loop appends
/// items in the exact order the model produced them (reasoning first, then
/// text and tool calls interleaved as streamed). A provider serializer replays
/// them one-item-one-block. It shares a role envelope over a run of same-role
/// items but never reorders separate native output items. Content parts inside
/// one native OpenAI message are canonically joined without a separator.
pub const Item = union(enum) {
    /// A user or assistant text turn.
    message: Message,
    /// One run of model reasoning (assistant-only).
    reasoning: Reasoning,
    /// The model's request to call a tool (assistant-only).
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
            anthropic_console: Anthropic,
            anthropic_api: Anthropic,
            openai_subscription: OpenAi,
            openai_api: OpenAi,

            pub fn dupe(
                self: *const Replay,
                gpa: std.mem.Allocator,
            ) !Replay {
                return switch (self.*) {
                    inline .anthropic_subscription,
                    .anthropic_api,
                    .anthropic_console,
                    => |proof, tag| switch (proof) {
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
                    inline .anthropic_subscription,
                    .anthropic_api,
                    .anthropic_console,
                    => |proof| switch (proof) {
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
        /// The raw JSON object for the arguments. Empty means an empty object.
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
    /// A stable per-conversation key a provider can use to improve prompt-cache
    /// routing. Empty sends none. OpenAI combines it with the prompt-prefix
    /// hash to keep a session's growing requests on one cache. Anthropic
    /// ignores it (its caching is driven by explicit breakpoints).
    cache_key: []const u8 = "",
};

/// Token counts for one assistant message. `input` is uncached prompt tokens.
/// The full billed prompt is `input + cache_read + cache_write`.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    /// The field-wise sum, to accumulate several messages' usage. The sum
    /// saturates. The counts arrive from the provider stream unchecked, so a
    /// hostile or buggy response must skew a gauge, never overflow a total.
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
    // A provider reports counts as JSON integers, so one message can claim up
    // to maxInt(i64) per field. Three of them must not wrap the per-model
    // total.
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

/// A subscription account's remaining allowance, read from the provider's
/// response head. Each window is optional and independent. Classify one by its
/// length (`window_minutes` ≈ 300 → a 5h window, ≈ 10080 → weekly). The quota
/// is absent for API-key accounts and any provider that reports no quota.
/// `used_percent` runs 0–100, so the remaining share is `100 - used_percent`.
pub const Quota = struct {
    primary: ?Window = null,
    secondary: ?Window = null,

    pub const Window = struct {
        used_percent: f64,
        window_minutes: ?u32 = null,
    };
};

/// A decoded part of a streamed assistant reply. Display deltas are kept
/// separate from completed conversation items. Transports own their native
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

    /// A completed assistant-only item before the Agent attaches history
    /// ownership and exact-account reasoning provenance.
    pub const Output = union(enum) {
        message: []const u8,
        reasoning: Reasoning,
        tool_call: Item.ToolCall,
    };

    /// A complete reasoning run before the Agent attaches exact-account
    /// provenance. The union makes redacted text and provider-proof mixtures
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
                inline .anthropic_subscription,
                .anthropic_api,
                .anthropic_console,
                => |tag| switch (self.*) {
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

    /// The authoritative end of an assistant message. It carries its cumulative
    /// usage, whether the provider completed or truncated the response, and any
    /// wire outcome that makes the reply locally unretainable.
    pub const Stop = struct {
        usage: Usage,
        status: Status = .complete,
        rejection: ?Rejection = null,

        pub const Rejection = enum {
            /// Malformed or incomplete output that a whole-request retry can fix.
            invalid,
            /// A valid provider outcome the neutral conversation model cannot retain.
            unsupported,
        };
    };

    /// A terminal response's completeness. `complete` is a clean finish.
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
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_console.provider());
}

test "account login flag and label" {
    try std.testing.expect(Account.anthropic_subscription.hasLogin());
    try std.testing.expect(Account.openai_subscription.hasLogin());
    try std.testing.expect(Account.anthropic_console.hasLogin());
    try std.testing.expect(!Account.anthropic_api.hasLogin());
    try std.testing.expect(!Account.openai_api.hasLogin());
    try std.testing.expectEqualStrings(
        "Anthropic Subscription",
        Account.anthropic_subscription.label(),
    );
    try std.testing.expectEqualStrings("Anthropic Console", Account.anthropic_console.label());
    try std.testing.expectEqualStrings("Anthropic API", Account.anthropic_api.label());
    try std.testing.expectEqualStrings("OpenAI Subscription", Account.openai_subscription.label());
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", Account.anthropic_api.apiKeyEnv().?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", Account.openai_api.apiKeyEnv().?);
    try std.testing.expect(Account.anthropic_console.apiKeyEnv() == null);
}
