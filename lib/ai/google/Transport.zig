//! The Gemini `streamGenerateContent` transport of Vertex AI. It sends a
//! serialized request and exposes the response as a pull stream of decoded SSE
//! chunks on the shared `sse` engine. It knows nothing about conversation state
//! or tools. It turns bytes into `Event`s.
//!
//! One chunk can carry several parts, and one function call part emits several
//! events, so the stream queues the events of a chunk and hands them out one at
//! a time. The wire sends no terminal frame, so the stream emits its stop when
//! the body ends.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const sse = @import("../sse.zig");

const Transport = @This();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
/// The full request URL (see `url`).
endpoint: []const u8,

/// The locations Drinky serves. The host decides where a request runs, and a
/// multi-region host keeps the processing inside its jurisdiction. A regional
/// host offers the legacy models alone, so Drinky names none.
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

/// The three names that form a request URL, named so no two can swap.
pub const Target = struct {
    project: []const u8,
    location: Location,
    model: []const u8,
};

/// One request's confusable string pair, named so body and token cannot swap.
pub const Payload = struct {
    body: []const u8,
    access_token: []const u8,
};

/// A single request in flight on the shared SSE engine, which supplies the
/// reading half. This struct keeps the Gemini chunk vocabulary (`decode`) and
/// its state. Pin it: the HTTP response borrows the request and the SSE reader
/// borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// A full connect sets this last. `sse.Engine.open`'s timeout path frees
    /// only an established stream.
    established: bool,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    body: *std.Io.Reader,
    io: std.Io,
    idle_ms: u64,
    budget: net.Budget,
    status: std.http.Status,
    error_length: usize,
    error_retryable: bool,
    retry_after_ms: ?u64,
    /// Scratch for one decoded frame. Events can borrow it until the next read.
    frame_arena: std.heap.ArenaAllocator,
    /// The events of the last chunk, in the frame arena, and the next one to
    /// hand out. Every slice of a queued event lives in the arena too, so a
    /// later part of the same chunk can reuse the retained buffers below.
    events: std.ArrayList(llm.Event),
    event_index: usize,
    /// Whether the body ended and the stop went out.
    ended: bool,
    /// The `thoughtSignature` that waits for the next part. Thought text shows
    /// through display deltas alone, because no wire needs it back.
    signature: std.ArrayList(u8),
    /// The answer text of the open text run.
    text: std.ArrayList(u8),
    /// The function calls emitted so far. Gemini sends no call id, so the count
    /// names each call within this reply.
    call_count: u64,
    /// Where the streamed reasoning display stands (see `sse.Reasoning`).
    reasoning: sse.Reasoning,
    /// The completeness that `finishReason` named, or null while none arrived.
    finish_status: ?llm.Event.Status,
    /// A wire outcome that makes this reply unretainable, latched until the stop.
    rejection: ?llm.Event.Stop.Rejection,
    /// The four cumulative counts of `usageMetadata`. A chunk can omit any of
    /// them, so each keeps its last value.
    prompt_tokens: u64,
    cached_tokens: u64,
    candidate_tokens: u64,
    thought_tokens: u64,
    usage: llm.Usage,
    /// The `modelVersion` the reply names. Owned, because the frame arena drops
    /// the chunk it arrives in. Empty until a chunk names one.
    served_model: std.ArrayList(u8),
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    /// The composed Authorization value. The retained request points at it for
    /// the stream's whole lifetime, so the stream owns the bytes.
    authorization: []u8,
    /// A Google error body carries a `details` array, so it runs past the 512
    /// bytes the other transports keep, and `describeError` needs the whole body.
    error_buffer: [4096]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    const engine = sse.Engine(Stream);
    pub const deinit = engine.deinit;
    pub const ok = engine.ok;
    pub const errorText = engine.errorText;
    pub const unauthorized = engine.unauthorized;
    pub const retryable = engine.retryable;
    pub const retryAfterMs = engine.retryAfterMs;
    pub const usageSoFar = engine.usageSoFar;

    /// The next decoded event, or null after the stop. A queued event of the
    /// last chunk goes out first. The end of the body closes the open text run
    /// and emits the stop.
    pub fn next(self: *Stream) !?llm.Event {
        if (self.takeQueued()) |event| return event;
        if (self.ended) return null;
        if (try engine.next(self)) |event| return event;
        self.ended = true;
        // The engine reset the arena before it met the end, so the queue
        // starts over in fresh memory.
        self.events = .empty;
        self.event_index = 0;
        try self.closeText();
        if (self.finish_status == null) self.markRejection(.invalid);
        try self.events.append(self.frame_arena.allocator(), .{ .stop = .{
            .usage = self.usage,
            .status = self.finish_status orelse .complete,
            .rejection = self.rejection,
            .model = self.served_model.items,
        } });
        return self.takeQueued();
    }

    fn takeQueued(self: *Stream) ?llm.Event {
        if (self.event_index >= self.events.items.len) return null;
        defer self.event_index += 1;
        return self.events.items[self.event_index];
    }

    /// Vertex reports no allowance in the head.
    pub fn quotaSoFar(_: *const Stream) ?llm.Quota {
        return null;
    }

    /// The message a failed head's error body carries (see
    /// `sse.Engine.refineError`). Null keeps the raw body.
    pub fn describeError(self: *Stream, body: []const u8) !?[]const u8 {
        const object = (try json.parseObject(self.frame_arena.allocator(), body)) orelse
            return null;
        const detail = json.object(object.get("error")) orelse return null;
        return json.string(detail.get("message"));
    }

    /// Set the decode state and the owned values to a blank start. The engine's
    /// `begin` calls it, so every construction site shares one list.
    pub fn beginDecode(self: *Stream) void {
        self.events = .empty;
        self.event_index = 0;
        self.ended = false;
        self.signature = .empty;
        self.text = .empty;
        self.call_count = 0;
        self.reasoning = .none;
        self.finish_status = null;
        self.rejection = null;
        self.prompt_tokens = 0;
        self.cached_tokens = 0;
        self.candidate_tokens = 0;
        self.thought_tokens = 0;
        self.served_model = .empty;
        self.authorization = &.{};
    }

    pub fn deinitDecode(self: *Stream) void {
        self.frame_arena.deinit();
        self.signature.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.served_model.deinit(self.gpa);
    }

    /// Free the owned Authorization value. The engine calls it after the
    /// request dies, so the request never points at freed bytes.
    pub fn deinitHeaders(self: *Stream) void {
        self.gpa.free(self.authorization);
    }

    /// Latch a rejection. `unsupported` and `uncorrelated` win over `invalid`,
    /// and the first of them to latch stays.
    fn markRejection(self: *Stream, rejection: llm.Event.Stop.Rejection) void {
        const latched = self.rejection orelse {
            self.rejection = rejection;
            return;
        };
        if (rejection.outranks(latched)) self.rejection = rejection;
    }

    /// Decode one `GenerateContentResponse` chunk. The parts of its first
    /// candidate become events, and the rest of the chunk updates the state.
    pub fn decode(self: *Stream, payload: []const u8) !sse.Decoded {
        const arena = self.frame_arena.allocator();
        self.events = .empty;
        self.event_index = 0;
        // A malformed payload is filler, not progress. A truncated tail then
        // surfaces as an incomplete reply at end of stream, which is retried.
        const object = (try json.parseObject(arena, payload)) orelse return .ignored;

        if (json.object(object.get("error"))) |detail| {
            engine.recordError(
                self,
                json.string(detail.get("message")) orelse "error",
                errorRetryable(detail),
            );
            return error.ApiError;
        }
        if (json.string(object.get("modelVersion"))) |version| {
            self.served_model.clearRetainingCapacity();
            try self.served_model.appendSlice(self.gpa, version);
        }
        if (json.object(object.get("usageMetadata"))) |usage| self.mergeUsage(usage);
        if (json.object(object.get("promptFeedback"))) |feedback| {
            if (feedback.get("blockReason") != null) {
                self.finish_status = .complete;
                self.markRejection(.unsupported);
            }
        }
        if (json.array(object.get("candidates"))) |candidates| {
            if (candidates.items.len != 0) try self.decodeCandidate(candidates.items[0]);
        }
        if (self.events.items.len == 0) return .progress;
        self.event_index = 1;
        return .{ .event = self.events.items[0] };
    }

    fn decodeCandidate(self: *Stream, value: std.json.Value) !void {
        const candidate = json.object(value) orelse return self.markRejection(.invalid);
        if (json.object(candidate.get("content"))) |content| {
            if (json.array(content.get("parts"))) |parts| {
                for (parts.items) |part| try self.decodePart(part);
            }
        }
        const reason = json.string(candidate.get("finishReason")) orelse return;
        try self.closeText();
        self.finish_status = .complete;
        if (std.mem.eql(u8, reason, "STOP")) return;
        if (std.mem.eql(u8, reason, "MAX_TOKENS")) {
            self.finish_status = .truncated;
        } else if (std.mem.eql(u8, reason, "MALFORMED_FUNCTION_CALL")) {
            self.markRejection(.invalid);
        } else {
            // SAFETY, RECITATION, BLOCKLIST, PROHIBITED_CONTENT, SPII, OTHER, and
            // every reason this design does not know.
            self.markRejection(.unsupported);
        }
    }

    fn decodePart(self: *Stream, value: std.json.Value) !void {
        const arena = self.frame_arena.allocator();
        const part = json.object(value) orelse return self.markRejection(.invalid);
        // Inline data, executable code, and every part this design does not
        // know cannot enter the history, so the reply cannot stand.
        for (part.keys()) |key| {
            if (!knownPartKey(key)) return self.markRejection(.unsupported);
        }
        if (json.object(part.get("functionCall"))) |call| {
            // The order of these reads decides where the signature lands. The
            // open text run takes the signature that earlier parts left, and
            // this call takes its own. A read before the close puts the
            // signature of the call on the text, and Gemini 3 then refuses the
            // call without it.
            try self.closeText();
            try self.takeSignature(part);
            const name = json.string(call.get("name")) orelse return self.markRejection(.invalid);
            const arguments = if (call.get("args")) |args| arguments: {
                if (args != .object) return self.markRejection(.invalid);
                break :arguments try std.json.Stringify.valueAlloc(arena, args, .{});
            } else "{}";
            try self.emitReasoning();
            try self.events.append(arena, .{ .tool_name = name });
            try self.events.append(arena, .{ .tool_arguments = arguments });
            self.call_count += 1;
            try self.events.append(arena, .{ .item = .{ .tool_call = .{
                .call_id = try std.fmt.allocPrint(arena, "call_{d}", .{self.call_count}),
                .name = name,
                .arguments_json = arguments,
            } } });
            return;
        }
        if (json.string(part.get("text"))) |text| {
            if (json.boolean(part.get("thought")) orelse false) {
                switch (try self.reasoning.display(arena, text)) {
                    .event => |event| try self.events.append(arena, event),
                    else => {},
                }
            } else {
                try self.text.appendSlice(self.gpa, text);
                if (self.reasoning.answer(text)) try self.events.append(arena, .{ .text = text });
            }
        }
        try self.takeSignature(part);
    }

    /// A `thoughtSignature` on `part` replaces the pending one.
    fn takeSignature(self: *Stream, part: std.json.ObjectMap) !void {
        const proof = json.string(part.get("thoughtSignature")) orelse return;
        if (proof.len == 0) return;
        self.signature.clearRetainingCapacity();
        try self.signature.appendSlice(self.gpa, proof);
    }

    /// Close the open text run: a reasoning item when a signature is pending,
    /// then a message item when the text has bytes.
    fn closeText(self: *Stream) !void {
        try self.emitReasoning();
        if (self.text.items.len == 0) return;
        const arena = self.frame_arena.allocator();
        try self.events.append(arena, .{ .item = .{ .message = try arena.dupe(u8, self.text.items) } });
        self.text.clearRetainingCapacity();
    }

    /// Emit the reasoning item of a pending signature, which consumes it, so one
    /// signature reaches one item.
    fn emitReasoning(self: *Stream) !void {
        self.reasoning.end();
        if (self.signature.items.len == 0) return;
        const arena = self.frame_arena.allocator();
        try self.events.append(arena, .{ .item = .{ .reasoning = .{ .signature = .{
            .text = "",
            .signature = try arena.dupe(u8, self.signature.items),
        } } } });
        self.signature.clearRetainingCapacity();
    }

    /// Overwrite each count the chunk carries and derive the neutral usage. The
    /// cached tokens are part of the prompt count, so the uncached input is the
    /// difference. Thought tokens bill as output.
    fn mergeUsage(self: *Stream, object: std.json.ObjectMap) void {
        if (json.unsigned(object.get("promptTokenCount"))) |count| self.prompt_tokens = count;
        if (json.unsigned(object.get("cachedContentTokenCount"))) |count| self.cached_tokens = count;
        if (json.unsigned(object.get("candidatesTokenCount"))) |count| self.candidate_tokens = count;
        if (json.unsigned(object.get("thoughtsTokenCount"))) |count| self.thought_tokens = count;
        self.usage = .{
            .input = self.prompt_tokens -| self.cached_tokens,
            .cache_read = self.cached_tokens,
            .output = self.candidate_tokens +| self.thought_tokens,
        };
    }
};

/// The `streamGenerateContent` URL of `target`. The caller frees the result.
pub fn url(gpa: std.mem.Allocator, target: *const Target) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "https://{s}/v1/projects/{s}/locations/{s}/publishers/google/models/{s}" ++
            ":streamGenerateContent?alt=sse",
        .{ target.location.host(), target.project, @tagName(target.location), target.model },
    );
}

/// Whether a part key names content this design reads.
fn knownPartKey(key: []const u8) bool {
    for ([_][]const u8{ "text", "thought", "thoughtSignature", "functionCall" }) |known| {
        if (std.mem.eql(u8, key, known)) return true;
    }
    return false;
}

/// A rate limit and every server fault are worth a retry.
fn errorRetryable(detail: std.json.ObjectMap) bool {
    const code = json.integer(detail.get("code")) orelse return false;
    return code == 429 or (code >= 500 and code < 600);
}

/// Open a streaming request bounded by the connect timeout. Any failure tears
/// down `out`, so a caller that sees an error owns nothing (see
/// `sse.Engine.open`).
pub fn send(self: *Transport, out: *Stream, payload: *const Payload) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, payload });
}

fn connect(self: *Transport, out: *Stream, payload: *const Payload) anyerror!void {
    // The token becomes a header value. Reject one that can split the head.
    if (!net.validHeaderValue(payload.access_token)) return error.BadCredentials;
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();
    errdefer out.frame_arena.deinit();

    // The retained request points at this header value until `deinit`, so the
    // stream owns the bytes.
    out.authorization = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{payload.access_token});
    errdefer self.gpa.free(out.authorization);

    const uri = try std.Uri.parse(self.endpoint);
    out.request = try out.client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = out.authorization },
            // Read the event stream uncompressed so event delivery stays
            // independent of any decompressor's own buffering.
            .accept_encoding = .{ .override = "identity" },
        },
    });
    errdefer out.request.deinit();

    try engine.finish(out, payload.body);
}

/// A stream over `body` for the tests: test allocator and fresh decode state.
/// The connection fields stay undefined. Pair with `defer stream.deinitDecode()`.
fn testStream(io: std.Io, body: *std.Io.Reader) Stream {
    var stream: Stream = undefined;
    sse.Engine(Stream).begin(&stream, std.testing.allocator, io);
    stream.io = io;
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = net.stream_response_bytes_max };
    stream.body = body;
    stream.status = .ok;
    return stream;
}

/// Drain a stream over `body` and write one line per event, so a test states
/// the whole event order in one string. The caller frees the result.
fn trace(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader);
    defer stream.deinitDecode();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    while (try stream.next()) |event| {
        switch (event) {
            .text => |text| try writer.print("text:{s}\n", .{text}),
            .thinking => |text| try writer.print("thinking:{s}\n", .{text}),
            .tool_name => |name| try writer.print("tool_name:{s}\n", .{name}),
            .tool_arguments => |text| try writer.print("tool_arguments:{s}\n", .{text}),
            .item => |item| switch (item) {
                .message => |text| try writer.print("message:{s}\n", .{text}),
                .reasoning => |reasoning| try writer.print("reasoning:{s}\n", .{
                    reasoning.signature.signature,
                }),
                .tool_call => |call| try writer.print("tool_call:{s}|{s}|{s}\n", .{
                    call.call_id,
                    call.name,
                    call.arguments_json,
                }),
            },
            .stop => |stop| try writer.print("stop:{s}|{s}|{s}|{d}/{d}/{d}\n", .{
                @tagName(stop.status),
                if (stop.rejection) |rejection| @tagName(rejection) else "-",
                stop.model,
                stop.usage.input,
                stop.usage.cache_read,
                stop.usage.output,
            }),
        }
    }
    return out.toOwnedSlice();
}

fn expectTrace(expected: []const u8, body: []const u8) !void {
    const actual = try trace(std.testing.allocator, body);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "text deltas display as they stream and close as one message at the end" {
    try expectTrace(
        \\text:Hel
        \\text:lo
        \\message:Hello
        \\stop:complete|-|gemini-3-pro-preview|10/0/2
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hel\"}]}}]," ++
            "\"modelVersion\":\"gemini-3-pro-preview\"}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]},\"finishReason\":\"STOP\"}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2}}\n\n",
    );
}

test "thought parts display only, and a call ends their run" {
    try expectTrace(
        \\thinking:**Plan**
        \\text:answer
        \\thinking:more
        \\message:answer
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"**Plan**\",\"thought\":true}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"answer\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"more\",\"thought\":true}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
    // Thought parts across chunks form one run. A call ends the run, so the
    // thought text behind it takes the blank line.
    try expectTrace(
        \\thinking:a
        \\thinking:b
        \\reasoning:s1
        \\tool_name:read
        \\tool_arguments:{}
        \\tool_call:call_1|read|{}
        \\thinking:
        \\
        \\c
        \\text:x
        \\message:x
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\",\"thought\":true}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"b\",\"thought\":true}," ++
            "{\"functionCall\":{\"name\":\"read\"},\"thoughtSignature\":\"s1\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"c\",\"thought\":true}," ++
            "{\"text\":\"x\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "a function call carries the pending signature and takes a synthesized id" {
    try expectTrace(
        \\thinking:look
        \\reasoning:sig1
        \\tool_name:read
        \\tool_arguments:{"path":"a.zig"}
        \\tool_call:call_1|read|{"path":"a.zig"}
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"look\",\"thought\":true}," ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a.zig\"}}," ++
            "\"thoughtSignature\":\"sig1\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "a function call without args is a call with an empty object" {
    try expectTrace(
        \\tool_name:list
        \\tool_arguments:{}
        \\tool_call:call_1|list|{}
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"list\"}}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
}

// The text parts carry no signature, and the call part does. The call must
// carry it, and the message must carry none, or Gemini 3 refuses the replay.
test "a signature on a call part after unsigned text lands on the call alone" {
    try expectTrace(
        \\thinking:hmm
        \\text:Let me look.
        \\message:Let me look.
        \\reasoning:sig
        \\tool_name:read
        \\tool_arguments:{}
        \\tool_call:call_1|read|{}
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hmm\",\"thought\":true}," ++
            "{\"text\":\"Let me look.\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\"}," ++
            "\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "two signed calls in one reply each reach one reasoning item" {
    try expectTrace(
        \\reasoning:s1
        \\tool_name:read
        \\tool_arguments:{"path":"a"}
        \\tool_call:call_1|read|{"path":"a"}
        \\reasoning:s2
        \\tool_name:read
        \\tool_arguments:{"path":"b"}
        \\tool_call:call_2|read|{"path":"b"}
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[" ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a\"}},\"thoughtSignature\":\"s1\"}," ++
            "{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"b\"}},\"thoughtSignature\":\"s2\"}" ++
            "]},\"finishReason\":\"STOP\"}]}\n\n",
    );
    // A second call without a signature emits no second reasoning item.
    try expectTrace(
        \\reasoning:s1
        \\tool_name:read
        \\tool_arguments:{}
        \\tool_call:call_1|read|{}
        \\tool_name:grep
        \\tool_arguments:{}
        \\tool_call:call_2|grep|{}
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[" ++
            "{\"functionCall\":{\"name\":\"read\"},\"thoughtSignature\":\"s1\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"grep\"}}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "a signature on the last empty text part emits a reasoning item alone" {
    try expectTrace(
        \\thinking:t
        \\text:done
        \\reasoning:sig
        \\message:done
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"t\",\"thought\":true}," ++
            "{\"text\":\"done\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\",\"thoughtSignature\":\"sig\"}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
    // With no text at all, the item stands alone before the stop.
    try expectTrace(
        \\reasoning:sig
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\",\"thoughtSignature\":\"sig\"}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "each finish reason folds to its stop and an absent one is invalid" {
    const Case = struct { reason: []const u8, expected: []const u8 };
    for ([_]Case{
        .{ .reason = "STOP", .expected = "complete|-" },
        .{ .reason = "MAX_TOKENS", .expected = "truncated|-" },
        .{ .reason = "MALFORMED_FUNCTION_CALL", .expected = "complete|invalid" },
        .{ .reason = "SAFETY", .expected = "complete|unsupported" },
        .{ .reason = "RECITATION", .expected = "complete|unsupported" },
        .{ .reason = "BLOCKLIST", .expected = "complete|unsupported" },
        .{ .reason = "PROHIBITED_CONTENT", .expected = "complete|unsupported" },
        .{ .reason = "SPII", .expected = "complete|unsupported" },
        .{ .reason = "OTHER", .expected = "complete|unsupported" },
        .{ .reason = "FUTURE_REASON", .expected = "complete|unsupported" },
    }) |case| {
        const gpa = std.testing.allocator;
        const body = try std.fmt.allocPrint(
            gpa,
            "data: {{\"candidates\":[{{\"content\":{{\"parts\":[{{\"text\":\"x\"}}]}}," ++
                "\"finishReason\":\"{s}\"}}]}}\n\n",
            .{case.reason},
        );
        defer gpa.free(body);
        const expected = try std.fmt.allocPrint(
            gpa,
            "text:x\nmessage:x\nstop:{s}||0/0/0\n",
            .{case.expected},
        );
        defer gpa.free(expected);
        const actual = try trace(gpa, body);
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    try expectTrace(
        \\text:x
        \\message:x
        \\stop:complete|invalid||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]}}]}\n\n",
    );
}

test "a blocked prompt is an unsupported stop with no candidates" {
    try expectTrace(
        \\stop:complete|unsupported||7/0/0
        \\
    ,
        "data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}," ++
            "\"usageMetadata\":{\"promptTokenCount\":7}}\n\n",
    );
}

test "an error chunk surfaces as an API error with its message" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(
        "data: {\"error\":{\"code\":503,\"message\":\"overloaded\",\"status\":\"UNAVAILABLE\"}}\n\n",
    );
    var stream = testStream(threaded.io(), &reader);
    defer stream.deinitDecode();
    try std.testing.expectError(error.ApiError, stream.next());
    try std.testing.expectEqualStrings("overloaded", stream.errorText());
    try std.testing.expect(stream.retryable());

    var refused: std.Io.Reader = .fixed(
        "data: {\"error\":{\"code\":400,\"message\":\"bad\",\"status\":\"INVALID_ARGUMENT\"}}\n\n",
    );
    var refused_stream = testStream(threaded.io(), &refused);
    defer refused_stream.deinitDecode();
    try std.testing.expectError(error.ApiError, refused_stream.next());
    try std.testing.expect(!refused_stream.retryable());
}

test "usage counts are cumulative and a chunk can omit any of them" {
    try expectTrace(
        \\text:a
        \\text:b
        \\message:ab
        \\stop:complete|-||100/900/15
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":1000,\"cachedContentTokenCount\":900," ++
            "\"candidatesTokenCount\":1,\"thoughtsTokenCount\":4}}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"b\"}]},\"finishReason\":\"STOP\"}]," ++
            "\"usageMetadata\":{\"promptTokenCount\":1000,\"candidatesTokenCount\":11}}\n\n",
    );
}

// A provider can switch a request to another model. The chunk names the model
// that serves the reply, so the stop carries it past every frame-arena reset,
// and the agent compares it to the requested name.
test "the stop names the served model verbatim" {
    try expectTrace(
        \\text:x
        \\message:x
        \\stop:complete|-|gemini-3.5-flash-lite|0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]}}]," ++
            "\"modelVersion\":\"gemini-3.5-flash-lite\"}\n\n" ++
            "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "a part of an unknown kind latches unsupported" {
    try expectTrace(
        \\text:x
        \\message:x
        \\stop:complete|unsupported||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}," ++
            "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"AA==\"}}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
    // A signature beside unknown content saves nothing: the reply still falls.
    try expectTrace(
        \\stop:complete|unsupported||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\"," ++
            "\"data\":\"AA==\"},\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
    // A part that carries a signature alone is a known shape.
    try expectTrace(
        \\reasoning:sig
        \\stop:complete|-||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"sig\"}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
}

test "a malformed part latches invalid and a malformed line is filler" {
    try expectTrace(
        \\text:x
        \\message:x
        \\stop:complete|invalid||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[\"not-a-part\",{\"text\":\"x\"}]}," ++
            "\"finishReason\":\"STOP\"}]}\n\n",
    );
    try expectTrace(
        \\text:x
        \\message:x
        \\stop:complete|invalid||0/0/0
        \\
    ,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"args\":{}}}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]},\"finishReason\":\"STOP\"}]}\n\n",
    );
    try expectTrace(
        \\stop:complete|invalid||0/0/0
        \\
    ,
        "data: not json\n\n",
    );
}

test "describeError reduces a failed head's error body to its message" {
    var stream = testStream(undefined, undefined);
    defer stream.deinitDecode();
    try std.testing.expectEqualStrings("Permission denied.", (try stream.describeError(
        \\{"error":{"code":403,"message":"Permission denied.","status":"PERMISSION_DENIED"}}
    )).?);
    try std.testing.expect((try stream.describeError("not json")) == null);
    try std.testing.expect((try stream.describeError("{}")) == null);
}

test "the head classifies a rejected token apart from a denied permission" {
    var stream = testStream(undefined, undefined);
    defer stream.deinitDecode();
    stream.status = .unauthorized;
    try std.testing.expect(stream.unauthorized());
    try std.testing.expect(!stream.retryable());
    stream.status = .forbidden;
    try std.testing.expect(!stream.unauthorized());
    try std.testing.expect(!stream.retryable());
    stream.status = .too_many_requests;
    stream.retry_after_ms = 7000;
    try std.testing.expect(stream.retryable());
    try std.testing.expectEqual(@as(?u64, 7000), stream.retryAfterMs());
    try std.testing.expect(stream.quotaSoFar() == null);
}

test url {
    const gpa = std.testing.allocator;
    const multi_region = try url(gpa, &.{
        .project = "my-project",
        .location = .eu,
        .model = "gemini-3.5-flash",
    });
    defer gpa.free(multi_region);
    try std.testing.expectEqualStrings(
        "https://aiplatform.eu.rep.googleapis.com/v1/projects/my-project/locations/eu/" ++
            "publishers/google/models/gemini-3.5-flash:streamGenerateContent?alt=sse",
        multi_region,
    );
    const global = try url(gpa, &.{ .project = "p", .location = .global, .model = "m" });
    defer gpa.free(global);
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/" ++
            "models/m:streamGenerateContent?alt=sse",
        global,
    );
    try std.testing.expectEqualStrings("aiplatform.us.rep.googleapis.com", Location.us.host());
}

test "connect rejects a token that splits the request head" {
    var transport: Transport = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .timeouts = .{},
        .endpoint = "https://example.test/v1",
    };
    var stream: Stream = undefined;
    try std.testing.expectError(error.BadCredentials, connect(&transport, &stream, &.{
        .body = "{}",
        .access_token = "token\r\nleaked: value",
    }));
}

/// One accepted connection for the header-lifetime test: read the whole
/// request, then answer with one chunk and end the body.
fn serveOneResponse(io: std.Io, server: *std.Io.net.Server) !void {
    const body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}]}," ++
        "\"finishReason\":\"STOP\"}]}\n\n";
    var connection = try server.accept(io);
    defer connection.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var content_length: usize = 0;
    // The head of one request holds few lines, so the cap only stops a runaway.
    var lines_left: usize = 64;
    while (lines_left > 0) : (lines_left -= 1) {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        const label = "content-length:";
        if (std.ascii.startsWithIgnoreCase(line, label)) {
            const value = std.mem.trim(u8, line[label.len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    try reader.interface.discardAll(content_length);

    var write_buffer: [512]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.print(
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try writer.interface.flush();
}

test "the stream owns the Authorization value and ends with a stop" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const endpoint = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/v1/models/m:streamGenerateContent?alt=sse",
        .{server.socket.address.getPort()},
    );
    defer gpa.free(endpoint);

    var serve = try io.concurrent(serveOneResponse, .{ io, &server });
    var reaped = false;
    defer if (!reaped) {
        _ = serve.cancel(io) catch {};
    };

    var transport: Transport = .{ .gpa = gpa, .io = io, .timeouts = .{}, .endpoint = endpoint };
    var stream: Stream = undefined;
    try transport.send(&stream, &.{ .body = "{}", .access_token = "secret-token" });
    defer stream.deinit();
    reaped = true;
    try serve.await(io);

    try std.testing.expectEqualStrings(
        "Bearer secret-token",
        stream.request.headers.authorization.override,
    );
    try std.testing.expectEqualStrings("hi", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("hi", (try stream.next()).?.item.message);
    try std.testing.expectEqual(llm.Event.Status.complete, (try stream.next()).?.stop.status);
    try std.testing.expect((try stream.next()) == null);
}
