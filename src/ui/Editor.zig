//! The input-line editing model: a text buffer whose caret follows rendered
//! units — grapheme clusters for valid UTF-8, one unit per canonical replacement
//! for malformed or control input, and one atomic unit per collapsed large paste.
//!
//! A large bracketed paste collapses to a `[paste #N …]` marker that behaves as
//! one editing unit and expands to its exact bytes on submit. The draft keeps two
//! named views: `visible` (literal text plus marker labels, for rendering) and
//! `expanded` (literal text plus paste payloads, for every send boundary). It owns
//! editing state only; submitting, quitting, and drawing are the caller's job.

const std = @import("std");

const paint = @import("paint.zig");
const terminal = @import("terminal");

const Editor = @This();

gpa: std.mem.Allocator,
draft: Draft,
/// Byte offset into the draft's visible buffer. Always a canonical display
/// boundary and never strictly inside a marker span.
caret: usize,
/// The first wrapped body row shown when the body is taller than its slot; the
/// window scrolls to keep the caret in view. `reflow` maintains it and `clear`
/// resets it; the rows above it show as an "N more" label on the top rule.
scroll: usize,
/// Desired logical column for vertical movement, remembered across consecutive
/// `moveUp`/`moveDown` so a step through a shorter row does not forget it. It is
/// logical, not display: a paste atom counts as one cell however wide its label
/// renders (see `logicalColumn`), so a marker never traps the caret at its edge.
/// Null until a vertical step captures the caret's column; a horizontal move, an
/// edit, or a vertical move off the top or bottom row clears it back to null.
goal_column: ?usize,
/// Next paste-atom ID to assign; the first real atom is 1. Monotonic for the
/// editor's lifetime — `clear`, submit, and deletion never reset or decrement it,
/// so no two atoms ever share an ID.
paste_id_next: u64,
/// Accumulates one in-progress bracketed paste across `Input` chunks until its
/// final chunk arrives. Reused across pastes; a large paste moves its bytes out.
capture: std.ArrayList(u8),

/// An atom-aware editor draft: the visible byte buffer and the paste atoms
/// collapsed within it. Owned by an `Editor` while live, and detachable so a
/// consumer can retain it (steering recovery) — hence its own lifecycle.
pub const Draft = struct {
    /// Literal text interleaved with generated marker spans. Rendered and
    /// measured directly; a marker span is a leading guard, the label, a
    /// trailing guard (see `marker_guard`).
    visible: std.ArrayList(u8),
    /// Paste atoms, sorted by `start`, non-overlapping, each within `visible`.
    atoms: std.ArrayList(Atom),

    pub const empty: Draft = .{ .visible = .empty, .atoms = .empty };

    /// One collapsed large paste: its half-open visible range `[start, end)` —
    /// exactly the generated marker span — its stable ID, and the owned exact
    /// pasted bytes (no guards or label). Literal text is never inferred to be
    /// an atom from its bytes.
    pub const Atom = struct {
        start: usize,
        end: usize,
        id: u64,
        payload: []u8,
    };

    pub fn deinit(self: *Draft, gpa: std.mem.Allocator) void {
        for (self.atoms.items) |atom| gpa.free(atom.payload);
        self.atoms.deinit(gpa);
        self.visible.deinit(gpa);
    }

    /// Free every payload and empty the draft, keeping the buffers' capacity.
    pub fn clear(self: *Draft, gpa: std.mem.Allocator) void {
        for (self.atoms.items) |atom| gpa.free(atom.payload);
        self.atoms.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
    }

    /// Allocate the expanded text — literal bytes with each atom's exact payload
    /// spliced in for its marker span, in document order — optionally stripped of
    /// leading and trailing whole-prompt whitespace. Caller owns the result.
    pub fn expanded(self: *const Draft, gpa: std.mem.Allocator, trim: Trim) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacityPrecise(gpa, try self.expandedLen());
        var pos: usize = 0;
        for (self.atoms.items) |atom| {
            out.appendSliceAssumeCapacity(self.visible.items[pos..atom.start]);
            out.appendSliceAssumeCapacity(atom.payload);
            pos = atom.end;
        }
        out.appendSliceAssumeCapacity(self.visible.items[pos..]);
        if (trim == .whole_prompt) {
            const trimmed = std.mem.trim(u8, out.items, whitespace);
            std.mem.copyForwards(u8, out.items, trimmed);
            out.items.len = trimmed.len;
        }
        return out.toOwnedSlice(gpa);
    }

    /// Whether the expanded-and-trimmed text is empty: no non-whitespace byte in
    /// any literal segment or atom payload. Allocation-free.
    pub fn blank(self: *const Draft) bool {
        var pos: usize = 0;
        for (self.atoms.items) |atom| {
            if (hasContent(self.visible.items[pos..atom.start])) return false;
            if (hasContent(atom.payload)) return false;
            pos = atom.end;
        }
        return !hasContent(self.visible.items[pos..]);
    }

    /// Expanded byte length, via checked additions on the visible length with
    /// each atom's marker span replaced by its payload.
    fn expandedLen(self: *const Draft) !usize {
        var total: usize = self.visible.items.len;
        for (self.atoms.items) |atom| {
            total = try std.math.sub(usize, total, atom.end - atom.start);
            total = try std.math.add(usize, total, atom.payload.len);
        }
        return total;
    }
};

/// Which whitespace trimming `expanded` applies.
pub const Trim = enum { none, whole_prompt };

/// One atom-aware text mutation, the sole path that edits the visible buffer.
/// Replaces `[from, to)` with `bytes`; when `new_atom` is set, the inserted bytes
/// are that atom's marker span and it takes ownership of the payload on success.
/// (Phase 3's draft append will generalize `new_atom` to a run of atoms inserted
/// under one reservation so it stays the only mutation primitive.)
const Splice = struct {
    from: usize,
    to: usize,
    bytes: []const u8 = "",
    new_atom: ?NewAtom = null,

    const NewAtom = struct { id: u64, payload: []u8 };
};

/// A paste is large past either threshold: more than `line_count_max` logical
/// (LF-delimited) lines or more than `byte_count_max` bytes.
const line_count_max = 10;
const byte_count_max = 1000;
/// Zero-width guard bracketing a marker span. U+200B is zero columns and, being
/// grapheme-break Control, forces a cluster break on each side, so a marker edge
/// is always a display boundary and cannot fuse with adjacent combining text.
/// The guards pin only the edges: the label between them is ordinary text that
/// wraps grapheme-by-grapheme like any other, so a marker is one atom for editing
/// (crossed and deleted whole) but not one unit for wrapping — a marker wider
/// than the terminal breaks across rows while staying a single atom.
const marker_guard = "\u{200B}";
/// Widest a marker span can be: two guards, the fixed label text, and two u64s in
/// decimal (the line form `[paste #{d} +{d} lines]` is the longer of the two).
const label_len_max =
    2 * marker_guard.len + "[paste #".len + 20 + " +".len + 20 + " lines]".len;
const whitespace = " \t\r\n";

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{
        .gpa = gpa,
        .draft = .empty,
        .caret = 0,
        .scroll = 0,
        .goal_column = null,
        .paste_id_next = 1,
        .capture = .empty,
    };
}

pub fn deinit(self: *Editor) void {
    self.draft.deinit(self.gpa);
    self.capture.deinit(self.gpa);
}

/// The visible text — literal bytes plus marker labels — borrowed for rendering,
/// display-length checks, and compact steering rows. Never a send boundary.
pub fn visible(self: *const Editor) []const u8 {
    return self.draft.visible.items;
}

/// The expanded text for a send boundary; see `Draft.expanded`. Caller owns it.
pub fn expanded(self: *const Editor, trim: Trim) ![]u8 {
    return self.draft.expanded(self.gpa, trim);
}

/// Whether the expanded-and-trimmed prompt is empty; see `Draft.blank`.
pub fn blank(self: *const Editor) bool {
    return self.draft.blank();
}

/// Empty the draft and pending capture and reset the caret, scroll, and goal.
/// Frees every atom payload but never resets the paste-ID counter.
pub fn clear(self: *Editor) void {
    self.draft.clear(self.gpa);
    self.capture.clearRetainingCapacity();
    self.caret = 0;
    self.scroll = 0;
    self.goal_column = null;
}

/// Accept one bracketed-paste chunk, accumulating it; on the `final` chunk,
/// classify the whole paste and commit one operation — a small paste inserts its
/// exact bytes as ordinary text, a large one collapses to a marker atom. An empty
/// paste is a no-op. Byte-for-byte; no newline, tab, or control normalization.
pub fn paste(self: *Editor, bytes: []const u8, final: bool) !void {
    // Any failure discards the partial capture so a later paste cannot merge
    // stale bytes; a successful non-final chunk keeps it for the next chunk.
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
        try self.splice(.{ .from = self.caret, .to = self.caret, .bytes = bytes });
        return;
    }
    // Reserve the ID, marker, and buffer capacity before moving the payload out,
    // so a failure leaves the capture, draft, and counter unchanged. The splice
    // re-checks that capacity, so the move is the last step that can fail.
    if (self.paste_id_next == std.math.maxInt(u64)) return error.PasteIdExhausted;
    const id = self.paste_id_next;
    var buffer: [label_len_max]u8 = undefined;
    const span = markerSpan(&buffer, id, line_count, bytes.len);
    try self.draft.visible.ensureUnusedCapacity(self.gpa, span.len);
    try self.draft.atoms.ensureUnusedCapacity(self.gpa, 1);
    const payload = try self.capture.toOwnedSlice(self.gpa);
    errdefer self.gpa.free(payload);
    try self.splice(.{
        .from = self.caret,
        .to = self.caret,
        .bytes = span,
        .new_atom = .{ .id = id, .payload = payload },
    });
    self.paste_id_next += 1;
}

/// Write a marker span — guard, label, guard — into `buffer` and return it. The
/// line form wins when both thresholds are crossed; the byte form's label says
/// `bytes`, not `chars`, to stay honest about arbitrary input.
fn markerSpan(buffer: []u8, id: u64, line_count: usize, byte_count: usize) []const u8 {
    if (line_count > line_count_max) {
        const form = marker_guard ++ "[paste #{d} +{d} lines]" ++ marker_guard;
        return std.fmt.bufPrint(buffer, form, .{ id, line_count }) catch unreachable;
    }
    const form = marker_guard ++ "[paste #{d} {d} bytes]" ++ marker_guard;
    return std.fmt.bufPrint(buffer, form, .{ id, byte_count }) catch unreachable;
}

pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try self.insert(buffer[0..length]);
}

pub fn insert(self: *Editor, bytes: []const u8) !void {
    try self.splice(.{ .from = self.caret, .to = self.caret, .bytes = bytes });
}

fn splice(self: *Editor, op: Splice) !void {
    const visible_list = &self.draft.visible;
    const atoms = &self.draft.atoms;
    std.debug.assert(op.from <= op.to);
    std.debug.assert(op.to <= visible_list.items.len);

    // Reject a range that cuts through an atom; find the contiguous run it covers.
    var remove_from: usize = atoms.items.len;
    var remove_to: usize = atoms.items.len;
    for (atoms.items, 0..) |atom, index| {
        if (op.to <= atom.start or op.from >= atom.end) continue;
        if (op.from > atom.start or atom.end > op.to) return error.PasteAtomSplit;
        remove_from = @min(remove_from, index);
        remove_to = index + 1;
    }

    // Reserve first; a failure here leaves the draft untouched. The checked
    // resulting length also proves the commit's range shifts cannot overflow:
    // every shifted offset is at most `shifted_len`, and each `start - removed`
    // stays nonnegative because a shifted atom has `start >= op.to >= removed`.
    const removed = op.to - op.from;
    const shifted_len = try std.math.add(usize, visible_list.items.len - removed, op.bytes.len);
    try visible_list.ensureTotalCapacity(self.gpa, shifted_len);
    if (op.new_atom != null) try atoms.ensureUnusedCapacity(self.gpa, 1);

    // Commit; every step below is infallible.
    for (atoms.items[remove_from..remove_to]) |atom| self.gpa.free(atom.payload);
    atoms.replaceRangeAssumeCapacity(remove_from, remove_to - remove_from, &.{});
    visible_list.replaceRangeAssumeCapacity(op.from, op.to - op.from, op.bytes);
    for (atoms.items) |*atom| {
        if (atom.start >= op.to) {
            atom.start = atom.start - removed + op.bytes.len;
            atom.end = atom.end - removed + op.bytes.len;
        }
    }
    if (op.new_atom) |new_atom| atoms.insertAssumeCapacity(atomIndexAfter(atoms.items, op.from), .{
        .start = op.from,
        .end = op.from + op.bytes.len,
        .id = new_atom.id,
        .payload = new_atom.payload,
    });
    self.goal_column = null;
    if (self.caret >= op.to) {
        self.caret = self.caret - removed + op.bytes.len;
    } else if (self.caret > op.from) {
        self.caret = op.from + op.bytes.len;
    }
    // Adjacent literal text can fuse into one grapheme after the edit; re-clamp
    // the caret to the resulting display boundary.
    self.caret = terminal.width.boundaryAtOrAfter(visible_list.items, self.caret);
}

/// The atom whose span begins exactly at `offset`, if any.
fn atomStartingAt(self: *const Editor, offset: usize) ?Draft.Atom {
    for (self.draft.atoms.items) |atom| if (atom.start == offset) return atom;
    return null;
}

/// The atom whose span ends exactly at `offset`, if any.
fn atomEndingAt(self: *const Editor, offset: usize) ?Draft.Atom {
    for (self.draft.atoms.items) |atom| if (atom.end == offset) return atom;
    return null;
}

/// Index of the first atom lying wholly at or after `offset` — the slot a new
/// atom starting there takes.
fn atomIndexAfter(atoms: []const Draft.Atom, offset: usize) usize {
    var index: usize = 0;
    while (index < atoms.len and atoms[index].end <= offset) index += 1;
    return index;
}

pub fn backspace(self: *Editor) void {
    if (self.caret == 0) return;
    // A valid deletion never grows the buffer and never splits an atom, so the
    // splice cannot fail.
    if (self.atomEndingAt(self.caret)) |atom| {
        self.splice(.{ .from = atom.start, .to = atom.end }) catch unreachable;
        return;
    }
    const previous = terminal.width.boundaryBefore(self.draft.visible.items, self.caret);
    self.splice(.{ .from = previous, .to = self.caret }) catch unreachable;
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

/// Move the caret one wrapped row up, keeping the sticky logical goal column. On
/// the top row it falls back to `moveHome`. The column is logical, so a marker
/// counts as one cell and never traps the caret at its edge (see `logicalColumn`
/// and `logicalOffset`).
pub fn moveUp(self: *Editor, columns: usize) void {
    const columns_max = @max(columns, 1);
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text[0..self.caret], columns_max).rows_before;
    if (row == 0) {
        self.moveHome();
        return;
    }
    const goal = self.goal_column orelse self.logicalColumn(columns_max, row);
    self.goal_column = goal;
    var result = self.logicalOffset(columns_max, .{ .row = row - 1, .column = goal });
    // A marker wider than the terminal has no caret on its interior rows, and
    // `logicalOffset` only escapes such a row forward, to the after-edge. When
    // that leaves the caret at or below where it started, climb to the marker's
    // before-edge instead so a step up always makes upward progress.
    if (result >= self.caret) {
        if (self.atomEndingAt(self.caret)) |atom| result = atom.start;
    }
    self.caret = result;
    std.debug.assert(self.legalCaret(self.caret));
}

/// Move the caret one wrapped row down, keeping the sticky logical goal column;
/// on the bottom row it falls back to `moveEnd`. See `moveUp`.
pub fn moveDown(self: *Editor, columns: usize) void {
    const columns_max = @max(columns, 1);
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text[0..self.caret], columns_max).rows_before;
    if (row + 1 >= terminal.width.rows(text, columns_max)) {
        self.moveEnd();
        return;
    }
    const goal = self.goal_column orelse self.logicalColumn(columns_max, row);
    self.goal_column = goal;
    self.caret = self.logicalOffset(columns_max, .{ .row = row + 1, .column = goal });
    std.debug.assert(self.legalCaret(self.caret));
}

/// A position in the logical column model: a display row and the logical column
/// within it (each atom one cell, each grapheme its display width).
const LogicalCaret = struct { row: usize, column: usize };

/// The slice of the visible buffer display `row` wraps to, or null when `row` is
/// past the last wrapped row. Both vertical-movement walks take their row start
/// from this line, so they measure the same wrapped geometry the renderer does.
fn wrappedLine(self: *const Editor, columns_max: usize, row: usize) ?[]const u8 {
    var iterator = terminal.width.wrapper(self.draft.visible.items, columns_max);
    var current: usize = 0;
    while (iterator.next()) |line| : (current += 1) {
        if (current == row) return line;
    }
    return null;
}

/// The caret's logical column within display `row`: each literal grapheme counts
/// its display width, but every paste atom counts as a single cell. The walk
/// starts at the row's first legal caret boundary, so a marker that wrapped onto
/// this row is skipped to its end while a marker that begins the row is counted
/// as its single cell.
fn logicalColumn(self: *const Editor, columns_max: usize, row: usize) usize {
    const text = self.draft.visible.items;
    const line = self.wrappedLine(columns_max, row) orelse return 0;
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    var column: usize = 0;
    var index = self.legalAtOrAfter(line_start);
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

/// Byte offset at `target`'s logical column on its display row — the inverse of
/// `logicalColumn`, clamped to the row's last legal boundary; a row past the last
/// wrapped row yields the buffer end. Atoms are always crossed whole, so the
/// result is a legal caret boundary and never lands strictly inside a marker,
/// even when the marker wraps across rows.
fn logicalOffset(self: *const Editor, columns_max: usize, target: LogicalCaret) usize {
    const text = self.draft.visible.items;
    const line = self.wrappedLine(columns_max, target.row) orelse return text.len;
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    const line_end = line_start + line.len;
    var index = self.legalAtOrAfter(line_start);
    var logical: usize = 0;
    while (index < line_end and logical < target.column) {
        if (self.atomStartingAt(index)) |atom| {
            logical += 1;
            index = atom.end;
        } else {
            const next = terminal.width.boundaryAfter(text, index);
            const unit = terminal.width.ofText(text[index..next]);
            // Stop before a wide grapheme the goal column falls inside rather
            // than overshooting past it.
            if (logical + unit > target.column) break;
            logical += unit;
            index = next;
        }
    }
    return index;
}

/// The first legal caret boundary at or after `offset`: the enclosing atom's end
/// when `offset` falls strictly inside a marker, otherwise `offset` unchanged.
fn legalAtOrAfter(self: *const Editor, offset: usize) usize {
    for (self.draft.atoms.items) |atom| {
        if (atom.start < offset and offset < atom.end) return atom.end;
    }
    return offset;
}

/// Whether `offset` is a legal caret: a display boundary in the visible buffer
/// that is not strictly inside any atom span (Draft invariant 4).
fn legalCaret(self: *const Editor, offset: usize) bool {
    const text = self.draft.visible.items;
    if (terminal.width.boundaryAtOrAfter(text, offset) != offset) return false;
    for (self.draft.atoms.items) |atom| {
        if (atom.start < offset and offset < atom.end) return false;
    }
    return true;
}

/// Re-clamp the scroll offset so the caret's wrapped row stays inside the visible
/// window. Call once per repaint, passing the same `size` whose columns and rows
/// `render` and `rows` will use, so all three agree on the window.
pub fn reflow(self: *Editor, size: terminal.View.Size) void {
    const columns_max = @max(size.columns, 1);
    const text = self.draft.visible.items;
    const total_body = self.bodyRows(columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(size.rows));
    const caret_row = terminal.width.caret(text[0..self.caret], columns_max).rows_before;
    if (caret_row < self.scroll) self.scroll = caret_row;
    if (caret_row >= self.scroll + visible_rows) self.scroll = caret_row - visible_rows + 1;
    self.scroll = @min(self.scroll, total_body - visible_rows);
}

/// Physical rows the editor occupies: the two framing rules plus the wrapped
/// body, the body capped to its scroll limit for `size.rows`.
pub fn rows(self: *const Editor, size: terminal.View.Size) usize {
    const total_body = self.bodyRows(@max(size.columns, 1));
    return paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// Body rows the editor lays out: the wrapped text plus, when the caret has
/// wrapped past a full-width final line, the empty trailing row it sits on — a
/// row the wrap itself never yields (see `caretPosition`).
fn bodyRows(self: *const Editor, columns_max: usize) usize {
    const text = self.draft.visible.items;
    const wrapped = terminal.width.rows(text, columns_max);
    const caret_row = terminal.width.caret(text[0..self.caret], columns_max).rows_before;
    return wrapped + @intFromBool(caret_row == wrapped);
}

/// Stream the framed input area — the rules and the wrapped visible text,
/// windowed to its scroll limit for `viewport_rows` — through `placement`,
/// placing the terminal caret on its row. Assumes `reflow` set the scroll.
pub fn render(self: *const Editor, placement: *const paint.Placement, viewport_rows: usize) !void {
    const columns_max = @max(placement.columns, 1);
    const text = self.draft.visible.items;
    const total_body = self.bodyRows(columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(viewport_rows));
    try paint.framed(placement, &.{
        .body = text,
        .caret = self.caretPosition(columns_max),
        .hidden_above = self.scroll,
        .shown = visible_rows,
        .hidden_below = total_body - self.scroll - visible_rows,
        .trailing_row = total_body > terminal.width.rows(text, columns_max),
    });
}

/// The caret's position within the rendered rows: row 0 is the top rule and the
/// scrolled-off rows above the window are hidden, so the caret sits one below the
/// top rule plus its wrapped row's offset from the top of the window. A caret at
/// a full-width line's end reports the empty trailing row `bodyRows` reserves.
fn caretPosition(self: *const Editor, columns_max: usize) terminal.View.Caret {
    const position = terminal.width.caret(self.draft.visible.items[0..self.caret], columns_max);
    return .{ .row = 1 + (position.rows_before - self.scroll), .column = position.column };
}

/// Whether any byte in `bytes` is not whole-prompt whitespace.
fn hasContent(bytes: []const u8) bool {
    for (bytes) |byte| switch (byte) {
        ' ', '\t', '\r', '\n' => {},
        else => return true,
    };
    return false;
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
    // Base emoji plus skin-tone modifier is one cluster.
    try editor.insert("👍\u{1F3FD}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // Base letter plus a combining mark.
    try editor.insert("e\u{0301}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // A regional-indicator flag is one cluster of two indicators.
    try editor.insert("🇯🇵");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // A four-emoji ZWJ family folds into one cluster.
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
    // Typing a base letter before a dangling combining mark lands the caret
    // after the completed cluster, not inside it.
    try editor.insert("\u{0301}");
    editor.moveHome();
    try editor.insert("e");
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // Typing one regional indicator before another completes a flag; the caret
    // sits after the whole two-column glyph.
    try editor.insert("🇵");
    editor.moveHome();
    try editor.insert("🇯");
    try std.testing.expectEqualStrings("🇯🇵", editor.visible());
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
}

test "left and right move by whole grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // "a"(1) + skin-tone cluster(8) + "b"(1): boundaries at 0, 1, 9, 10.
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

// Pastes `payload` as one complete bracketed paste, then returns the expanded
// text for the caller to check, caller-owned.
fn pasteWhole(editor: *Editor, payload: []const u8) !void {
    try editor.paste(payload, true);
}

fn expectExpanded(editor: *const Editor, trim: Trim, expected: []const u8) !void {
    const text = try editor.expanded(trim);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

// Eleven logical lines: ten LFs joining eleven single-letter lines.
const eleven_lines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk";
// Ten logical lines: nine LFs.
const ten_lines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj";

test "the line threshold collapses more than ten logical lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Ten lines stay literal.
    try pasteWhole(&editor, ten_lines);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(ten_lines, editor.visible());

    // Eleven lines collapse; the label counts the empty trailing line too.
    editor.clear();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[paste #1 +11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, eleven_lines);

    // A trailing LF contributes the eleventh line.
    editor.clear();
    try pasteWhole(&editor, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[paste #2 +11 lines]\u{200B}", editor.visible());
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
    try std.testing.expectEqualStrings("\u{200B}[paste #1 1001 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, longer);
}

test "the byte threshold counts bytes, not characters" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // 501 two-byte codepoints on one line: 1002 bytes, far fewer characters.
    const multibyte = "é" ** 501;
    try pasteWhole(&editor, multibyte);
    try std.testing.expectEqualStrings("\u{200B}[paste #1 1002 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, multibyte);

    // 1001 malformed bytes on one line collapse the same way and round-trip.
    editor.clear();
    const malformed = "\xff" ** 1001;
    try pasteWhole(&editor, malformed);
    try std.testing.expectEqualStrings("\u{200B}[paste #2 1001 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, malformed);
}

test "a lone CR is payload, and CRLF counts one line" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Eleven CR-terminated fragments have no LF, so one logical line; short, so
    // it stays literal.
    try pasteWhole(&editor, "x\r" ** 11);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);

    // Eleven CRLF-terminated fragments are eleven logical lines and collapse; the
    // lone CRs survive in the payload.
    editor.clear();
    const crlf = "x\r\n" ** 11;
    try pasteWhole(&editor, crlf);
    try std.testing.expectEqualStrings("\u{200B}[paste #1 +12 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, crlf);
}

test "the line form wins when both thresholds are crossed" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Eleven lines of a hundred columns each: over both thresholds.
    const big = ("x" ** 100 ++ "\n") ** 10 ++ "x" ** 100;
    try pasteWhole(&editor, big);
    try std.testing.expectEqualStrings("\u{200B}[paste #1 +11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, big);
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
    // Three non-final chunks then a final one form one logical paste.
    try editor.paste("a\nb\nc\n", false);
    try editor.paste("d\ne\nf\n", false);
    try editor.paste("g\nh\ni\n", false);
    try editor.paste("j\nk", true);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[paste #1 +11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, eleven_lines);
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
        "A\u{200B}[paste #1 +11 lines]\u{200B}B\u{200B}[paste #2 1001 bytes]\u{200B}C",
        editor.visible(),
    );
    try expectExpanded(&editor, .none, "A" ++ eleven_lines ++ "B" ++ "z" ** 1001 ++ "C");
}

test "arbitrary payload bytes round-trip through expansion exactly" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Controls, tabs, malformed UTF-8, and marker-looking text, over the byte
    // threshold so it collapses.
    const payload =
        "tab\tesc\x1b bad\xff\xfe text [paste #99 +5 lines] literal\n" ** 40;
    try pasteWhole(&editor, payload);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try expectExpanded(&editor, .none, payload);
}

test "a typed marker-looking string stays literal and never expands" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    const typed = "[paste #1 +11 lines]";
    try editor.insert(typed);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings(typed, editor.visible());
    try expectExpanded(&editor, .none, typed);
    // It is ordinary editable text: one backspace removes one character.
    editor.moveEnd();
    editor.backspace();
    try std.testing.expectEqualStrings("[paste #1 +11 lines", editor.visible());
}

test "paste IDs are stable across deletion and never reused" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines); // #1
    try editor.insert("mid");
    try pasteWhole(&editor, eleven_lines); // #2
    try std.testing.expectEqual(@as(u64, 1), editor.draft.atoms.items[0].id);
    try std.testing.expectEqual(@as(u64, 2), editor.draft.atoms.items[1].id);

    // Delete the first atom; the second keeps its ID and label.
    editor.moveHome();
    editor.moveRight(); // Across atom #1 to its after-edge.
    editor.backspace(); // Removes atom #1.
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 2), editor.draft.atoms.items[0].id);

    // A later paste is #3, never reusing 1, and sorts after #2.
    editor.moveEnd();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(u64, 2), editor.draft.atoms.items[0].id);
    try std.testing.expectEqual(@as(u64, 3), editor.draft.atoms.items[1].id);

    // A clear frees the atoms but preserves the counter.
    editor.clear();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(u64, 4), editor.draft.atoms.items[0].id);
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
    editor.moveRight(); // a -> after a
    editor.moveRight(); // b -> atom start (before-edge)
    try std.testing.expectEqual(atom.start, editor.caret);
    editor.moveRight(); // cross the whole marker in one step
    try std.testing.expectEqual(atom.end, editor.caret);
    editor.moveLeft(); // back across the whole marker
    try std.testing.expectEqual(atom.start, editor.caret);
}

test "backspace deletes a whole marker and leaves neighbours intact" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    // Caret sits after "cd"; step left across "d", "c" to the marker's after-edge.
    editor.moveLeft();
    editor.moveLeft();
    try std.testing.expectEqual(editor.draft.atoms.items[0].end, editor.caret);
    editor.backspace();
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("abcd", editor.visible());
    try expectExpanded(&editor, .none, "abcd");
}

test "inserting on either edge of a marker shifts its range" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const span_len = editor.draft.atoms.items[0].end;

    // Insert before the marker (caret at its start).
    editor.moveHome();
    try editor.insert("<");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items[0].start);
    try std.testing.expectEqual(span_len + 1, editor.draft.atoms.items[0].end);

    // Insert after the marker (caret at its end).
    editor.moveEnd();
    try editor.insert(">");
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items[0].start);
    try std.testing.expectEqual(span_len + 1, editor.draft.atoms.items[0].end);
    try expectExpanded(&editor, .none, "<" ++ eleven_lines ++ ">");
}

test "deleting a marker between combining text re-clamps the boundary" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("e");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\u{0301}");
    // Step left over the combining mark to the marker's after-edge, then delete.
    editor.moveLeft();
    try std.testing.expectEqual(editor.draft.atoms.items[0].end, editor.caret);
    editor.backspace();
    // "e" and the combining mark fuse; the caret clamps past the whole cluster.
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(editor.visible().len, editor.caret);
    try expectExpanded(&editor, .none, "e\u{0301}");
}

test "marker guards keep both edges legal between combining marks" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // A combining mark on each side of a marker. The zero-width guards force a
    // cluster break at both edges, so neither mark fuses into the label and both
    // edges stay legal caret boundaries.
    try editor.insert("\u{0301}");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\u{0301}");
    const atom = editor.draft.atoms.items[0];
    // From the end, one left step stops at the after-edge (past the trailing
    // mark), the next crosses the whole marker to the before-edge.
    editor.moveLeft();
    try std.testing.expectEqual(atom.end, editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(atom.start, editor.caret);
    // Expansion drops both guards and keeps both marks around the payload.
    try expectExpanded(&editor, .none, "\u{0301}" ++ eleven_lines ++ "\u{0301}");
}

test "vertical movement counts a marker as one logical column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // "abc" then a marker alone on its own row then "def".
    try editor.insert("abc\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("\ndef");
    const atom = editor.draft.atoms.items[0];

    // The marker's row holds a single logical cell, so goal column 2 clamps past
    // it to the after-edge rather than snapping back to the marker's start.
    editor.caret = 2; // Row 0, column 2 within "abc".
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);
    try std.testing.expectEqual(@as(?usize, 2), editor.goal_column);

    // The same from below: up lands on the after-edge, never inside the marker.
    editor.caret = editor.visible().len - 1; // Row 2, column 2 within "def".
    editor.goal_column = null;
    editor.moveUp(80);
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "vertical movement lands in the text after a leading marker" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Row 0 "This"; row 1 is a marker at the line start followed by " foo".
    try editor.insert("This\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert(" foo");
    const atom = editor.draft.atoms.items[0];

    editor.caret = 4; // Row 0, column 4 (after "This").
    editor.moveDown(80);
    // The marker is one column, so column 4 falls between the two o's of "foo":
    // marker(1) + space(1) + "fo"(2).
    try std.testing.expectEqual(atom.end + 3, editor.caret);
    try std.testing.expectEqualStrings(" fo", editor.visible()[atom.end .. atom.end + 3]);
}

test "vertical movement departs a row-leading marker as one column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Row 0 "ab"; row 1 begins with a marker, then "cd".
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    // The caret right after the marker is logical column 1 (the marker is the one
    // cell at column 0), so a first step up lands at column 1 of "ab".
    editor.caret = atom.end;
    editor.goal_column = null;
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);

    // Symmetric: from row 0 column 1, a step down returns to just after the marker
    // — past its one cell and no further, i.e. the after-edge.
    editor.caret = 1;
    editor.goal_column = null;
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "vertical movement treats a mid-line marker as one column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Row 0 is wide padding; row 1 is "ab" + marker + "cd".
    try editor.insert("xxxxxxxx\nab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    // Row 1 columns: a(0..1) b(1..2) marker(2..3) c(3..4) d(4..5). Goal column 3
    // lands on the after-edge; goal column 4 one cell into the trailing "cd".
    editor.caret = 3; // Row 0, column 3.
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);

    editor.moveHome();
    editor.caret = 4; // Row 0, column 4.
    editor.goal_column = null;
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end + 1, editor.caret);
}

test "repeated vertical steps cross a marker wider than the terminal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines); // 21-column label wraps at width 5.
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    editor.caret = 1; // Row 0 of "ab".
    // Step down repeatedly; the caret must never land strictly inside the marker
    // and must eventually reach its far edge.
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
    try pasteWhole(&editor, eleven_lines); // 21-column label wraps at width 5.
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    editor.moveEnd(); // In "cd", below the wrapped marker.
    // Step up repeatedly; the caret must never land strictly inside the marker
    // and must climb past its near edge rather than sticking at the far edge.
    var reached_start = false;
    for (0..8) |_| {
        editor.moveUp(5);
        try std.testing.expect(editor.caret <= atom.start or editor.caret >= atom.end);
        if (editor.caret == atom.start) reached_start = true;
    }
    try std.testing.expect(reached_start);
}

test "vertical movement clamps before a wide grapheme as display columns did" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Row 1 opens with a two-column grapheme; no atoms are involved.
    try editor.insert("ab\n\u{4F60}c"); // U+4F60 spans columns 0..2.
    editor.caret = 1; // Row 0, column 1 (after "a").
    editor.moveDown(80);
    // Goal column 1 falls inside the wide grapheme; clamp to the row start,
    // the boundary before it, never past it.
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "a marker wider than the terminal wraps but stays one atom" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const atom = editor.draft.atoms.items[0];
    // The 21-column label wraps across several rows at width 5.
    try std.testing.expect(terminal.width.rows(editor.visible(), 5) > 1);
    // Right from the start still crosses the whole marker in one step.
    editor.moveHome();
    editor.moveRight();
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "scrolling keeps the caret visible with markers above and below" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines); // #1
    try editor.insert("\nmiddle\n");
    try pasteWhole(&editor, eleven_lines); // #2
    // Put the caret between the two markers and reflow a short window.
    editor.caret = editor.draft.atoms.items[0].end + 4; // Within "middle".
    editor.reflow(.{ .columns = 80, .rows = 20 });
    const columns_max: usize = 80;
    const prefix = editor.visible()[0..editor.caret];
    const caret_row = terminal.width.caret(prefix, columns_max).rows_before;
    const window = @min(editor.bodyRows(columns_max), paint.bodyLimit(20));
    try std.testing.expect(caret_row >= editor.scroll);
    try std.testing.expect(caret_row < editor.scroll + window);
}

test "marker guards are zero-column and absent from expanded output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    // The visible label measures exactly its printable width; the guards add none.
    try std.testing.expectEqual(@as(usize, 20), terminal.width.ofText(editor.visible()));
    // Neither guard survives expansion.
    const text = try editor.expanded(.none);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, marker_guard) == null);
    try std.testing.expectEqualStrings(eleven_lines, text);
}

test "expanded whole-prompt trimming matches literal trimming, guards aside" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // A payload with whitespace edges, collapsed, framed by literal whitespace.
    try editor.insert("  ");
    try pasteWhole(&editor, "  " ++ "y" ** 1001 ++ "  ");
    try editor.insert("  ");
    // Expansion happens before trimming, so edge whitespace trims like literal.
    try expectExpanded(&editor, .whole_prompt, "y" ** 1001);
    try std.testing.expect(!editor.blank());
}

test "a placeholder-only prompt is nonblank and sends its payload" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expect(!editor.blank());
    // The blank predicate agrees with the trimmed-expanded length.
    const text = try editor.expanded(.whole_prompt);
    defer std.testing.allocator.free(text);
    try std.testing.expect(editor.blank() == (text.len == 0));
    try std.testing.expectEqualStrings(eleven_lines, text);

    // A payload of only whitespace is genuinely blank.
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
    const text = try editor.expanded(.whole_prompt);
    defer std.testing.allocator.free(text);
    // Clearing frees the atom payloads; the already-taken copy is unaffected, so
    // a submit that expands then clears keeps a valid prompt copy for the worker.
    editor.clear();
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("A" ++ eleven_lines ++ "B", text);
}

test "large-paste allocation failures leave the editor usable and leak nothing" {
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const gpa = failing.allocator();
        var editor = Editor.init(gpa);
        defer editor.deinit();
        editor.insert("keep") catch continue;
        editor.paste(eleven_lines, true) catch {
            // A failed finalization leaves the prior draft intact.
            try std.testing.expectEqualStrings("keep", editor.visible());
            try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    }
}

test render {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("hi");
    // Top rule, the body row, bottom rule.
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 80, .rows = 24 }));
    // The caret is on the body row (row 1, below the top rule) at column 2.
    try expectCaretAt(&editor, 80, .{ .row = 1, .column = 2 });

    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hi") != null);
    // The live input, so the view shows the hardware cursor.
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.cursor_show) != null);
}

test "a marker renders its label into the frame" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "[paste #1 +11 lines]") != null);
}

test "a full-width line reserves an empty trailing row for the wrapped caret" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("abc"); // Fills a three-column row exactly.
    editor.reflow(.{ .columns = 3, .rows = 24 });

    // The caret wraps onto an empty trailing row: two rules, the full row, and it.
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 2, .column = 0 });
    try std.testing.expectEqual(@as(usize, 4), try renderedRows(gpa, &editor, 3));

    // Backing the caret off the margin drops the trailing row again.
    editor.moveLeft();
    editor.reflow(.{ .columns = 3, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 1, .column = 2 });
    try std.testing.expectEqual(@as(usize, 3), try renderedRows(gpa, &editor, 3));
}

// Renders `editor` into a fresh view and returns the frame's bytes, caller-owned.
fn rendered(gpa: std.mem.Allocator, editor: *const Editor, size: terminal.View.Size) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = size.columns, .base = 0, .skip = 0 };
    try editor.render(&placement, size.rows);
    try view.render();
    return gpa.dupe(u8, out.written());
}

fn renderedRows(gpa: std.mem.Allocator, editor: *const Editor, columns: usize) !usize {
    const painted = try rendered(gpa, editor, .{ .columns = columns, .rows = 24 });
    defer gpa.free(painted);
    return std.mem.count(u8, painted, "\r\n") + 1;
}

fn expectCaretAt(editor: *const Editor, columns: usize, expected: terminal.View.Caret) !void {
    try std.testing.expectEqual(expected, editor.caretPosition(columns));
}

test "caret sits on the empty row after a trailing newline" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n");
    // Rules plus "a" plus the empty new line: four rows.
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, 80, .{ .row = 2, .column = 0 });
}

test "caret occupies a blank row between two newlines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveLeft();
    editor.moveLeft();
    // The caret now sits just after the first newline, on the blank middle row.
    try std.testing.expectEqual(@as(usize, 5), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, 80, .{ .row = 2, .column = 0 });
}

test "consecutive newlines each add an occupiable row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\n\n");
    try expectCaretAt(&editor, 80, .{ .row = 3, .column = 0 });
}

test "moveUp and moveDown across newline lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hello\nworld");
    editor.caret = 3; // Row 0, column 3, between the two 'l's.
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret); // Row 1, column 3.
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "moveUp and moveDown across wrapped continuation rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef");
    editor.caret = 1; // Wrapped at width 3: row 0, column 1.
    editor.moveDown(3);
    try std.testing.expectEqual(@as(usize, 4), editor.caret); // Row 1, column 1.
    editor.moveUp(3);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
}

test "moveUp off the top row jumps to the start and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    editor.caret = 16; // Row 2, column 5.
    editor.moveUp(80); // Row 1, clamped to column 3.
    editor.moveUp(80); // Row 0, back at column 5 via the goal.
    try std.testing.expectEqual(@as(usize, 5), editor.caret);
    try std.testing.expectEqual(@as(?usize, 5), editor.goal_column);
    editor.moveUp(80); // Top row: jump to the very start.
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "moveDown off the bottom row jumps to the end and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    editor.caret = 1; // Row 0, column 1.
    editor.moveDown(80); // Row 1, column 1.
    editor.moveDown(80); // Row 2, column 1.
    try std.testing.expectEqual(@as(usize, 12), editor.caret);
    try std.testing.expectEqual(@as(?usize, 1), editor.goal_column);
    editor.moveDown(80); // Bottom row: jump to the very end.
    try std.testing.expectEqual(@as(usize, 17), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "vertical movement keeps a sticky goal column across a shorter row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80);
    // "xy" is only two columns, so the caret clamps to its end.
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveDown(80);
    // The goal column survives the short row and lands at column 5 again.
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
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80); // Clamps to column 2 at the end of "xy".
    editor.moveLeft(); // Column 1, and the old goal is forgotten.
    editor.moveDown(80);
    // The recaptured goal is column 1, not the original 5.
    try std.testing.expectEqual(@as(usize, 11), editor.caret);
}

test "an edit resets the vertical goal column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80); // Clamps to column 2 at the end of "xy".
    try editor.insert("z"); // "xyz"; the edit forgets the old goal.
    editor.moveDown(80);
    // The recaptured goal is column 3, after "xyz", not the original 5.
    try std.testing.expectEqual(@as(usize, 14), editor.caret);
}

test "moving right across blank lines does not skip rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveHome();
    const expected_rows = [_]usize{ 1, 1, 2, 3, 3 };
    for (expected_rows) |row| {
        try std.testing.expectEqual(row, editor.caretPosition(80).row);
        editor.moveRight();
    }
}

test "a tall body caps its rows and scrolls the window to keep the caret in view" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Ten single-column rows; a 20-row viewport caps the body at six.
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    editor.reflow(.{ .columns = 80, .rows = 20 });
    // Two rules plus the six shown body rows, not the whole ten-row body.
    try std.testing.expectEqual(@as(usize, 8), editor.rows(.{ .columns = 80, .rows = 20 }));
    // The caret ends on the last row, so the window ends there.
    try std.testing.expectEqual(@as(usize, 4), editor.scroll);
    // Window-relative: below the top rule and the five earlier shown rows.
    try std.testing.expectEqual(@as(usize, 6), editor.caretPosition(80).row);

    // Climbing to the top drags the window back up with the caret.
    for (0..9) |_| editor.moveUp(80);
    editor.reflow(.{ .columns = 80, .rows = 20 });
    try std.testing.expectEqual(@as(usize, 0), editor.scroll);
    try std.testing.expectEqual(@as(usize, 1), editor.caretPosition(80).row);
}

test "the framing rules report the rows scrolled out of view" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    for (0..3) |_| editor.moveUp(80); // The caret climbs to row 6.
    editor.reflow(.{ .columns = 80, .rows = 20 });
    // The window shows rows 1..6: one row hidden above, three below.
    try std.testing.expectEqual(@as(usize, 1), editor.scroll);

    const painted = try rendered(gpa, &editor, .{ .columns = 40, .rows = 20 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ 1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↓ 3 more") != null);
    // The shown window carries its rows; the scrolled-off ones do not.
    try std.testing.expect(std.mem.indexOf(u8, painted, "l6") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l9") == null);
}
