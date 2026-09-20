const std = @import("std");

pub const Account = enum {
    anthropic_plan,
    anthropic_api,
    anthropic_api_key,
    openai_plan,
    openai_api_key,
    xai_plan,
    xai_api_key,
    openrouter_api,
    openrouter_api_key,
    deepseek_api_key,
    google_cloud_key,
    ds4,

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

    pub fn id(self: Account) []const u8 {
        return ids.get(self);
    }

    pub fn parse(text: []const u8) ?Account {
        for (std.enums.values(Account)) |account| {
            if (std.mem.eql(u8, account.id(), text)) return account;
        }
        return null;
    }

    pub fn hasLogin(self: Account) bool {
        return switch (self) {
            .anthropic_plan,
            .openai_plan,
            .anthropic_api,
            .xai_plan,
            .openrouter_api,
            => true,
            .anthropic_api_key,
            .openai_api_key,
            .xai_api_key,
            .openrouter_api_key,
            .deepseek_api_key,
            .google_cloud_key,
            .ds4,
            => false,
        };
    }

    pub fn hasRefreshCredential(self: Account) bool {
        return switch (self) {
            .anthropic_plan, .openai_plan, .xai_plan => true,
            .anthropic_api,
            .anthropic_api_key,
            .openai_api_key,
            .xai_api_key,
            .openrouter_api,
            .openrouter_api_key,
            .deepseek_api_key,
            .google_cloud_key,
            .ds4,
            => false,
        };
    }

    pub fn credentialEnv(self: Account) ?[]const u8 {
        return switch (self) {
            .anthropic_api_key => "ANTHROPIC_API_KEY",
            .openai_api_key => "OPENAI_API_KEY",
            .xai_api_key => "XAI_API_KEY",
            .openrouter_api_key => "OPENROUTER_API_KEY",
            .deepseek_api_key => "DEEPSEEK_API_KEY",
            .google_cloud_key => "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
            .ds4 => "DS4_BASE_URL",
            .anthropic_plan,
            .openai_plan,
            .anthropic_api,
            .xai_plan,
            .openrouter_api,
            => null,
        };
    }

    pub fn provider(self: Account) Provider {
        return switch (self) {
            .anthropic_api_key, .anthropic_plan, .anthropic_api => .anthropic,
            .openai_api_key, .openai_plan => .openai,
            .xai_api_key, .xai_plan => .xai,
            .openrouter_api, .openrouter_api_key => .openrouter,
            .deepseek_api_key => .deepseek,
            .google_cloud_key => .google,
            .ds4 => .ds4,
        };
    }

    pub fn replaysPlainReasoning(self: Account) bool {
        return switch (self.provider()) {
            .openrouter, .deepseek, .ds4 => true,
            .anthropic, .openai, .xai, .google => false,
        };
    }

    pub fn acceptsEmptyReasoning(self: Account) bool {
        return self == .ds4;
    }
};

pub const Provider = enum {
    anthropic,
    openai,
    xai,
    openrouter,
    deepseek,
    google,
    ds4,
};

pub const Role = enum { user, assistant };

pub const Effort = enum { low, medium, high, xhigh, max };

pub const Item = union(enum) {
    message: Message,
    reasoning: Reasoning,
    tool_call: ToolCall,
    tool_result: ToolResult,

    pub const Message = struct {
        role: Role,
        text: []const u8,
    };

    pub const Reasoning = struct {
        replay: Replay,

        pub const Replay = union(Account) {
            anthropic_plan: Anthropic,
            anthropic_api: Anthropic,
            anthropic_api_key: Anthropic,
            openai_plan: OpenAi,
            openai_api_key: OpenAi,
            xai_plan: OpenAi,
            xai_api_key: OpenAi,
            openrouter_api: OpenAi,
            openrouter_api_key: OpenAi,
            deepseek_api_key: OpenAi,
            google_cloud_key: Signature,
            ds4: OpenAi,

            pub fn dupe(
                self: *const Replay,
                gpa: std.mem.Allocator,
            ) !Replay {
                return switch (self.*) {
                    inline .anthropic_plan,
                    .anthropic_api_key,
                    .anthropic_api,
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
                    .google_cloud_key => |signature| .{
                        .google_cloud_key = try signature.dupe(gpa),
                    },
                    inline .openai_plan,
                    .openai_api_key,
                    .xai_plan,
                    .xai_api_key,
                    .openrouter_api,
                    .openrouter_api_key,
                    .deepseek_api_key,
                    .ds4,
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
                    inline .anthropic_plan,
                    .anthropic_api_key,
                    .anthropic_api,
                    => |proof| switch (proof) {
                        .signature => |signature| signature.deinit(gpa),
                        .redacted => |data| gpa.free(data),
                    },
                    inline .openai_plan,
                    .openai_api_key,
                    .xai_plan,
                    .xai_api_key,
                    .openrouter_api,
                    .openrouter_api_key,
                    .deepseek_api_key,
                    .ds4,
                    => |proof| {
                        gpa.free(proof.text);
                        gpa.free(proof.id);
                        gpa.free(proof.encrypted_content);
                        gpa.free(proof.raw_text);
                    },
                    .google_cloud_key => |signature| signature.deinit(gpa),
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

            pub fn replayable(self: *const OpenAi, account: Account) bool {
                return self.replayableWith(.{
                    .plain = account.replaysPlainReasoning(),
                    .empty = account.acceptsEmptyReasoning(),
                });
            }

            pub fn replayableWith(
                self: *const OpenAi,
                options: struct { plain: bool, empty: bool },
            ) bool {
                if (self.id.len == 0) return false;
                if (self.encrypted_content.len != 0) return true;
                if (self.text.len != 0 or self.raw_text.len != 0) return options.plain;
                return options.empty;
            }
        };
    };

    pub const ToolCall = struct {
        call_id: []const u8,
        name: []const u8,
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
    reasoning: Reasoning = .omitted,
    cache_key: []const u8 = "",

    pub const Reasoning = union(enum) {
        omitted,
        named: Effort,

        pub fn replaysReasoning(self: Reasoning, vendor: Provider) bool {
            return switch (vendor) {
                .anthropic => self == .named,
                .openai, .xai, .openrouter, .deepseek, .google, .ds4 => true,
            };
        }

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

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    pub fn prompt(self: *const Usage) u64 {
        return self.input +| self.cache_read +| self.cache_write;
    }
};

pub const Quota = struct {
    primary: ?Window = null,
    secondary: ?Window = null,

    pub const Window = struct {
        used_percent: f64,
        window_minutes: ?u32 = null,
        reset_seconds: ?u64 = null,
    };
};

pub const amount_usd_max: f64 = 1_000_000_000;

pub const Credits = struct {
    total: f64,
    used: f64,

    pub fn remaining(self: Credits) f64 {
        return @max(0.0, self.total - self.used);
    }
};

pub const Event = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_name: []const u8,
    tool_arguments: []const u8,
    item: Output,
    stop: Stop,

    pub const Output = union(enum) {
        message: []const u8,
        reasoning: Reasoning,
        tool_call: Item.ToolCall,
    };

    pub const Reasoning = union(enum) {
        signature: Item.Reasoning.Signature,
        redacted: []const u8,
        encrypted: Item.Reasoning.OpenAi,

        pub fn replay(
            self: *const Reasoning,
            account: Account,
        ) ?Item.Reasoning.Replay {
            return switch (account) {
                inline .anthropic_plan,
                .anthropic_api_key,
                .anthropic_api,
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
                inline .openai_plan,
                .openai_api_key,
                .xai_plan,
                .xai_api_key,
                .openrouter_api,
                .openrouter_api_key,
                .deepseek_api_key,
                .ds4,
                => |tag| switch (self.*) {
                    .encrypted => |encrypted| if (encrypted.replayable(tag))
                        @unionInit(Item.Reasoning.Replay, @tagName(tag), encrypted)
                    else
                        null,
                    .signature, .redacted => null,
                },
                .google_cloud_key => switch (self.*) {
                    .signature => |signature| if (signature.signature.len != 0)
                        .{ .google_cloud_key = signature }
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

    pub const Stop = struct {
        usage: Usage,
        status: Status = .complete,
        rejection: ?Rejection = null,
        model: []const u8 = "",
        cost: ?f64 = null,

        pub const Rejection = enum {
            invalid,
            unsupported,
            uncorrelated,

            pub fn outranks(self: Rejection, other: Rejection) bool {
                return self != .invalid and other == .invalid;
            }
        };
    };

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
    const openai_replay = encrypted.replay(.openai_plan).?;
    try std.testing.expectEqual(Account.openai_plan, std.meta.activeTag(openai_replay));
    try std.testing.expectEqualStrings("rs_1", openai_replay.openai_plan.id);
    try std.testing.expectEqualStrings("hmm", openai_replay.openai_plan.text);
    try std.testing.expect(encrypted.replay(.anthropic_plan) == null);
    try std.testing.expect(encrypted.replay(.openrouter_api_key) != null);
    try std.testing.expectEqual(
        Account.openrouter_api_key,
        std.meta.activeTag(encrypted.replay(.openrouter_api_key).?),
    );
    const xai_replay = encrypted.replay(.xai_plan).?;
    try std.testing.expectEqual(Account.xai_plan, std.meta.activeTag(xai_replay));
    try std.testing.expectEqualStrings("enc", xai_replay.xai_plan.encrypted_content);
    try std.testing.expect(signature.replay(.xai_api_key) == null);

    const redacted: Event.Reasoning = .{ .redacted = "secret" };
    try std.testing.expectEqualStrings(
        "secret",
        redacted.replay(.anthropic_plan).?.anthropic_plan.redacted,
    );

    const google_replay = signature.replay(.google_cloud_key).?;
    try std.testing.expectEqualStrings("sig", google_replay.google_cloud_key.signature);
    try std.testing.expect(redacted.replay(.google_cloud_key) == null);
    try std.testing.expect(encrypted.replay(.google_cloud_key) == null);
    const unsigned: Event.Reasoning = .{ .signature = .{ .text = "hmm", .signature = "" } };
    try std.testing.expect(unsigned.replay(.google_cloud_key) == null);
    try std.testing.expect(unsigned.replay(.anthropic_api_key) == null);
}

test "only an account that replays plain reasoning takes a summary without encryption" {
    const reasoning: Event.Reasoning = .{ .encrypted = .{
        .text = "think",
        .id = "rs_1",
        .encrypted_content = "",
    } };
    inline for (.{
        Account.openrouter_api,
        Account.openrouter_api_key,
        Account.deepseek_api_key,
        Account.ds4,
    }) |account| {
        const maybe_replay = reasoning.replay(account);
        try std.testing.expect(maybe_replay != null);
        try std.testing.expectEqualStrings("think", @field(maybe_replay.?, @tagName(account)).text);
    }
    inline for (.{
        Account.openai_plan,
        Account.openai_api_key,
        Account.xai_plan,
        Account.xai_api_key,
        Account.anthropic_api_key,
        Account.google_cloud_key,
    }) |account| {
        try std.testing.expect(reasoning.replay(account) == null);
    }
}

test "OpenRouter, DeepSeek, and DwarfStar ask for no encrypted reasoning" {
    for (std.enums.values(Account)) |account| {
        try std.testing.expectEqual(
            account.provider() == .openrouter or
                account.provider() == .deepseek or
                account.provider() == .ds4,
            account.replaysPlainReasoning(),
        );
    }
}

test "only the DwarfStar account replays a reasoning id with no state" {
    const reasoning: Event.Reasoning = .{ .encrypted = .{
        .text = "",
        .id = "rs_1",
        .encrypted_content = "",
    } };
    try std.testing.expect(reasoning.replay(.ds4) != null);
    try std.testing.expectEqualStrings("rs_1", reasoning.replay(.ds4).?.ds4.id);
    try std.testing.expect(reasoning.replay(.deepseek_api_key) == null);
    try std.testing.expect(reasoning.replay(.openai_api_key) == null);
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
        .google_cloud_key = .{ .text = "think", .signature = "sig" },
    };
    const copy = try google.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("think", copy.google_cloud_key.text);
    try std.testing.expectEqualStrings("sig", copy.google_cloud_key.signature);
    try std.testing.expect(
        copy.google_cloud_key.signature.ptr != google.google_cloud_key.signature.ptr,
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
        try std.testing.expect(std.mem.indexOfScalar(u8, account.id(), '_') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, account.id(), '/') == null);
        try std.testing.expectEqual(account, Account.parse(account.id()).?);
        if (account == .ds4) {
            try std.testing.expectEqualStrings(prefix, account.id());
            try std.testing.expect(!std.mem.endsWith(u8, account.id(), "-key"));
            continue;
        }
        try std.testing.expectEqual(account.id()[prefix.len], '-');
        try std.testing.expectEqual(
            !account.hasLogin(),
            std.mem.endsWith(u8, account.id(), "-key"),
        );
    }
    try std.testing.expectEqualStrings("anthropic-plan", Account.anthropic_plan.id());
    try std.testing.expectEqualStrings("anthropic-api", Account.anthropic_api.id());
    try std.testing.expectEqualStrings("anthropic-api-key", Account.anthropic_api_key.id());
    try std.testing.expectEqualStrings("openai-plan", Account.openai_plan.id());
    try std.testing.expectEqualStrings("openai-api-key", Account.openai_api_key.id());
    try std.testing.expectEqualStrings("xai-plan", Account.xai_plan.id());
    try std.testing.expectEqualStrings("xai-api-key", Account.xai_api_key.id());
    try std.testing.expectEqualStrings("openrouter-api", Account.openrouter_api.id());
    try std.testing.expectEqualStrings("openrouter-api-key", Account.openrouter_api_key.id());
    try std.testing.expectEqualStrings("deepseek-api-key", Account.deepseek_api_key.id());
    try std.testing.expectEqualStrings("google-cloud-key", Account.google_cloud_key.id());
    try std.testing.expectEqualStrings("ds4", Account.ds4.id());
    try std.testing.expect(Account.parse("anthropic_plan") == null);
    try std.testing.expect(Account.parse("anthropic-plan/claude-fable-5-1") == null);
    try std.testing.expect(Account.parse("") == null);
}

test "Account.provider maps each account to its vendor" {
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api_key.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_plan.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_api_key.provider());
    try std.testing.expectEqual(Provider.openai, Account.openai_plan.provider());
    try std.testing.expectEqual(Provider.anthropic, Account.anthropic_api.provider());
    try std.testing.expectEqual(Provider.xai, Account.xai_plan.provider());
    try std.testing.expectEqual(Provider.xai, Account.xai_api_key.provider());
    try std.testing.expectEqual(Provider.openrouter, Account.openrouter_api.provider());
    try std.testing.expectEqual(Provider.openrouter, Account.openrouter_api_key.provider());
    try std.testing.expectEqual(Provider.deepseek, Account.deepseek_api_key.provider());
    try std.testing.expectEqual(Provider.google, Account.google_cloud_key.provider());
    try std.testing.expectEqual(Provider.ds4, Account.ds4.provider());
}

test "account credential flags and environment variables" {
    try std.testing.expect(Account.anthropic_plan.hasLogin());
    try std.testing.expect(Account.openai_plan.hasLogin());
    try std.testing.expect(Account.anthropic_api.hasLogin());
    try std.testing.expect(Account.xai_plan.hasLogin());
    try std.testing.expect(Account.openrouter_api.hasLogin());
    try std.testing.expect(!Account.anthropic_api_key.hasLogin());
    try std.testing.expect(!Account.openai_api_key.hasLogin());
    try std.testing.expect(!Account.xai_api_key.hasLogin());
    try std.testing.expect(!Account.openrouter_api_key.hasLogin());
    try std.testing.expect(!Account.deepseek_api_key.hasLogin());
    try std.testing.expect(!Account.google_cloud_key.hasLogin());
    try std.testing.expect(!Account.ds4.hasLogin());
    try std.testing.expect(Account.anthropic_plan.hasRefreshCredential());
    try std.testing.expect(Account.openai_plan.hasRefreshCredential());
    try std.testing.expect(Account.xai_plan.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_api.hasRefreshCredential());
    try std.testing.expect(!Account.anthropic_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.openai_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.xai_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.openrouter_api.hasRefreshCredential());
    try std.testing.expect(!Account.openrouter_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.deepseek_api_key.hasRefreshCredential());
    try std.testing.expect(!Account.google_cloud_key.hasRefreshCredential());
    try std.testing.expect(!Account.ds4.hasRefreshCredential());
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
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", Account.deepseek_api_key.credentialEnv().?);
    try std.testing.expectEqualStrings(
        "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
        Account.google_cloud_key.credentialEnv().?,
    );
    try std.testing.expectEqualStrings("DS4_BASE_URL", Account.ds4.credentialEnv().?);
    try std.testing.expect(Account.anthropic_api.credentialEnv() == null);
    for (std.enums.values(Account)) |account|
        try std.testing.expectEqual(account.hasLogin(), account.credentialEnv() == null);
    const accounts = std.enums.values(Account);
    try std.testing.expectEqual(Account.ds4, accounts[accounts.len - 1]);
}

test "a rejection a retry cannot clear outranks one it can" {
    const Rejection = Event.Stop.Rejection;
    try std.testing.expect(Rejection.unsupported.outranks(.invalid));
    try std.testing.expect(Rejection.uncorrelated.outranks(.invalid));
    try std.testing.expect(!Rejection.invalid.outranks(.unsupported));
    try std.testing.expect(!Rejection.invalid.outranks(.uncorrelated));
    try std.testing.expect(!Rejection.unsupported.outranks(.uncorrelated));
    try std.testing.expect(!Rejection.uncorrelated.outranks(.unsupported));
    try std.testing.expect(!Rejection.invalid.outranks(.invalid));
}
