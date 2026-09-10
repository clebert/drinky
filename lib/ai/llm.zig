//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types. The agent loop and tools depend only on
//! this module, never on a specific provider. Pure data: no state, no I/O.

const std = @import("std");

/// A configured account. Its tag holds three segments: the vendor that serves
/// the requests, the product the user buys, and the source of the credential.
/// `sub` is a consumer subscription, `api` is the developer API, and `cloud` is
/// the cloud platform of the vendor. `login` is an interactive OAuth login,
/// `key` is an environment variable, and `keyfile` is a service account key
/// file. This is the tag `provider.Client`/`Stream` key on. It is also the
/// origin stamped on stored reasoning, so only the exact account that produced
/// a blob replays it. At startup any account with a login is preferred over an
/// environment credential, across vendors. Within a tier, declaration order
/// decides.
pub const Account = enum {
    /// Claude Pro/Max subscription OAuth, authorized with a `Bearer` token and
    /// the Claude Code identity headers.
    anthropic_sub_login,
    /// Anthropic Console (Developer Platform), authorized with an `x-api-key`
    /// key that an OAuth login mints and stores. It sends the Claude Code system
    /// prompt like the subscription, so it reaches every model.
    anthropic_api_login,
    /// Per-token platform API, authorized with `x-api-key`.
    anthropic_api_key,
    /// ChatGPT (Codex) subscription OAuth.
    openai_sub_login,
    /// Per-token platform API, authorized with a `Bearer` key.
    openai_api_key,
    /// SuperGrok or X Premium subscription OAuth, authorized with a `Bearer`
    /// token on the public xAI API.
    xai_sub_login,
    /// Per-token xAI API, authorized with a `Bearer` key.
    xai_api_key,
    /// OpenRouter OAuth login, authorized with a minted `Bearer` key.
    openrouter_api_login,
    /// Per-token OpenRouter API, authorized with a `Bearer` key.
    openrouter_api_key,
    /// Gemini models on the Agent Platform of Google Cloud, authorized with an
    /// access token that Drinky mints from a service account key file. It goes
    /// last, so the startup order prefers every other account.
    google_cloud_keyfile,

    /// The identifier of each account: its tag with `-` in place of `_`.
    const ids: std.EnumArray(Account, []const u8) = table: {
        var built: std.EnumArray(Account, []const u8) = .initUndefined();
        for (std.enums.values(Account)) |account| {
            const tag = @tagName(account);
            var text: [tag.len]u8 = undefined;
            for (tag, &text) |byte, *out| out.* = if (byte == '_') '-' else byte;
            const frozen = text;
            built.set(account, &frozen);
        }
        break :table built;
    };

    /// The identifier, as in `anthropic-api-login`. It is the key of every store
    /// entry and the spelling of every message, so one string names an account
    /// everywhere. `id/model` names a model under the account.
    pub fn id(self: Account) []const u8 {
        return ids.get(self);
    }

    /// The account that `text` identifies, or null.
    pub fn parse(text: []const u8) ?Account {
        for (std.enums.values(Account)) |account| {
            if (std.mem.eql(u8, account.id(), text)) return account;
        }
        return null;
    }

    /// Whether this account signs in through an interactive OAuth login (as
    /// opposed to an environment credential). Such an account can be logged in
    /// and out mid-session. The Console account signs in this way even though it
    /// then authorizes with a minted `x-api-key` key.
    pub fn hasLogin(self: Account) bool {
        return switch (self) {
            .anthropic_sub_login,
            .openai_sub_login,
            .anthropic_api_login,
            .xai_sub_login,
            .openrouter_api_login,
            => true,
            .anthropic_api_key,
            .openai_api_key,
            .xai_api_key,
            .openrouter_api_key,
            .google_cloud_keyfile,
            => false,
        };
    }

    /// Whether this account uses a refresh credential for provider requests. The
    /// key file account renews its token once, but a rejected token is a
    /// configuration problem of the user and not a rotated credential.
    pub fn hasRefreshCredential(self: Account) bool {
        return switch (self) {
            .anthropic_sub_login, .openai_sub_login, .xai_sub_login => true,
            .anthropic_api_login,
            .anthropic_api_key,
            .openai_api_key,
            .xai_api_key,
            .openrouter_api_login,
            .openrouter_api_key,
            .google_cloud_keyfile,
            => false,
        };
    }

    /// The environment variables that supply the credential of an account
    /// without a login, or null for an account whose credential comes from an
    /// interactive login.
    pub fn credentialEnv(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api_key => "ANTHROPIC_API_KEY",
            .openai_api_key => "OPENAI_API_KEY",
            .xai_api_key => "XAI_API_KEY",
            .openrouter_api_key => "OPENROUTER_API_KEY",
            .google_cloud_keyfile => "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
            .anthropic_sub_login,
            .openai_sub_login,
            .anthropic_api_login,
            .xai_sub_login,
            .openrouter_api_login,
            => null,
        };
    }

    /// The vendor this account belongs to: the first segment of its tag.
    pub fn provider(self: Account) Provider {
        return switch (self) {
            .anthropic_api_key, .anthropic_sub_login, .anthropic_api_login => .anthropic,
            .openai_api_key, .openai_sub_login => .openai,
            .xai_api_key, .xai_sub_login => .xai,
            .openrouter_api_login, .openrouter_api_key => .openrouter,
            .google_cloud_keyfile => .google,
        };
    }

    /// Whether this account replays a reasoning item without encrypted content.
    /// OpenRouter picks the endpoint of a request from the parameters of that
    /// request, and a request for encrypted content reaches fewer endpoints, so
    /// Drinky asks for none and replays the reasoning text instead. Every other
    /// Responses account must hold the encrypted blob.
    pub fn replaysPlainReasoning(self: Account) bool {
        return self.provider() == .openrouter;
    }
};

/// The vendor axis: whose wire protocol an account uses. The choice of the
/// serializer keys on this, and each serializer then takes the full account.
/// The catalog keeps one model list per account, because such a list belongs to
/// the principal behind a credential. It keeps the public metadata per vendor,
/// because those facts belong to nobody. xAI speaks the OpenAI protocol, but it
/// is a vendor of its own: its models, its metadata, and its timeouts are its
/// own. The tag is the identifier, and every account identifier of the vendor
/// starts with it.
pub const Provider = enum {
    anthropic,
    openai,
    xai,
    openrouter,
    google,
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
            anthropic_sub_login: Anthropic,
            anthropic_api_login: Anthropic,
            anthropic_api_key: Anthropic,
            openai_sub_login: OpenAi,
            openai_api_key: OpenAi,
            /// The xAI accounts speak the Responses protocol, so their proof
            /// has the OpenAI shape.
            xai_sub_login: OpenAi,
            xai_api_key: OpenAi,
            /// The OpenRouter accounts speak the Responses protocol, so their
            /// proof has the OpenAI shape.
            openrouter_api_login: OpenAi,
            openrouter_api_key: OpenAi,
            /// The `thoughtSignature` of one part. The text stays empty, because
            /// no wire needs the thought text back.
            google_cloud_keyfile: Signature,

            pub fn dupe(
                self: *const Replay,
                gpa: std.mem.Allocator,
            ) !Replay {
                return switch (self.*) {
                    inline .anthropic_sub_login,
                    .anthropic_api_key,
                    .anthropic_api_login,
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
                    .google_cloud_keyfile => |signature| .{
                        .google_cloud_keyfile = try signature.dupe(gpa),
                    },
                    inline .openai_sub_login,
                    .openai_api_key,
                    .xai_sub_login,
                    .xai_api_key,
                    .openrouter_api_login,
                    .openrouter_api_key,
                    => |proof, tag| openai: {
                        const text_copy = try gpa.dupe(u8, proof.text);
                        errdefer gpa.free(text_copy);
                        const id_copy = try gpa.dupe(u8, proof.id);
                        errdefer gpa.free(id_copy);
                        const content_copy = try gpa.dupe(u8, proof.encrypted_content);
                        errdefer gpa.free(content_copy);
                        const raw_copy = try gpa.dupe(u8, proof.raw_text);
                        break :openai @unionInit(Replay, @tagName(tag), .{
                            .text = text_copy,
                            .id = id_copy,
                            .encrypted_content = content_copy,
                            .raw_text = raw_copy,
                        });
                    },
                };
            }

            pub fn deinit(self: *const Replay, gpa: std.mem.Allocator) void {
                switch (self.*) {
                    inline .anthropic_sub_login,
                    .anthropic_api_key,
                    .anthropic_api_login,
                    => |proof| switch (proof) {
                        .signature => |signature| signature.deinit(gpa),
                        .redacted => |data| gpa.free(data),
                    },
                    inline .openai_sub_login,
                    .openai_api_key,
                    .xai_sub_login,
                    .xai_api_key,
                    .openrouter_api_login,
                    .openrouter_api_key,
                    => |proof| {
                        gpa.free(proof.text);
                        gpa.free(proof.id);
                        gpa.free(proof.encrypted_content);
                        gpa.free(proof.raw_text);
                    },
                    .google_cloud_keyfile => |signature| signature.deinit(gpa),
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
            raw_text: []const u8 = "",

            /// Whether this proof can go back on the wire. Every account needs
            /// the id and the encrypted blob. An account that replays plain
            /// reasoning (see `Account.replaysPlainReasoning`) takes the summary
            /// or the raw reasoning text instead.
            pub fn replayable(self: *const OpenAi, plain: bool) bool {
                if (self.id.len == 0) return false;
                if (self.encrypted_content.len != 0) return true;
                return plain and (self.text.len != 0 or self.raw_text.len != 0);
            }
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
        /// the request names a level. OpenAI and xAI replay an encrypted item at
        /// every level. Gemini validates the signature of every function call,
        /// so a request replays them whatever the control names. The gauges and
        /// the serializers read this one rule, so they cannot drift apart.
        pub fn replaysReasoning(self: Reasoning, vendor: Provider) bool {
            return switch (vendor) {
                .anthropic => self == .named,
                .openai, .xai, .openrouter, .google => true,
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

    /// The whole billed prompt. Saturating, because the counts arrive from the
    /// provider stream unchecked.
    pub fn prompt(self: *const Usage) u64 {
        return self.input +| self.cache_read +| self.cache_write;
    }
};

/// A subscription account's remaining allowance. Anthropic and OpenAI state it
/// in the response head. The xAI subscription states it on a billing request.
/// Each window is optional and independent. Classify one by its length
/// (`window_minutes` ≈ 300 → a 5h window, ≈ 10080 → weekly). The quota is
/// absent for API-key accounts and any provider that reports no quota.
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
        /// Seconds from the report until the window starts again, or null when
        /// the report named none. It ages with the report that carried it, so a
        /// consumer must subtract the time since that report.
        reset_seconds: ?u64 = null,
    };
};

/// The largest money figure Drinky holds, in USD. No charge, pool, or session
/// comes near it. A consumer prints the figure into a fixed buffer, so a
/// report that names a figure past this bound is no report, and a total stops
/// at it.
pub const amount_usd_max: f64 = 1_000_000_000;

/// The prepaid credit pool of an account, in USD. The provider states the pool
/// and the spend it drew from it, and a consumer derives the remaining amount.
/// No window rolls, so a fresh report states the truth and no consumer ages
/// the numbers. The pool states an amount and no share: the figures are
/// lifetime totals, so their ratio measures no pressure. The OpenRouter pool
/// states none of the window fields of a quota, so it keeps its own type.
pub const Credits = struct {
    total: f64,
    used: f64,

    /// The amount still available, never negative.
    pub fn remaining(self: Credits) f64 {
        return @max(0.0, self.total - self.used);
    }
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
        /// The item of an account that replays plain reasoning can omit the
        /// encrypted content.
        encrypted: Item.Reasoning.OpenAi,

        pub fn replay(
            self: *const Reasoning,
            account: Account,
        ) ?Item.Reasoning.Replay {
            return switch (account) {
                inline .anthropic_sub_login,
                .anthropic_api_key,
                .anthropic_api_login,
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
                inline .openai_sub_login,
                .openai_api_key,
                .xai_sub_login,
                .xai_api_key,
                .openrouter_api_login,
                .openrouter_api_key,
                => |tag| switch (self.*) {
                    .encrypted => |encrypted| if (encrypted.replayable(
                        tag.replaysPlainReasoning(),
                    ))
                        @unionInit(Item.Reasoning.Replay, @tagName(tag), encrypted)
                    else
                        null,
                    .signature, .redacted => null,
                },
                .google_cloud_keyfile => switch (self.*) {
                    .signature => |signature| if (signature.signature.len != 0)
                        .{ .google_cloud_keyfile = signature }
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
        /// The reported charge of this reply in USD, or null when the wire
        /// states none. A session prefers this number over a rate estimate.
        cost: ?f64 = null,

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
    const anthropic_replay = signature.replay(.anthropic_api_key).?;
    try std.testing.expectEqual(Account.anthropic_api_key, std.meta.activeTag(anthropic_replay));
    try std.testing.expectEqualStrings("hmm", anthropic_replay.anthropic_api_key.signature.text);
    try std.testing.expectEqualStrings(
        "sig",
        anthropic_replay.anthropic_api_key.signature.signature,
    );
    try std.testing.expect(signature.replay(.openai_api_key) == null);

    const encrypted: Event.Reasoning = .{ .encrypted = .{
        .text = "hmm",
        .id = "rs_1",
        .encrypted_content = "enc",
    } };
    const openai_replay = encrypted.replay(.openai_sub_login).?;
    try std.testing.expectEqual(Account.openai_sub_login, std.meta.activeTag(openai_replay));
    try std.testing.expectEqualStrings("rs_1", openai_replay.openai_sub_login.id);
    try std.testing.expectEqualStrings("hmm", openai_replay.openai_sub_login.text);
    try std.testing.expect(encrypted.replay(.anthropic_sub_login) == null);
    try std.testing.expect(encrypted.replay(.openrouter_api_key) != null);
    try std.testing.expectEqual(
        Account.openrouter_api_key,
        std.meta.activeTag(encrypted.replay(.openrouter_api_key).?),
    );
    // An xAI proof has the same shape and binds to its own account alone.
    const xai_replay = encrypted.replay(.xai_sub_login).?;
    try std.testing.expectEqual(Account.xai_sub_login, std.meta.activeTag(xai_replay));
    try std.testing.expectEqualStrings("enc", xai_replay.xai_sub_login.encrypted_content);
    try std.testing.expect(signature.replay(.xai_api_key) == null);

    const redacted: Event.Reasoning = .{ .redacted = "secret" };
    try std.testing.expectEqualStrings(
        "secret",
        redacted.replay(.anthropic_sub_login).?.anthropic_sub_login.redacted,
    );

    // The key file account takes a signature alone, and only one with bytes.
    const google_replay = signature.replay(.google_cloud_keyfile).?;
    try std.testing.expectEqualStrings("sig", google_replay.google_cloud_keyfile.signature);
    try std.testing.expect(redacted.replay(.google_cloud_keyfile) == null);
    try std.testing.expect(encrypted.replay(.google_cloud_keyfile) == null);
    const unsigned: Event.Reasoning = .{ .signature = .{ .text = "hmm", .signature = "" } };
    try std.testing.expect(unsigned.replay(.google_cloud_keyfile) == null);
    try std.testing.expect(unsigned.replay(.anthropic_api_key) == null);
}

test "only an account that replays plain reasoning takes a summary without encryption" {
    const reasoning: Event.Reasoning = .{ .encrypted = .{
        .text = "think",
        .id = "rs_1",
        .encrypted_content = "",
    } };
    inline for (.{ Account.openrouter_api_login, Account.openrouter_api_key }) |account| {
        const maybe_replay = reasoning.replay(account);
        try std.testing.expect(maybe_replay != null);
        try std.testing.expectEqualStrings("think", @field(maybe_replay.?, @tagName(account)).text);
    }
    // OpenAI and xAI ask for the encrypted blob, and their backend rejects a
    // reasoning item that carries none, so such a proof replays nowhere.
    inline for (.{
        Account.openai_sub_login,
        Account.openai_api_key,
        Account.xai_sub_login,
        Account.xai_api_key,
        Account.anthropic_api_key,
        Account.google_cloud_keyfile,
    }) |account| {
        try std.testing.expect(reasoning.replay(account) == null);
    }
}

test "an account replays plain reasoning exactly when OpenRouter serves it" {
    for (std.enums.values(Account)) |account| {
        try std.testing.expectEqual(
            account.provider() == .openrouter,
            account.replaysPlainReasoning(),
        );
    }
}

fn dupeRawReasoning(gpa: std.mem.Allocator) !void {
    const source: Item.Reasoning.Replay = .{ .openrouter_api_key = .{
        .text = "summary",
        .id = "rs_1",
        .encrypted_content = "enc",
        .raw_text = "raw reasoning",
    } };
    const copy = try source.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("raw reasoning", copy.openrouter_api_key.raw_text);
    try std.testing.expect(
        copy.openrouter_api_key.raw_text.ptr != source.openrouter_api_key.raw_text.ptr,
    );
}

test "raw reasoning owns its text and frees every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dupeRawReasoning, .{});
}

test "a replay copies and frees every arm" {
    const gpa = std.testing.allocator;
    const google: Item.Reasoning.Replay = .{
        .google_cloud_keyfile = .{ .text = "think", .signature = "sig" },
    };
    const copy = try google.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("think", copy.google_cloud_keyfile.text);
    try std.testing.expectEqualStrings("sig", copy.google_cloud_keyfile.signature);
    try std.testing.expect(
        copy.google_cloud_keyfile.signature.ptr != google.google_cloud_keyfile.signature.ptr,
    );

    const xai: Item.Reasoning.Replay = .{
        .xai_api_key = .{ .text = "think", .id = "rs_1", .encrypted_content = "enc" },
    };
    const xai_copy = try xai.dupe(gpa);
    defer xai_copy.deinit(gpa);
    try std.testing.expectEqualStrings("rs_1", xai_copy.xai_api_key.id);
    try std.testing.expect(
        xai_copy.xai_api_key.encrypted_content.ptr != xai.xai_api_key.encrypted_content.ptr,
    );
}

test "an account identifier starts with its provider and parses back" {
    for (std.enums.values(Account)) |account| {
        const prefix = @tagName(account.provider());
        try std.testing.expect(std.mem.startsWith(u8, account.id(), prefix));
        try std.testing.expectEqual(account.id()[prefix.len], '-');
        try std.testing.expect(std.mem.indexOfScalar(u8, account.id(), '_') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, account.id(), '/') == null);
        try std.testing.expectEqual(account, Account.parse(account.id()).?);
    }
    try std.testing.expectEqualStrings("anthropic-sub-login", Account.anthropic_sub_login.id());
    try std.testing.expectEqualStrings("anthropic-api-login", Account.anthropic_api_login.id());
    try std.testing.expectEqualStrings("anthropic-api-key", Account.anthropic_api_key.id());
    try std.testing.expectEqualStrings("openai-sub-login", Account.openai_sub_login.id());
    try std.testing.expectEqualStrings("openai-api-key", Account.openai_api_key.id());
    try std.testing.expectEqualStrings("xai-sub-login", Account.xai_sub_login.id());
    try std.testing.expectEqualStrings("xai-api-key", Account.xai_api_key.id());
    try std.testing.expectEqualStrings("openrouter-api-login", Account.openrouter_api_login.id());
    try std.testing.expectEqualStrings("openrouter-api-key", Account.openrouter_api_key.id());
    try std.testing.expectEqualStrings("google-cloud-keyfile", Account.google_cloud_keyfile.id());
    // The tag spelling is not the identifier, so a store key never holds it.
    try std.testing.expect(Account.parse("anthropic_sub_login") == null);
    try std.testing.expect(Account.parse("anthropic-sub-login/claude-fable-5-1") == null);
    try std.testing.expect(Account.parse("") == null);
}

test "Account.provider maps each account to its vendor" {
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api_key.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_sub_login.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_api_key.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_sub_login.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api_login.provider());
    try std.testing.expectEqual(Provider.xai, Account.xai_sub_login.provider());
    try std.testing.expectEqual(Provider.xai, Account.xai_api_key.provider());
    try std.testing.expectEqual(Provider.openrouter, Account.openrouter_api_login.provider());
    try std.testing.expectEqual(Provider.openrouter, Account.openrouter_api_key.provider());
    try std.testing.expectEqual(Provider.google, Account.google_cloud_keyfile.provider());
}

test "account credential flags and environment variables" {
    try std.testing.expect(Account.anthropic_sub_login.hasLogin());
    try std.testing.expect(Account.openai_sub_login.hasLogin());
    try std.testing.expect(Account.anthropic_api_login.hasLogin());
    try std.testing.expect(Account.xai_sub_login.hasLogin());
    try std.testing.expect(Account.openrouter_api_login.hasLogin());
    try std.testing.expect(!Account.anthropic_api_key.hasLogin());
    try std.testing.expect(!Account.openai_api_key.hasLogin());
    try std.testing.expect(!Account.xai_api_key.hasLogin());
    try std.testing.expect(!Account.openrouter_api_key.hasLogin());
    try std.testing.expect(!Account.google_cloud_keyfile.hasLogin());
    try std.testing.expect(Account.anthropic_sub_login.hasRefreshCredential());
    try std.testing.expect(Account.openai_sub_login.hasRefreshCredential());
    try std.testing.expect(Account.xai_sub_login.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_api_login.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.openai_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.xai_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.openrouter_api_login.hasRefreshCredential());
    try std.testing.expect(!Account.openrouter_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.google_cloud_keyfile.hasRefreshCredential());
    try std.testing.expectEqualStrings(
        "ANTHROPIC_API_KEY",
        Account.anthropic_api_key.credentialEnv().?,
    );
    try std.testing.expectEqualStrings("OPENAI_API_KEY", Account.openai_api_key.credentialEnv().?);
    try std.testing.expectEqualStrings("XAI_API_KEY", Account.xai_api_key.credentialEnv().?);
    try std.testing.expectEqualStrings(
        "OPENROUTER_API_KEY",
        Account.openrouter_api_key.credentialEnv().?,
    );
    try std.testing.expectEqualStrings(
        "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
        Account.google_cloud_keyfile.credentialEnv().?,
    );
    try std.testing.expect(Account.anthropic_api_login.credentialEnv() == null);
    // An account names a variable exactly when it has no login.
    for (std.enums.values(Account)) |account|
        try std.testing.expectEqual(account.hasLogin(), account.credentialEnv() == null);
    // The key file account goes last, so the startup order prefers every other one.
    const accounts = std.enums.values(Account);
    try std.testing.expectEqual(Account.google_cloud_keyfile, accounts[accounts.len - 1]);
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
