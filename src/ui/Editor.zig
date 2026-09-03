//! The input-line editing model: a text buffer whose caret follows rendered
//! units. A unit is a grapheme cluster for valid UTF-8, one canonical replacement
//! for malformed or control input, or one collapsed atom.
//!
//! A large bracketed paste collapses to a `[Paste #N: …]` marker that behaves as
//! one editing unit and expands to its exact bytes on submit. A caller can append
//! its own atom under its own label, and that atom behaves the same way. The draft
//! keeps two named views: `visible` (literal text plus marker labels, for
//! rendering) and `expanded` (literal text plus atom payloads, for every send
//! boundary). It owns editing state only. The caller submits, quits, and draws.

const std = @import("std");

const paint = @import("paint.zig");
const role = @import("role.zig");
const terminal = @import("terminal");

const Editor = @This();

gpa: std.mem.Allocator,
draft: Draft,
/// The byte offset into the draft's visible buffer. Always a canonical display
/// boundary and never strictly inside a marker span.
caret: usize,
/// The first wrapped body row shown when the body is taller than its slot. The
/// window scrolls to keep the caret in view. `reflow` maintains it and `clear`
/// resets it. The rows above it show as an "N more" label on the top separator.
scroll: usize,
/// The desired logical column for vertical movement, remembered across consecutive
/// `moveUp`/`moveDown` so a step through a shorter row does not forget it. It is
/// logical, not display: an atom counts as one cell however wide its label
/// renders (see `logicalColumn`). So a marker never traps the caret at its edge.
/// It is null until a vertical step captures the caret's column. A horizontal
/// move, an edit, or a vertical move off the top or bottom row clears it back to
/// null.
goal_column: ?usize,
/// The next paste-atom ID to assign. The first real atom is 1. It is monotonic
/// for the editor's lifetime. `clear`, submit, and deletion never reset or
/// decrement it, so no two atoms ever share an ID.
paste_id_next: u64,
/// Accumulates one in-progress bracketed paste across `Input` chunks until its
/// final chunk arrives. Reused across pastes. A large paste moves its bytes out.
capture: std.ArrayList(u8),

/// An atom-aware editor draft: the visible byte buffer and the atoms collapsed
/// within it. Owned by an `Editor` while live, and detachable so a consumer can
/// retain it (steering recovery). Hence it has its own lifecycle.
pub const Draft = struct {
    /// Literal text interleaved with generated marker spans. Rendered and
    /// measured directly. A marker span is a leading guard, the label, and a
    /// trailing guard (see `marker_guard`).
    visible: std.ArrayList(u8),
    /// The atoms, sorted by `start`, non-overlapping, each within `visible`.
    atoms: std.ArrayList(Atom),

    pub const empty: Draft = .{ .visible = .empty, .atoms = .empty };

    /// One collapsed atom: its half-open visible range `[start, end)`, its stable
    /// ID, and the owned exact payload bytes (no guards or label). A collapsed
    /// large paste creates it. The range is exactly the generated marker span.
    /// The editor never infers an atom from the bytes of literal text.
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

    /// Free every payload and empty the draft. The buffers keep their capacity.
    pub fn clear(self: *Draft, gpa: std.mem.Allocator) void {
        for (self.atoms.items) |atom| gpa.free(atom.payload);
        self.atoms.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
    }

    /// Build a plain draft that holds a copy of `text` with no atoms. The caller
    /// owns the result.
    pub fn fromText(gpa: std.mem.Allocator, text: []const u8) !Draft {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        try buffer.appendSlice(gpa, text);
        return .{ .visible = buffer, .atoms = .empty };
    }

    /// Allocate the expanded text: literal bytes with each atom's exact payload
    /// spliced in for its marker span, in document order. `trim` can strip the
    /// leading and trailing whole-prompt whitespace. The caller owns the result.
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

    /// The expanded byte length, via checked additions on the visible length with
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

/// The whitespace trim that `expanded` applies.
pub const Trim = enum { none, whole_prompt };

pub const RenderOptions = struct {
    viewport_rows: usize,
    activity: ?paint.Activity = null,
};

/// One atom-aware text mutation, the sole path that edits the visible buffer.
/// Replaces `[from, to)` with `bytes`. `new_atoms` are the atoms the inserted
/// `bytes` carry, with their ranges relative to `bytes`. Each takes ownership of
/// its payload on success. A collapsed paste passes one. An append of a detached
/// draft passes its whole run under a single reservation.
const Splice = struct {
    from: usize,
    to: usize,
    bytes: []const u8 = "",
    new_atoms: []const Draft.Atom = &.{},
};

/// A paste is large past either threshold: more than `line_count_max` logical
/// (LF-delimited) lines or more than `byte_count_max` bytes.
const line_count_max = 10;
const byte_count_max = 1000;
/// The zero-width guard that brackets a marker span. U+200B is zero columns. It is
/// grapheme-break Control, so it forces a cluster break on each side. Thus a
/// marker edge is always a display boundary and cannot fuse with adjacent
/// combining text. The guards pin only the edges. The label between them is
/// ordinary text that wraps grapheme-by-grapheme like any other. So a marker is
/// one atom for editing (crossed and deleted whole) but not one unit for wrapping.
/// A marker wider than the terminal breaks across rows but stays a single atom.
const marker_guard = "\u{200B}";
/// The role a marker paints in. A marker is a label for content the user did not
/// type, so it takes the role of a label, and the typed text around it stays
/// plain.
const marker_role: role.Name = .accent;
/// The widest a marker span can be: two guards, the fixed label text, and two
/// u64s in decimal. The line form `[Paste #{d}: {d} lines]` and the byte form
/// have equal length.
const label_len_max =
    2 * marker_guard.len + "[Paste #".len + 20 + ": ".len + 20 + " lines]".len;
const whitespace = " \t\r\n";
/// The blank-line separator inserted before each draft that `appendDraft` joins
/// onto a non-empty draft. It matches the queue's `join` and the whole-prompt
/// convention.
const draft_separator = "\n\n";

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

/// The visible text — literal bytes plus marker labels — borrowed for rendering
/// and display-length checks. Never a send boundary.
pub fn visible(self: *const Editor) []const u8 {
    return self.draft.visible.items;
}

/// The expanded text for a send boundary (see `Draft.expanded`). The caller owns it.
pub fn expanded(self: *const Editor, trim: Trim) ![]u8 {
    return self.draft.expanded(self.gpa, trim);
}

/// Whether the expanded-and-trimmed prompt is empty (see `Draft.blank`).
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

/// Trim the draft's literal edges, then move it out and leave an empty draft. The
/// trim strips whole-prompt whitespace outside every atom, so a paste payload and
/// its label stay byte-exact and keep their ID. The paste-ID counter does not
/// reset, so a later atom cannot reuse an ID still live in the detached draft.
/// The caller owns the returned draft. Allocation-free, so it cannot fail.
pub fn detachTrimmed(self: *Editor) Draft {
    // Whole-prompt whitespace never includes a marker guard or label byte. So a
    // trim of the visible buffer stops at any edge atom and never splits one.
    const items = self.draft.visible.items;
    const trimmed = std.mem.trim(u8, items, whitespace);
    const lead = @intFromPtr(trimmed.ptr) - @intFromPtr(items.ptr);
    const trail = items.len - lead - trimmed.len;
    self.splice(.{ .from = items.len - trail, .to = items.len }) catch unreachable;
    self.splice(.{ .from = 0, .to = lead }) catch unreachable;
    const draft = self.draft;
    self.draft = .empty;
    self.caret = 0;
    self.scroll = 0;
    self.goal_column = null;
    return draft;
}

/// Reserve visible-buffer and atom-list capacity to append every draft in
/// `drafts`, each after a blank-line separator, so a following `appendDraft` per
/// entry cannot fail. Checked additions guard the totals.
pub fn reserveDrafts(self: *Editor, drafts: []const Draft) !void {
    return self.reserveComposition(null, drafts);
}

/// Reserve capacity to insert `lead` (when present) and every draft in `drafts`,
/// each after a blank-line separator, in one batch. The cancel composition
/// reserves the returned prompt and the recalled steering together so the later
/// `prependComposition` cannot half-complete. Checked additions guard the totals.
pub fn reserveComposition(self: *Editor, lead: ?*const Draft, drafts: []const Draft) !void {
    var visible_extra: usize = 0;
    var atoms_extra: usize = 0;
    if (lead) |source| {
        visible_extra = try std.math.add(usize, visible_extra, source.visible.items.len);
        visible_extra = try std.math.add(usize, visible_extra, draft_separator.len);
        atoms_extra = try std.math.add(usize, atoms_extra, source.atoms.items.len);
    }
    for (drafts) |draft| {
        visible_extra = try std.math.add(usize, visible_extra, draft.visible.items.len);
        visible_extra = try std.math.add(usize, visible_extra, draft_separator.len);
        atoms_extra = try std.math.add(usize, atoms_extra, draft.atoms.items.len);
    }
    try self.draft.visible.ensureUnusedCapacity(self.gpa, visible_extra);
    try self.draft.atoms.ensureUnusedCapacity(self.gpa, atoms_extra);
}

/// Move `source`'s content to the end of the draft and leave `source` empty. A
/// blank-line separator comes first when the draft is already non-empty. The move
/// preserves the atoms and their stable IDs (payloads move by pointer). Infallible
/// once `reserveDrafts` has covered it, so recall after a reservation cannot
/// half-complete.
pub fn appendDraft(self: *Editor, source: *Draft) void {
    self.moveEnd();
    if (self.draft.visible.items.len > 0) self.insert(draft_separator) catch unreachable;
    self.splice(.{
        .from = self.caret,
        .to = self.caret,
        .bytes = source.visible.items,
        .new_atoms = source.atoms.items,
    }) catch unreachable;
    // The atoms' payloads moved into this draft. Free only `source`'s buffers.
    source.atoms.deinit(self.gpa);
    source.visible.deinit(self.gpa);
    source.* = .empty;
}

/// Insert `lead` (when present) then every draft in `drafts`, in order and
/// blank-line separated, above the current content. A blank line comes before
/// that content when it is non-empty. Leave the caret at the end (after the
/// existing line). The insert consumes each source (its atoms' payloads move by
/// pointer) and leaves it empty. Infallible once `reserveComposition` has covered
/// it, so the cancel composition cannot half-complete after the worker is already
/// canceled.
pub fn prependComposition(self: *Editor, lead: ?*Draft, drafts: []Draft) void {
    const had_content = self.draft.visible.items.len > 0;
    var offset: usize = 0;
    var wrote = false;
    if (lead) |source| {
        offset = self.spliceDraftAt(offset, source, false);
        wrote = true;
    }
    for (drafts) |*source| {
        offset = self.spliceDraftAt(offset, source, wrote);
        wrote = true;
    }
    if (wrote and had_content)
        self.splice(.{ .from = offset, .to = offset, .bytes = draft_separator }) catch unreachable;
    self.moveEnd();
}

/// Splice `source`'s content into the draft at `offset` (after a blank-line
/// separator when `separate`). Move its atoms in and empty `source`. Return the
/// position just past the inserted content. Infallible once `reserveComposition`
/// has covered the batch.
fn spliceDraftAt(self: *Editor, offset: usize, source: *Draft, separate: bool) usize {
    var position = offset;
    if (separate) {
        self.splice(.{
            .from = position,
            .to = position,
            .bytes = draft_separator,
        }) catch unreachable;
        position += draft_separator.len;
    }
    self.splice(.{
        .from = position,
        .to = position,
        .bytes = source.visible.items,
        .new_atoms = source.atoms.items,
    }) catch unreachable;
    position += source.visible.items.len;
    source.atoms.deinit(self.gpa);
    source.visible.deinit(self.gpa);
    source.* = .empty;
    return position;
}

/// Accept and accumulate one bracketed-paste chunk. On the `final` chunk,
/// classify the whole paste and commit one operation. A small paste inserts its
/// exact bytes as ordinary text. A large one collapses to a marker atom. An empty
/// paste is a no-op. Byte-for-byte: no newline, tab, or control normalization.
pub fn paste(self: *Editor, bytes: []const u8, final: bool) !void {
    // Any failure discards the partial capture so a later paste cannot merge
    // stale bytes. A successful non-final chunk keeps it for the next chunk.
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
    // Reserve the ID, marker, and buffer capacity before the payload moves out,
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
        .new_atoms = &.{.{ .start = 0, .end = span.len, .id = id, .payload = payload }},
    });
    self.paste_id_next += 1;
}

/// Write a marker span — guard, label, guard — into `buffer` and return it. The
/// line form wins when a paste crosses both thresholds. The byte form's label
/// says `bytes`, not `chars`, to stay honest about arbitrary input.
fn markerSpan(buffer: []u8, id: u64, line_count: usize, byte_count: usize) []const u8 {
    if (line_count > line_count_max) {
        const form = marker_guard ++ "[Paste #{d}: {d} lines]" ++ marker_guard;
        return std.fmt.bufPrint(buffer, form, .{ id, line_count }) catch unreachable;
    }
    const form = marker_guard ++ "[Paste #{d}: {d} bytes]" ++ marker_guard;
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

    // Reject a range that cuts through an atom. Find the contiguous run it covers.
    var remove_from: usize = atoms.items.len;
    var remove_to: usize = atoms.items.len;
    for (atoms.items, 0..) |atom, index| {
        if (op.to <= atom.start or op.from >= atom.end) continue;
        if (op.from > atom.start or atom.end > op.to) return error.PasteAtomSplit;
        remove_from = @min(remove_from, index);
        remove_to = index + 1;
    }

    // Reserve first. A failure here leaves the draft untouched. The checked
    // resulting length also proves the commit's range shifts cannot overflow.
    // Every shifted offset is at most `shifted_len`, and each `start - removed`
    // stays nonnegative because a shifted atom has `start >= op.to >= removed`.
    const removed = op.to - op.from;
    const shifted_len = try std.math.add(usize, visible_list.items.len - removed, op.bytes.len);
    try visible_list.ensureTotalCapacity(self.gpa, shifted_len);
    try atoms.ensureUnusedCapacity(self.gpa, op.new_atoms.len);

    // Commit. Every step below is infallible.
    for (atoms.items[remove_from..remove_to]) |atom| self.gpa.free(atom.payload);
    atoms.replaceRangeAssumeCapacity(remove_from, remove_to - remove_from, &.{});
    visible_list.replaceRangeAssumeCapacity(op.from, op.to - op.from, op.bytes);
    for (atoms.items) |*atom| {
        if (atom.start >= op.to) {
            atom.start = atom.start - removed + op.bytes.len;
            atom.end = atom.end - removed + op.bytes.len;
        }
    }
    var insert_index = atomIndexAfter(atoms.items, op.from);
    for (op.new_atoms) |atom| {
        atoms.insertAssumeCapacity(insert_index, .{
            .start = op.from + atom.start,
            .end = op.from + atom.end,
            .id = atom.id,
            .payload = atom.payload,
        });
        insert_index += 1;
    }
    self.goal_column = null;
    if (self.caret >= op.to) {
        self.caret = self.caret - removed + op.bytes.len;
    } else if (self.caret > op.from) {
        self.caret = op.from + op.bytes.len;
    }
    // Adjacent literal text can fuse into one grapheme after the edit. Re-clamp
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

/// The index of the first atom that lies wholly at or after `offset`. A new atom
/// that starts there takes this slot.
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

/// Move the caret one wrapped row up and keep the sticky logical goal column. On
/// the top row it falls back to `moveHome`. The column is logical, so a marker
/// counts as one cell and never traps the caret at its edge (see `logicalColumn`
/// and `logicalOffset`).
pub fn moveUp(self: *Editor, columns: usize) void {
    const columns_max = paint.contentColumns(columns);
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns_max,
    }).rows_before;
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
    // before-edge instead. A step up then always makes upward progress.
    if (result >= self.caret) {
        if (self.atomEndingAt(self.caret)) |atom| result = atom.start;
    }
    self.caret = result;
    std.debug.assert(self.legalCaret(self.caret));
}

/// Move the caret one wrapped row down and keep the sticky logical goal column.
/// On the bottom row it falls back to `moveEnd`. See `moveUp`.
pub fn moveDown(self: *Editor, columns: usize) void {
    const columns_max = paint.contentColumns(columns);
    const text = self.draft.visible.items;
    const row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns_max,
    }).rows_before;
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

/// The byte span of the visible buffer that display `row` wraps to, or null when
/// `row` is past the last wrapped row. Both vertical-movement walks take their row
/// start from this span, so they measure the wrapped geometry the renderer does.
fn wrappedSpan(
    self: *const Editor,
    columns_max: usize,
    row: usize,
) ?terminal.width.Wrapper.Span {
    var iterator = terminal.width.wrapper(self.draft.visible.items, columns_max);
    var current: usize = 0;
    while (iterator.nextSpan()) |span| : (current += 1) {
        if (current == row) return span;
    }
    return null;
}

/// The caret's logical column within display `row`: each literal grapheme counts
/// its display width, but every atom counts as a single cell. The walk
/// starts at the row's first legal caret boundary. It skips a marker that wrapped
/// onto this row to its end. It counts a marker that begins the row as its single
/// cell.
fn logicalColumn(self: *const Editor, columns_max: usize, row: usize) usize {
    const text = self.draft.visible.items;
    const span = self.wrappedSpan(columns_max, row) orelse return 0;
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

/// The byte offset at `target`'s logical column on its display row: the inverse
/// of `logicalColumn`, clamped to the last offset the row keeps. A row past the
/// last wrapped row yields the buffer end. The walk always crosses atoms whole, so
/// the result is a legal caret boundary. It never lands strictly inside a marker,
/// even when the marker wraps across rows.
fn logicalOffset(self: *const Editor, columns_max: usize, target: LogicalCaret) usize {
    const text = self.draft.visible.items;
    const span = self.wrappedSpan(columns_max, target.row) orelse return text.len;
    // A word wrap can end a row before the margin, and every offset past that end
    // belongs to the row under it. The walk stops at the last offset this row
    // keeps, or a step up lands on the row it started from and stalls there.
    const end = terminal.width.caretEnd(text, span, columns_max);
    var index = self.legalAtOrAfter(span.start);
    var logical: usize = 0;
    while (index < end and logical < target.column) {
        if (self.atomStartingAt(index)) |atom| {
            logical += 1;
            index = atom.end;
        } else {
            const next = terminal.width.boundaryAfter(text, index);
            const unit = terminal.width.ofText(text[index..next]);
            // Stop before a wide grapheme the goal column falls inside. Do not
            // overshoot past it.
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
/// window. Call once per repaint. Pass the same `size` whose columns and rows
/// `render` and `rows` will use, so all three agree on the window.
pub fn reflow(self: *Editor, size: terminal.View.Size) void {
    const columns_max = paint.contentColumns(size.columns);
    const text = self.draft.visible.items;
    const total_body = self.bodyRows(columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(size.rows));
    const caret_row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns_max,
    }).rows_before;
    if (caret_row < self.scroll) self.scroll = caret_row;
    if (caret_row >= self.scroll + visible_rows) self.scroll = caret_row - visible_rows + 1;
    self.scroll = @min(self.scroll, total_body - visible_rows);
}

/// The physical rows the editor occupies: two separators plus the wrapped body.
/// The body stops at its scroll limit for `size.rows`.
pub fn rows(self: *const Editor, size: terminal.View.Size) usize {
    const columns_max = paint.contentColumns(size.columns);
    const total_body = self.bodyRows(columns_max);
    return paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// The body rows the editor lays out: the wrapped text, plus the empty trailing
/// row for a caret wrapped past a full-width final line. The wrap itself never
/// yields that row (see `caretPosition`).
fn bodyRows(self: *const Editor, columns_max: usize) usize {
    const text = self.draft.visible.items;
    const wrapped = terminal.width.rows(text, columns_max);
    const caret_row = terminal.width.caret(text, .{
        .offset = self.caret,
        .columns_max = columns_max,
    }).rows_before;
    return wrapped + @intFromBool(caret_row == wrapped);
}

/// Stream the open input area and wrapped visible text through `placement`.
/// Place the terminal caret with no side decoration. Assumes `reflow` set the
/// scroll from the same viewport dimensions.
pub fn render(
    self: *const Editor,
    placement: *const paint.Placement,
    options: *const RenderOptions,
) !void {
    const columns_max = paint.contentColumns(placement.columns);
    const text = self.draft.visible.items;
    const total_body = self.bodyRows(columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(options.viewport_rows));
    const atoms = self.draft.atoms.items;
    const marks = try self.gpa.alloc(paint.Mark, atoms.len);
    defer self.gpa.free(marks);
    for (marks, atoms) |*mark, atom|
        mark.* = .{ .start = atom.start, .end = atom.end, .role = marker_role };
    try paint.framed(placement, &.{
        .body = text,
        .body_rows = visible_rows,
        .caret = self.caretPosition(placement.columns),
        .hidden_above = self.scroll,
        .hidden_below = total_body - self.scroll - visible_rows,
        .trailing_row = total_body > terminal.width.rows(text, columns_max),
        .marks = marks,
        .activity = options.activity,
    });
}

/// The caret's position within the rendered rows. Row 0 is the top separator.
/// A caret at a full-width line's end reports the empty trailing row that
/// `bodyRows` reserves.
fn caretPosition(self: *const Editor, columns: usize) terminal.View.Caret {
    const position = terminal.width.caret(self.draft.visible.items, .{
        .offset = self.caret,
        .columns_max = paint.contentColumns(columns),
    });
    return .{
        .row = 1 + (position.rows_before - self.scroll),
        .column = position.column,
    };
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
    // A base emoji plus a skin-tone modifier is one cluster.
    try editor.insert("👍\u{1F3FD}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // A base letter plus a combining mark.
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
    // A base letter typed before a dangling combining mark lands the caret
    // after the completed cluster, not inside it.
    try editor.insert("\u{0301}");
    editor.moveHome();
    try editor.insert("e");
    try std.testing.expectEqualStrings("e\u{0301}", editor.visible());
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.visible());
    // One regional indicator typed before another completes a flag. The caret
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

// Eleven logical lines: ten LFs that join eleven single-letter lines.
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

    // Eleven lines collapse. The label counts the empty trailing line too.
    editor.clear();
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, eleven_lines);

    // A trailing LF contributes the eleventh line.
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
    try expectExpanded(&editor, .none, longer);
}

test "the byte threshold counts bytes, not characters" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // 501 two-byte codepoints on one line: 1002 bytes, far fewer characters.
    const multibyte = "é" ** 501;
    try pasteWhole(&editor, multibyte);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 1002 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, multibyte);

    // 1001 malformed bytes on one line collapse the same way and round-trip.
    editor.clear();
    const malformed = "\xff" ** 1001;
    try pasteWhole(&editor, malformed);
    try std.testing.expectEqualStrings("\u{200B}[Paste #2: 1001 bytes]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, malformed);
}

test "a lone CR is payload, and CRLF counts one line" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Eleven CR-terminated fragments have no LF, so one logical line. It is
    // short, so it stays literal.
    try pasteWhole(&editor, "x\r" ** 11);
    try std.testing.expectEqual(@as(usize, 0), editor.draft.atoms.items.len);

    // Eleven CRLF-terminated fragments are eleven logical lines and collapse. The
    // lone CRs survive in the payload.
    editor.clear();
    const crlf = "x\r\n" ** 11;
    try pasteWhole(&editor, crlf);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 12 lines]\u{200B}", editor.visible());
    try expectExpanded(&editor, .none, crlf);
}

test "the line form wins when both thresholds are crossed" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Eleven lines of a hundred columns each: over both thresholds.
    const big = ("x" ** 100 ++ "\n") ** 10 ++ "x" ** 100;
    try pasteWhole(&editor, big);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
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
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
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
        "A\u{200B}[Paste #1: 11 lines]\u{200B}B\u{200B}[Paste #2: 1001 bytes]\u{200B}C",
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

    // Delete the first atom. The second keeps its ID and label.
    editor.moveHome();
    editor.moveRight(); // Across atom #1 to its after-edge.
    editor.backspace(); // Removes atom #1.
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 2), editor.draft.atoms.items[0].id);

    // A later paste is #3 and sorts after #2. It never reuses 1.
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
    // The caret sits after "cd". Step left across "d", "c" to the marker's after-edge.
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
    // "e" and the combining mark fuse. The caret clamps past the whole cluster.
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
    // mark). The next crosses the whole marker to the before-edge.
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

    // The marker's row holds a single logical cell. Goal column 2 clamps past it
    // to the after-edge and does not snap back to the marker's start.
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
    // Row 0 is "This". Row 1 is a marker at the line start followed by " foo".
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
    // Row 0 is "ab". Row 1 begins with a marker, then "cd".
    try editor.insert("ab\n");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    // The caret right after the marker is logical column 1 (the marker is the one
    // cell at column 0). So a first step up lands at column 1 of "ab".
    editor.caret = atom.end;
    editor.goal_column = null;
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);

    // Symmetric: from row 0 column 1, a step down returns to just after the
    // marker. It stops past the one cell and no further, at the after-edge.
    editor.caret = 1;
    editor.goal_column = null;
    editor.moveDown(80);
    try std.testing.expectEqual(atom.end, editor.caret);
}

test "vertical movement treats a mid-line marker as one column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Row 0 is wide padding. Row 1 is "ab" + marker + "cd".
    try editor.insert("xxxxxxxx\nab");
    try pasteWhole(&editor, eleven_lines);
    try editor.insert("cd");
    const atom = editor.draft.atoms.items[0];

    // Row 1 columns: a(0..1) b(1..2) marker(2..3) c(3..4) d(4..5). Goal column 3
    // lands on the after-edge. Goal column 4 lands one cell into the trailing "cd".
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
    try pasteWhole(&editor, eleven_lines); // The 21-column label wraps at width 5.
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    editor.caret = 1; // Row 0 of "ab".
    // Step down repeatedly. The caret must never land strictly inside the marker
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
    try pasteWhole(&editor, eleven_lines); // The 21-column label wraps at width 5.
    try editor.insert("\ncd");
    const atom = editor.draft.atoms.items[0];

    editor.moveEnd(); // In "cd", below the wrapped marker.
    // Step up repeatedly. The caret must never land strictly inside the marker
    // and must climb past its near edge, not stick at the far edge.
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
    // Row 1 opens with a two-column grapheme. The test involves no atoms.
    try editor.insert("ab\n\u{4F60}c"); // U+4F60 spans columns 0..2.
    editor.caret = 1; // Row 0, column 1 (after "a").
    editor.moveDown(80);
    // Goal column 1 falls inside the wide grapheme. Clamp to the row start,
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
    const caret_row = terminal.width.caret(editor.visible(), .{
        .offset = editor.caret,
        .columns_max = columns_max,
    }).rows_before;
    const window = @min(editor.bodyRows(columns_max), paint.bodyLimit(20));
    try std.testing.expect(caret_row >= editor.scroll);
    try std.testing.expect(caret_row < editor.scroll + window);
}

test "marker guards are zero-column and absent from expanded output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    // The visible label measures exactly its printable width. The guards add none.
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
    // Expansion happens before the trim, so edge whitespace trims like literal.
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
    // A clear frees the atom payloads. The already-taken copy is unaffected, so
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

test "detachTrimmed strips literal edges but keeps a paste payload byte-exact" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("  ");
    try pasteWhole(&editor, "  " ++ eleven_lines ++ "  ");
    try editor.insert("  ");
    var draft = editor.detachTrimmed();
    defer draft.deinit(gpa);

    try std.testing.expectEqualStrings("", editor.visible());
    try std.testing.expectEqual(@as(u64, 2), editor.paste_id_next);
    try std.testing.expectEqual(@as(usize, 1), draft.atoms.items.len);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", draft.visible.items);
    const payload = try draft.expanded(gpa, .none);
    defer gpa.free(payload);
    try std.testing.expectEqualStrings("  " ++ eleven_lines ++ "  ", payload);
}

test "detachTrimmed on literal text trims like the whole-prompt rule" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("  hello world  ");
    var draft = editor.detachTrimmed();
    defer draft.deinit(gpa);
    try std.testing.expectEqualStrings("hello world", draft.visible.items);
    try std.testing.expectEqualStrings("", editor.visible());
}

test "appendDraft joins a detached draft after in-progress text, atom live" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines); // #1
    var recalled = editor.detachTrimmed();
    defer recalled.deinit(gpa);

    try editor.insert("draft");
    try editor.reserveDrafts(&.{recalled});
    editor.appendDraft(&recalled);
    try std.testing.expectEqualStrings(
        "draft\n\n\u{200B}[Paste #1: 11 lines]\u{200B}",
        editor.visible(),
    );
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 1), editor.draft.atoms.items[0].id);
    try expectExpanded(&editor, .none, "draft\n\n" ++ eleven_lines);
}

test "appendDraft onto an empty draft adds no separator" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    var recalled = editor.detachTrimmed();
    defer recalled.deinit(gpa);

    try editor.reserveDrafts(&.{recalled});
    editor.appendDraft(&recalled);
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());
}

test "paste IDs stay unique across detach and append with no reuse" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    var first = editor.detachTrimmed();
    defer first.deinit(gpa);
    try editor.paste("z" ** 1001, true);
    var second = editor.detachTrimmed();
    defer second.deinit(gpa);

    try editor.reserveDrafts(&.{ first, second });
    editor.appendDraft(&first);
    editor.appendDraft(&second);
    try std.testing.expectEqual(@as(u64, 1), editor.draft.atoms.items[0].id);
    try std.testing.expectEqual(@as(u64, 2), editor.draft.atoms.items[1].id);
    try pasteWhole(&editor, eleven_lines);
    try std.testing.expectEqual(@as(usize, 3), editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 3), editor.draft.atoms.items[2].id);
}

test "reserveDrafts covers appendDraft against allocation failure and leaks nothing" {
    var fail_index: usize = 0;
    while (fail_index < 30) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const gpa = failing.allocator();
        var editor = Editor.init(gpa);
        defer editor.deinit();
        editor.insert("keep") catch continue;

        var source = Editor.init(gpa);
        source.paste(eleven_lines, true) catch {
            source.deinit();
            continue;
        };
        var recalled = source.detachTrimmed();
        source.deinit();

        editor.reserveDrafts(&.{recalled}) catch {
            recalled.deinit(gpa);
            // A failed reservation leaves the prior draft intact.
            try std.testing.expectEqualStrings("keep", editor.visible());
            continue;
        };
        // Reserved, so the move cannot fail (any internal allocation panics).
        editor.appendDraft(&recalled);
        try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    }
}

test "reserveDrafts covers several drafts" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("keep");

    var source = Editor.init(gpa);
    defer source.deinit();
    try source.paste(eleven_lines, true);
    var first = source.detachTrimmed();
    defer first.deinit(gpa);
    try source.paste(eleven_lines, true);
    var second = source.detachTrimmed();
    defer second.deinit(gpa);

    try editor.reserveDrafts(&.{ first, second });
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    editor.appendDraft(&first);
    editor.appendDraft(&second);
    try std.testing.expectEqual(@as(usize, 2), editor.draft.atoms.items.len);
}

test render {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("hi");
    // Top separator, the body row, bottom separator.
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 80, .rows = 24 }));
    // The open body puts the caret directly after "hi".
    try expectCaretAt(&editor, 80, .{ .row = 1, .column = 2 });

    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "─") != null);
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘" }) |glyph|
        try std.testing.expect(std.mem.indexOf(u8, painted, glyph) == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "━") == null);
    // The live input, so the view shows the hardware cursor.
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.cursor_show) != null);
}

test "a marker renders its label into the input area" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try pasteWhole(&editor, eleven_lines);
    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "[Paste #1: 11 lines]") != null);
}

// A marker stands for content the user did not type, so it takes the accent role.
// The typed text around it stays plain, and a typed marker-looking string is
// typed text.
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
    try std.testing.expect(std.mem.indexOf(u8, painted, row) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, role.sequence(.accent)));
}

test "a full-width line reserves an empty trailing row for the wrapped caret" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("abc"); // Fills the three content columns exactly.
    editor.reflow(.{ .columns = 3, .rows = 24 });

    // The caret wraps onto an empty trailing row between the separators.
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 2, .column = 0 });
    try std.testing.expectEqual(@as(usize, 4), try renderedRows(gpa, &editor, 3));

    // A caret move back off the margin drops the trailing row again.
    editor.moveLeft();
    editor.reflow(.{ .columns = 3, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 1, .column = 2 });
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
    try expectCaretAt(&editor, size.columns, .{ .row = 1, .column = 2 });
    const painted = try rendered(gpa, &editor, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "你") != null);
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘" }) |glyph|
        try std.testing.expect(std.mem.indexOf(u8, painted, glyph) == null);
}

// A wrapped row ends on the last cell it fills. The blank the wrap breaks at holds
// no content, so no copy of the input area carries it.
test "a wrapped input row paints no trailing blank" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("aaa bbbb");

    const size: terminal.View.Size = .{ .columns = 5, .rows = 24 };
    editor.reflow(size);
    const painted = try rendered(gpa, &editor, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\r\naaa\r\nbbbb\r\n") != null);
}

test "activity crosses the separators without changing the editor height" {
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
        try std.testing.expect(std.mem.indexOf(u8, first, glyph) != null);
    for ([_][]const u8{ "┌", "┐", "│", "└", "┘", "┃" }) |glyph|
        try std.testing.expect(std.mem.indexOf(u8, first, glyph) == null);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqual(
        std.mem.count(u8, first, "\r\n"),
        std.mem.count(u8, second, "\r\n"),
    );
}

// Renders `editor` into a fresh view and returns the frame's bytes, caller-owned.
fn rendered(gpa: std.mem.Allocator, editor: *const Editor, size: terminal.View.Size) ![]u8 {
    return renderedWithOptions(gpa, editor, size, &.{ .viewport_rows = size.rows });
}

fn renderedWithOptions(
    gpa: std.mem.Allocator,
    editor: *const Editor,
    size: terminal.View.Size,
    options: *const RenderOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try editor.render(&placement, options);
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
    // Separators plus "a" plus the empty new line make four rows.
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
    editor.caret = 1; // Wrapped at three content columns: row 0, column 1.
    editor.moveDown(3);
    try std.testing.expectEqual(@as(usize, 4), editor.caret); // Row 1, column 1.
    editor.moveUp(3);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
}

// The input wraps between words like every other block. The caret then reads the
// row the whole draft gives it, which the text behind the caret can move.
test "the caret follows a word the wrap moves to the next row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("aaa bbbb");
    const columns = 5;
    try std.testing.expectEqual(@as(usize, 2), editor.bodyRows(columns));

    // "bbbb" does not fit behind "aaa ", so the whole word sits on row 1.
    editor.caret = 6; // In "bbbb", after its second byte.
    const position: terminal.View.Caret = .{ .row = 2, .column = 2 };
    try std.testing.expectEqual(position, editor.caretPosition(columns));
    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 2), editor.caret); // Row 0, column 2.
    editor.moveDown(columns);
    try std.testing.expectEqual(@as(usize, 6), editor.caret);
}

// A word wrap ends a row before the margin, so a goal column can reach past the
// row above. The step up must still land on that row, or the sticky goal holds the
// caret where it started and every further step up does nothing.
test "a step up onto a short wrapped row lands on that row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("aaa bbbb");
    const columns = 5;
    editor.caret = 8; // End of "bbbb": row 1, column 4.
    try std.testing.expectEqual(@as(usize, 2), terminal.width.rows(editor.visible(), columns));

    // Row 0 holds "aaa" and the blank it breaks at. Its last caret is column 3.
    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    try expectCaretAt(&editor, columns, .{ .row = 1, .column = 3 });
    // The goal survives the clamp, so the way back down keeps the column.
    editor.moveDown(columns);
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
    // A second step up from the top row falls back to the start.
    editor.moveUp(columns);
    editor.moveUp(columns);
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
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
    editor.moveLeft(); // Column 1. The move forgets the old goal.
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
    try editor.insert("z"); // "xyz". The edit forgets the old goal.
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
    // Ten single-column rows. A 20-row viewport caps the body at six.
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    editor.reflow(.{ .columns = 80, .rows = 20 });
    // Two separators plus the six shown body rows, not the whole ten-row body.
    try std.testing.expectEqual(@as(usize, 8), editor.rows(.{ .columns = 80, .rows = 20 }));
    // The caret ends on the last row, so the window ends there.
    try std.testing.expectEqual(@as(usize, 4), editor.scroll);
    // Window-relative: below the top separator and the five earlier shown rows.
    try std.testing.expectEqual(@as(usize, 6), editor.caretPosition(80).row);

    // A climb to the top drags the window back up with the caret.
    for (0..9) |_| editor.moveUp(80);
    editor.reflow(.{ .columns = 80, .rows = 20 });
    try std.testing.expectEqual(@as(usize, 0), editor.scroll);
    try std.testing.expectEqual(@as(usize, 1), editor.caretPosition(80).row);
}

test "the separators report the rows scrolled out of view" {
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
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ Hidden: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↓ Hidden: 3") != null);
    // The shown window carries its rows. The scrolled-off ones do not.
    try std.testing.expect(std.mem.indexOf(u8, painted, "l6") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l9") == null);
}

// The cancel composition: a lead prompt and recalled steering drafts prepend above
// the in-progress line, blank-line separated. The caret rests at the end, and
// every paste atom survives for an exact expansion.
test "prependComposition composes lead, drafts, then the current line" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("typing");

    // The lead carries a collapsed paste, so its atom must survive the prepend.
    var builder = Editor.init(gpa);
    defer builder.deinit();
    const payload = "line\n" ** 15;
    try builder.paste(payload, true);
    var lead = builder.detachTrimmed();
    defer lead.deinit(gpa);

    var drafts = [_]Draft{
        try Draft.fromText(gpa, "steer one"),
        try Draft.fromText(gpa, "steer two"),
    };
    defer for (&drafts) |*draft| draft.deinit(gpa);

    try editor.reserveComposition(&lead, &drafts);
    editor.prependComposition(&lead, &drafts);

    const shown = editor.visible();
    try std.testing.expect(std.mem.indexOf(u8, shown, "[Paste #1: 16 lines]") != null);
    try std.testing.expect(std.mem.endsWith(u8, shown, "\n\nsteer one\n\nsteer two\n\ntyping"));
    // The caret rests after the in-progress line so typing resumes there.
    try std.testing.expectEqual(shown.len, editor.caret);
    // The lead's paste atom survives and expands to its exact bytes.
    try std.testing.expectEqual(@as(usize, 1), editor.draft.atoms.items.len);
    const text = try editor.expanded(.none);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, payload));
    try std.testing.expect(std.mem.endsWith(u8, text, "\n\nsteer one\n\nsteer two\n\ntyping"));
}
