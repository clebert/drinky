//! What running a slash command produces: either `feedback` to show the user or
//! a request to open an interactive `pick`. Only the feedback arm owns memory
//! (its `content`, freed by the caller); the pick arm's ownership is described
//! on `Pick`.

const std = @import("std");

pub const Outcome = union(enum) {
    feedback: Feedback,
    pick: Pick,

    pub const Status = enum { ok, err };

    pub const Feedback = struct {
        /// Owned by the caller's allocator.
        content: []const u8,
        is_error: bool,
    };

    /// A request to open a picker. On selection the app hands `command` the
    /// chosen row index (`command.select`), which re-derives its list and acts on
    /// that row. `options` (each string and the slice) transfers to the app,
    /// freed when the picker closes; `current`, if set, is the row to mark and
    /// preselect.
    pub const Pick = struct {
        command: []const u8,
        title: []const u8,
        options: []const []const u8,
        current: ?usize,
    };

    /// Feedback whose content is `format` rendered with `args`.
    pub fn report(gpa: std.mem.Allocator, status: Status, comptime format: []const u8, args: anytype) !Outcome {
        return .{ .feedback = .{
            .content = try std.fmt.allocPrint(gpa, format, args),
            .is_error = status == .err,
        } };
    }
};
