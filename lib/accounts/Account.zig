const std = @import("std");

const providers = @import("providers");

const Account = @This();

id: []const u8,
vendor: Vendor,
dialect: Dialect,
credential: Credential,
model_source: ModelSource,
usage: Usage,

pub const Vendor = enum {
    anthropic,
    openai,
    xai,
    openrouter,
    deepseek,
    google,

    pub fn label(self: Vendor) []const u8 {
        return switch (self) {
            .anthropic => "Anthropic",
            .openai => "OpenAI",
            .xai => "xAI",
            .openrouter => "OpenRouter",
            .deepseek => "DeepSeek",
            .google => "Google",
        };
    }
};

const Dialect = union(enum) {
    responses: Responses,
    messages: providers.Messages.Identity,
    gemini,

    const Responses = struct {
        base_url: []const u8,
        codex: bool = false,
        switches: providers.Responses.Switches = .{},
    };
};

pub const Credential = union(enum) {
    login: Login,
    key,
    key_file,
};

pub const Login = enum { claude, console, chatgpt, grok, openrouter };

const ModelSource = enum { messages, codex, responses, gemini, public };

const Usage = union(enum) {
    none,
    head,
    xai_billing: []const u8,
    openrouter_credits: []const u8,
    deepseek_balance: []const u8,
};

const xai_billing_url = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const openrouter_credits_url = "https://openrouter.ai/api/v1/credits";
const deepseek_balance_url = "https://api.deepseek.com/user/balance";

const key_file_setting = "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION";

pub const table = [_]Account{
    .{
        .id = "anthropic-plan",
        .vendor = .anthropic,
        .dialect = .{ .messages = .subscription },
        .credential = .{ .login = .claude },
        .model_source = .messages,
        .usage = .head,
    },
    .{
        .id = "anthropic-api",
        .vendor = .anthropic,
        .dialect = .{ .messages = .console },
        .credential = .{ .login = .console },
        .model_source = .messages,
        .usage = .none,
    },
    .{
        .id = "anthropic-api-key",
        .vendor = .anthropic,
        .dialect = .{ .messages = .api_key },
        .credential = .key,
        .model_source = .messages,
        .usage = .none,
    },
    .{
        .id = "openai-plan",
        .vendor = .openai,
        .dialect = .{ .responses = .{
            .base_url = "https://chatgpt.com/backend-api/codex",
            .codex = true,
        } },
        .credential = .{ .login = .chatgpt },
        .model_source = .codex,
        .usage = .head,
    },
    .{
        .id = "openai-api-key",
        .vendor = .openai,
        .dialect = .{ .responses = .{ .base_url = "https://api.openai.com/v1" } },
        .credential = .key,
        .model_source = .responses,
        .usage = .none,
    },
    .{
        .id = "xai-plan",
        .vendor = .xai,
        .dialect = .{ .responses = .{ .base_url = "https://api.x.ai/v1" } },
        .credential = .{ .login = .grok },
        .model_source = .responses,
        .usage = .{ .xai_billing = xai_billing_url },
    },
    .{
        .id = "xai-api-key",
        .vendor = .xai,
        .dialect = .{ .responses = .{ .base_url = "https://api.x.ai/v1" } },
        .credential = .key,
        .model_source = .responses,
        .usage = .none,
    },
    .{
        .id = "openrouter-api",
        .vendor = .openrouter,
        .dialect = .{ .responses = .{
            .base_url = "https://openrouter.ai/api/v1",
            .switches = .{ .plain_reasoning = true, .require_parameters = true },
        } },
        .credential = .{ .login = .openrouter },
        .model_source = .public,
        .usage = .{ .openrouter_credits = openrouter_credits_url },
    },
    .{
        .id = "openrouter-api-key",
        .vendor = .openrouter,
        .dialect = .{ .responses = .{
            .base_url = "https://openrouter.ai/api/v1",
            .switches = .{ .plain_reasoning = true, .require_parameters = true },
        } },
        .credential = .key,
        .model_source = .public,
        .usage = .{ .openrouter_credits = openrouter_credits_url },
    },
    .{
        .id = "deepseek-api-key",
        .vendor = .deepseek,
        .dialect = .{ .responses = .{
            .base_url = "https://api.deepseek.com/v1",
            .switches = .{ .plain_reasoning = true },
        } },
        .credential = .key,
        .model_source = .responses,
        .usage = .{ .deepseek_balance = deepseek_balance_url },
    },
    .{
        .id = "google-cloud-key",
        .vendor = .google,
        .dialect = .gemini,
        .credential = .key_file,
        .model_source = .gemini,
        .usage = .none,
    },
};

comptime {
    for (&table) |*row| {
        const login: ?Login = switch (row.credential) {
            .login => |flow| flow,
            .key, .key_file => null,
        };
        const fetchable = switch (row.model_source) {
            .messages => row.dialect == .messages and
                (row.credential == .key or login == .claude or login == .console),
            .codex => login == .chatgpt,
            .responses => row.credential == .key or login == .grok,
            .gemini => row.credential == .key_file,
            .public => true,
        };
        if (!fetchable) {
            @compileError("The model source of a row must match its dialect and its credential.");
        }
        const checkable = switch (row.model_source) {
            .messages, .responses, .public => true,
            .codex, .gemini => false,
        };
        if (row.credential == .key and !checkable) {
            @compileError("A key row must take a model source that can check a new key.");
        }
        if (row.model_source == .public and row.vendor != .openrouter) {
            @compileError("Only an OpenRouter row can take the public model list.");
        }
    }
}

pub fn index(id: []const u8) ?usize {
    for (&table, 0..) |*account, position| {
        if (std.mem.eql(u8, account.id, id)) return position;
    }
    return null;
}

pub fn hasLogin(self: *const Account) bool {
    return self.credential == .login;
}

pub fn requiresOutputLimit(self: *const Account) bool {
    return switch (self.dialect) {
        .messages => true,
        .responses, .gemini => false,
    };
}

pub fn setting(self: *const Account) ?[]const u8 {
    return switch (self.credential) {
        .key_file => key_file_setting,
        .login, .key => null,
    };
}

test "an account identifier starts with its vendor and ends in -key without a login" {
    for (&table, 0..) |*account, position| {
        const prefix = @tagName(account.vendor);
        try std.testing.expect(std.mem.startsWith(u8, account.id, prefix));
        try std.testing.expect(std.mem.findAny(u8, account.id, "_/") == null);
        try std.testing.expectEqual(position, index(account.id).?);
        try std.testing.expectEqual(account.credential == .key_file, account.setting() != null);
        try std.testing.expectEqual(account.id[prefix.len], '-');
        try std.testing.expectEqual(!account.hasLogin(), std.mem.endsWith(u8, account.id, "-key"));
    }
    try std.testing.expectEqual(@as(usize, 11), table.len);
    try std.testing.expect(index("anthropic_plan") == null);
    try std.testing.expect(index("anthropic-plan/claude-fable-5-1") == null);
    try std.testing.expect(index("") == null);
}

test "only the key file account names a setting of the environment" {
    try std.testing.expectEqualStrings(
        "GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_LOCATION",
        table[index("google-cloud-key").?].setting().?,
    );
    try std.testing.expect(table[index("deepseek-api-key").?].setting() == null);
    try std.testing.expect(table[index("anthropic-api").?].setting() == null);
}

test "only OpenRouter and DeepSeek replay plain reasoning" {
    for (&table) |*account| {
        const options = switch (account.dialect) {
            .responses => |responses| responses,
            .messages, .gemini => continue,
        };
        const plain = switch (account.vendor) {
            .openrouter, .deepseek => true,
            .anthropic, .openai, .xai, .google => false,
        };
        const switches = options.switches;
        try std.testing.expectEqual(plain, switches.plain_reasoning);
        try std.testing.expectEqual(account.vendor == .openrouter, switches.require_parameters);
        try std.testing.expectEqual(std.mem.eql(u8, account.id, "openai-plan"), options.codex);
    }
}

test "a usage source belongs to the plan and the pool accounts alone" {
    for (&table) |*account| {
        const expected: std.meta.Tag(Usage) = if (std.mem.eql(u8, account.id, "xai-plan"))
            .xai_billing
        else if (account.vendor == .openrouter)
            .openrouter_credits
        else if (account.vendor == .deepseek)
            .deepseek_balance
        else if (!account.hasLogin())
            .none
        else if (account.credential.login == .console)
            .none
        else
            .head;
        try std.testing.expectEqual(expected, std.meta.activeTag(account.usage));
    }
}
