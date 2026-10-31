const std = @import("std");
const Controller = @import("Controller.zig");
const Record = @import("Record.zig");
const reference = @import("reference.zig");
const testing = @import("testing.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
list: std.ArrayList(Entry) = .empty,
current: ?Stream = null,
held: std.ArrayList(u8) = .empty,
retained: usize = 0,
removed: std.ArrayList(u64) = .empty,
id_next: u64 = 1,
dirty_from: usize = 0,

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Entry = struct {
    record: Record,
    survives_discard: bool = false,
    revision: u32 = 0,
    published: ?Mark = null,

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.record.deinit(gpa);
    }

    fn mark(self: *const Entry) Mark {
        const text = self.record.streamedText() orelse "";
        return .{ .text_length = text.len, .work = self.record.work, .revision = self.revision };
    }
};

const Mark = struct {
    text_length: usize,
    work: ?Record.Work,
    revision: u32,
};

const Stream = struct {
    kind: Record.Kind,
    index: ?usize,
};

pub const Options = struct {
    id: ?u64 = null,
    survives_discard: bool = false,
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Transcript) void {
    for (self.list.items) |*entry| entry.deinit(self.gpa);
    self.list.deinit(self.gpa);
    self.held.deinit(self.gpa);
    self.removed.deinit(self.gpa);
}

pub fn entries(self: *const Transcript) []const Entry {
    return self.list.items;
}

pub fn allocateId(self: *Transcript) u64 {
    defer self.id_next += 1;
    return self.id_next;
}

pub fn append(self: *Transcript, source: *const Record.Source, options: Options) !void {
    self.endMessage();
    try self.reserve();
    var entry: Entry = .{
        .record = try .init(self.gpa, options.id orelse self.allocateId(), source),
        .survives_discard = options.survives_discard,
    };
    errdefer entry.deinit(self.gpa);
    self.list.appendAssumeCapacity(entry);
}

pub fn replaceEvent(self: *Transcript, index: usize, event: *const Record.Event) !void {
    const entry = &self.list.items[index];
    try entry.record.replaceEvent(self.gpa, event);
    entry.revision +%= 1;
    self.dirty_from = @min(self.dirty_from, index);
}

pub fn beginRun(self: *Transcript, kind: Record.Kind) void {
    self.current = .{ .kind = kind, .index = null };
    self.held.clearRetainingCapacity();
}

pub fn beginThinking(self: *Transcript, started_ms: i64) !usize {
    self.beginRun(.thinking);
    const index = try self.openRun(.thinking);
    self.current.?.index = index;
    self.list.items[index].record.work = .{ .started_ms = started_ms };
    return index;
}

pub fn closeWork(self: *Transcript, end: *const Record.Work.End) void {
    var index = self.list.items.len;
    while (index > 0) {
        index -= 1;
        const record = &self.list.items[index].record;
        if (record.content == .user) return;
        const work = if (record.work) |*work| work else continue;
        if (work.end == null) {
            work.end = end.*;
            self.dirty_from = @min(self.dirty_from, index);
        }
        return;
    }
}

pub fn runIndex(self: *const Transcript) ?usize {
    const run = self.current orelse return null;
    return run.index;
}

pub fn appendStream(self: *Transcript, kind: Record.Kind, delta: []const u8) !void {
    if (delta.len == 0) return;
    if (self.current == null or self.current.?.kind != kind) self.beginRun(kind);
    const run = &self.current.?;
    if (run.index == null) {
        if (std.mem.findNone(u8, delta, reference.blank_bytes) == null)
            return self.held.appendSlice(self.gpa, delta);
        run.index = try self.openRun(kind);
    }
    try self.list.items[run.index.?].record.appendText(self.gpa, delta);
    self.dirty_from = @min(self.dirty_from, run.index.?);
}

fn openRun(self: *Transcript, kind: Record.Kind) !usize {
    const source: Record.Source = switch (kind) {
        .thinking => .{ .thinking = self.held.items },
        .model => .{ .model = self.held.items },
        .user, .user_note, .tool_result, .event, .authorization => unreachable,
    };
    try self.reserve();
    var entry: Entry = .{ .record = try .init(self.gpa, self.allocateId(), &source) };
    errdefer entry.deinit(self.gpa);
    self.list.appendAssumeCapacity(entry);
    self.held.clearRetainingCapacity();
    return self.list.items.len - 1;
}

pub fn reserve(self: *Transcript) error{OutOfMemory}!void {
    const count = self.list.items.len + self.retained + 1;
    try self.list.ensureTotalCapacity(self.gpa, count);
    try self.removed.ensureTotalCapacity(self.gpa, count);
}

pub fn endMessage(self: *Transcript) void {
    self.current = null;
    self.held.clearRetainingCapacity();
}

pub fn truncate(self: *Transcript, count: usize) void {
    self.remove(.{ .start = count, .end = self.list.items.len });
}

pub fn remove(self: *Transcript, range: Range) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= self.list.items.len);
    self.endMessage();
    for (self.list.items[range.start..range.end]) |*entry| self.drop(entry);
    self.list.replaceRangeAssumeCapacity(range.start, range.end - range.start, &.{});
    self.dirty_from = @min(self.dirty_from, range.start);
}

pub fn clear(self: *Transcript) void {
    self.endMessage();
    for (self.list.items) |*entry| entry.deinit(self.gpa);
    self.list.clearRetainingCapacity();
    self.removed.clearRetainingCapacity();
    self.dirty_from = 0;
}

pub fn takeThinking(
    self: *Transcript,
    count: usize,
    held: *std.ArrayList(Entry),
) error{OutOfMemory}!void {
    const tail = self.list.items[count..];
    var thinking: usize = 0;
    for (tail) |*entry| thinking += @intFromBool(entry.record.content == .thinking);
    try held.ensureUnusedCapacity(self.gpa, thinking);
    self.retained += thinking;
    self.dirty_from = @min(self.dirty_from, count);
    for (tail) |*entry| {
        if (entry.record.content != .thinking) continue;
        self.unpublish(entry);
        held.appendAssumeCapacity(entry.*);
        entry.* = .{ .record = .{ .id = 0, .content = .{ .thinking = .empty } } };
    }
}

pub fn restoreThinking(self: *Transcript, held: *std.ArrayList(Entry)) void {
    self.list.appendSliceAssumeCapacity(held.items);
    self.retained -= held.items.len;
    held.clearRetainingCapacity();
}

pub fn discard(self: *Transcript, count: usize) void {
    std.debug.assert(count <= self.list.items.len);
    self.endMessage();
    var kept = count;
    for (self.list.items[count..]) |*entry| {
        if (entry.survives_discard) {
            self.list.items[kept] = entry.*;
            kept += 1;
        } else self.drop(entry);
    }
    self.list.shrinkRetainingCapacity(kept);
    self.dirty_from = @min(self.dirty_from, count);
}

fn drop(self: *Transcript, entry: *Entry) void {
    self.unpublish(entry);
    entry.deinit(self.gpa);
}

fn unpublish(self: *Transcript, entry: *Entry) void {
    if (entry.published == null) return;
    entry.published = null;
    self.removed.appendAssumeCapacity(entry.record.id);
}

pub fn writeAnswer(
    self: *const Transcript,
    start: usize,
    answer: *std.ArrayList(u8),
) error{OutOfMemory}!void {
    answer.clearRetainingCapacity();
    for (self.list.items[start..]) |*entry| {
        const text = switch (entry.record.content) {
            .model => |list| list.items,
            .user, .user_note, .thinking, .tool_result, .event, .authorization => continue,
        };
        if (answer.items.len > 0) try answer.appendSlice(self.gpa, "\n\n");
        try answer.appendSlice(self.gpa, text);
    }
}

pub fn flush(self: *Transcript, sink: Controller.Sink, io: std.Io) void {
    if (self.removed.items.len > 0) {
        sink.emit(io, &.{ .remove_records = self.removed.items });
        self.removed.clearRetainingCapacity();
    }
    for (self.list.items[self.dirty_from..]) |*entry| {
        const record = &entry.record;
        defer entry.published = entry.mark();
        const mark = entry.published orelse {
            sink.emit(io, &.{ .append_record = record.* });
            continue;
        };
        if (mark.revision != entry.revision or !std.meta.eql(mark.work, record.work)) {
            sink.emit(io, &.{ .replace_record = record.* });
            continue;
        }
        const text = record.streamedText() orelse continue;
        if (text.len > mark.text_length) sink.emit(io, &.{ .record_text = .{
            .id = record.id,
            .text = text[mark.text_length..],
        } });
    }
    self.dirty_from = self.list.items.len;
}

pub fn sync(self: *Transcript) void {
    for (self.list.items[self.dirty_from..]) |*entry| entry.published = entry.mark();
    self.dirty_from = self.list.items.len;
    self.removed.clearRetainingCapacity();
}

test "streamed deltas collect into one block until a discrete block ends the run" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "hel");
    try transcript.appendStream(.model, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries().len);
    try std.testing.expectEqualStrings("hello", textAt(&transcript, 0));

    try transcript.append(&.{ .user = "hi" }, .{});
    try transcript.appendStream(.model, "more");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries().len);
    try std.testing.expectEqualStrings("more", textAt(&transcript, 2));
}

fn textAt(transcript: *const Transcript, index: usize) []const u8 {
    return switch (transcript.entries()[index].record.content) {
        .user, .thinking, .model => |list| list.items,
        .event => |*event| event.choices_corrupt,
        .user_note, .tool_result, .authorization => unreachable,
    };
}

fn textEvent(text: []const u8) Record.Source {
    return .{ .event = .{ .choices_corrupt = text } };
}

test "an empty delta opens no block and does not break a run" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "");
    try transcript.appendStream(.model, "");
    try std.testing.expectEqual(@as(usize, 0), transcript.entries().len);

    try transcript.appendStream(.model, "he");
    try transcript.appendStream(.model, "");
    try transcript.appendStream(.model, "llo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries().len);
    try std.testing.expectEqualStrings("hello", textAt(&transcript, 0));
}

test "a run holds its whitespace until another byte opens the block" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "\n");
    try transcript.appendStream(.thinking, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), transcript.entries().len);

    try transcript.appendStream(.model, "answer");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries().len);
    try std.testing.expectEqualStrings("answer", textAt(&transcript, 0));

    transcript.endMessage();
    try transcript.appendStream(.thinking, "\n\n");
    try transcript.appendStream(.thinking, "weigh it");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries().len);
    try std.testing.expectEqualStrings("\n\nweigh it", textAt(&transcript, 1));

    transcript.endMessage();
    try transcript.appendStream(.model, " ");
    transcript.endMessage();
    try transcript.appendStream(.model, " ");
    transcript.endMessage();
    try transcript.appendStream(.model, "fresh");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries().len);
    try std.testing.expectEqualStrings("fresh", textAt(&transcript, 2));
}

test "endMessage and beginRun force the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "a");
    transcript.endMessage();
    try transcript.appendStream(.model, "b");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries().len);
    try std.testing.expectEqual(@as(?usize, 1), transcript.runIndex());

    transcript.beginRun(.model);
    try std.testing.expect(transcript.runIndex() == null);
    try transcript.appendStream(.model, "c");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries().len);
    try std.testing.expectEqual(@as(?usize, 2), transcript.runIndex());
    try std.testing.expectEqualStrings("c", textAt(&transcript, 2));
}

test "truncate removes optimistic tail blocks" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.append(&.{ .user = "keep" }, .{});
    try transcript.append(&.{ .user = "rollback" }, .{});
    transcript.truncate(1);
    try std.testing.expectEqual(@as(usize, 1), transcript.entries().len);
    try std.testing.expectEqualStrings("keep", textAt(&transcript, 0));
}

test "remove drops the blocks of its range and keeps the blocks around it" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.append(&.{ .user = "keep prompt" }, .{});
    try transcript.append(&.{ .user = "drop prompt" }, .{});
    try transcript.appendStream(.model, "drop reply");
    try transcript.append(&textEvent("drop retry"), .{ .survives_discard = true });
    try transcript.append(&textEvent("keep later event"), .{});
    transcript.remove(.{ .start = 1, .end = 4 });

    try std.testing.expectEqual(@as(usize, 2), transcript.entries().len);
    try std.testing.expectEqualStrings("keep prompt", textAt(&transcript, 0));
    try std.testing.expectEqualStrings("keep later event", textAt(&transcript, 1));
}

test "a discard preserves only marked events after its checkpoint" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.append(&textEvent("keep before checkpoint"), .{});
    try transcript.append(&.{ .user = "drop user prompt" }, .{});
    try transcript.append(&textEvent("keep retry"), .{ .survives_discard = true });
    try transcript.append(&textEvent("drop ordinary event"), .{});
    try transcript.appendStream(.model, "drop partial reply");
    transcript.discard(1);

    try std.testing.expectEqual(@as(usize, 2), transcript.entries().len);
    try std.testing.expectEqualStrings("keep before checkpoint", textAt(&transcript, 0));
    try std.testing.expectEqualStrings("keep retry", textAt(&transcript, 1));
}

test "reasoning collects into a thinking block that the answer run does not extend" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "weigh ");
    try transcript.appendStream(.thinking, "it");
    try transcript.appendStream(.model, "answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries().len);
    try std.testing.expectEqualStrings("weigh it", textAt(&transcript, 0));
    try std.testing.expectEqualStrings("answer", textAt(&transcript, 1));
}

test "a flush sends new records, added text, replacements, and removals by id once" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();
    var changes: Changes = .{};
    defer changes.deinit();

    try transcript.append(&textEvent("notice"), .{});
    try transcript.appendStream(.model, "hel");
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{ "append 1 notice", "append 2 hel" });

    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{});

    try transcript.appendStream(.model, "lo");
    const started = try transcript.beginThinking(5);
    try transcript.appendStream(.thinking, "weigh");
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{ "text 2 lo", "append 3 weigh" });

    transcript.closeWork(&.{ .time_ms = 9, .status = .complete });
    try transcript.replaceEvent(0, &.{ .choices_corrupt = "edited" });
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{ "replace 1 edited", "replace 3 weigh" });
    try std.testing.expectEqual(@as(usize, 2), started);

    transcript.remove(.{ .start = 1, .end = 3 });
    try transcript.append(&textEvent("later"), .{});
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{ "remove 2 3", "append 4 later" });
}

test "discarded thinking leaves the published records and returns with its id" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();
    var changes: Changes = .{};
    defer changes.deinit();
    var held: std.ArrayList(Transcript.Entry) = .empty;
    defer {
        for (held.items) |*entry| entry.deinit(gpa);
        held.deinit(gpa);
    }

    try transcript.append(&.{ .user = "prompt" }, .{});
    _ = try transcript.beginThinking(1);
    try transcript.appendStream(.thinking, "weigh");
    try transcript.appendStream(.model, "partial");
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{ "append 1 prompt", "append 2 weigh", "append 3 partial" });

    try transcript.takeThinking(1, &held);
    transcript.discard(1);
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{"remove 2 3"});

    transcript.restoreThinking(&held);
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{"append 2 weigh"});
}

test "a cleared transcript sends no removal, and a synced transcript sends nothing" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();
    var changes: Changes = .{};
    defer changes.deinit();

    try transcript.append(&.{ .user = "prompt" }, .{});
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{"append 1 prompt"});
    transcript.clear();
    try transcript.append(&.{ .user = "fresh" }, .{});
    transcript.sync();
    transcript.flush(changes.sink(), std.testing.io);
    try changes.expect(&.{});
}

const Changes = struct {
    lines: std.ArrayList([]u8) = .empty,

    const vtable: Controller.Sink.VTable = .{ .emit = emit };

    fn sink(self: *Changes) Controller.Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *Changes) void {
        for (self.lines.items) |line| std.testing.allocator.free(line);
        self.lines.deinit(std.testing.allocator);
    }

    fn emit(ptr: *anyopaque, event: *const Controller.Event) void {
        const self: *Changes = @ptrCast(@alignCast(ptr));
        const gpa = std.testing.allocator;
        const line = switch (event.*) {
            .append_record => |*record| print("append", record),
            .replace_record => |*record| print("replace", record),
            .record_text => |text| gpa.print("text {d} {s}", .{ text.id, text.text }),
            .remove_records => |ids| removal: {
                var line: std.Io.Writer.Allocating = .init(gpa);
                defer line.deinit();
                line.writer.writeAll("remove") catch unreachable;
                for (ids) |id| line.writer.print(" {d}", .{id}) catch unreachable;
                break :removal gpa.dupe(u8, line.written());
            },
            .snapshot,
            .live,
            .statistics,
            .state,
            .clear_conversation,
            .paste_replayed,
            .turn_ended,
            .sign_in_ended,
            .fetch_ended,
            .no_account,
            .charge,
            .startup_refused,
            => unreachable,
        } catch unreachable;
        self.lines.append(gpa, line) catch unreachable;
    }

    fn print(comptime verb: []const u8, record: *const Record) error{OutOfMemory}![]u8 {
        const text = switch (record.content) {
            .user, .thinking, .model => |list| list.items,
            .event => |*event| event.choices_corrupt,
            .user_note, .tool_result, .authorization => unreachable,
        };
        return std.testing.allocator.print(verb ++ " {d} {s}", .{ record.id, text });
    }

    fn expect(self: *Changes, expected: []const []const u8) !void {
        defer {
            for (self.lines.items) |line| std.testing.allocator.free(line);
            self.lines.clearRetainingCapacity();
        }
        try std.testing.expectEqual(expected.len, self.lines.items.len);
        for (expected, self.lines.items) |line, actual|
            try std.testing.expectEqualStrings(line, actual);
    }
};
