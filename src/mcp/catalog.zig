const std = @import("std");
const application = @import("application");
const discovery = @import("discovery.zig");
const protocol = @import("protocol.zig");
const reference = @import("../reference.zig");
const wording = @import("../wording.zig");

const answer_bytes_max = 32 * 1024;
const prompt_bytes_max = 4 * 1024;
const description_bytes_max = 1024;
const turns_max = 64;

pub const Call = union(enum) {
    identify,
    get_state,
    list_turns,
    get_operation: Operation,
    send_message: Message,
    list_skills,
    invoke_skill: Skill,
    cancel: Operation,
    retry,
    new_conversation,
    list_accounts,
    list_models: Account,
    fetch_models: Account,
    select_model: Model,
    set_effort: Effort,

    pub const Operation = struct { operation: OperationId };
    pub const Message = struct { text: []const u8 };
    pub const Skill = struct { name: []const u8, arguments: []const u8 = "" };
    pub const Account = struct { account: []const u8 };
    pub const Model = struct { account: []const u8, model: []const u8 };
    pub const Effort = struct { effort: application.Effort };
};

const OperationId = struct {
    value: u64,

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!OperationId {
        const text = switch (source) {
            .string => |text| text,
            else => return error.UnexpectedToken,
        };
        return .{ .value = std.fmt.parseInt(u64, text, 10) catch return error.InvalidNumber };
    }

    pub fn jsonStringify(
        self: OperationId,
        json: *std.json.Stringify,
    ) std.json.Stringify.Error!void {
        var buffer: [20]u8 = undefined;
        try json.write(std.fmt.bufPrint(&buffer, "{d}", .{self.value}) catch unreachable);
    }
};

pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    targeted: bool = true,
    properties: []const Property = &.{},
    hints: Hints,

    pub const Property = struct {
        name: []const u8,
        schema: []const u8,
        required: bool = true,
    };
    pub const Hints = struct {
        read_only: bool,
        destructive: bool = false,
        idempotent: bool = false,
        open_world: bool = false,
    };
};

pub const Failure = struct {
    kind: Kind,
    message: []const u8,
    cause: ?[]const u8 = null,

    pub const Kind = enum {
        invalid_request,
        incompatible,
        unknown_instance,
        invalid_arguments,
        unknown_account,
        terminal_interaction,
        reply_too_large,
        busy,
        not_accepted,
        unknown_outcome,
        unavailable,
        unreadable,
        invalid_reply,
    };
};

pub const Facts = struct {
    controller: *application.Controller,
    instance: discovery.Id,
    working_directory: []const u8,
    interaction: bool,
};

const Verdict = enum { complete, failed };
const WriteError = std.json.Stringify.Error || error{OutOfMemory};

pub const instance_schema = std.fmt.comptimePrint(
    "{{\"type\":\"string\",\"pattern\":\"^[0-9a-f]{{{d}}}$\"," ++
        "\"description\":\"The instance_id of an instance from list_instances.\"}}",
    .{discovery.id_length},
);
const operation_schema = "{\"type\":\"string\",\"pattern\":\"^[0-9]+$\"," ++
    "\"description\":\"The operation id that an earlier result returned.\"}";
const account_schema = "{\"type\":\"string\"," ++
    "\"description\":\"The account id of an account from list_accounts.\"}";
const effort_schema = schema: {
    var text: []const u8 = "{\"type\":\"string\",\"enum\":[";
    for (std.enums.values(application.Effort), 0..) |level, index| {
        text = text ++ (if (index == 0) "" else ",") ++ "\"" ++ @tagName(level) ++ "\"";
    }
    break :schema text ++ "],\"description\":\"The reasoning effort of the next turns.\"}";
};

const read_only: Definition.Hints = .{ .read_only = true };

pub const definitions = [_]Definition{
    .{
        .name = "list_instances",
        .description = "List the Drinky instances that accept MCP requests. Each entry has an " ++
            "instance_id and a status. An available entry also names the working directory, " ++
            "the branch, the account, the model, the effort, and the current work. Two " ++
            "instances can share a directory, so ask the user when the facts do not name one.",
        .targeted = false,
        .hints = read_only,
    },
    .{
        .name = "get_state",
        .description = "Read the current work, the offer, the notice, the account, the model, " ++
            "the effort, and the branch of an instance.",
        .hints = read_only,
    },
    .{
        .name = "list_turns",
        .description = "List the prompts of the conversation, with the oldest prompt first. " ++
            "Each prompt has the operation id of its turn.",
        .hints = read_only,
    },
    .{
        .name = "get_operation",
        .description = "Read the status of an operation. An ended turn has its outcome and its " ++
            "final answer. An ended model fetch has its outcome. The status unknown means that " ++
            "the instance holds no outcome: the operation is not a turn or the last model " ++
            "fetch, or the conversation no longer holds the turn.",
        .properties = &.{.{ .name = "operation", .schema = operation_schema }},
        .hints = read_only,
    },
    .{
        .name = "send_message",
        .description = "Send a user message to the conversation of an instance. The coding " ++
            "agent can change files and run commands. Acceptance starts a turn and returns its " ++
            "operation id, but acceptance is not completion. Poll get_operation for the answer.",
        .properties = &.{.{
            .name = "text",
            .schema = "{\"type\":\"string\",\"minLength\":1,\"description\":\"The message.\"}",
        }},
        .hints = .{ .read_only = false, .destructive = true, .open_world = true },
    },
    .{
        .name = "list_skills",
        .description = "List the skills of an instance.",
        .hints = read_only,
    },
    .{
        .name = "invoke_skill",
        .description = "Start a turn that loads a skill of the instance. The optional " ++
            "arguments give the task of the skill. Acceptance returns the operation id.",
        .properties = &.{
            .{
                .name = "name",
                .schema = "{\"type\":\"string\",\"description\":\"A skill from list_skills.\"}",
            },
            .{
                .name = "arguments",
                .schema = "{\"type\":\"string\",\"description\":\"The task of the skill.\"}",
                .required = false,
            },
        },
        .hints = .{ .read_only = false, .destructive = true, .open_world = true },
    },
    .{
        .name = "cancel",
        .description = "Cancel the running operation with the given operation id. Accepted " ++
            "work that ended already gets the refusal stale.",
        .properties = &.{.{ .name = "operation", .schema = operation_schema }},
        .hints = .{ .read_only = false, .idempotent = true },
    },
    .{
        .name = "retry",
        .description = "Ask the model to continue a failed turn from the committed work. The " ++
            "offer of get_state must be retry. Acceptance returns the operation id.",
        .hints = .{ .read_only = false, .destructive = true, .open_world = true },
    },
    .{
        .name = "new_conversation",
        .description = "Clear the conversation of an instance, so that the next message " ++
            "starts a new conversation. The files stay. Nothing can restore the conversation, " ++
            "so call this tool only when the user asks for a new conversation.",
        .hints = .{ .read_only = false, .destructive = true },
    },
    .{
        .name = "list_accounts",
        .description = "List the accounts of an instance with their sign-in state.",
        .hints = read_only,
    },
    .{
        .name = "list_models",
        .description = "List the saved models of an account. The tool fetch_models fetches " ++
            "a new list.",
        .properties = &.{.{ .name = "account", .schema = account_schema }},
        .hints = read_only,
    },
    .{
        .name = "fetch_models",
        .description = "Fetch a new model list of a signed-in account. Acceptance returns " ++
            "the operation id. Poll get_operation for the outcome, then call list_models.",
        .properties = &.{.{ .name = "account", .schema = account_schema }},
        .hints = .{ .read_only = false, .idempotent = true, .open_world = true },
    },
    .{
        .name = "select_model",
        .description = "Select a model of a signed-in account for the next turns.",
        .properties = &.{
            .{ .name = "account", .schema = account_schema },
            .{
                .name = "model",
                .schema = "{\"type\":\"string\",\"description\":\"A model from list_models.\"}",
            },
        },
        .hints = .{ .read_only = false, .idempotent = true },
    },
    .{
        .name = "set_effort",
        .description = "Set the reasoning effort for the next turns.",
        .properties = &.{.{ .name = "effort", .schema = effort_schema }},
        .hints = .{ .read_only = false, .idempotent = true },
    },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (&definitions) |*entry| {
        const tag = std.meta.stringToEnum(std.meta.Tag(Call), entry.name);
        if (entry.targeted == (tag == null))
            @compileError("a targeted tool must name a call: " ++ entry.name);
        if (tag) |found| if (found == .identify)
            @compileError("no tool can name the identify call");
        const fields = if (tag) |found| @FieldType(Call, @tagName(found)) else void;
        const count = if (fields == void) 0 else @typeInfo(fields).@"struct".field_names.len;
        if (count != entry.properties.len)
            @compileError("the properties of a tool must match its call: " ++ entry.name);
    }
}

pub fn definition(name: []const u8) ?*const Definition {
    for (&definitions) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn answer(
    gpa: std.mem.Allocator,
    facts: *const Facts,
    line: []const u8,
) error{OutOfMemory}![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    writeAnswer(arena.allocator(), facts, line, &json) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    if (output.written().len < protocol.line_bytes_max) return output.toOwnedSlice();
    return failure(gpa, &facts.instance, &.{
        .kind = .reply_too_large,
        .message = "The reply exceeds the size limit.",
    });
}

pub fn failure(
    gpa: std.mem.Allocator,
    instance: *const discovery.Id,
    reason: *const Failure,
) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    writeEnvelope(&json, instance, .failed) catch return error.OutOfMemory;
    writeFailure(&json, reason) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn failureContent(
    gpa: std.mem.Allocator,
    reason: *const Failure,
) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    writeFailure(&json, reason) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeEnvelope(
    json: *std.json.Stringify,
    instance: *const discovery.Id,
    verdict: Verdict,
) std.json.Stringify.Error!void {
    try json.beginObject();
    try protocol.field(json, "drinky", protocol.version);
    try protocol.field(json, "instance", instance[0..]);
    try protocol.field(json, "error", verdict == .failed);
    try json.objectField("content");
}

fn writeAnswer(
    arena: std.mem.Allocator,
    facts: *const Facts,
    line: []const u8,
    json: *std.json.Stringify,
) WriteError!void {
    var content: std.Io.Writer.Allocating = .init(arena);
    var inner: std.json.Stringify = .{ .writer = &content.writer };
    const verdict = try writeContent(arena, facts, line, &inner);
    try writeEnvelope(json, &facts.instance, verdict);
    try protocol.writeRaw(json, content.written());
    try json.endObject();
}

fn writeContent(
    arena: std.mem.Allocator,
    facts: *const Facts,
    line: []const u8,
    json: *std.json.Stringify,
) WriteError!Verdict {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(json, &.{
                .kind = .invalid_request,
                .message = "The request is not valid JSON.",
            }),
        };
    const envelope = switch (value) {
        .object => |object| object,
        else => return invalid(json, &.{
            .kind = .invalid_request,
            .message = "The request is not a JSON object.",
        }),
    };
    const declared = envelope.get("drinky") orelse .null;
    if (declared != .integer or declared.integer != protocol.version)
        return invalid(json, &.{
            .kind = .incompatible,
            .message = "The instance uses another private protocol.",
        });
    const addressed = envelope.get("instance") orelse .null;
    if (addressed != .string or !std.mem.eql(u8, addressed.string, &facts.instance))
        return invalid(json, &.{
            .kind = .unknown_instance,
            .message = "The request names another instance.",
        });
    const call = std.json.parseFromValueLeaky(
        Call,
        arena,
        envelope.get("call") orelse .null,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |other| return invalid(json, &.{
            .kind = .invalid_arguments,
            .message = "The arguments do not match the input schema of the tool.",
            .cause = @errorName(other),
        }),
    };
    const entry = definition(@tagName(call)) orelse return execute(arena, facts, &call, json);
    if (!entry.hints.read_only and facts.interaction) return invalid(json, &.{
        .kind = .terminal_interaction,
        .message = "The terminal shows a picker, a page, or a sign-in. Ask the user to end it.",
    });
    return execute(arena, facts, &call, json);
}

fn execute(
    arena: std.mem.Allocator,
    facts: *const Facts,
    call: *const Call,
    json: *std.json.Stringify,
) WriteError!Verdict {
    const controller = facts.controller;
    switch (call.*) {
        .identify => {
            _ = controller.submit(&.refresh_project);
            const state = controller.state();
            try json.beginObject();
            try writeFacts(json, facts, &state);
            try protocol.field(json, "work", @tagName(state.work));
            try json.endObject();
        },
        .get_state => {
            _ = controller.submit(&.refresh_project);
            const state = controller.state();
            try json.beginObject();
            try writeFacts(json, facts, &state);
            try json.objectField("work");
            try writeWork(json, &state.work);
            try protocol.field(json, "offer", @tagName(state.offer));
            try json.objectField("notice");
            if (state.notice) |*notice| {
                const message = try wording.event(arena, notice);
                try json.beginObject();
                try protocol.field(json, "severity", @tagName(message.severity));
                try protocol.field(json, "text", message.content);
                try json.endObject();
            } else try json.write(null);
            try json.endObject();
        },
        .list_turns => try writeTurns(json, controller.listTurns()),
        .get_operation => |target| try writeOperation(
            json,
            target.operation,
            &controller.operation(target.operation.value),
        ),
        .send_message => |message| {
            if (std.mem.trim(u8, message.text, application.reference.blank_bytes).len == 0)
                return invalid(json, &.{
                    .kind = .invalid_arguments,
                    .message = "The message is blank.",
                });
            return submit(arena, json, controller, &.{ .send_message = message.text });
        },
        .list_skills => try writeSkills(json, controller.listSkills()),
        .invoke_skill => |skill| {
            const separator: []const u8 = if (skill.arguments.len == 0) "" else " ";
            const line = try arena.print(
                "/{s}{s}{s}{s}",
                .{ reference.skill_prefix, skill.name, separator, skill.arguments },
            );
            return submit(arena, json, controller, &.{ .invoke_skill = .{
                .name = skill.name,
                .arguments = skill.arguments,
                .line = line,
            } });
        },
        .cancel => |target| return submit(arena, json, controller, &.{
            .cancel = target.operation.value,
        }),
        .retry => return submit(arena, json, controller, &.retry),
        .new_conversation => return submit(arena, json, controller, &.new_conversation),
        .list_accounts => {
            const state = controller.state();
            const known = controller.listAccounts();
            try json.beginObject();
            try json.objectField("accounts");
            try json.beginArray();
            for (&known, 0..) |*account, index| {
                try json.beginObject();
                try protocol.field(json, "account", account.id);
                try protocol.field(json, "vendor", account.vendor);
                try protocol.field(json, "signed_in", account.authenticated);
                try protocol.field(json, "selected", state.choice.isActive(index));
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        },
        .list_models => |target| {
            const account = accountIndex(controller, target.account) orelse
                return unknownAccount(json);
            const choice = controller.state().choice;
            try json.beginObject();
            try json.objectField("models");
            try json.beginArray();
            for (controller.listModels(account)) |*model| {
                try json.beginObject();
                try protocol.field(json, "model", model.name);
                try protocol.field(json, "author", model.author);
                try protocol.field(json, "selected", choice.usesModel(account, model.name));
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        },
        .fetch_models => |target| {
            const account = accountIndex(controller, target.account) orelse
                return unknownAccount(json);
            return submit(arena, json, controller, &.{ .fetch_models = account });
        },
        .select_model => |target| {
            const account = accountIndex(controller, target.account) orelse
                return unknownAccount(json);
            return submit(arena, json, controller, &.{ .select_model = .{
                .account = account,
                .model = target.model,
            } });
        },
        .set_effort => |target| return submit(arena, json, controller, &.{
            .set_effort = target.effort,
        }),
    }
    return .complete;
}

fn writeFacts(
    json: *std.json.Stringify,
    facts: *const Facts,
    state: *const application.State,
) std.json.Stringify.Error!void {
    try protocol.field(json, "working_directory", facts.working_directory);
    try protocol.field(json, "branch", state.branch);
    try protocol.field(json, "account", state.choice.accountId());
    try protocol.field(json, "model", state.choice.modelName());
    try protocol.field(json, "effort", @tagName(state.choice.effort));
}

fn writeWork(
    json: *std.json.Stringify,
    work: *const application.State.Work,
) std.json.Stringify.Error!void {
    try json.beginObject();
    try protocol.field(json, "kind", @tagName(work.*));
    if (work.operation()) |id| try protocol.field(json, "operation", OperationId{ .value = id });
    const account = switch (work.*) {
        .sign_in => |sign_in| sign_in.account,
        .fetch => |fetch| fetch.account,
        .idle, .turn, .aside => return json.endObject(),
    };
    try protocol.field(json, "account", application.query.accountId(account));
    try json.endObject();
}

fn writeTurns(
    json: *std.json.Stringify,
    turns: []const application.query.Turn,
) std.json.Stringify.Error!void {
    const shown = turns[turns.len -| turns_max..];
    try json.beginObject();
    try protocol.field(json, "earlier", turns.len - shown.len);
    try json.objectField("turns");
    try json.beginArray();
    for (shown) |*turn| {
        const prompt = clip(turn.line, prompt_bytes_max);
        try json.beginObject();
        try protocol.field(json, "operation", OperationId{ .value = turn.id });
        try protocol.field(json, "prompt", prompt);
        try protocol.field(json, "prompt_truncated", prompt.len < turn.line.len);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn writeOperation(
    json: *std.json.Stringify,
    id: OperationId,
    operation: *const application.query.Operation,
) std.json.Stringify.Error!void {
    try json.beginObject();
    try protocol.field(json, "operation", id);
    switch (operation.*) {
        .running => try protocol.field(json, "status", "running"),
        .unknown => try protocol.field(json, "status", "unknown"),
        .turn_ended => |*ended| {
            try protocol.field(json, "status", "ended");
            switch (ended.outcome) {
                .stopped => |reason| try protocol.field(json, "outcome", switch (reason) {
                    .complete => "complete",
                    .truncated => "truncated",
                }),
                .canceled, .exhausted => |_, tag| {
                    try protocol.field(json, "outcome", @tagName(tag));
                },
                .failed => |*cause| {
                    try protocol.field(json, "outcome", "failed");
                    try json.objectField("failure");
                    try json.beginObject();
                    try protocol.field(json, "reason", @tagName(cause.reason));
                    try protocol.field(json, "message", cause.message);
                    try json.endObject();
                },
            }
            const text = clip(ended.answer, answer_bytes_max);
            try protocol.field(json, "answer", text);
            try protocol.field(json, "answer_truncated", text.len < ended.answer.len);
        },
        .fetch_ended => |outcome| {
            try protocol.field(json, "status", "ended");
            try protocol.field(json, "outcome", @tagName(outcome));
            switch (outcome) {
                .failed => |cause| try protocol.field(json, "cause", @errorName(cause)),
                .listed, .canceled => {},
            }
        },
    }
    try json.endObject();
}

fn writeSkills(
    json: *std.json.Stringify,
    skills: []const application.query.Skill,
) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("skills");
    try json.beginArray();
    for (skills) |*skill| {
        try json.beginObject();
        try protocol.field(json, "name", skill.name);
        try protocol.field(json, "description", clip(skill.description, description_bytes_max));
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn submit(
    arena: std.mem.Allocator,
    json: *std.json.Stringify,
    controller: *application.Controller,
    command: *const application.Command,
) WriteError!Verdict {
    const response = controller.submit(command);
    if (response.refusal) |*refusal| {
        try writeRefusal(arena, json, refusal);
        return .failed;
    }
    try json.beginObject();
    try protocol.field(json, "accepted", true);
    if (response.operation) |id| try protocol.field(json, "operation", OperationId{ .value = id });
    try json.endObject();
    return .complete;
}

fn writeRefusal(
    arena: std.mem.Allocator,
    json: *std.json.Stringify,
    refusal: *const application.Refusal,
) WriteError!void {
    try json.beginObject();
    try protocol.field(json, "accepted", false);
    try protocol.field(json, "refusal", @tagName(refusal.*));
    const message: []const u8 = switch (refusal.*) {
        .busy => "Another operation runs. Wait for its end, or cancel it.",
        .signed_out => "The instance has no signed-in account for the request.",
        .no_model => "The instance has no selected model. Select a model first.",
        .unknown_target => "The instance does not know the target of the request.",
        .stale => "The target of the request is no longer current.",
        .unavailable => "The instance cannot run the request.",
        .no_conversation => "The conversation is empty.",
        .skill_unreadable => |unreadable| skill: {
            try protocol.field(json, "skill", unreadable.name);
            try protocol.field(json, "cause", @errorName(unreadable.cause));
            break :skill try arena.print(
                "Drinky could not load the skill {s} because of error {t}.",
                .{ unreadable.name, unreadable.cause },
            );
        },
        .account_unloaded => |unloaded| account: {
            const id = application.query.accountId(unloaded.account);
            try protocol.field(json, "account", id);
            try protocol.field(json, "cause", @errorName(unloaded.cause));
            break :account try arena.print(
                "Drinky could not load the {s} account because of error {t}.",
                .{ id, unloaded.cause },
            );
        },
        .credential_missing => |account| missing: {
            const id = application.query.accountId(account);
            try protocol.field(json, "account", id);
            break :missing try arena.print(
                "The instance needs {s} in its environment to use {s}.",
                .{ application.query.accountSetting(account).?, id },
            );
        },
    };
    try protocol.field(json, "message", message);
    try json.endObject();
}

fn unknownAccount(json: *std.json.Stringify) std.json.Stringify.Error!Verdict {
    return invalid(json, &.{
        .kind = .unknown_account,
        .message = "The instance has no account with this id.",
    });
}

fn invalid(json: *std.json.Stringify, reason: *const Failure) std.json.Stringify.Error!Verdict {
    try writeFailure(json, reason);
    return .failed;
}

fn writeFailure(json: *std.json.Stringify, reason: *const Failure) std.json.Stringify.Error!void {
    try json.beginObject();
    try protocol.field(json, "failure", reason.kind);
    try protocol.field(json, "message", reason.message);
    if (reason.cause) |cause| try protocol.field(json, "cause", cause);
    try json.endObject();
}

fn accountIndex(controller: *application.Controller, id: []const u8) ?usize {
    for (&controller.listAccounts(), 0..) |*account, index| {
        if (std.mem.eql(u8, account.id, id)) return index;
    }
    return null;
}

fn clip(text: []const u8, bytes_max: usize) []const u8 {
    if (text.len <= bytes_max) return text;
    var end = bytes_max;
    for (0..4) |_| {
        if (text[end] & 0xc0 != 0x80) break;
        end -= 1;
    }
    return text[0..end];
}

test "the catalog maps outcomes, refusals, and malformed requests to their content" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Demo.\n---\nBody.\n",
        }},
        .replies = &.{
            .{ .stall = &stall },
            .{ .status = .bad_request, .body = "{}" },
            .{ .body = providers.testing.replyStream(long_answer) },
        },
    });
    defer rig.deinit();
    var facts: Facts = .{
        .controller = rig.controller,
        .instance = "0123456789ab".*,
        .working_directory = "/work",
        .interaction = false,
    };
    const first = try Reply.of(&facts, request("send_message", "{\"text\":\"Task.\"}"));
    defer first.deinit();
    const operation = try first.text("operation");
    try stall.reached.wait(std.testing.io);
    try expectRefusal(&facts, request("send_message", "{\"text\":\"More.\"}"), "busy");
    try expectRefusal(&facts, request("new_conversation", "{}"), "busy");
    const running = try Reply.of(&facts, try targetOperation("get_operation", operation));
    defer running.deinit();
    try std.testing.expectEqualStrings("running", try running.text("status"));
    const canceled = try Reply.of(&facts, try targetOperation("cancel", operation));
    defer canceled.deinit();
    try rig.expectTurn(.canceled);
    try expectOutcome(&facts, operation, "canceled");
    try expectRefusal(&facts, try targetOperation("cancel", operation), "stale");
    const failed = try Reply.of(&facts, request("send_message", "{\"text\":\"Again.\"}"));
    defer failed.deinit();
    try rig.expectTurn(.failed);
    try expectOutcome(&facts, try failed.text("operation"), "failed");
    const long = try Reply.of(&facts, request("send_message", "{\"text\":\"Long.\"}"));
    defer long.deinit();
    try rig.expectTurn(.stopped);
    const long_operation = try long.text("operation");
    const ended = try Reply.of(&facts, try targetOperation("get_operation", long_operation));
    defer ended.deinit();
    const answer_text = try ended.text("answer");
    try std.testing.expect(std.unicode.utf8ValidateSlice(answer_text));
    try std.testing.expectEqual(answer_bytes_max - 1, answer_text.len);
    try std.testing.expect((try mcp_testing.member(ended.content, "answer_truncated")).bool);
    try expectFailure(&facts, request("send_message", "{\"text\":\" \\n\"}"), .invalid_arguments);
    try expectRefusal(&facts, request("invoke_skill", "{\"name\":\"missing\"}"), "unknown_target");
    try rig.tree.tmp.dir.deleteFile(std.testing.io, ".agents/skills/demo/SKILL.md");
    try expectRefusal(&facts, request("invoke_skill", "{\"name\":\"demo\"}"), "skill_unreadable");
    try expectFailure(
        &facts,
        request("select_model", "{\"account\":\"nope\",\"model\":\"x\"}"),
        .unknown_account,
    );
    try expectRefusal(
        &facts,
        request("select_model", "{\"account\":\"openai-plan\",\"model\":\"gpt-5.6-sol\"}"),
        "signed_out",
    );
    try expectFailure(&facts, request("fetch_models", "{\"account\":\"nope\"}"), .unknown_account);
    const plan = "{\"account\":\"openai-plan\"}";
    try expectRefusal(&facts, request("fetch_models", plan), "signed_out");
    for ([_]struct { line: []const u8, kind: Failure.Kind }{
        .{ .line = "nope", .kind = .invalid_request },
        .{
            .line = "{\"drinky\":2,\"instance\":\"0123456789ab\",\"call\":{}}",
            .kind = .incompatible,
        },
        .{
            .line = "{\"drinky\":1,\"instance\":\"aaaaaaaaaaaa\",\"call\":{}}",
            .kind = .unknown_instance,
        },
        .{
            .line = request("set_effort", "{\"effort\":\"extreme\"}"),
            .kind = .invalid_arguments,
        },
    }) |case| try expectFailure(&facts, case.line, case.kind);
    facts.interaction = true;
    const lower = request("set_effort", "{\"effort\":\"low\"}");
    try expectFailure(&facts, lower, .terminal_interaction);
    const read = try Reply.of(&facts, request("get_state", "{}"));
    defer read.deinit();
    try std.testing.expectEqualStrings("/work", try read.text("working_directory"));
}

test "a clip keeps whole UTF-8 sequences" {
    try std.testing.expectEqualStrings("a", clip("aé", 2));
    try std.testing.expectEqualStrings("aé", clip("aé", 3));
    try std.testing.expectEqualStrings("", clip("€", 2));
}

const long_answer = "a" ++ application.support.repeat("é", @divExact(answer_bytes_max, 2));

fn request(comptime name: []const u8, comptime arguments: []const u8) []const u8 {
    return "{\"drinky\":1,\"instance\":\"0123456789ab\",\"call\":{\"" ++ name ++ "\":" ++
        arguments ++ "}}";
}

fn targetOperation(comptime name: []const u8, operation: []const u8) ![]const u8 {
    const State = struct {
        var buffer: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(
        &State.buffer,
        "{{\"drinky\":1,\"instance\":\"0123456789ab\",\"call\":{{\"" ++ name ++
            "\":{{\"operation\":\"{s}\"}}}}}}",
        .{operation},
    );
}

fn expectOutcome(facts: *const Facts, operation: []const u8, outcome: []const u8) !void {
    const ended = try Reply.of(facts, try targetOperation("get_operation", operation));
    defer ended.deinit();
    try std.testing.expectEqualStrings("ended", try ended.text("status"));
    try std.testing.expectEqualStrings(outcome, try ended.text("outcome"));
}

fn expectRefusal(facts: *const Facts, line: []const u8, refusal: []const u8) !void {
    const reply = try Reply.of(facts, line);
    defer reply.deinit();
    try std.testing.expect(reply.failed);
    try std.testing.expectEqualStrings(refusal, try reply.text("refusal"));
    _ = try reply.text("message");
}

fn expectFailure(facts: *const Facts, line: []const u8, kind: Failure.Kind) !void {
    const reply = try Reply.of(facts, line);
    defer reply.deinit();
    try std.testing.expect(reply.failed);
    try std.testing.expectEqualStrings(@tagName(kind), try reply.text("failure"));
}

const Reply = struct {
    parsed: std.json.Parsed(std.json.Value),
    content: std.json.Value,
    failed: bool,

    fn of(facts: *const Facts, line: []const u8) !Reply {
        const gpa = std.testing.allocator;
        const raw = try answer(gpa, facts, line);
        defer gpa.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        const named = try mcp_testing.member(parsed.value, "instance");
        try std.testing.expectEqualStrings(&facts.instance, named.string);
        return .{
            .parsed = parsed,
            .content = try mcp_testing.member(parsed.value, "content"),
            .failed = (try mcp_testing.member(parsed.value, "error")).bool,
        };
    }

    fn deinit(self: *const Reply) void {
        self.parsed.deinit();
    }

    fn text(self: *const Reply, name: []const u8) ![]const u8 {
        const value = try mcp_testing.member(self.content, name);
        if (value != .string) return error.TestExpectedString;
        return value.string;
    }
};

const mcp_testing = @import("testing.zig");
const providers = @import("providers");
