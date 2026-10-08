const std = @import("std");

const core = @import("core");

const Account = @import("Account.zig");
const testing = @import("testing.zig");

const Model = @This();

pub const tokens_per_million = 1_000_000.0;

pub const name_bytes_max = 64;

name_buffer: [name_bytes_max]u8,
name_length: u8,
served_buffer: [name_bytes_max]u8,
served_length: u8,
efforts: std.EnumSet(core.Provider.Effort),
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
    if (!validName(id)) return error.BadModelName;
    var model: Model = .{
        .name_buffer = undefined,
        .name_length = @intCast(id.len),
        .served_buffer = undefined,
        .served_length = 0,
        .efforts = .empty,
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

fn validName(id: []const u8) bool {
    if (id.len == 0 or id.len > name_bytes_max) return false;
    for (id) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or
            std.mem.findScalar(u8, "-._~:/", byte) != null;
        if (!safe) return false;
    }
    return true;
}

pub fn name(self: *const Model) []const u8 {
    return self.name_buffer[0..self.name_length];
}

pub fn serveAs(self: *Model, id: []const u8) error{BadModelName}!void {
    if (!validName(id)) return error.BadModelName;
    @memcpy(self.served_buffer[0..id.len], id);
    self.served_length = @intCast(id.len);
}

pub fn servedName(self: *const Model) []const u8 {
    return self.served_buffer[0..self.served_length];
}

pub fn serves(self: *const Model, served: []const u8) bool {
    return self.sameName(served) or std.mem.eql(u8, self.servedName(), served);
}

pub fn addEffort(self: *Model, level: core.Provider.Effort) void {
    self.efforts.insert(level);
}

pub fn sameName(self: *const Model, other: []const u8) bool {
    return std.mem.eql(u8, self.name(), other);
}

pub fn eql(self: *const Model, other: *const Model) bool {
    return self.sameName(other.name()) and
        std.mem.eql(u8, self.servedName(), other.servedName()) and
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

pub fn fold(self: *const Model, level: core.Provider.Effort) ?core.Provider.Effort {
    if (!self.takesEffort()) return null;
    return self.nearest(level);
}

fn nearest(self: *const Model, level: core.Provider.Effort) ?core.Provider.Effort {
    const ladder = comptime std.enums.values(core.Provider.Effort);
    const start: usize = @backingInt(level);
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

pub fn outputLimitUnknown(self: *const Model, account: *const Account) bool {
    return self.tokens_max == null and account.requiresOutputLimit();
}

pub fn cost(self: *const Model, usage: *const core.Provider.Usage) ?f64 {
    const price = self.price orelse return null;
    if (price.long_context) |tier| {
        if (usage.prompt() >= tier.prompt_tokens_min) return charge(&.{
            .input = tier.input,
            .output = tier.output,
            .cache_read = tier.cache_read,
            .cache_write = tier.cache_write,
        }, usage);
    }
    return charge(&price, usage);
}

fn charge(rates: *const Price, usage: *const core.Provider.Usage) f64 {
    return (rates.input * asFloat(usage.input) +
        rates.output * asFloat(usage.output) +
        rates.cache_read * asFloat(usage.cache_read) +
        rates.cache_write * asFloat(usage.cache_write)) / tokens_per_million;
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
    try std.testing.expectEqual(Thinking.unknown, model.thinking);
    try std.testing.expectEqual(Tools.unknown, model.tools);
    try std.testing.expect(!model.efforts_denied);
    try std.testing.expect(model.price == null);

    try std.testing.expectError(error.BadModelName, init(""));
    const over = core.text.repeat("x", name_bytes_max + 1);
    try std.testing.expectError(error.BadModelName, init(over));
    const at_max = core.text.repeat("x", name_bytes_max);
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
    const copy = original;
    original = try init("gpt-5.6-luna");
    try std.testing.expectEqualStrings("gpt-5.6-sol", copy.name());
    try std.testing.expectEqualStrings("gpt-5.6-luna", original.name());
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
    try std.testing.expectError(
        error.BadModelName,
        alias.serveAs(core.text.repeat("x", name_bytes_max + 1)),
    );
}

test "a fold takes the nearest level and prefers the lower one on a tie" {
    var model = try init("folds");
    model.addEffort(.low);
    model.addEffort(.medium);
    model.addEffort(.high);

    try std.testing.expectEqual(core.Provider.Effort.high, model.fold(.high).?);
    try std.testing.expectEqual(core.Provider.Effort.high, model.fold(.max).?);
    try std.testing.expectEqual(core.Provider.Effort.high, model.fold(.xhigh).?);

    var raised = try init("raised");
    raised.addEffort(.medium);
    raised.addEffort(.high);
    try std.testing.expectEqual(core.Provider.Effort.medium, raised.fold(.low).?);

    var gapped = try init("gapped");
    gapped.addEffort(.low);
    gapped.addEffort(.max);
    try std.testing.expectEqual(core.Provider.Effort.max, gapped.fold(.xhigh).?);
    try std.testing.expectEqual(core.Provider.Effort.low, gapped.fold(.medium).?);

    var tied = try init("tied");
    tied.addEffort(.low);
    tied.addEffort(.high);
    try std.testing.expectEqual(core.Provider.Effort.low, tied.fold(.medium).?);

    for ([_]core.Provider.Effort{ .low, .high }) |named| {
        var single = try init("single");
        single.addEffort(named);
        for (comptime std.enums.values(core.Provider.Effort)) |level|
            try std.testing.expectEqual(named, single.fold(level).?);
    }

    const bare = try init("bare");
    try std.testing.expect(bare.fold(.high) == null);
    try std.testing.expect(bare.fold(.low) == null);
}

test "an unknown thinking state folds every level like a supported one" {
    var model = try init("thinks");
    model.addEffort(.low);
    model.addEffort(.max);

    for ([_]Thinking{ .supported, .unknown }) |state| {
        model.thinking = state;
        try std.testing.expectEqual(core.Provider.Effort.low, model.fold(.low).?);
        try std.testing.expectEqual(core.Provider.Effort.max, model.fold(.xhigh).?);
    }
}

test takesEffort {
    var model = try init("denies");
    model.addEffort(.high);
    try std.testing.expect(model.takesEffort());
    try std.testing.expectEqual(core.Provider.Effort.high, model.fold(.high).?);

    model.thinking = .unsupported;
    try std.testing.expect(!model.takesEffort());
    try std.testing.expect(model.fold(.high) == null);

    model.thinking = .supported;
    model.efforts_denied = true;
    try std.testing.expect(!model.takesEffort());
    try std.testing.expect(model.fold(.high) == null);
}

test outputLimitUnknown {
    var model = try init("claude-opus-5");
    try std.testing.expect(model.outputLimitUnknown(&Account.table[testing.anthropic_plan]));
    try std.testing.expect(!model.outputLimitUnknown(&Account.table[testing.openai_plan]));
    try std.testing.expect(!model.outputLimitUnknown(&Account.table[testing.google_cloud_key]));

    model.tokens_max = 64_000;
    for (&Account.table) |*account| try std.testing.expect(!model.outputLimitUnknown(account));
}

test cost {
    var model = try init("priced");
    const usage: core.Provider.Usage = .{
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

    const under: core.Provider.Usage = .{
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

    const at: core.Provider.Usage = .{
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
