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
    /// Gemini models on Vertex AI, authorized with an access token that Drinky
    /// mints from a service account key file. It goes last, so the startup
    /// order prefers every other account.
    google_vertex,

    /// Whether this account signs in through an interactive OAuth login (as
    /// opposed to an environment credential). Such an account can be logged in
    /// and out mid-session. The Console account signs in this way even though it
    /// then authorizes with a minted `x-api-key` key.
    pub fn hasLogin(self: Account) bool {
        return switch (self) {
            .anthropic_subscription, .openai_subscription, .anthropic_console => true,
            .anthropic_api, .openai_api, .google_vertex => false,
        };
    }

    /// Whether this account uses a refresh credential for provider requests. The
    /// Vertex account renews its token once, but a rejected token is a
    /// configuration problem of the user and not a rotated credential.
    pub fn hasRefreshCredential(self: Account) bool {
        return switch (self) {
            .anthropic_subscription, .openai_subscription => true,
            .anthropic_console, .anthropic_api, .openai_api, .google_vertex => false,
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
            .google_vertex => "Google Vertex",
        };
    }

    /// The kind of credential that an account without a login holds, as a
    /// picker names it, or null for an account with a login.
    pub fn credentialLabel(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api, .openai_api => "API key",
            .google_vertex => "Key file",
            .anthropic_subscription, .openai_subscription, .anthropic_console => null,
        };
    }

    /// The environment variables that supply the credential of an account
    /// without a login, or null for a subscription (whose credential comes from
    /// an interactive login, not the environment).
    pub fn credentialEnv(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api => "ANTHROPIC_API_KEY",
            .openai_api => "OPENAI_API_KEY",
            .google_vertex => "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
            .anthropic_subscription, .openai_subscription, .anthropic_console => null,
        };
    }

    /// The vendor this account belongs to.
    pub fn provider(self: Account) Provider {
        return switch (self) {
            .anthropic_api, .anthropic_subscription, .anthropic_console => .anthropic,
            .openai_api, .openai_subscription => .openai,
            .google_vertex => .google,
        };
    }
};

/// The vendor axis: whose wire protocol an account uses. The choice of the
/// serializer keys on this, and each serializer then takes the full account.
/// The catalog keeps one model list per account, because such a list belongs to
/// the principal behind a credential. It keeps the public metadata per vendor,
/// because those facts belong to nobody.
pub const Provider = enum {
    anthropic,
    openai,
    google,

    /// The human-readable label, e.g. "Anthropic". Every account label of the
    /// vendor starts with it.
    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "Anthropic",
            .openai => "OpenAI",
            .google => "Google",
        };
    }
};

pub const Role = enum { user, assistant };

/// A named reasoning-effort level passed through to the provider, which picks
/// the actual thinking depth itself. Anthropic maps it to
/// `output_config.effort` under adaptive thinking. OpenAI maps it to its
/// reasoning-effort control.
///
/// Declaration order is the ladder. A model that does not name a level resolves
/// it onto the nearest level it does name, so the order carries meaning and
/// every member must keep its place. Every rung is a wire spelling that a
/// provider accepts. Drinky never asks a model to stop its reasoning, so the
/// ladder holds no such rung.
pub const Effort = enum { low, medium, high, xhigh, max };

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
            /// The `thoughtSignature` of one part. The text stays empty, because
            /// no wire needs the thought text back.
            google_vertex: Signature,

            pub fn dupe(
                self: *const Replay,
                gpa: std.mem.Allocator,
            ) !Replay {
                return switch (self.*) {
                    inline .anthropic_subscription,
                    .anthropic_api,
                    .anthropic_console,
                    => |proof, tag| switch (proof) {
                        .signature => |signature| @unionInit(Replay, @tagName(tag), .{
                            .signature = try signature.dupe(gpa),
                        }),
                        .redacted => |data| @unionInit(
                            Replay,
                            @tagName(tag),
                            .{ .redacted = try gpa.dupe(u8, data) },
                        ),
                    },
                    .google_vertex => |signature| .{ .google_vertex = try signature.dupe(gpa) },
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
                        .signature => |signature| signature.deinit(gpa),
                        .redacted => |data| gpa.free(data),
                    },
                    inline .openai_subscription, .openai_api => |proof| {
                        gpa.free(proof.text);
                        gpa.free(proof.id);
                        gpa.free(proof.encrypted_content);
                    },
                    .google_vertex => |signature| signature.deinit(gpa),
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

            pub fn dupe(self: *const Signature, gpa: std.mem.Allocator) !Signature {
                const text_copy = try gpa.dupe(u8, self.text);
                errdefer gpa.free(text_copy);
                return .{ .text = text_copy, .signature = try gpa.dupe(u8, self.signature) };
            }

            pub fn deinit(self: *const Signature, gpa: std.mem.Allocator) void {
                gpa.free(self.text);
                gpa.free(self.signature);
            }
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
    /// The reasoning control, already resolved against the model that serves
    /// this request.
    reasoning: Reasoning = .omitted,
    /// A stable per-conversation key a provider can use to improve prompt-cache
    /// routing. Empty sends none. OpenAI combines it with the prompt-prefix
    /// hash to keep a session's growing requests on one cache. Anthropic
    /// ignores it (its caching is driven by explicit breakpoints).
    cache_key: []const u8 = "",

    /// The reasoning control of one request, already resolved against the model
    /// that serves it. A serializer renders it, so no serializer needs to know
    /// which levels a model offers.
    pub const Reasoning = union(enum) {
        /// The request names no reasoning control and takes the provider default.
        omitted,
        /// The request names this level.
        named: Effort,

        /// Whether a request that renders this control replays the stored
        /// reasoning of `vendor`. Anthropic drops every thinking block unless
        /// the request names a level. OpenAI replays an encrypted item at every
        /// level. Gemini validates the signature of every function call, so a
        /// request replays them whatever the control names. The gauges and the
        /// serializers read this one rule, so they cannot drift apart.
        pub fn replaysReasoning(self: Reasoning, vendor: Provider) bool {
            return switch (vendor) {
                .anthropic => self == .named,
                .openai, .google => true,
            };
        }

        /// Whether two controls produce the same request bytes. Two effort
        /// levels that fold onto one level share a prompt cache, so the
        /// cache-hit rate compares controls, not levels.
        pub fn eql(self: Reasoning, other: Reasoning) bool {
            return switch (self) {
                .omitted => other == .omitted,
                .named => |level| switch (other) {
                    .named => |other_level| level == other_level,
                    .omitted => false,
                },
            };
        }
    };
};

/// Token counts for one assistant message. `input` is uncached prompt tokens.
/// The full billed prompt is `input + cache_read + cache_write`.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
};

/// A subscription account's remaining allowance, read from the provider's
/// response head. Each window is optional and independent. Classify one by its
/// length (`window_minutes` ≈ 300 → a 5h window, ≈ 10080 → weekly). The quota
/// is absent for API-key accounts and any provider that reports no quota.
/// `used_percent` runs 0–100, so the remaining share is `100 - used_percent`.
///
/// The two slots carry no fixed window. One provider sent the weekly window in
/// the primary slot and left the secondary slot empty, so a consumer must read
/// `window_minutes` and never the slot.
pub const Quota = struct {
    primary: ?Window = null,
    secondary: ?Window = null,

    pub const Window = struct {
        used_percent: f64,
        window_minutes: ?u32 = null,
        /// Seconds from the response until the window starts again, or null
        /// when the head named none. It ages with the response that carried it,
        /// so a consumer must subtract the time since that response.
        reset_seconds: ?u64 = null,
    };
};

/// A decoded part of a streamed assistant reply. Display deltas are kept
/// separate from completed conversation items. Transports own their native
/// block/item lifecycles and emit an `item` only after the wire closes it.
pub const Event = union(enum) {
    /// Display-only streamed answer text. A delta with bytes ends the open
    /// reasoning run (see `thinking`).
    text: []const u8,
    /// Display-only streamed reasoning text. A consumer collects a run of these
    /// deltas into one block, and the answer text ends that run. A delta with no
    /// bytes displays nothing and ends no run. A transport that starts a new
    /// reasoning part must put a blank line in front of the text of that part.
    /// Without that line the two parts join into one line.
    thinking: []const u8,
    /// Display-only name of a tool call the model has started to stream. The
    /// wire carries the name when the call opens, so the interface can show the
    /// call while its arguments still stream. The call itself arrives as an
    /// `item` once it closes.
    tool_name: []const u8,
    /// Display-only fragment of the open tool call's arguments, in wire order.
    /// The fragments of one call concatenate to its arguments, but a fragment on
    /// its own is not valid JSON.
    tool_arguments: []const u8,
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
                .google_vertex => switch (self.*) {
                    .signature => |signature| if (signature.signature.len != 0)
                        .{ .google_vertex = signature }
                    else
                        null,
                    .redacted, .encrypted => null,
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
        /// The model the response names as the one that served it, or empty when
        /// the wire states none. A provider can switch a request to another
        /// model, so the agent compares this against the requested model and
        /// reports a switch. The slice borrows the stream, like an item slice.
        model: []const u8 = "",

        pub const Rejection = enum {
            /// Malformed or incomplete output that a whole-request retry can fix.
            invalid,
            /// A valid provider outcome the neutral conversation model cannot retain.
            unsupported,
            /// A frame that names an item or a block other than the open one.
            /// The wire streams one at a time, so the wire order broke the
            /// assumption the decoder holds. A retry meets that same order and
            /// only spends the budget. It is reported apart from the two above,
            /// because its cause is the stream shape rather than the content of
            /// the reply, and it needs a different fix.
            uncorrelated,

            /// Which of two rejections a stream latches. A retry cannot clear
            /// either `unsupported` or `uncorrelated`, so both outrank the
            /// retryable `invalid`, and the first of them to latch stays.
            pub fn outranks(self: Rejection, other: Rejection) bool {
                return self != .invalid and other == .invalid;
            }
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

    // The Vertex account takes a signature alone, and only one with bytes.
    const google_replay = signature.replay(.google_vertex).?;
    try std.testing.expectEqualStrings("sig", google_replay.google_vertex.signature);
    try std.testing.expect(redacted.replay(.google_vertex) == null);
    try std.testing.expect(encrypted.replay(.google_vertex) == null);
    const unsigned: Event.Reasoning = .{ .signature = .{ .text = "hmm", .signature = "" } };
    try std.testing.expect(unsigned.replay(.google_vertex) == null);
    try std.testing.expect(unsigned.replay(.anthropic_api) == null);
}

test "a replay copies and frees every arm" {
    const gpa = std.testing.allocator;
    const google: Item.Reasoning.Replay = .{
        .google_vertex = .{ .text = "think", .signature = "sig" },
    };
    const copy = try google.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("think", copy.google_vertex.text);
    try std.testing.expectEqualStrings("sig", copy.google_vertex.signature);
    try std.testing.expect(copy.google_vertex.signature.ptr != google.google_vertex.signature.ptr);
}

test "a provider label prefixes the label of each of its accounts" {
    for (std.enums.values(Account)) |account| {
        const vendor = account.provider();
        try std.testing.expect(std.mem.startsWith(u8, account.label(), vendor.label()));
    }
    try std.testing.expectEqualStrings("Anthropic", Provider.anthropic.label());
    try std.testing.expectEqualStrings("OpenAI", Provider.openai.label());
    try std.testing.expectEqualStrings("Google", Provider.google.label());
}

test "Account.provider maps each account to its vendor" {
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_subscription.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_api.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_subscription.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_console.provider());
    try std.testing.expectEqual(Provider.google, Account.google_vertex.provider());
}

test "account credential flags and label" {
    try std.testing.expect(Account.anthropic_subscription.hasLogin());
    try std.testing.expect(Account.openai_subscription.hasLogin());
    try std.testing.expect(Account.anthropic_console.hasLogin());
    try std.testing.expect(!Account.anthropic_api.hasLogin());
    try std.testing.expect(!Account.openai_api.hasLogin());
    try std.testing.expect(!Account.google_vertex.hasLogin());
    try std.testing.expect(Account.anthropic_subscription.hasRefreshCredential());
    try std.testing.expect(Account.openai_subscription.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_console.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_api.hasRefreshCredential());
    try std.testing.expect(!Account.openai_api.hasRefreshCredential());
    try std.testing.expect(!Account.google_vertex.hasRefreshCredential());
    try std.testing.expectEqualStrings(
        "Anthropic Subscription",
        Account.anthropic_subscription.label(),
    );
    try std.testing.expectEqualStrings("Anthropic Console", Account.anthropic_console.label());
    try std.testing.expectEqualStrings("Anthropic API", Account.anthropic_api.label());
    try std.testing.expectEqualStrings("OpenAI Subscription", Account.openai_subscription.label());
    try std.testing.expectEqualStrings("Google Vertex", Account.google_vertex.label());
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", Account.anthropic_api.credentialEnv().?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", Account.openai_api.credentialEnv().?);
    try std.testing.expectEqualStrings(
        "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
        Account.google_vertex.credentialEnv().?,
    );
    try std.testing.expect(Account.anthropic_console.credentialEnv() == null);
    // An account names a credential kind exactly when it names a variable.
    for (std.enums.values(Account)) |account|
        try std.testing.expectEqual(account.credentialEnv() == null, account.credentialLabel() == null);
    try std.testing.expectEqualStrings("API key", Account.openai_api.credentialLabel().?);
    try std.testing.expectEqualStrings("Key file", Account.google_vertex.credentialLabel().?);
    // The Vertex account goes last, so the startup order prefers every other one.
    const accounts = std.enums.values(Account);
    try std.testing.expectEqual(Account.google_vertex, accounts[accounts.len - 1]);
}

test "a rejection a retry cannot clear outranks one it can" {
    const Rejection = Event.Stop.Rejection;
    // Neither of these clears on a resample, so both hold against `invalid`.
    try std.testing.expect(Rejection.unsupported.outranks(.invalid));
    try std.testing.expect(Rejection.uncorrelated.outranks(.invalid));
    // A retryable outcome never displaces a latched terminal one.
    try std.testing.expect(!Rejection.invalid.outranks(.unsupported));
    try std.testing.expect(!Rejection.invalid.outranks(.uncorrelated));
    // Between two terminal outcomes the first to latch stays, so neither
    // outranks the other and the caller keeps what it has.
    try std.testing.expect(!Rejection.unsupported.outranks(.uncorrelated));
    try std.testing.expect(!Rejection.uncorrelated.outranks(.unsupported));
    try std.testing.expect(!Rejection.invalid.outranks(.invalid));
}
