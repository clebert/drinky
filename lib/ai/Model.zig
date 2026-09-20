const std = @import("std");

const llm = @import("llm.zig");

const Model = @This();

const million = 1_000_000.0;

pub const name_bytes_max = 64;

pub const engine_bytes_max = 128;

pub const tokens_max_fallback = 4096;

name_buffer: [name_bytes_max]u8,
name_length: u8,
served_buffer: [name_bytes_max]u8,
served_length: u8,
engine_buffer: [engine_bytes_max]u8,
engine_length: u8,
efforts: std.EnumSet(llm.Effort),
efforts_denied: bool,
thinking: Thinking,
tools: Tools,
context_window: ?u64,
tokens_max: ?u32,
price: ?Price,

pub const Thinking = enum {
    unknown,
    supported,
    unsupported,
};

pub const Tools = enum {
    unknown,
    supported,
    unsupported,
};

pub const Price = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    long_context: ?LongContext = null,

    pub const LongContext = struct {
        prompt_tokens_min: u64,
        input: f64,
        output: f64,
        cache_read: f64,
        cache_write: f64,
    };
};

pub fn init(id: []const u8) error{BadModelName}!Model {
    if (id.len == 0 or id.len > name_bytes_max) return error.BadModelName;
    if (!requestSafe(id)) return error.BadModelName;
    var model: Model = .{
        .name_buffer = undefined,
        .name_length = @intCast(id.len),
        .served_buffer = undefined,
        .served_length = 0,
        .engine_buffer = undefined,
        .engine_length = 0,
        .efforts = .initEmpty(),
        .efforts_denied = false,
        .thinking = .unknown,
        .tools = .unknown,
        .context_window = null,
        .tokens_max = null,
        .price = null,
    };
    @memcpy(model.name_buffer[0..id.len], id);
    return model;
}

fn requestSafe(id: []const u8) bool {
    for (id) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "-._~:/", byte) != null;
        if (!safe) return false;
    }
    return true;
}

pub fn name(self: *const Model) []const u8 {
    return self.name_buffer[0..self.name_length];
}

pub fn serveAs(self: *Model, id: []const u8) error{BadModelName}!void {
    if (id.len == 0 or id.len > name_bytes_max) return error.BadModelName;
    if (!requestSafe(id)) return error.BadModelName;
    @memcpy(self.served_buffer[0..id.len], id);
    self.served_length = @intCast(id.len);
}

pub fn servedName(self: *const Model) []const u8 {
    return self.served_buffer[0..self.served_length];
}

pub fn setEngine(self: *Model, engine_name: []const u8) error{BadEngineName}!void {
    if (engine_name.len == 0 or engine_name.len > engine_bytes_max) return error.BadEngineName;
    if (!std.unicode.utf8ValidateSlice(engine_name)) return error.BadEngineName;
    for (engine_name) |byte| {
        if (byte < ' ' or byte == 0x7f) return error.BadEngineName;
    }
    @memcpy(self.engine_buffer[0..engine_name.len], engine_name);
    self.engine_length = @intCast(engine_name.len);
}

pub fn engineName(self: *const Model) []const u8 {
    return self.engine_buffer[0..self.engine_length];
}

pub fn serves(self: *const Model, served: []const u8) bool {
    return self.sameName(served) or std.mem.eql(u8, self.servedName(), served);
}

pub fn addEffort(self: *Model, level: llm.Effort) void {
    self.efforts.insert(level);
}

pub fn sameName(self: *const Model, other: []const u8) bool {
    return std.mem.eql(u8, self.name(), other);
}

pub fn eql(self: *const Model, other: *const Model) bool {
    return self.sameName(other.name()) and
        std.mem.eql(u8, self.servedName(), other.servedName()) and
        std.mem.eql(u8, self.engineName(), other.engineName()) and
        self.efforts.eql(other.efforts) and
        self.efforts_denied == other.efforts_denied and
        self.thinking == other.thinking and
        self.tools == other.tools and
        std.meta.eql(self.context_window, other.context_window) and
        std.meta.eql(self.tokens_max, other.tokens_max) and
        std.meta.eql(self.price, other.price);
}

pub fn takesEffort(self: *const Model) bool {
    return !self.efforts_denied and self.thinking != .unsupported;
}

pub fn offers(self: *const Model, level: llm.Effort) bool {
    return self.takesEffort() and self.efforts.contains(level);
}

pub fn reasoning(self: *const Model, level: llm.Effort) llm.Request.Reasoning {
    if (!self.takesEffort()) return .omitted;
    const found = self.nearest(level) orelse return .omitted;
    return .{ .named = found };
}

fn nearest(self: *const Model, level: llm.Effort) ?llm.Effort {
    const ladder = comptime std.enums.values(llm.Effort);
    const start: usize = @intFromEnum(level);
    for (0..ladder.len) |distance| {
        if (start >= distance) {
            const lower = ladder[start - distance];
            if (self.efforts.contains(lower)) return lower;
        }
        const higher_index = start + distance;
        if (higher_index < ladder.len and self.efforts.contains(ladder[higher_index]))
            return ladder[higher_index];
    }
    return null;
}

pub fn outputLimitUnknown(self: *const Model, account: llm.Account) bool {
    if (self.tokens_max != null) return false;
    return switch (account.provider()) {
        .anthropic => true,
        .openai, .xai, .openrouter, .deepseek, .google, .ds4 => false,
    };
}

pub fn cost(self: *const Model, usage: *const llm.Usage) ?f64 {
    const price = self.price orelse return null;
    if (price.long_context) |tier| {
        if (usage.prompt() >= tier.prompt_tokens_min) return charge(&tier, usage);
    }
    return charge(&price, usage);
}

fn charge(rates: anytype, usage: *const llm.Usage) f64 {
    return (rates.input * asFloat(usage.input) +
        rates.output * asFloat(usage.output) +
        rates.cache_read * asFloat(usage.cache_read) +
        rates.cache_write * asFloat(usage.cache_write)) / million;
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test init {
    var model = try init("claude-opus-4-8");
    try std.testing.expectEqualStrings("claude-opus-4-8", model.name());
    try std.testing.expect(model.sameName("claude-opus-4-8"));
    try std.testing.expect(!model.sameName("claude-opus-5"));
    try std.testing.expectEqual(@as(?u64, null), model.context_window);
    try std.testing.expectEqual(@as(?u32, null), model.tokens_max);
    try std.testing.expectEqualStrings("", model.engineName());
    try std.testing.expectEqual(Thinking.unknown, model.thinking);
    try std.testing.expectEqual(Tools.unknown, model.tools);
    try std.testing.expect(!model.efforts_denied);
    try std.testing.expect(model.price == null);

    try std.testing.expectError(error.BadModelName, init(""));
    const over = "x" ** (name_bytes_max + 1);
    try std.testing.expectError(error.BadModelName, init(over));
    const at_max = "x" ** name_bytes_max;
    try std.testing.expectEqualStrings(at_max, (try init(at_max)).name());
}

test "a name that a request line cannot carry names no model" {
    for ([_][]const u8{
        "claude opus",
        "claude&limit=1",
        "claude?limit=1",
        "claude#fragment",
        "claude=1",
        "claude\rx-injected: 1",
        "claude\nx-injected: 1",
        "claude\r\nx-injected: 1",
        "claude\x00opus",
        "claude%2f",
    }) |hostile| try std.testing.expectError(error.BadModelName, init(hostile));

    for ([_][]const u8{
        "claude-opus-4-8",
        "claude-haiku-4-5-20251001",
        "gpt-5.6-sol",
        "text-embedding-3-large",
        "ft:gpt-5.6-sol:org:suffix",
    }) |accepted| try std.testing.expectEqualStrings(accepted, (try init(accepted)).name());
}

test "a copy owns its name" {
    var original = try init("gpt-5.6-sol");
    try original.setEngine("Engine one");
    const copy = original;
    original = try init("gpt-5.6-luna");
    try std.testing.expectEqualStrings("gpt-5.6-sol", copy.name());
    try std.testing.expectEqualStrings("Engine one", copy.engineName());
    try std.testing.expectEqualStrings("gpt-5.6-luna", original.name());
}

test "an engine label is bounded and safe for one picker row" {
    var model = try init("model");
    try model.setEngine("DeepSeek V4 Flash");
    try std.testing.expectEqualStrings("DeepSeek V4 Flash", model.engineName());
    try std.testing.expectError(error.BadEngineName, model.setEngine(""));
    try std.testing.expectError(error.BadEngineName, model.setEngine("bad\nlabel"));
    try std.testing.expectError(
        error.BadEngineName,
        model.setEngine("x" ** (engine_bytes_max + 1)),
    );
}

test eql {
    const fetched = init("claude-opus-5") catch unreachable;
    var described = fetched;
    described.context_window = 1_000_000;

    var twin = init("claude-opus-5") catch unreachable;
    try std.testing.expect(fetched.eql(&twin));
    try std.testing.expect(!fetched.eql(&described));

    twin.tokens_max = 128_000;
    try std.testing.expect(!fetched.eql(&twin));
    twin.tokens_max = null;
    twin.addEffort(.high);
    try std.testing.expect(!fetched.eql(&twin));

    var other = init("claude-sonnet-4-6") catch unreachable;
    other.addEffort(.high);
    try std.testing.expect(!twin.eql(&other));

    var priced = init("claude-opus-5") catch unreachable;
    priced.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    try std.testing.expect(!fetched.eql(&priced));
    var tiered = priced;
    tiered.price.?.long_context = .{
        .prompt_tokens_min = 200_000,
        .input = 6,
        .output = 30,
        .cache_read = 0.6,
        .cache_write = 7.5,
    };
    try std.testing.expect(!priced.eql(&tiered));

    var denied = init("claude-opus-5") catch unreachable;
    denied.efforts_denied = true;
    try std.testing.expect(!fetched.eql(&denied));

    var thinks = init("claude-opus-5") catch unreachable;
    thinks.thinking = .supported;
    try std.testing.expect(!fetched.eql(&thinks));

    var tool_state = init("claude-opus-5") catch unreachable;
    tool_state.tools = .unsupported;
    try std.testing.expect(!fetched.eql(&tool_state));

    var aliased = init("claude-opus-5") catch unreachable;
    aliased.serveAs("claude-opus-5-20260101") catch unreachable;
    try std.testing.expect(!fetched.eql(&aliased));

    var labeled = init("claude-opus-5") catch unreachable;
    labeled.setEngine("Other weights") catch unreachable;
    try std.testing.expect(!fetched.eql(&labeled));
}

test serves {
    var alias = try init("grok-4.20");
    try std.testing.expect(alias.serves("grok-4.20"));
    try std.testing.expect(!alias.serves("grok-4.20-0309-reasoning"));
    try std.testing.expectEqualStrings("", alias.servedName());

    try alias.serveAs("grok-4.20-0309-reasoning");
    try std.testing.expectEqualStrings("grok-4.20-0309-reasoning", alias.servedName());
    try std.testing.expect(alias.serves("grok-4.20"));
    try std.testing.expect(alias.serves("grok-4.20-0309-reasoning"));
    try std.testing.expect(!alias.serves("grok-4.20-0309"));
    try std.testing.expect(!alias.serves(""));

    try std.testing.expectError(error.BadModelName, alias.serveAs(""));
    try std.testing.expectError(error.BadModelName, alias.serveAs("grok 4"));
    try std.testing.expectError(error.BadModelName, alias.serveAs("x" ** (name_bytes_max + 1)));
}

test "a fold takes the nearest level and prefers the lower one on a tie" {
    var model = try init("folds");
    model.addEffort(.low);
    model.addEffort(.medium);
    model.addEffort(.high);

    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.high).named);
    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.max).named);
    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.xhigh).named);

    var raised = try init("raised");
    raised.addEffort(.medium);
    raised.addEffort(.high);
    try std.testing.expectEqual(llm.Effort.medium, raised.reasoning(.low).named);

    var gapped = try init("gapped");
    gapped.addEffort(.low);
    gapped.addEffort(.max);
    try std.testing.expectEqual(llm.Effort.max, gapped.reasoning(.xhigh).named);
    try std.testing.expectEqual(llm.Effort.low, gapped.reasoning(.medium).named);

    var tied = try init("tied");
    tied.addEffort(.low);
    tied.addEffort(.high);
    try std.testing.expectEqual(llm.Effort.low, tied.reasoning(.medium).named);

    for ([_]llm.Effort{ .low, .high }) |named| {
        var single = try init("single");
        single.addEffort(named);
        for (comptime std.enums.values(llm.Effort)) |level|
            try std.testing.expectEqual(named, single.reasoning(level).named);
    }

    const bare = try init("bare");
    try std.testing.expect(bare.reasoning(.high) == .omitted);
    try std.testing.expect(bare.reasoning(.low) == .omitted);
}

test "a thinking state that reasons renders every level alike" {
    var model = try init("thinks");
    model.addEffort(.low);
    model.addEffort(.max);

    for ([_]Thinking{ .supported, .unknown }) |state| {
        model.thinking = state;
        try std.testing.expectEqual(llm.Effort.low, model.reasoning(.low).named);
        try std.testing.expectEqual(llm.Effort.max, model.reasoning(.xhigh).named);
    }
}

test takesEffort {
    var model = try init("denies");
    model.addEffort(.high);
    try std.testing.expect(model.takesEffort());
    try std.testing.expect(model.offers(.high));

    model.thinking = .unsupported;
    try std.testing.expect(!model.takesEffort());
    try std.testing.expect(!model.offers(.high));
    try std.testing.expect(model.reasoning(.high) == .omitted);

    model.thinking = .supported;
    model.efforts_denied = true;
    try std.testing.expect(!model.takesEffort());
    try std.testing.expect(!model.offers(.high));
    try std.testing.expect(model.reasoning(.high) == .omitted);
}

test "a model names the levels its provider stated alone" {
    var model = try init("offers");
    model.addEffort(.medium);
    model.addEffort(.xhigh);

    try std.testing.expect(model.offers(.medium));
    try std.testing.expect(model.offers(.xhigh));
    for ([_]llm.Effort{ .low, .high, .max }) |level|
        try std.testing.expect(!model.offers(level));
}

test outputLimitUnknown {
    var model = try init("claude-opus-5");
    try std.testing.expect(model.outputLimitUnknown(.anthropic_plan));
    try std.testing.expect(model.outputLimitUnknown(.anthropic_api));
    try std.testing.expect(model.outputLimitUnknown(.anthropic_api_key));
    try std.testing.expect(!model.outputLimitUnknown(.openai_plan));
    try std.testing.expect(!model.outputLimitUnknown(.openai_api_key));
    try std.testing.expect(!model.outputLimitUnknown(.xai_plan));
    try std.testing.expect(!model.outputLimitUnknown(.xai_api_key));
    try std.testing.expect(!model.outputLimitUnknown(.openrouter_api));
    try std.testing.expect(!model.outputLimitUnknown(.openrouter_api_key));
    try std.testing.expect(!model.outputLimitUnknown(.deepseek_api_key));
    try std.testing.expect(!model.outputLimitUnknown(.google_cloud_key));

    model.tokens_max = 64_000;
    for (comptime std.enums.values(llm.Account)) |account|
        try std.testing.expect(!model.outputLimitUnknown(account));
}

test cost {
    var model = try init("priced");
    const usage: llm.Usage = .{
        .input = 1_000_000,
        .output = 1_000_000,
        .cache_read = 1_000_000,
        .cache_write = 1_000_000,
    };
    try std.testing.expectEqual(@as(?f64, null), model.cost(&usage));

    model.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), model.cost(&usage).?, 1e-9);
}

test "a prompt at the threshold bills every token at the long-context rates" {
    var model = try init("tiered");
    model.price = .{
        .input = 2,
        .output = 10,
        .cache_read = 0.2,
        .cache_write = 2.5,
        .long_context = .{
            .prompt_tokens_min = 200_000,
            .input = 4,
            .output = 20,
            .cache_read = 0.4,
            .cache_write = 5,
        },
    };

    const under: llm.Usage = .{
        .input = 100_000,
        .cache_read = 50_000,
        .cache_write = 49_999,
        .output = 1_000_000,
    };
    try std.testing.expectApproxEqAbs(
        (2 * 0.1 + 0.2 * 0.05 + 2.5 * 0.049999 + 10),
        model.cost(&under).?,
        1e-9,
    );

    const at: llm.Usage = .{
        .input = 100_000,
        .cache_read = 50_000,
        .cache_write = 50_000,
        .output = 1_000_000,
    };
    try std.testing.expectApproxEqAbs(
        (4 * 0.1 + 0.4 * 0.05 + 5 * 0.05 + 20),
        model.cost(&at).?,
        1e-9,
    );

    model.price.?.long_context = null;
    try std.testing.expectApproxEqAbs(
        (2 * 0.1 + 0.2 * 0.05 + 2.5 * 0.05 + 10),
        model.cost(&at).?,
        1e-9,
    );
}

test "a reasoning control compares by the request bytes it produces" {
    const Reasoning = llm.Request.Reasoning;
    try std.testing.expect(Reasoning.eql(.omitted, .omitted));
    try std.testing.expect(Reasoning.eql(.{ .named = .high }, .{ .named = .high }));
    try std.testing.expect(!Reasoning.eql(.{ .named = .high }, .{ .named = .xhigh }));
    try std.testing.expect(!Reasoning.eql(.{ .named = .high }, .omitted));

    var model = try init("folds");
    model.addEffort(.high);
    try std.testing.expect(model.reasoning(.xhigh).eql(model.reasoning(.max)));
}

test "reasoning replay follows the rendered control of the vendor" {
    var model = try init("replays");
    model.addEffort(.high);
    try std.testing.expect(model.reasoning(.high).replaysReasoning(.anthropic));
    try std.testing.expect(model.reasoning(.high).replaysReasoning(.openai));

    const bare = try init("bare");
    try std.testing.expect(!bare.reasoning(.high).replaysReasoning(.anthropic));
    try std.testing.expect(bare.reasoning(.high).replaysReasoning(.openai));
}
