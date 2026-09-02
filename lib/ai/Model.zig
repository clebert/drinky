//! One model as Drinky discovered it: the identity, the limits, the effort
//! levels, and the price. Every field but the name is optional, because each
//! source states what it knows and no more, and Drinky shows only what a source
//! filled. The name lives in an inline buffer, so a model is a plain value and
//! no copy of it outlives the cache it came from.

const std = @import("std");

const llm = @import("llm.zig");

const Model = @This();

const million = 1_000_000.0;

/// The longest model id Drinky keeps. A picker row must name a model, and no
/// provider Drinky reaches names one this long, so a decoder drops a longer id
/// instead of truncating it into a name that no request can use.
pub const name_bytes_max = 64;

/// The output limit a request carries for a model whose sources state none.
/// Anthropic requires the field, so a request must carry a number. A model that
/// states its own limit stands far above this floor, and a reply that reaches
/// the floor stops there.
pub const tokens_max_fallback = 4096;

name_buffer: [name_bytes_max]u8,
name_length: u8,
/// The levels the provider named for this model.
efforts: std.EnumSet(llm.Effort),
/// Whether the vendor stated that this model takes no effort level at all. An
/// empty list alone cannot state that, because a source that names no level
/// states nothing rather than a denial.
efforts_denied: bool,
thinking: Thinking,
context_window: ?u64,
tokens_max: ?u32,
price: ?Price,

/// Whether the model reasons, as far as a source stated it. Only `unsupported`
/// closes the ladder.
pub const Thinking = enum {
    unknown,
    /// The model reasons.
    supported,
    /// The model never reasons.
    unsupported,
};

/// The rates of one model in USD per million tokens. A cache rate is absolute
/// rather than a factor of the input rate, so a provider with its own cache
/// economics needs no special case.
pub const Price = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

/// A model that states its name alone. A decoder fills whatever its source
/// states. An empty id, an over-long id, and an id that a request line cannot
/// carry name no model Drinky can request.
pub fn init(id: []const u8) error{BadModelName}!Model {
    if (id.len == 0 or id.len > name_bytes_max) return error.BadModelName;
    if (!requestSafe(id)) return error.BadModelName;
    var model: Model = .{
        .name_buffer = undefined,
        .name_length = @intCast(id.len),
        .efforts = .initEmpty(),
        .efforts_denied = false,
        .thinking = .unknown,
        .context_window = null,
        .tokens_max = null,
        .price = null,
    };
    @memcpy(model.name_buffer[0..id.len], id);
    return model;
}

/// Whether every byte of `id` can travel in a request line. A model name
/// reaches the query of a list request as the page cursor, so a byte that
/// delimits a URL, a control byte, or a space corrupts or splits that line.
/// Every decoder builds its model through `init`, so this one guard keeps such
/// a name out of every request Drinky sends.
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

/// Record that the provider named `level` for this model.
pub fn addEffort(self: *Model, level: llm.Effort) void {
    self.efforts.insert(level);
}

/// Whether the two models name the same model of the same provider.
pub fn sameName(self: *const Model, other: []const u8) bool {
    return std.mem.eql(u8, self.name(), other);
}

/// Whether `other` describes this model in every part: the name, the levels,
/// the limits, and the price. A fetch replaces the description of a model and
/// keeps its name, so a caller that compares names alone cannot see that
/// replacement. The name buffer holds bytes past the name, so no comparison of
/// the whole value can stand in for this one.
pub fn eql(self: *const Model, other: *const Model) bool {
    return self.sameName(other.name()) and
        self.efforts.eql(other.efforts) and
        self.efforts_denied == other.efforts_denied and
        self.thinking == other.thinking and
        std.meta.eql(self.context_window, other.context_window) and
        std.meta.eql(self.tokens_max, other.tokens_max) and
        std.meta.eql(self.price, other.price);
}

/// Whether this model takes a named effort level at all. A model that never
/// reasons, and one whose vendor denied the effort control, take none, so no
/// list of another source can name one for it.
pub fn takesEffort(self: *const Model) bool {
    return !self.efforts_denied and self.thinking != .unsupported;
}

/// Whether this model names `level`. The answer describes the model alone.
/// `reasoning` resolves the level of a request, and it reads the ladder of the
/// model directly.
pub fn offers(self: *const Model, level: llm.Effort) bool {
    return self.takesEffort() and self.efforts.contains(level);
}

/// The reasoning control that `level` renders for this model. The level states
/// the intention of the user, and this call resolves it silently: a level the
/// model does not name folds onto the nearest one it does, and a model that
/// takes no level renders no control at all. The fold lands on a level the
/// provider itself named, so the request carries a spelling that provider
/// knows.
pub fn reasoning(self: *const Model, level: llm.Effort) llm.Request.Reasoning {
    if (!self.takesEffort()) return .omitted;
    const found = self.nearest(level) orelse return .omitted;
    return .{ .named = found };
}

/// The level closest to `level` that this model names, or null when it names
/// none at all. The search steps outward one rung at a time and reads the lower
/// rung of each step first, so a tie takes the lower level and no fold spends
/// more effort than the user asked for.
fn nearest(self: *const Model, level: llm.Effort) ?llm.Effort {
    const ladder = comptime std.enums.values(llm.Effort);
    // The tag type of the ladder is too narrow to hold every index of the walk,
    // so the index widens before it.
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

/// Whether Drinky caps a reply of this model at `tokens_max_fallback`. It holds
/// where the vendor of `account` takes the limit from the request and no source
/// states one for this model. Such a reply stops short of its end, so the
/// request path sends the floor and a picker marks the model. This is the one
/// place that states the rule.
pub fn outputLimitUnknown(self: *const Model, account: llm.Account) bool {
    if (self.tokens_max != null) return false;
    return switch (account.provider()) {
        // The Anthropic wire requires `max_tokens` in every request.
        .anthropic => true,
        // The OpenAI wire sends no cap, so the budget of the model governs.
        .openai => false,
    };
}

/// The dollar cost of `usage`, or null when no source priced this model.
pub fn cost(self: *const Model, usage: *const llm.Usage) ?f64 {
    const price = self.price orelse return null;
    return (price.input * asFloat(usage.input) +
        price.output * asFloat(usage.output) +
        price.cache_read * asFloat(usage.cache_read) +
        price.cache_write * asFloat(usage.cache_write)) / million;
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test init {
    var model = try init("claude-opus-4-8");
    try std.testing.expectEqualStrings("claude-opus-4-8", model.name());
    try std.testing.expect(model.sameName("claude-opus-4-8"));
    try std.testing.expect(!model.sameName("claude-opus-5"));
    // A fresh model states nothing beyond its name.
    try std.testing.expectEqual(@as(?u64, null), model.context_window);
    try std.testing.expectEqual(@as(?u32, null), model.tokens_max);
    try std.testing.expectEqual(Thinking.unknown, model.thinking);
    try std.testing.expect(!model.efforts_denied);
    try std.testing.expect(model.price == null);

    try std.testing.expectError(error.BadModelName, init(""));
    const over = "x" ** (name_bytes_max + 1);
    try std.testing.expectError(error.BadModelName, init(over));
    const at_max = "x" ** name_bytes_max;
    try std.testing.expectEqualStrings(at_max, (try init(at_max)).name());
}

// A model name travels in a request line, because the list request carries the
// name of the last model as the cursor of the next page. A name that holds a
// query-reserved byte corrupts that line, and one that holds CR or LF splits the
// head that carries the credential.
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

    // Every spelling a provider Drinky reaches uses stays valid.
    for ([_][]const u8{
        "claude-opus-4-8",
        "claude-haiku-4-5-20251001",
        "gpt-5.6-sol",
        "text-embedding-3-large",
        "ft:gpt-5.6-sol:org:suffix",
    }) |accepted| try std.testing.expectEqualStrings(accepted, (try init(accepted)).name());
}

// A model is a plain value, so a copy keeps its own name and nothing points
// back into the store the model came from.
test "a copy owns its name" {
    var original = try init("gpt-5.6-sol");
    const copy = original;
    original = try init("gpt-5.6-luna");
    try std.testing.expectEqualStrings("gpt-5.6-sol", copy.name());
    try std.testing.expectEqualStrings("gpt-5.6-luna", original.name());
}

// A fetch replaces the description of a model and keeps its name, so the
// comparison that decides a switch must read every described part.
test eql {
    const fetched = init("claude-opus-5") catch unreachable;
    var described = fetched;
    described.context_window = 1_000_000;

    // The name buffer holds bytes past the name, so two models built apart from
    // the same name still compare equal.
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

    var denied = init("claude-opus-5") catch unreachable;
    denied.efforts_denied = true;
    try std.testing.expect(!fetched.eql(&denied));

    var thinks = init("claude-opus-5") catch unreachable;
    thinks.thinking = .supported;
    try std.testing.expect(!fetched.eql(&thinks));
}

test "a fold takes the nearest level and prefers the lower one on a tie" {
    var model = try init("folds");
    model.addEffort(.low);
    model.addEffort(.medium);
    model.addEffort(.high);

    // A named level renders itself.
    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.high).named);
    // A level above the highest named one folds down to it.
    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.max).named);
    try std.testing.expectEqual(llm.Effort.high, model.reasoning(.xhigh).named);

    // A level below the lowest named one turns upward, because no lower level
    // exists to fold onto.
    var raised = try init("raised");
    raised.addEffort(.medium);
    raised.addEffort(.high);
    try std.testing.expectEqual(llm.Effort.medium, raised.reasoning(.low).named);

    // A near level above beats a far level below, so the fold reads the whole
    // ladder rather than the part under the level.
    var gapped = try init("gapped");
    gapped.addEffort(.low);
    gapped.addEffort(.max);
    try std.testing.expectEqual(llm.Effort.max, gapped.reasoning(.xhigh).named);
    try std.testing.expectEqual(llm.Effort.low, gapped.reasoning(.medium).named);

    // Two named levels at one distance tie, and the tie takes the lower one, so
    // no fold spends more effort than the user asked for.
    var tied = try init("tied");
    tied.addEffort(.low);
    tied.addEffort(.high);
    try std.testing.expectEqual(llm.Effort.low, tied.reasoning(.medium).named);

    // One named level answers every request. The lowest rung sits at index 0,
    // so the downward walk must reach it from every rung above.
    for ([_]llm.Effort{ .low, .high }) |named| {
        var single = try init("single");
        single.addEffort(named);
        for (comptime std.enums.values(llm.Effort)) |level|
            try std.testing.expectEqual(named, single.reasoning(level).named);
    }

    // A model that names no level carries no control at all.
    const bare = try init("bare");
    try std.testing.expect(bare.reasoning(.high) == .omitted);
    try std.testing.expect(bare.reasoning(.low) == .omitted);
}

// A model that reasons, and one whose state no source stated, render a level
// alike. Only a model that never reasons closes the ladder.
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

    // A model that never reasons takes no level, whatever a source lists.
    model.thinking = .unsupported;
    try std.testing.expect(!model.takesEffort());
    try std.testing.expect(!model.offers(.high));
    try std.testing.expect(model.reasoning(.high) == .omitted);

    // A vendor that denies the effort control closes the ladder the same way.
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

// Only a vendor that takes the output limit from the request caps a reply, so
// the answer needs the account beside the model. Every OpenAI model states no
// limit, and no request of that vendor carries one, so no such model is capped.
test outputLimitUnknown {
    var model = try init("claude-opus-5");
    try std.testing.expect(model.outputLimitUnknown(.anthropic_subscription));
    try std.testing.expect(model.outputLimitUnknown(.anthropic_console));
    try std.testing.expect(model.outputLimitUnknown(.anthropic_api));
    try std.testing.expect(!model.outputLimitUnknown(.openai_subscription));
    try std.testing.expect(!model.outputLimitUnknown(.openai_api));

    // A stated limit answers the question for every account.
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
    // An unpriced model reports no cost rather than a zero one.
    try std.testing.expectEqual(@as(?f64, null), model.cost(&usage));

    model.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), model.cost(&usage).?, 1e-9);
}

test "a reasoning control compares by the request bytes it produces" {
    const Reasoning = llm.Request.Reasoning;
    try std.testing.expect(Reasoning.eql(.omitted, .omitted));
    try std.testing.expect(Reasoning.eql(.{ .named = .high }, .{ .named = .high }));
    try std.testing.expect(!Reasoning.eql(.{ .named = .high }, .{ .named = .xhigh }));
    try std.testing.expect(!Reasoning.eql(.{ .named = .high }, .omitted));

    // Two levels that fold onto one level share a prompt cache.
    var model = try init("folds");
    model.addEffort(.high);
    try std.testing.expect(model.reasoning(.xhigh).eql(model.reasoning(.max)));
}

// An Anthropic request that names no level carries no thinking block back, so
// the stored reasoning leaves the prompt. An OpenAI request replays its
// encrypted item whatever the control names.
test "reasoning replay follows the rendered control of the vendor" {
    var model = try init("replays");
    model.addEffort(.high);
    try std.testing.expect(model.reasoning(.high).replaysReasoning(.anthropic));
    try std.testing.expect(model.reasoning(.high).replaysReasoning(.openai));

    // A model that takes no level renders no control.
    const bare = try init("bare");
    try std.testing.expect(!bare.reasoning(.high).replaysReasoning(.anthropic));
    try std.testing.expect(bare.reasoning(.high).replaysReasoning(.openai));
}
