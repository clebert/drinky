const std = @import("std");

const terminal = @import("terminal");

const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const Editor = @This();

gpa: std.mem.Allocator,
draft: Draft,
caret: usize,
window: paint.Window,
goal_column: ?usize,
paste_id_next: u64,
capture: std.ArrayList(u8),

const Draft = struct {
    visible: std.ArrayList(u8),
    atoms: std.ArrayList(Atom),

    const empty: Draft = .{ .visible = .empty, .atoms = .empty };

    const Atom = struct {
        start: usize,
        end: usize,
        payload: []u8,
    };

    fn deinit(self: *Draft, gpa: std.mem.Allocator) void {
        for (self.atoms.items) |atom| gpa.free(atom.payload);
        self.atoms.deinit(gpa);
        self.visible.deinit(gpa);
    }

    fn clear(self: *Draft, gpa: std.mem.Allocator) void {
        for (self.atoms.items) |atom| gpa.free(atom.payload);
        self.atoms.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
    }

    fn expanded(self: *const Draft, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacityPrecise(gpa, try self.expandedLen());
        var position: usize = 0;
        for (self.atoms.items) |atom| {
            out.appendSliceAssumeCapacity(self.visible.items[position..atom.start]);
            out.appendSliceAssumeCapacity(atom.payload);
            position = atom.end;
        }
        out.appendSliceAssumeCapacity(self.visible.items[position..]);
        const trimmed = std.mem.trim(u8, out.items, paint.blank_bytes);
        std.mem.copyForwards(u8, out.items, trimmed);
        out.items.len = trimmed.len;
        return out.toOwnedSlice(gpa);
    }

    fn blank(self: *const Draft) bool {
        var position: usize = 0;
        for (self.atoms.items) |atom| {
            if (!paint.isBlank(self.visible.items[position..atom.start])) return false;
            if (!paint.isBlank(atom.payload)) return false;
            position = atom.end;
        }
        return paint.isBlank(self.visible.items[position..]);
    }

    fn expandedLen(self: *const Draft) !usize {
        var total: usize = self.visible.items.len;
        for (self.atoms.items) |atom| {
            total = try std.math.sub(usize, total, atom.end - atom.start);
            total = try std.math.add(usize, total, atom.payload.len);
        }
        return total;
    }
};

const Splice = struct {
    from: usize,
    to: usize,
    bytes: []const u8 = "",
    new_atoms: []const Draft.Atom = &.{},
};

const line_count_max = 10;
const byte_count_max = 1000;
const marker_role: role.Name = .accent;
const digits_max = std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1;
const label_len_max = 2 * terminal.width.grapheme_boundary.len + "[Paste #".len + digits_max +
    ": ".len + digits_max + " lines]".len;

const LogicalCaret = struct { row: usize, column: usize };

const WrappedRow = struct { columns: usize, row: usize };

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{
        .gpa = gpa,
        .draft = .empty,
        .caret = 0,
        .window = .{},
        .goal_column = null,
        .paste_id_next = 1,
        .capture = .empty,
    };
}

pub fn deinit(self: *Editor) void {
    self.draft.deinit(self.gpa);
    self.capture.deinit(self.gpa);
}

pub fn visible(self: *const Editor) []const u8 {
    return self.draft.visible.items;
}

pub fn expanded(self: *const Editor) ![]u8 {
    return self.draft.expanded(self.gpa);
}

pub fn blank(self: *const Editor) bool {
    return self.draft.blank();
}

pub fn clear(self: *Editor) void {
    self.draft.clear(self.gpa);
    self.capture.clearRetainingCapacity();
    self.caret = 0;
    self.window = .{};
    self.goal_column = null;
}

pub fn paste(self: *Editor, bytes: []const u8, final: bool) !void {
    errdefer self.capture.clearRetainingCapacity();
    try self.capture.appendSlice(self.gpa, bytes);
    if (!final) return;
    try self.finalizePaste();
    self.capture.clearRetainingCapacity();
}

fn finalizePaste(self: *Editor) !void {
    const bytes = self.capture.items;
    if (bytes.len == 0) return;
    const line_count = 1 + std.mem.count(u8, bytes, "\n");
    if (line_count <= line_count_max and bytes.len <= byte_count_max) {
        try self.splice(&.{ .from = self.caret, .to = self.caret, .bytes = bytes });
        return;
    }
    if (self.paste_id_next == std.math.maxInt(u64)) return error.PasteIdExhausted;
    const id = self.paste_id_next;
    var buffer: [label_len_max]u8 = undefined;
    const span = markerSpan(&buffer, &.{
        .id = id,
        .line_count = line_count,
        .byte_count = bytes.len,
    });
    try self.draft.visible.ensureUnusedCapacity(self.gpa, span.len);
    try self.draft.atoms.ensureUnusedCapacity(self.gpa, 1);
    const payload = try self.capture.toOwnedSlice(self.gpa);
    errdefer self.gpa.free(payload);
    try self.splice(&.{
        .from = self.caret,
        .to = self.caret,
        .bytes = span,
        .new_atoms = &.{.{ .start = 0, .end = span.len, .payload = payload }},
    });
    self.paste_id_next += 1;
}

fn markerSpan(
    buffer: []u8,
    marker: *const struct { id: u64, line_count: usize, byte_count: usize },
) []const u8 {
    if (marker.line_count > line_count_max) {
        const form = terminal.width.grapheme_boundary ++ "[Paste #{d}: {d} lines]" ++
            terminal.width.grapheme_boundary;
        return std.fmt.bufPrint(buffer, form, .{ marker.id, marker.line_count }) catch unreachable;
    }
    const form = terminal.width.grapheme_boundary ++ "[Paste #{d}: {d} bytes]" ++
        terminal.width.grapheme_boundary;
    return std.fmt.bufPrint(buffer, form, .{ marker.id, marker.byte_count }) catch unreachable;
}

pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
    try self.insert(buffer[0..length]);
}

pub fn insert(self: *Editor, bytes: []const u8) !void {
    try self.splice(&.{ .from = self.caret, .to = self.caret, .bytes = bytes });
}

pub fn prependText(self: *Editor, text: []const u8) !void {
    if (text.len == 0) return;
    if (self.blank()) {
        self.clear();
        return self.insert(text);
    }
    const extra = try std.math.add(usize, text.len, "\n".len);
    try self.draft.visible.ensureUnusedCapacity(self.gpa, extra);
    self.splice(&.{ .from = 0, .to = 0, .bytes = "\n" }) catch unreachable;
    self.splice(&.{ .from = 0, .to = 0, .bytes = text }) catch unreachable;
}

fn splice(self: *Editor, edit: *const Splice) !void {
    const visible_list = &self.draft.visible;
    const atoms = &self.draft.atoms;
    std.debug.assert(edit.from <= edit.to);
    std.debug.assert(edit.to <= visible_list.items.len);

    var remove_from: usize = atoms.items.len;
    var remove_to: usize = atoms.items.len;
    for (atoms.items, 0..) |atom, index| {
        if (edit.to <= atom.start or edit.from >= atom.end) continue;
        if (edit.from > atom.start or atom.end > edit.to) return error.PasteAtomSplit;
        remove_from = @min(remove_from, index);
        remove_to = index + 1;
    }

    const removed = edit.to - edit.from;
    const shifted_len = try std.math.add(usize, visible_list.items.len - removed, edit.bytes.len);
    try visible_list.ensureTotalCapacity(self.gpa, shifted_len);
    try atoms.ensureUnusedCapacity(self.gpa, edit.new_atoms.len);

    for (atoms.items[remove_from..remove_to]) |atom| self.gpa.free(atom.payload);
    atoms.replaceRangeAssumeCapacity(remove_from, remove_to - remove_from, &.{});
    visible_list.replaceRangeAssumeCapacity(edit.from, edit.to - edit.from, edit.bytes);
    for (atoms.items) |*atom| {
        if (atom.start >= edit.to) {
            atom.start = atom.start - removed + edit.bytes.len;
            atom.end = atom.end - removed + edit.bytes.len;
        }
    }
    var insert_index = atomIndexAfter(atoms.items, edit.from);
    for (edit.new_atoms) |atom| {
        atoms.insertAssumeCapacity(insert_index, .{
            .start = edit.from + atom.start,
            .end = edit.from + atom.end,
            .payload = atom.payload,
        });
        insert_index += 1;
    }
    self.goal_column = null;
    if (self.caret >= edit.to) {
        self.caret = self.caret - removed + edit.bytes.len;
    } else if (self.caret > edit.from) {
        self.caret = edit.from + edit.bytes.len;
    }
    self.caret = terminal.width.boundaryAtOrAfter(visible_list.items, self.caret);
}

fn atomStartingAt(self: *const Editor, offset: usize) ?Draft.Atom {
    for (self.draft.atoms.items) |atom| if (atom.start == offset) return atom;
    return null;
}

fn atomEndingAt(self: *const Editor, offset: usize) ?Draft.Atom {
    for (self.draft.atoms.items) |atom| if (atom.end == offset) return atom;
    return null;
}

fn atomIndexAfter(atoms: []const Draft.Atom, offset: usize) usize {
    var index: usize = 0;
    while (index < atoms.len and atoms[index].end <= offset) index += 1;
    return index;
}

pub fn backspace(self: *Editor) void {
    if (self.caret == 0) return;
    if (self.atomEndingAt(self.caret)) |atom| {
        self.splice(&.{ .from = atom.start, .to = atom.end }) catch unreachable;
        return;
    }
    const previous = terminal.width.boundaryBefore(self.draft.visible.items, self.caret);
    self.splice(&.{ .from = previous, .to = self.caret }) catch unreachable;
}

pub fn moveLeft(self: *Editor) void {
    self.goal_column = null;
    if (self.caret == 0) return;
    if (self.atomEndingAt(self.caret)) |atom| {
        self.caret = atom.start;
        return;
    }
    self.caret = terminal.width.boundaryBefore(self.draft.visible.items, self.caret);
}

pub fn moveRight(self: *Editor) void {
    self.goal_column = null;
    if (self.caret >= self.draft.visible.items.len) return;
    if (self.atomStartingAt(self.caret)) |atom| {
        self.caret = atom.end;
        return;
    }
    self.caret = terminal.width.boundaryAfter(self.draft.visible.items, self.caret);
}

pub fn moveHome(self: *Editor) void {
    self.goal_column = null;
    self.caret = 0;
}

pub fn moveEnd(self: *Editor) void {
    self.goal_column = null;
    self.caret = self.draft.visible.items.len;
}

pub fn moveUp(self: *Editor, columns: usize) void {
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns,
    }).row;
    if (row == 0) {
        self.moveHome();
        return;
    }
    const goal = self.goal_column orelse self.logicalColumn(.{ .columns = columns, .row = row });
    self.goal_column = goal;
    var result = self.logicalOffset(columns, .{ .row = row - 1, .column = goal });
    if (result >= self.caret) {
        if (self.atomEndingAt(self.caret)) |atom| result = atom.start;
    }
    self.caret = result;
    std.debug.assert(self.legalCaret(self.caret));
}

pub fn moveDown(self: *Editor, columns: usize) void {
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns,
    }).row;
    if (row + 1 >= terminal.width.rows(text, columns)) {
        self.moveEnd();
        return;
    }
    const goal = self.goal_column orelse self.logicalColumn(.{ .columns = columns, .row = row });
    self.goal_column = goal;
    self.caret = self.logicalOffset(columns, .{ .row = row + 1, .column = goal });
    std.debug.assert(self.legalCaret(self.caret));
}

fn wrappedSpan(self: *const Editor, wrapped: WrappedRow) ?terminal.width.Wrapper.Span {
    var iterator = terminal.width.wrapper(self.draft.visible.items, wrapped.columns);
    var current: usize = 0;
    while (iterator.nextSpan()) |span| : (current += 1) {
        if (current == wrapped.row) return span;
    }
    return null;
}

fn logicalColumn(self: *const Editor, wrapped: WrappedRow) usize {
    const text = self.draft.visible.items;
    const span = self.wrappedSpan(wrapped) orelse return 0;
    var column: usize = 0;
    var index = self.legalAtOrAfter(span.start);
    while (index < self.caret) {
        if (self.atomStartingAt(index)) |atom| {
            column += 1;
            index = atom.end;
        } else {
            const next = terminal.width.boundaryAfter(text, index);
            column += terminal.width.ofText(text[index..next]);
            index = next;
        }
    }
    return column;
}

fn logicalOffset(self: *const Editor, columns: usize, target: LogicalCaret) usize {
    const text = self.draft.visible.items;
    const span = self.wrappedSpan(.{
        .columns = columns,
        .row = target.row,
    }) orelse return text.len;
    const end = terminal.width.caretEnd(text, span, columns);
    var index = self.legalAtOrAfter(span.start);
    var logical: usize = 0;
    while (index < end and logical < target.column) {
        if (self.atomStartingAt(index)) |atom| {
            logical += 1;
            index = atom.end;
        } else {
            const next = terminal.width.boundaryAfter(text, index);
            const unit = terminal.width.ofText(text[index..next]);
            if (logical + unit > target.column) break;
            logical += unit;
            index = next;
        }
    }
    return index;
}

fn legalAtOrAfter(self: *const Editor, offset: usize) usize {
    for (self.draft.atoms.items) |atom| {
        if (atom.start < offset and offset < atom.end) return atom.end;
    }
    return offset;
}

fn legalCaret(self: *const Editor, offset: usize) bool {
    const text = self.draft.visible.items;
    if (terminal.width.boundaryAtOrAfter(text, offset) != offset) return false;
    for (self.draft.atoms.items) |atom| {
        if (atom.start < offset and offset < atom.end) return false;
    }
    return true;
}

pub fn reflow(self: *Editor, size: terminal.View.Size) void {
    const caret_row = terminal.width.caret(self.draft.visible.items, .{
        .offset = self.caret,
        .columns_max = size.columns,
    }).row;
    self.window.follow(self.extent(size), caret_row);
}

pub fn rows(self: *const Editor, size: terminal.View.Size) usize {
    return self.extent(size).rows();
}

fn extent(self: *const Editor, size: terminal.View.Size) paint.Window.Extent {
    const text = self.draft.visible.items;
    const wrapped = terminal.width.rows(text, size.columns);
    const caret_row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = size.columns,
    }).row;
    return .{
        .body_rows = wrapped + @intFromBool(caret_row == wrapped),
        .viewport_rows = size.rows,
    };
}

pub fn render(
    self: *const Editor,
    placement: *const paint.Placement,
    options: *const paint.RenderOptions,
) !void {
    const text = self.draft.visible.items;
    const body = self.extent(.{ .columns = placement.columns, .rows = options.viewport_rows });
    const shown = self.window.shown(body);
    const atoms = self.draft.atoms.items;
    const marks = try self.gpa.alloc(paint.Mark, atoms.len);
    defer self.gpa.free(marks);
    for (marks, atoms) |*mark, atom|
        mark.* = .{ .start = atom.start, .end = atom.end, .role = marker_role };
    try paint.framed(placement, &.{
        .body = text,
        .body_rows = shown.body_rows,
        .caret = self.caretPosition(placement.columns),
        .hidden_above = shown.hidden_above,
        .hidden_below = shown.hidden_below,
        .trailing_row = body.body_rows > terminal.width.rows(text, placement.columns),
        .marks = marks,
        .activity = options.activity,
    });
}

fn caretPosition(self: *const Editor, columns: usize) terminal.View.Caret {
    const position = terminal.width.caret(self.draft.visible.items, .{
        .offset = self.caret,
        .columns_max = columns,
    });
    return .{
        .row = 1 + (position.row - self.window.scroll),
        .column = position.column,
    };
}

test "caret movement and backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abc");
    editor.moveLeft();
    try editor.insertCodepoint('X');
    try std.testing.expectEqualStrings("abXc", editor.visible());
    editor.backspace();
    try std.testing.expectEqualStrings("abc", editor.visible());
    editor.moveHome();
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    editor.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

fn moveCaretTo(editor: *Editor, offset: usize) !void {
    for (0..editor.visible().len) |_| editor.moveLeft();
    for (0..editor.visible().len) |_| {
        if (editor.caret == offset) return;
        editor.moveRight();
    }
    if (editor.caret != offset) return error.TestCaretUnreachable;
}

test "malformed bytes and controls move by displayed units" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\xf0\x9f");
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveEnd();
    editor.backspace();
    try std.testing.expectEqualStrings("\xf0", editor.visible());

    editor.clear();
    try editor.insert("\r\n");
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);

    editor.clear();
    try editor.insert("e\r\u{0301}");
    editor.moveLeft();
    editor.backspace();
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(editor.visible().len, editor.caret);

    editor.clear();
    try editor.insert("\xc3\xff\xa9");
    editor.moveLeft();
    editor.backspace();
    try std.testing.expectEqualStrings("é", editor.visible());
    try std.testing.expectEqual(editor.visible().len, editor.caret);
}

test "backspace deletes a whole grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("👍\u{1F3FD}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    try editor.insert("e\u{0301}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    try editor.insert("🇯🇵");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    try editor.insert("👨\u{200D}👩\u{200D}👧\u{200D}👦");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
}

test "backspace peels one cluster at a time and leaves neighbours intact" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a👍\u{1F3FD}b");
    editor.backspace();
    try std.testing.expectEqualStrings("a👍\u{1F3FD}", editor.visible());
    editor.backspace();
    try std.testing.expectEqualStrings("a", editor.visible());
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
}

test "insert keeps the caret on a cluster boundary when text fuses" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\u{0301}");
    editor.moveHome();
    try editor.insert("e");
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    try editor.insert("🇵");
    editor.moveHome();
    try editor.insert("🇯");
    try std.testing.expectEqualStrings("🇯🇵", editor.visible());
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
}

test "left and right move by whole grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a👍\u{1F3FD}b");
    try std.testing.expectEqual(@as(usize, 10), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 10), editor.caret);
}

fn pasteWhole(editor: *Editor, payload: []const u8) !void {
    try editor.paste(payload, true);
}

fn expectExpanded(editor: *const Editor, expected: []const u8) !void {
    const text = try editor.expanded();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

const eleven_lines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk";
const ten_lines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj";

test "the line threshold collapses more than ten logical lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, ten_lines);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(ten_lines, editor.visible());

    editor.clear();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, eleven_lines);

    editor.clear();
    try pasteWhole(&editor, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[Paste #2: 11 lines]\u{200B}", editor.visible());
}

test "the byte threshold collapses more than a thousand bytes" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const long = "x" ** 1000;
    try pasteWhole(&editor, long);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(long, editor.visible());

    editor.clear();
    const longer = "x" ** 1001;
    try pasteWhole(&editor, longer);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 1001 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, longer);
}

test "the byte threshold counts bytes, not characters" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const multibyte = "é" ** 501;
    try pasteWhole(&editor, multibyte);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 1002 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, multibyte);

    editor.clear();
    const malformed = "\xff" ** 1001;
    try pasteWhole(&editor, malformed);
    try std.testing.expectEqualStrings("\u{200B}[Paste #2: 1001 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, malformed);
}

test "a lone CR is payload, and CRLF counts one line" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, "x\r" ** 11);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);

    editor.clear();
    const crlf = "x\r\n" ** 11;
    try pasteWhole(&editor, crlf);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 12 lines]\u{200B}", editor.visible());
    try editor.insert(">");
    try expectExpanded(&editor, crlf ++ ">");
}

test "the line form wins when both thresholds are crossed" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const big = ("x" ** 100 ++ "\n") ** 10 ++ "x" ** 100;
    try pasteWhole(&editor, big);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, big);
}

test "an empty paste is a no-op" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, "");
    try std.testing.expectEqualStrings("", editor.visible());
    try std.testing.expectEqual(@as(u64, 1), editor.paste_id_next);
}

test "a paste split across chunks collapses to one atom" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.paste("a\nb\nc\n", false);
    try editor.paste("d\ne\nf\n", false);
    try editor.paste("g\nh\ni\n", false);
    try editor.paste("j\nk", true);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, eleven_lines);
}

test "multiple atoms mixed with ordinary text expand in document order" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("A");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("B");
    try pasteWhole(&editor, "z" ** 1001);
    try editor.insert("C");
    try std.testing.expectEqual(@as(usize, 2), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(
        "A\u{200B}[Paste #1: 11 lines]\u{200B}B\u{200B}[Paste #2: 1001 bytes]\u{200B}C",
        editor.visible(),
    );
    try expectExpanded(&editor, "A" ++ eleven_lines ++ "B" ++ "z" ** 1001 ++ "C");
}

test "arbitrary payload bytes round-trip through expansion exactly" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const payload =
        "tab\tesc\x1b bad\xff\xfe text [paste #99 +5 lines] literal\n" ** 40;
    try pasteWhole(&editor, payload);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try editor.insert(">");
    try expectExpanded(&editor, payload ++ ">");
}

test "a typed marker-looking string stays literal and never expands" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const typed = "[paste #1 +11 lines]";
    try editor.insert(typed);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(typed, editor.visible());
    try expectExpanded(&editor, typed);
    editor.moveEnd();
    editor.backspace();
    try std.testing.expectEqualStrings("[paste #1 +11 lines", editor.visible());
}

test "paste IDs are stable across deletion and never reused" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("mid");
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqualStrings(
        comptime elevenLinesMarker(1) ++ "mid" ++ elevenLinesMarker(2),
        editor.visible(),
    );

    editor.moveHome();
    editor.moveRight();
    editor.backspace();
    try std.testing.expectEqualStrings(comptime "mid" ++ elevenLinesMarker(2), editor.visible());

    editor.moveEnd();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqualStrings(
        comptime "mid" ++ elevenLinesMarker(2) ++ elevenLinesMarker(3),
        editor.visible(),
    );

    editor.clear();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqualStrings(elevenLinesMarker(4), editor.visible());
}

fn elevenLinesMarker(comptime id: u64) []const u8 {
    return std.fmt.comptimePrint("\u{200B}[Paste #{d}: 11 lines]\u{200B}", .{id});
}

test "counter exhaustion leaves the draft unchanged" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("keep");
    editor.paste_id_next = std.math.maxInt(u64);
    try std.testing.expectError(error.PasteIdExhausted, editor.paste(eleven_lines, true));
    try std.testing.expectEqualStrings("keep", editor.visible());
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 4), editor.caret);
}

test "left and right cross a marker in one step" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];
    try std.testing.expectEqual(@as(usize, 2), atom.start);

    editor.moveHome();
    editor.moveRight();
    editor.moveRight();
    try std.testing.expectEqual(atom.start, editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(atom.end, editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(atom.start, editor.caret);
}

test "backspace deletes a whole marker and leaves neighbours intact" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    editor.moveLeft();
    editor.moveLeft();
    try std.testing.expectEqual(editor.draft.atoms.items[0].end, editor.caret);
    editor.backspace();
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("abcd", editor.visible());
    try expectExpanded(&editor, "abcd");
}

test "inserting on either edge of a marker shifts its range" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const span_len = editor.draft.atoms.items[0].end;

    editor.moveHome();
    try editor.insert("<");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items[0].start);
    try std.testing.expectEqual(span_len + 1, editor.draft.atoms.items[0].end);

    editor.moveEnd();
    try editor.insert(">");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items[0].start);
    try std.testing.expectEqual(span_len + 1, editor.draft.atoms.items[0].end);
    try expectExpanded(&editor, "<" ++ eleven_lines ++ ">");
}

test "deleting a marker between combining text re-clamps the boundary" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("e");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\u{0301}");
    editor.moveLeft();
    try std.testing.expectEqual(editor.draft.atoms.items[0].end, editor.caret);
    editor.backspace();
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(editor.visible().len, editor.caret);
    try expectExpanded(&editor, "e\u{0301}");
}

test "marker guards keep both edges legal between combining marks" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\u{0301}");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\u{0301}");
    const atom = editor.draft.atoms.items[0];
    editor.moveLeft();
    try std.testing.expectEqual(atom.end, editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(atom.start, editor.caret);
    try expectExpanded(&editor, "\u{0301}" ++ eleven_lines ++ "\u{0301}");
}

test "vertical movement counts a marker as one logical column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abc\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\ndef");
    const atom = editor.draft.atoms.items[0];

    try moveCaretTo(&editor, 2);
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);
    try std.testing.expectEqual(@as(?usize, 2), editor.goal_column);

    try moveCaretTo(&editor, editor.visible().len - 1);
    editor.moveUp(80);
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "vertical movement lands in the text after a leading marker" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("This\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert(" foo");
    const atom = editor.draft.atoms.items[0];

    try moveCaretTo(&editor, 4);
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end + 3, editor.caret);
    try std.testing.expectEqualStrings(" fo", editor.visible()[atom.end .. atom.end + 3]);
}

test "vertical movement departs a row-leading marker as one column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    try moveCaretTo(&editor, atom.end);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);

    try moveCaretTo(&editor, 1);
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "vertical movement treats a mid-line marker as one column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("xxxxxxxx\nab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    try moveCaretTo(&editor, 3);
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);

    editor.moveHome();
    try moveCaretTo(&editor, 4);
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end + 1, editor.caret);
}

test "repeated vertical steps cross a marker wider than the terminal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    try moveCaretTo(&editor, 1);
    var reached_end = false;
    for (0..8) |_| {
        editor.moveDown(5);
        try std.testing.expect(editor.caret <= atom.start or editor.caret >= atom.end);
        if (editor.caret == atom.end) reached_end = true;
    }
    try std.testing.expect(reached_end);
}

test "repeated vertical steps climb above a marker wider than the terminal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    editor.moveEnd();
    var reached_start = false;
    for (0..8) |_| {
        editor.moveUp(5);
        try std.testing.expect(editor.caret <= atom.start or editor.caret >= atom.end);
        if (editor.caret == atom.start) reached_start = true;
    }
    try std.testing.expect(reached_start);
}

test "vertical movement stops before a wide grapheme that the goal column splits" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab\n\u{4F60}c");
    try moveCaretTo(&editor, 1);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "a marker wider than the terminal wraps but stays one atom" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const atom = editor.draft.atoms.items[0];
    try std.testing.expect(terminal.width.rows(editor.visible(), 5) > 1);
    editor.moveHome();
    editor.moveRight();
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "the caret between two markers shows on its row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\nmiddle\n");
    try pasteWhole(&editor, eleven_lines);
    try moveCaretTo(&editor, editor.draft.atoms.items[0].end + 4);
    const size: terminal.View.Size = .{ .columns = 80, .rows = 20 };
    editor.reflow(size);
    try expectCaretAt(&editor, size, .{ .row = 2, .column = 3 });
}

test "marker guards are zero-column and absent from expanded output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(usize, 20), terminal.width.ofText(editor.visible()));
    const text = try editor.expanded();
    defer std.testing.allocator.free(text);
    try testing.expectHides(text, &.{terminal.width.grapheme_boundary});
    try std.testing.expectEqualStrings(eleven_lines, text);
}

test "expanded whole-prompt trimming matches literal trimming, guards aside" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("  ");
    try pasteWhole(&editor, "  " ++ "y" ** 1001 ++ "  ");
    try editor.insert("  ");
    try expectExpanded(&editor, "y" ** 1001);
    try std.testing.expect(!editor.blank());
}

test "a placeholder-only prompt is nonblank and sends its payload" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expect(!editor.blank());
    const text = try editor.expanded();
    defer std.testing.allocator.free(text);
    try std.testing.expect(editor.blank() == (text.len == 0));
    try std.testing.expectEqualStrings(eleven_lines, text);

    editor.clear();
    try pasteWhole(&editor, " " ** 1001);
    try std.testing.expect(editor.blank());
}

test "an expanded send copy is independent of clearing the editor" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("A");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("B");
    const text = try editor.expanded();
    defer std.testing.allocator.free(text);
    editor.clear();
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("A" ++ eleven_lines ++ "B", text);
}

test "large-paste allocation failures leave the editor usable and leak nothing" {
    const fail_index_max = 40;
    var fail_index: usize = 0;
    while (fail_index < fail_index_max) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const gpa = failing.allocator();
        var editor = Editor.init(gpa);
        defer editor.deinit();
        editor.insert("keep") catch continue;
        editor.paste(eleven_lines, true) catch {
            try std.testing.expectEqualStrings("keep", editor.visible());
            try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
        break;
    }
    try std.testing.expect(fail_index < fail_index_max);
}

test render {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("hi");
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, .{ .columns = 80, .rows = 24 }, .{ .row = 1, .column = 2 });

    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"hi"});
    try testing.expectShows(painted, &.{"─"});
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘" }) |glyph|
        try testing.expectHides(painted, &.{glyph});
    try testing.expectHides(painted, &.{"━"});
    try testing.expectShows(painted, &.{terminal.escape.cursor_show});
}

test "a marker renders its label into the input area" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"[Paste #1: 11 lines]"});
}

test "a marker paints in the accent role between plain text" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("ab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd [Paste #2: 1 lines]");
    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    const row = comptime "ab" ++ role.sequence(.accent) ++ "\u{200B}[Paste #1: 11 lines]\u{200B}" ++
        "\x1b[0mcd [Paste #2: 1 lines]\r\n";
    try testing.expectShows(painted, &.{row});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, role.sequence(.accent)));
}

test "a full-width line reserves an empty trailing row for the wrapped caret" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("abc");
    editor.reflow(.{ .columns = 3, .rows = 24 });

    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, .{ .columns = 3, .rows = 24 }, .{ .row = 2, .column = 0 });
    try std.testing.expectEqual(@as(usize, 4), try renderedRows(gpa, &editor, 3));

    editor.moveLeft();
    editor.reflow(.{ .columns = 3, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, .{ .columns = 3, .rows = 24 }, .{ .row = 1, .column = 2 });
    try std.testing.expectEqual(@as(usize, 3), try renderedRows(gpa, &editor, 3));
}

test "an open input preserves a wide grapheme without side glyphs" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("你");

    const size: terminal.View.Size = .{ .columns = 3, .rows = 24 };
    editor.reflow(size);
    try std.testing.expectEqual(@as(usize, 3), editor.rows(size));
    try expectCaretAt(&editor, size, .{ .row = 1, .column = 2 });
    const painted = try rendered(gpa, &editor, size);
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"你"});
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘" }) |glyph|
        try testing.expectHides(painted, &.{glyph});
}

test "a wrapped input row paints no trailing blank" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("aaa bbbb");

    const size: terminal.View.Size = .{ .columns = 5, .rows = 24 };
    editor.reflow(size);
    const painted = try rendered(gpa, &editor, size);
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"\r\naaa\r\nbbbb\r\n"});
}

test "activity crosses the frame edges without changing the editor height" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("hi");
    const size: terminal.View.Size = .{ .columns = 40, .rows = 24 };

    const first = try renderedWithOptions(gpa, &editor, size, &.{
        .viewport_rows = size.rows,
        .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
    });
    defer gpa.free(first);
    const second = try renderedWithOptions(gpa, &editor, size, &.{
        .viewport_rows = size.rows,
        .activity = .{ .motion_tick = 3, .progress_age_ticks = 0 },
    });
    defer gpa.free(second);

    for ([_][]const u8{ "╼", "━", "╾" }) |glyph|
        try testing.expectShows(first, &.{glyph});
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘", "┃" }) |glyph|
        try testing.expectHides(first, &.{glyph});
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqual(
        std.mem.count(u8, first, "\r\n"),
        std.mem.count(u8, second, "\r\n"),
    );
}

fn rendered(gpa: std.mem.Allocator, editor: *const Editor, size: terminal.View.Size) ![]u8 {
    return renderedWithOptions(gpa, editor, size, &.{ .viewport_rows = size.rows });
}

fn renderedWithOptions(
    gpa: std.mem.Allocator,
    editor: *const Editor,
    size: terminal.View.Size,
    options: *const paint.RenderOptions,
) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = size.columns, .rows = size.rows, .pages = 4 });
    try editor.render(&placement, options);
    return gpa.dupe(u8, try rig.painted());
}

fn renderedRows(gpa: std.mem.Allocator, editor: *const Editor, columns: usize) !usize {
    const painted = try rendered(gpa, editor, .{ .columns = columns, .rows = 24 });
    defer gpa.free(painted);
    return testing.paintedRows(painted);
}

fn expectCaretAt(
    editor: *const Editor,
    size: terminal.View.Size,
    expected: terminal.View.Caret,
) !void {
    const gpa = std.testing.allocator;
    const painted = try rendered(gpa, editor, size);
    defer gpa.free(painted);
    var emulator: terminal.testing.Emulator = try .init(gpa, size.columns);
    defer emulator.deinit();
    try emulator.feed(painted);
    try emulator.expectCaret(&.{
        .frame_len = editor.rows(size),
        .row = expected.row,
        .column = expected.column,
    });
}

test "caret sits on the empty row after a trailing newline" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n");
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, .{ .columns = 80, .rows = 24 }, .{ .row = 2, .column = 0 });
}

test "caret occupies a blank row between two newlines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveLeft();
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 5), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, .{ .columns = 80, .rows = 24 }, .{ .row = 2, .column = 0 });
}

test "consecutive newlines each add an occupiable row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\n\n");
    try expectCaretAt(&editor, .{ .columns = 80, .rows = 24 }, .{ .row = 3, .column = 0 });
}

test "moveUp and moveDown across newline lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hello\nworld");
    try moveCaretTo(&editor, 3);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "moveUp and moveDown across wrapped continuation rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef");
    try moveCaretTo(&editor, 1);
    editor.moveDown(3);
    try std.testing.expectEqual(@as(usize, 4), editor.caret);
    editor.moveUp(3);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
}

test "the caret follows a word the wrap moves to the next row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("aaa bbbb");
    const columns = 5;
    const size: terminal.View.Size = .{ .columns = columns, .rows = 24 };
    try std.testing.expectEqual(@as(usize, 4), editor.rows(size));

    try moveCaretTo(&editor, 6);
    try expectCaretAt(&editor, size, .{ .row = 2, .column = 2 });
    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 2), editor.caret);
    editor.moveDown(columns);
    try std.testing.expectEqual(@as(usize, 6), editor.caret);
}

test "a step up onto a short wrapped row lands on that row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("aaa bbbb");
    const columns = 5;
    try moveCaretTo(&editor, 8);
    try std.testing.expectEqual(@as(usize, 2), terminal.width.rows(editor.visible(), columns));

    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    try expectCaretAt(&editor, .{ .columns = columns, .rows = 24 }, .{ .row = 1, .column = 3 });
    editor.moveDown(columns);
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
    editor.moveUp(columns);
    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
}

test "moveUp off the top row jumps to the start and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    try moveCaretTo(&editor, 16);
    editor.moveUp(80);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 5), editor.caret);
    try std.testing.expectEqual(@as(?usize, 5), editor.goal_column);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "moveDown off the bottom row jumps to the end and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    try moveCaretTo(&editor, 1);
    editor.moveDown(80);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 12), editor.caret);
    try std.testing.expectEqual(@as(?usize, 1), editor.goal_column);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 17), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "vertical movement keeps a sticky goal column across a shorter row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    try moveCaretTo(&editor, 5);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 15), editor.caret);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 5), editor.caret);
}

test "a horizontal move resets the vertical goal column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    try moveCaretTo(&editor, 5);
    editor.moveDown(80);
    editor.moveLeft();
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 11), editor.caret);
}

test "an edit resets the vertical goal column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    try moveCaretTo(&editor, 5);
    editor.moveDown(80);
    try editor.insert("z");
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 14), editor.caret);
}

test "moving right across blank lines does not skip rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveHome();
    const expected = [_]terminal.View.Caret{
        .{ .row = 1, .column = 0 },
        .{ .row = 1, .column = 1 },
        .{ .row = 2, .column = 0 },
        .{ .row = 3, .column = 0 },
        .{ .row = 3, .column = 1 },
    };
    for (expected) |caret| {
        try expectCaretAt(&editor, .{ .columns = 80, .rows = 24 }, caret);
        editor.moveRight();
    }
}

test "a tall body caps its rows and scrolls the window to keep the caret in view" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    const size: terminal.View.Size = .{ .columns = 80, .rows = 20 };
    editor.reflow(size);
    try std.testing.expectEqual(@as(usize, 8), editor.rows(size));
    const bottom = try rendered(gpa, &editor, size);
    defer gpa.free(bottom);
    try testing.expectShows(bottom, &.{"↑ Hidden: 4"});
    try testing.expectHides(bottom, &.{"↓ Hidden"});
    try expectCaretAt(&editor, size, .{ .row = 6, .column = 2 });

    for (0..9) |_| editor.moveUp(80);
    editor.reflow(size);
    const top = try rendered(gpa, &editor, size);
    defer gpa.free(top);
    try testing.expectHides(top, &.{"↑ Hidden"});
    try testing.expectShows(top, &.{"↓ Hidden: 4"});
    try expectCaretAt(&editor, size, .{ .row = 1, .column = 2 });
}

test "the frame edges report the rows scrolled out of view" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    for (0..3) |_| editor.moveUp(80);
    editor.reflow(.{ .columns = 80, .rows = 20 });

    const painted = try rendered(gpa, &editor, .{ .columns = 40, .rows = 20 });
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"↑ Hidden: 1"});
    try testing.expectShows(painted, &.{"↓ Hidden: 3"});
    try testing.expectShows(painted, &.{"l6"});
    try testing.expectHides(painted, &.{"l0"});
    try testing.expectHides(painted, &.{"l9"});
}

test "prependText puts the text and a line break before a draft and fills a blank editor" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    const payload = "line\n" ** 15;
    try editor.paste(payload, true);
    try editor.insert("draft");
    try editor.prependText("");
    try std.testing.expect(std.mem.startsWith(u8, editor.visible(), "\u{200B}[Paste #1"));

    try editor.prependText("refused");
    const text = try editor.expanded();
    defer gpa.free(text);
    try std.testing.expectEqualStrings("refused\n" ++ payload ++ "draft", text);
    try std.testing.expectEqual(editor.visible().len, editor.caret);

    editor.clear();
    try editor.insert(" \n");
    try editor.prependText("refused");
    try std.testing.expectEqualStrings("refused", editor.visible());
    try std.testing.expectEqual(editor.visible().len, editor.caret);
}
