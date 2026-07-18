//! What running a slash command produces: either `feedback` to show the user or
//! a request to open an interactive `pick`. Only the feedback arm owns memory
//! (its `content`, freed by the caller); the pick arm's ownership is described
//! on `Pick`.

const std = @import("std");

const llm = @import("../llm.zig");

pub const Outcome = union(enum) {
    feedback: Feedback,
    pick: Pick,
    /// Authenticate this subscription account, then switch to it. The app owns
    /// the flow (it must suspend the tty around the OAuth browser callback); the
    /// command only names the account.
    login: llm.Account,
    /// Drop this subscription account's stored credentials. The app owns the
    /// aftermath: logging out the active account hands the session to the next
    /// authenticated account, or forces a login when none remains.
    logout: llm.Account,

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

    /// Builds a picker's owned `options` rows, freeing every row already built
    /// when the build fails.
    pub const Options = struct {
        gpa: std.mem.Allocator,
        rows: std.ArrayList([]const u8) = .empty,

        pub fn deinit(self: *Options) void {
            for (self.rows.items) |row| self.gpa.free(row);
            self.rows.deinit(self.gpa);
        }

        /// Append `format` rendered with `args` as the next row.
        pub fn print(self: *Options, comptime format: []const u8, args: anytype) !void {
            const row = try std.fmt.allocPrint(self.gpa, format, args);
            errdefer self.gpa.free(row);
            try self.rows.append(self.gpa, row);
        }

        /// The finished rows; ownership transfers to the caller.
        pub fn toOwnedSlice(self: *Options) ![]const []const u8 {
            return self.rows.toOwnedSlice(self.gpa);
        }
    };

    /// Feedback whose content is `format` rendered with `args`.
    pub fn report(gpa: std.mem.Allocator, status: Status, comptime format: []const u8, args: anytype) !Outcome {
        return .{ .feedback = .{
            .content = try std.fmt.allocPrint(gpa, format, args),
            .is_error = status == .err,
        } };
    }

    /// Test helper: assert `outcome` is feedback with `status`, freeing its
    /// content (allocated from the testing allocator).
    pub fn expectFeedback(outcome: Outcome, status: Status) !void {
        return expectFeedbackContaining(outcome, status, "");
    }

    /// Test helper: `expectFeedback` plus a substring check on the content.
    pub fn expectFeedbackContaining(outcome: Outcome, status: Status, needle: []const u8) !void {
        switch (outcome) {
            .feedback => |feedback| {
                defer std.testing.allocator.free(feedback.content);
                try std.testing.expectEqual(status == .err, feedback.is_error);
                try std.testing.expect(std.mem.indexOf(u8, feedback.content, needle) != null);
            },
            else => return error.ExpectedFeedback,
        }
    }
};
