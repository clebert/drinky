const std = @import("std");
const core = @import("core");
const tools = @import("tools");
const Message = @import("Message.zig");

const Record = @This();

id: u64,
content: Content,
work: ?Work = null,

pub const Work = struct {
    started_ms: i64,
    end: ?End = null,
    pub const Status = enum { running, complete, canceled, failed, truncated };
    pub const End = struct { time_ms: i64, status: Status };
};

pub const Content = union(enum) {
    user: std.ArrayList(u8),
    user_note: Note,
    thinking: std.ArrayList(u8),
    model: std.ArrayList(u8),
    tool_result: Result,
    event: Event,
};
pub const Kind = std.meta.Tag(Content);
pub const Source = union(Kind) {
    user: []const u8,
    user_note: Note.Payload,
    thinking: []const u8,
    model: []const u8,
    tool_result: Result,
    event: Event.Payload,
};

pub const Note = struct {
    text: std.ArrayList(u8),
    skill: ?core.Session.Event.SkillLoaded,
    pub const Payload = struct {
        text: []const u8 = "",
        skill: ?core.Session.Event.SkillLoaded = null,
    };
};

pub const Result = struct {
    name: []const u8,
    description: tools.Registry.Description,
    output: core.Tool.Output,
    elapsed_ms: ?i64 = null,
    started_ms: i64,
    received_bytes: usize,
};

pub const Event = struct {
    text: std.ArrayList(u8),
    severity: Message.Severity,
    pub const Payload = struct {
        text: []const u8,
        severity: Message.Severity = .information,
    };
};

pub fn init(gpa: std.mem.Allocator, id: u64, source: *const Source) error{OutOfMemory}!Record {
    return .{
        .id = id,
        .work = switch (source.*) {
            .thinking => .{ .started_ms = 0 },
            .tool_result => |*result| .{ .started_ms = result.started_ms },
            else => null,
        },
        .content = switch (source.*) {
            .event => |*event| .{ .event = .{
                .text = try copy(gpa, event.text),
                .severity = event.severity,
            } },
            .user_note => |*note| note: {
                var text = try copy(gpa, note.text);
                errdefer text.deinit(gpa);
                const skill = if (note.skill) |skill| skill: {
                    const name = try gpa.dupe(u8, skill.name);
                    errdefer gpa.free(name);
                    break :skill core.Session.Event.SkillLoaded{
                        .name = name,
                        .source = try gpa.dupe(u8, skill.source),
                    };
                } else null;
                break :note .{ .user_note = .{ .text = text, .skill = skill } };
            },
            .tool_result => |*result| result: {
                var owned = result.*;
                owned.name = try gpa.dupe(u8, result.name);
                errdefer gpa.free(owned.name);
                owned.description = try dupeDescription(gpa, &result.description);
                errdefer owned.description.deinit(gpa);
                owned.output = try result.output.dupe(gpa);
                break :result .{ .tool_result = owned };
            },
            inline else => |text, tag| @unionInit(Content, @tagName(tag), try copy(gpa, text)),
        },
    };
}

pub fn dupeDescription(
    gpa: std.mem.Allocator,
    description: *const tools.Registry.Description,
) error{OutOfMemory}!tools.Registry.Description {
    var result = description.*;
    if (result.subject) |*subject| subject.text = try gpa.dupe(u8, subject.text);
    return result;
}

pub fn dupe(self: *const Record, gpa: std.mem.Allocator) error{OutOfMemory}!Record {
    var result = try init(gpa, self.id, &self.sourceValue());
    result.work = self.work;
    return result;
}

pub fn deinit(self: *Record, gpa: std.mem.Allocator) void {
    switch (self.content) {
        .event => |*event| event.text.deinit(gpa),
        .user_note => |*note| {
            note.text.deinit(gpa);
            if (note.skill) |skill| {
                gpa.free(skill.name);
                gpa.free(skill.source);
            }
        },
        .tool_result => |*result| {
            gpa.free(result.name);
            result.description.deinit(gpa);
            result.output.deinit(gpa);
        },
        inline else => |*list| list.deinit(gpa),
    }
}

pub fn appendText(
    self: *Record,
    gpa: std.mem.Allocator,
    delta: []const u8,
) error{OutOfMemory}!void {
    switch (self.content) {
        .thinking, .model => |*list| try list.appendSlice(gpa, delta),
        else => unreachable,
    }
}

pub fn replaceEvent(self: *Record, gpa: std.mem.Allocator, payload: *const Event.Payload) !void {
    const event = &self.content.event;
    try event.text.ensureTotalCapacity(gpa, payload.text.len);
    event.text.items.len = payload.text.len;
    std.mem.copyForwards(u8, event.text.items, payload.text);
    event.severity = payload.severity;
}

pub fn streamedText(self: *const Record) ?[]const u8 {
    return switch (self.content) {
        .thinking, .model => |list| list.items,
        else => null,
    };
}

fn sourceValue(self: *const Record) Source {
    return switch (self.content) {
        .event => |*event| .{ .event = .{ .text = event.text.items, .severity = event.severity } },
        .user_note => |*note| .{ .user_note = .{ .text = note.text.items, .skill = note.skill } },
        .tool_result => |*result| .{ .tool_result = result.* },
        inline else => |list, tag| @unionInit(Source, @tagName(tag), list.items),
    };
}

fn copy(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, text);
    return list;
}
