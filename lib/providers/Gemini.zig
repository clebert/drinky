const std = @import("std");

const core = @import("core");

const Dialect = @import("Dialect.zig");
const json = @import("json.zig");
const testing = @import("testing.zig");
const Transport = @import("Transport.zig");

const Gemini = @This();

gpa: std.mem.Allocator,
options: Options,
reply: Dialect.Reply,
signature: std.ArrayList(u8),
text: std.ArrayList(u8),
call_number_max: u64,
reasoning_open: bool,
finish_reason: ?core.Provider.Stop.Reason,
prompt_tokens: u64,
cached_tokens: u64,
candidate_tokens: u64,
thought_tokens: u64,

pub const Options = struct {
    account: []const u8,
    project: []const u8,
    location: Location,
};

pub const Location = enum {
    global,
    us,
    eu,

    pub fn host(self: Location) []const u8 {
        return switch (self) {
            .global => "aiplatform.googleapis.com",
            .us => "aiplatform.us.rep.googleapis.com",
            .eu => "aiplatform.eu.rep.googleapis.com",
        };
    }
};

const Stored = struct {
    signature: []const u8,
};

const TextPart = struct {
    text: []const u8,
    thoughtSignature: ?[]const u8 = null,
};

const FunctionCallPart = struct {
    functionCall: struct { name: []const u8, args: json.Raw },
    thoughtSignature: ?[]const u8 = null,
};

const FunctionResponsePart = struct {
    functionResponse: struct { name: []const u8, response: Response },

    const Response = union(enum) {
        output: []const u8,
        @"error": []const u8,
    };
};

const ThinkingConfig = struct {
    includeThoughts: bool = true,
    thinkingLevel: []const u8,
};

const Entry = enum {
    model,
    user_text,
    user_response,

    fn of(item: *const core.Conversation.Item) Entry {
        return switch (item.*) {
            .message => |message| if (message.role == .user) .user_text else .model,
            .reasoning, .tool_call => .model,
            .tool_result => .user_response,
        };
    }
};

const vtable: Dialect.VTable = .{
    .prepare = prepare,
    .failure = failure,
    .quota = quota,
    .reset = reset,
    .decode = decode,
    .finish = finish,
};

pub fn init(gpa: std.mem.Allocator, options: Options) Gemini {
    return .{
        .gpa = gpa,
        .options = options,
        .reply = .{},
        .signature = .empty,
        .text = .empty,
        .call_number_max = 0,
        .reasoning_open = false,
        .finish_reason = null,
        .prompt_tokens = 0,
        .cached_tokens = 0,
        .candidate_tokens = 0,
        .thought_tokens = 0,
    };
}

pub fn deinit(self: *Gemini) void {
    self.signature.deinit(self.gpa);
    self.text.deinit(self.gpa);
    self.reply.deinit(self.gpa);
}

pub fn dialect(self: *Gemini) Dialect {
    return .{ .ptr = self, .vtable = &vtable };
}

fn url(
    arena: std.mem.Allocator,
    options: *const Options,
    model: []const u8,
) error{OutOfMemory}![]u8 {
    return arena.print(
        "https://{s}/v1/projects/{s}/locations/{s}/publishers/google/models/{s}" ++
            ":streamGenerateContent?alt=sse",
        .{ options.location.host(), options.project, @tagName(options.location), model },
    );
}

fn prepare(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
    token: []const u8,
) Dialect.Error!Transport.Request {
    const self: *Gemini = @ptrCast(@alignCast(ptr));
    self.call_number_max = callNumberMax(request.items);
    return .{
        .url = try url(arena, &self.options, request.model),
        .authorization = try arena.print("Bearer {s}", .{token}),
        .body = try self.body(arena, request),
    };
}

fn body(
    self: *const Gemini,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
) Dialect.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    self.writeBody(arena, &out.writer, request) catch |err| return switch (err) {
        error.OrphanToolResult => error.OrphanToolResult,
        else => error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writeBody(
    self: *const Gemini,
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    request: *const core.Provider.Request,
) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try stringify.beginObject();
    try stringify.objectField("systemInstruction");
    try stringify.write(.{ .parts = [_]TextPart{.{ .text = request.system }} });

    try stringify.objectField("contents");
    try stringify.beginArray();
    try self.writeContents(arena, &stringify, request.items);
    try stringify.endArray();

    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("functionDeclarations");
        try stringify.beginArray();
        for (request.tools) |*tool| try writeTool(&stringify, tool);
        try stringify.endArray();
        try stringify.endObject();
        try stringify.endArray();
    }

    if (request.effort) |effort| {
        try stringify.objectField("generationConfig");
        try stringify.write(.{ .thinkingConfig = ThinkingConfig{
            .thinkingLevel = @tagName(effort),
        } });
    }
    try stringify.endObject();
}

fn writeTool(stringify: *std.json.Stringify, tool: *const core.Tool) !void {
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write(tool.name);
    try stringify.objectField("description");
    try stringify.write(tool.description);
    try stringify.objectField("parametersJsonSchema");
    try json.writeParametersSchema(stringify, tool.parameters);
    try stringify.endObject();
}

fn writeContents(
    self: *const Gemini,
    arena: std.mem.Allocator,
    stringify: *std.json.Stringify,
    items: []const core.Conversation.Item,
) !void {
    var open: ?Entry = null;
    var pending_signature: ?[]const u8 = null;
    for (items, 0..) |*item, index| {
        if (item.* == .reasoning) {
            if (try self.storedSignature(arena, &item.reasoning)) |signature| {
                pending_signature = signature;
            }
            continue;
        }
        const entry = Entry.of(item);
        if (open != entry) {
            if (open != null) try endContent(stringify);
            try stringify.beginObject();
            try stringify.objectField("role");
            try stringify.write(if (entry == .model) "model" else "user");
            try stringify.objectField("parts");
            try stringify.beginArray();
            open = entry;
        }
        switch (item.*) {
            .message => |message| try stringify.write(TextPart{
                .text = message.text,
                .thoughtSignature = if (entry == .model) pending_signature else null,
            }),
            .tool_call => |*call| try stringify.write(FunctionCallPart{
                .functionCall = .{ .name = call.name, .args = .{ .bytes = call.argumentsJson() } },
                .thoughtSignature = pending_signature,
            }),
            .tool_result => |result| try stringify.write(FunctionResponsePart{
                .functionResponse = .{
                    .name = try callName(items[0..index], result.call_id),
                    .response = if (result.output.hasFailure())
                        .{ .@"error" = result.output.content }
                    else
                        .{ .output = result.output.content },
                },
            }),
            .reasoning => unreachable,
        }
        pending_signature = null;
    }
    if (open != null) try endContent(stringify);
}

fn storedSignature(
    self: *const Gemini,
    arena: std.mem.Allocator,
    proof: *const core.Conversation.Proof,
) error{OutOfMemory}!?[]const u8 {
    const account = self.options.account;
    const stored = (try Dialect.decodeProof(Stored, arena, account, proof)) orelse return null;
    return if (stored.signature.len == 0) null else stored.signature;
}

fn endContent(stringify: *std.json.Stringify) !void {
    try stringify.endArray();
    try stringify.endObject();
}

fn callNumberMax(items: []const core.Conversation.Item) u64 {
    var number_max: u64 = 0;
    for (items) |*item| switch (item.*) {
        .tool_call => |*call| {
            const digits = std.mem.cutPrefix(u8, call.id, "call_") orelse continue;
            const number = std.fmt.parseInt(u64, digits, 10) catch continue;
            number_max = @max(number_max, number);
        },
        else => {},
    };
    return number_max;
}

fn callName(prior: []const core.Conversation.Item, call_id: []const u8) ![]const u8 {
    var index = prior.len;
    while (index > 0) {
        index -= 1;
        switch (prior[index]) {
            .tool_call => |call| if (std.mem.eql(u8, call.id, call_id)) return call.name,
            else => {},
        }
    }
    return error.OrphanToolResult;
}

fn failure(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    failed: *const Dialect.Failed,
) error{OutOfMemory}!core.Provider.Failure {
    _ = ptr;
    var parsed: Dialect.Failed.Parsed = .{};
    if (try json.parseObject(arena, failed.body)) |object| {
        if (json.object(object.getPtr("error"))) |error_detail| {
            parsed.detail = json.string(error_detail.getPtr("message"));
        }
    }
    return failed.failure(arena, &parsed);
}

fn quota(
    ptr: *anyopaque,
    headers: []const std.http.Header,
    now_seconds: i64,
) ?core.Provider.Quota {
    _ = ptr;
    _ = headers;
    _ = now_seconds;
    return null;
}

fn reset(ptr: *anyopaque) void {
    const self: *Gemini = @ptrCast(@alignCast(ptr));
    self.reply.reset();
    self.signature.clearRetainingCapacity();
    self.text.clearRetainingCapacity();
    self.reasoning_open = false;
    self.finish_reason = null;
    self.prompt_tokens = 0;
    self.cached_tokens = 0;
    self.candidate_tokens = 0;
    self.thought_tokens = 0;
}

fn finish(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    events: *Dialect.Events,
) error{OutOfMemory}!void {
    const self: *Gemini = @ptrCast(@alignCast(ptr));
    try self.closeText(arena, events);
    if (self.finish_reason == null) self.reply.reject(.invalid);
    try self.reply.end(arena, events, self.finish_reason orelse .complete);
}

fn decode(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    payload: []const u8,
    events: *Dialect.Events,
) error{OutOfMemory}!Dialect.Decoded {
    const self: *Gemini = @ptrCast(@alignCast(ptr));
    const object = (try json.parseObject(arena, payload)) orelse return .ignored;

    if (json.object(object.getPtr("error"))) |detail| {
        try events.append(arena, .{ .failed = .{
            .reason = errorReason(detail),
            .message = json.string(detail.getPtr("message")) orelse "",
        } });
        return .progress;
    }
    if (json.string(object.getPtr("modelVersion"))) |version| {
        try self.reply.serve(self.gpa, version);
    }
    if (json.object(object.getPtr("usageMetadata"))) |usage| {
        self.mergeUsage(usage);
        try events.append(arena, .{ .usage = self.reply.usage });
    }
    if (json.object(object.getPtr("promptFeedback"))) |feedback| {
        if (feedback.get("blockReason") != null) {
            self.finish_reason = .complete;
            self.reply.reject(.unsupported);
        }
    }
    if (json.array(object.getPtr("candidates"))) |candidates| {
        if (candidates.items.len != 0)
            try self.decodeCandidate(arena, &candidates.items[0], events);
    }
    return .progress;
}

fn decodeCandidate(
    self: *Gemini,
    arena: std.mem.Allocator,
    value: *const std.json.Value,
    events: *Dialect.Events,
) !void {
    const candidate = json.object(value) orelse return self.reply.reject(.invalid);
    if (json.object(candidate.getPtr("content"))) |content| {
        if (json.array(content.getPtr("parts"))) |parts| {
            for (parts.items) |*part| try self.decodePart(arena, part, events);
        }
    }
    const reason = json.string(candidate.getPtr("finishReason")) orelse return;
    try self.closeText(arena, events);
    self.finish_reason = .complete;
    if (std.mem.eql(u8, reason, "STOP")) return;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) {
        self.finish_reason = .truncated;
    } else if (std.mem.eql(u8, reason, "MALFORMED_FUNCTION_CALL")) {
        self.reply.reject(.invalid);
    } else {
        self.reply.reject(.unsupported);
    }
}

fn decodePart(
    self: *Gemini,
    arena: std.mem.Allocator,
    value: *const std.json.Value,
    events: *Dialect.Events,
) !void {
    const part = json.object(value) orelse return self.reply.reject(.invalid);
    for (part.keys()) |key| {
        if (!knownPartKey(key)) return self.reply.reject(.unsupported);
    }
    if (json.object(part.getPtr("functionCall"))) |call| {
        try self.closeText(arena, events);
        try self.takeSignature(part);
        const name = json.string(call.getPtr("name")) orelse return self.reply.reject(.invalid);
        const arguments = if (call.get("args")) |args| arguments: {
            if (args != .object) return self.reply.reject(.invalid);
            break :arguments try std.json.Stringify.valueAlloc(arena, args, .{});
        } else "{}";
        try self.emitReasoning(arena, events);
        try events.append(arena, .{ .tool_call_started = name });
        try events.append(arena, .{ .tool_call_arguments = arguments });
        self.call_number_max +|= 1;
        try events.append(arena, .{ .output = .{ .tool_call = .{
            .id = try arena.print("call_{d}", .{self.call_number_max}),
            .name = name,
            .arguments = arguments,
        } } });
        return;
    }
    if (json.string(part.getPtr("text"))) |text| {
        if (json.boolean(part.getPtr("thought")) orelse false) {
            if (text.len != 0) {
                if (!self.reasoning_open) try events.append(arena, .reasoning_started);
                self.reasoning_open = true;
                try events.append(arena, .{ .reasoning = text });
            }
        } else {
            try self.text.appendSlice(self.gpa, text);
            if (text.len != 0) {
                self.reasoning_open = false;
                try events.append(arena, .{ .text = text });
            }
        }
    }
    try self.takeSignature(part);
}

fn takeSignature(self: *Gemini, part: *const std.json.ObjectMap) !void {
    const proof = json.string(part.getPtr("thoughtSignature")) orelse return;
    if (proof.len == 0) return;
    self.signature.clearRetainingCapacity();
    try self.signature.appendSlice(self.gpa, proof);
}

fn closeText(self: *Gemini, arena: std.mem.Allocator, events: *Dialect.Events) !void {
    try self.emitReasoning(arena, events);
    if (self.text.items.len == 0) return;
    try events.append(arena, .{ .output = .{ .message = try arena.dupe(u8, self.text.items) } });
    self.text.clearRetainingCapacity();
}

fn emitReasoning(self: *Gemini, arena: std.mem.Allocator, events: *Dialect.Events) !void {
    self.reasoning_open = false;
    if (self.signature.items.len == 0) return;
    const stored: Stored = .{ .signature = self.signature.items };
    const proof = try Dialect.encodeProof(Stored, arena, self.options.account, &stored);
    try events.append(arena, .{ .output = .{ .reasoning = proof } });
    self.signature.clearRetainingCapacity();
}

fn mergeUsage(self: *Gemini, object: *const std.json.ObjectMap) void {
    if (json.unsigned(object.getPtr("promptTokenCount"))) |count| self.prompt_tokens = count;
    if (json.unsigned(object.getPtr("cachedContentTokenCount"))) |count| self.cached_tokens = count;
    if (json.unsigned(object.getPtr("candidatesTokenCount"))) |count| self.candidate_tokens = count;
    if (json.unsigned(object.getPtr("thoughtsTokenCount"))) |count| self.thought_tokens = count;
    self.reply.usage = .{
        .input = self.prompt_tokens -| self.cached_tokens,
        .cache_read = self.cached_tokens,
        .output = self.candidate_tokens +| self.thought_tokens,
    };
}

fn knownPartKey(key: []const u8) bool {
    for ([_][]const u8{ "text", "thought", "thoughtSignature", "functionCall" }) |known| {
        if (std.mem.eql(u8, key, known)) return true;
    }
    return false;
}

fn errorReason(detail: *const std.json.ObjectMap) core.Provider.Failure.Reason {
    const code = json.integer(detail.getPtr("code")) orelse return .invalid_request;
    if (code < 100 or code > 999) return .invalid_request;
    return Dialect.reason(@fromBackingInt(@intCast(code)));
}

test "the golden bytes place every signature and merge every run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gemini: Gemini = .init(std.testing.allocator, test_options);
    var request = testRequest(&golden_items, .high);
    request.tools = &golden_tools;
    try std.testing.expectEqualStrings(golden_level, try gemini.body(arena.allocator(), &request));
}

const test_options: Options = .{
    .account = "google-cloud-key",
    .project = "my-project",
    .location = .global,
};

const Rig = testing.DialectRig(Gemini);

fn expectTrace(expected: []const u8, payloads: []const []const u8) !void {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(payloads);
    try rig.frames.finish();
    try rig.frames.expect(expected);
}

fn testRequest(
    items: []const core.Conversation.Item,
    effort: ?core.Provider.Effort,
) core.Provider.Request {
    return .{
        .model = "gemini-3-pro-preview",
        .tokens_max = 8192,
        .system = "be terse",
        .items = items,
        .tools = &.{},
        .effort = effort,
        .cache_key = "",
    };
}

const golden_tools = [_]core.Tool{
    .{ .name = "read", .description = "Read a file.", .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "The path." },
    } },
};

const golden_items = [_]core.Conversation.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .message = .{ .role = .user, .text = "second" } },
    .{ .reasoning = .{ .account = "google-cloud-key", .payload = "{\"signature\":\"sig1\"}" } },
    .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "call_1", .output = .{ .content = "contents" } } },
    .{ .message = .{ .role = .user, .text = "resume" } },
    .{ .reasoning = .{ .account = "google-cloud-key", .payload = "{\"signature\":\"sig2\"}" } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
    .{ .message = .{ .role = .user, .text = "again" } },
    .{ .reasoning = .{ .account = "google-cloud-key", .payload = "{\"signature\":\"dropped\"}" } },
    .{ .message = .{ .role = .user, .text = "more" } },
    .{ .reasoning = .{ .account = "openai-api-key", .payload = "{\"signature\":\"foreign\"}" } },
    .{ .reasoning = .{ .account = "google-cloud-key", .payload = "{\"signature\":\"\"}" } },
    .{ .tool_call = .{ .id = "call_1", .name = "write", .arguments = "" } },
    .{ .tool_result = .{ .call_id = "call_1", .output = .{
        .content = "done",
        .conditions = .initOne(.failed),
    } } },
    .{ .reasoning = .{ .account = "google-cloud-key", .payload = "{\"signature\":\"tail\"}" } },
};

const golden_level = testing.oneLine(
    \\{"systemInstruction":{"parts":[{"text":"be terse"}]},"contents":[{"role":"user",
    \\"parts":[{"text":"first"},{"text":"second"}]},{"role":"model",
    \\"parts":[{"functionCall":{"name":"read","args":{"path":"a.zig"}},
    \\"thoughtSignature":"sig1"},{"text":"checking"}]},{"role":"user",
    \\"parts":[{"functionResponse":{"name":"read","response":{"output":"contents"}}}]},
    \\{"role":"user","parts":[{"text":"resume"}]},{"role":"model","parts":[{"text":"all set",
    \\"thoughtSignature":"sig2"}]},{"role":"user","parts":[{"text":"again"},{"text":"more"}]},
    \\{"role":"model","parts":[{"functionCall":{"name":"write","args":{}}}]},{"role":"user",
    \\"parts":[{"functionResponse":{"name":"write","response":{"error":"done"}}}]}],
    \\"tools":[{"functionDeclarations":[{"name":"read","description":"Read a file.",
    \\"parametersJsonSchema":{"type":"object","properties":{"path":{"type":"string",
    \\"description":"The path."}},"required":["path"],"additionalProperties":false}}]}],
    \\"generationConfig":{"thinkingConfig":{"includeThoughts":true,"thinkingLevel":"high"}}}
);

test "a named level sends the thoughts and its name, no effort sends no config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gemini: Gemini = .init(std.testing.allocator, test_options);
    const items = [_]core.Conversation.Item{.{ .message = .{ .role = .user, .text = "hi" } }};
    var named = testRequest(&items, .medium);
    named.system = "s";
    try std.testing.expectEqualStrings(testing.oneLine(
        \\{"systemInstruction":{"parts":[{"text":"s"}]},"contents":[{"role":"user",
        \\"parts":[{"text":"hi"}]}],
        \\"generationConfig":{"thinkingConfig":{"includeThoughts":true,
        \\"thinkingLevel":"medium"}}}
    ), try gemini.body(arena.allocator(), &named));
    const omitted = try gemini.body(arena.allocator(), &testRequest(&items, null));
    try std.testing.expect(std.mem.find(u8, omitted, "generationConfig") == null);
    try std.testing.expect(std.mem.find(u8, omitted, "tools") == null);
}

test "a result without its call refuses the request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gemini: Gemini = .init(std.testing.allocator, test_options);
    const items = [_]core.Conversation.Item{
        .{ .tool_result = .{ .call_id = "call_9", .output = .{ .content = "x" } } },
    };
    try std.testing.expectError(
        error.OrphanToolResult,
        gemini.body(arena.allocator(), &testRequest(&items, null)),
    );
}

test "prepare builds the URL of the model and sends the bearer token" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var multi_region: Gemini = .init(std.testing.allocator, .{
        .account = "google-cloud-key",
        .project = "my-project",
        .location = .eu,
    });
    var request = testRequest(&.{}, null);
    request.model = "gemini-3.5-flash";
    const prepared =
        try multi_region.dialect().prepare(arena.allocator(), &request, "secret-token");
    try std.testing.expectEqualStrings(
        "https://aiplatform.eu.rep.googleapis.com/v1/projects/my-project/locations/eu/" ++
            "publishers/google/models/gemini-3.5-flash:streamGenerateContent?alt=sse",
        prepared.url,
    );
    try std.testing.expectEqualStrings("Bearer secret-token", prepared.authorization.?);
    try std.testing.expectEqual(@as(?[]const u8, null), prepared.user_agent);
    try std.testing.expectEqual(@as(usize, 0), prepared.headers.len);
    try std.testing.expect(std.mem.startsWith(u8, prepared.body, "{\"systemInstruction\""));

    const global = try url(arena.allocator(), &test_options, "m");
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1/projects/my-project/locations/global/publishers/" ++
            "google/models/m:streamGenerateContent?alt=sse",
        global,
    );
    try std.testing.expectEqualStrings("aiplatform.us.rep.googleapis.com", Location.us.host());
}

test "text deltas stream as they arrive and close as one message at the end" {
    try expectTrace(
        \\text:Hel
        \\usage:10/2/0/0
        \\text:lo
        \\message:Hello
        \\stopped:complete|gemini-3-pro-preview
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hel\"}]}}]," ++
            "\"modelVersion\":\"gemini-3-pro-preview\"}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]}," ++
            "\"finishReason\":\"STOP\"}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2}}",
    });
}

test "thought parts stream as one run, and a call or answer text ends the run" {
    try expectTrace(
        \\reasoning_started
        \\reasoning:**Plan**
        \\text:answer
        \\reasoning_started
        \\reasoning:more
        \\message:answer
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"**Plan**\",\"thought\":true}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"answer\"}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"more\",\"thought\":true}]}," ++
            "\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(
        \\reasoning_started
        \\reasoning:a
        \\reasoning:b
        \\proof:google-cloud-key:{"signature":"s1"}
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_1|read|{}
        \\reasoning_started
        \\reasoning:c
        \\text:x
        \\message:x
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\",\"thought\":true}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"b\",\"thought\":true}," ++
            "{\"functionCall\":{\"name\":\"read\"},\"thoughtSignature\":\"s1\"}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"c\",\"thought\":true}," ++
            "{\"text\":\"x\"}]},\"finishReason\":\"STOP\"}]}",
    });
}

test "a function call carries the pending signature and takes a synthesized id" {
    try expectTrace(
        \\reasoning_started
        \\reasoning:look
        \\proof:google-cloud-key:{"signature":"sig1"}
        \\tool_call_started:read
        \\tool_call_arguments:{"path":"a.zig"}
        \\tool_call:call_1|read|{"path":"a.zig"}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"look\",\"thought\":true}," ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a.zig\"}}," ++
            "\"thoughtSignature\":\"sig1\"}]},\"finishReason\":\"STOP\"}]}",
    });
}

test "a synthesized id follows the highest call id of the request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var gemini: Gemini = .init(std.testing.allocator, test_options);
    defer gemini.deinit();
    const items = [_]core.Conversation.Item{
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{}" } },
        .{ .tool_result = .{ .call_id = "call_1", .output = .{ .content = "a" } } },
        .{ .tool_call = .{ .id = "toolu_7", .name = "read", .arguments = "{}" } },
        .{ .tool_result = .{ .call_id = "toolu_7", .output = .{ .content = "b" } } },
        .{ .tool_call = .{ .id = "call_x9", .name = "read", .arguments = "{}" } },
        .{ .tool_result = .{ .call_id = "call_x9", .output = .{ .content = "c" } } },
    };
    _ = try gemini.dialect().prepare(arena.allocator(), &testRequest(&items, null), "token");
    var frames: testing.Frames = .init(std.testing.allocator, gemini.dialect());
    defer frames.deinit();
    try frames.feed(&.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\"}}," ++
            "{\"functionCall\":{\"name\":\"grep\"}}]},\"finishReason\":\"STOP\"}]}",
    });
    try frames.finish();
    try frames.expect(
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_2|read|{}
        \\tool_call_started:grep
        \\tool_call_arguments:{}
        \\tool_call:call_3|grep|{}
        \\stopped:complete|
        \\
    );
}

test "a signature on a call part after unsigned text lands on the call alone" {
    try expectTrace(
        \\reasoning_started
        \\reasoning:hmm
        \\text:Let me look.
        \\message:Let me look.
        \\proof:google-cloud-key:{"signature":"sig"}
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_1|read|{}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hmm\",\"thought\":true}," ++
            "{\"text\":\"Let me look.\"}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\"}," ++
            "\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}",
    });
}

test "two signed calls in one reply each reach one reasoning item" {
    try expectTrace(
        \\proof:google-cloud-key:{"signature":"s1"}
        \\tool_call_started:read
        \\tool_call_arguments:{"path":"a"}
        \\tool_call:call_1|read|{"path":"a"}
        \\proof:google-cloud-key:{"signature":"s2"}
        \\tool_call_started:read
        \\tool_call_arguments:{"path":"b"}
        \\tool_call:call_2|read|{"path":"b"}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[" ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a\"}}," ++
            "\"thoughtSignature\":\"s1\"}," ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"b\"}}," ++
            "\"thoughtSignature\":\"s2\"}" ++
            "]},\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(
        \\proof:google-cloud-key:{"signature":"s1"}
        \\tool_call_started:read
        \\tool_call_arguments:{}
        \\tool_call:call_1|read|{}
        \\tool_call_started:grep
        \\tool_call_arguments:{}
        \\tool_call:call_2|grep|{}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[" ++
            "{\"functionCall\":{\"name\":\"read\"},\"thoughtSignature\":\"s1\"}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"grep\"}}]}," ++
            "\"finishReason\":\"STOP\"}]}",
    });
}

test "a signature on the last empty text part emits a reasoning item alone" {
    try expectTrace(
        \\reasoning_started
        \\reasoning:t
        \\text:done
        \\proof:google-cloud-key:{"signature":"sig"}
        \\message:done
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"t\",\"thought\":true}," ++
            "{\"text\":\"done\"}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"," ++
            "\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(
        \\proof:google-cloud-key:{"signature":"sig"}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"," ++
            "\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}",
    });
}

test "each finish reason folds to its stop and an absent one is invalid" {
    const Case = struct { reason: []const u8, expected: []const u8 };
    const unsupported = "failed:unsupported_reply|-|" ++
        "The reply holds content that Drinky cannot keep.";
    for ([_]Case{
        .{ .reason = "STOP", .expected = "stopped:complete|" },
        .{ .reason = "MAX_TOKENS", .expected = "stopped:truncated|" },
        .{ .reason = "MALFORMED_FUNCTION_CALL", .expected = "failed:invalid_reply|-|" },
        .{ .reason = "SAFETY", .expected = unsupported },
        .{ .reason = "RECITATION", .expected = unsupported },
        .{ .reason = "BLOCKLIST", .expected = unsupported },
        .{ .reason = "PROHIBITED_CONTENT", .expected = unsupported },
        .{ .reason = "SPII", .expected = unsupported },
        .{ .reason = "OTHER", .expected = unsupported },
        .{ .reason = "FUTURE_REASON", .expected = unsupported },
    }) |case| {
        const gpa = std.testing.allocator;
        const payload = try gpa.print(
            "{{\"candidates\":[{{\"content\":{{\"parts\":[{{\"text\":\"x\"}}]}}," ++
                "\"finishReason\":\"{s}\"}}]}}",
            .{case.reason},
        );
        defer gpa.free(payload);
        const expected = try gpa.print("text:x\nmessage:x\n{s}\n", .{case.expected});
        defer gpa.free(expected);
        try expectTrace(expected, &.{payload});
    }
    try expectTrace(
        \\text:x
        \\message:x
        \\failed:invalid_reply|-|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]}}]}",
    });
}

test "a blocked prompt is an unsupported stop with its usage and no candidates" {
    try expectTrace(
        \\usage:7/0/0/0
        \\failed:unsupported_reply|-|The reply holds content that Drinky cannot keep.
        \\
    , &.{
        "{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}," ++
            "\"usageMetadata\":{\"promptTokenCount\":7}}",
    });
}

test "a streamed error frame fails with its reason and message" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        "{\"error\":{\"code\":503,\"message\":\"overloaded\",\"status\":\"UNAVAILABLE\"}}",
        "{\"error\":{\"code\":400,\"message\":\"bad\",\"status\":\"INVALID_ARGUMENT\"}}",
        "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}",
        "{\"error\":{\"code\":401,\"message\":\"expired\"}}",
    });
    try rig.frames.expect(
        \\failed:overloaded|-|overloaded
        \\failed:invalid_request|-|bad
        \\failed:rate_limited|-|
        \\failed:unauthorized|-|expired
        \\
    );
}

test "usage counts are cumulative and a chunk can omit any of them" {
    try expectTrace(
        \\usage:100/5/900/0
        \\text:a
        \\usage:100/15/900/0
        \\text:b
        \\message:ab
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":1000,\"cachedContentTokenCount\":900," ++
            "\"candidatesTokenCount\":1,\"thoughtsTokenCount\":4}}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"b\"}]}," ++
            "\"finishReason\":\"STOP\"}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":1000,\"candidatesTokenCount\":11}}",
    });
}

test "the stop names the served model verbatim" {
    try expectTrace(
        \\text:x
        \\message:x
        \\stopped:complete|gemini-3.5-flash-lite
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]}}]," ++
            "\"modelVersion\":\"gemini-3.5-flash-lite\"}",
        "{\"candidates\":[{\"finishReason\":\"STOP\"}]}",
    });
}

test "a part of an unknown kind latches unsupported" {
    const unsupported = "failed:unsupported_reply|-|" ++
        "The reply holds content that Drinky cannot keep.\n";
    try expectTrace("text:x\nmessage:x\n" ++ unsupported, &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}," ++
            "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"AA==\"}}]}," ++
            "\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(unsupported, &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\"," ++
            "\"data\":\"AA==\"},\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(
        \\proof:google-cloud-key:{"signature":"sig"}
        \\stopped:complete|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"sig\"}]}," ++
            "\"finishReason\":\"STOP\"}]}",
    });
}

test "a malformed part latches invalid and a malformed line is filler" {
    try expectTrace(
        \\text:x
        \\message:x
        \\failed:invalid_reply|-|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[\"not-a-part\",{\"text\":\"x\"}]}," ++
            "\"finishReason\":\"STOP\"}]}",
    });
    try expectTrace(
        \\text:x
        \\message:x
        \\failed:invalid_reply|-|
        \\
    , &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"args\":{}}}]}}]}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]},\"finishReason\":\"STOP\"}]}",
    });
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode("not json"));
    try rig.frames.finish();
    try rig.frames.expect("failed:invalid_reply|-|\n");
}

test "a failed head reports its status with the message of its body and no quota" {
    try Rig.expectFailure(test_options, &.{
        .status = .forbidden,
        .retry_after_ms = null,
        .body =
        \\{"error":{"code":403,"message":"Permission denied.","status":"PERMISSION_DENIED"}}
        ,
    }, "failed:invalid_request|-|403 Forbidden: Permission denied.");
    try Rig.expectFailure(test_options, &.{
        .status = .unauthorized,
        .retry_after_ms = null,
        .body = "not json",
    }, "failed:unauthorized|-|401 Unauthorized: not json");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = 7000,
        .body = "{}",
    }, "failed:rate_limited|7000|429 Too Many Requests: {}");
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expect(rig.wire.dialect().quota(&.{}, 0) == null);
}

test "decoding frees its state at every allocation-failure point" {
    try Rig.checkDecodeAllocationFailures(test_options, &.{
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"look\",\"thought\":true}," ++
            "{\"text\":\"done\",\"thoughtSignature\":\"sig1\"}]}}]," ++
            "\"modelVersion\":\"gemini-3.5-flash-lite\"}",
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\"," ++
            "\"args\":{\"path\":\"a.zig\"}},\"thoughtSignature\":\"sig2\"}]}," ++
            "\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10}}",
    });
}
