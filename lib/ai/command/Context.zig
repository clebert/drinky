//! Ambient session state handed to every slash-command handler, mirroring the
//! tool Context.

const std = @import("std");

const llm = @import("../llm.zig");
const skills = @import("../skills.zig");
const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");

const Context = @This();

gpa: std.mem.Allocator,
/// Filesystem I/O for commands that load runtime-discovered content.
io: std.Io,
agent: *Agent,
/// For account-qualified model selection.
accounts: *Accounts,
/// Runtime-discovered skills; null in command tests that do not need them.
skill_registry: ?*const skills.Registry = null,

/// A slash command's result. Feedback, picker, and prompt allocations transfer
/// to the caller; account and conversation actions are owned by the app.
pub const Outcome = union(enum) {
    feedback: Feedback,
    pick: Pick,
    /// Submit an expanded skill instruction as a user turn. The app records the
    /// skill marker and optional task while sending `content` to the model.
    prompt: Prompt,
    /// Authenticate this subscription account, then switch to it. The app owns
    /// the flow (it must suspend the tty around the OAuth browser callback).
    login: llm.Account,
    /// Drop this subscription account's stored credentials. Logging out the active
    /// account hands the session to the next authenticated one, or forces a login.
    logout: llm.Account,
    /// Switch to this already-authenticated account. The app owns the switch so
    /// its configured per-account default model applies.
    switch_account: llm.Account,
    /// Clear conversation and presentation state while preserving configuration.
    new_conversation,
    /// Show the complete provider-neutral system prompt assembled by the app.
    show_system_prompt,

    pub const Status = enum { ok, err };

    pub const Feedback = struct {
        /// Owned by the caller's allocator.
        content: []const u8,
        is_error: bool,
    };

    pub const Prompt = struct {
        name: []const u8,
        arguments: []const u8,
        content: []const u8,

        pub fn deinit(self: *const Prompt, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.arguments);
            gpa.free(self.content);
        }
    };

    /// A request to open a picker; a selection routes straight to `select`.
    /// `options` (each row and the slice) transfers to the app, freed when the
    /// picker closes; `current`, if set, is the row to mark and preselect.
    pub const Pick = struct {
        select: *const fn (*Context, usize) anyerror!Outcome,
        title: []const u8,
        options: []const []const u8,
        current: ?usize,
    };

    /// Builds a picker's owned rows, freeing those already built when the build fails.
    pub const Options = struct {
        gpa: std.mem.Allocator,
        rows: std.ArrayList([]const u8) = .empty,

        pub fn deinit(self: *Options) void {
            for (self.rows.items) |row| self.gpa.free(row);
            self.rows.deinit(self.gpa);
        }

        pub fn print(self: *Options, comptime format: []const u8, args: anytype) !void {
            const row = try std.fmt.allocPrint(self.gpa, format, args);
            errdefer self.gpa.free(row);
            try self.rows.append(self.gpa, row);
        }

        pub fn toOwnedSlice(self: *Options) ![]const []const u8 {
            return self.rows.toOwnedSlice(self.gpa);
        }
    };

    /// Feedback whose content is `format` rendered with `args`.
    pub fn report(
        gpa: std.mem.Allocator,
        status: Status,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return .{ .feedback = .{
            .content = try std.fmt.allocPrint(gpa, format, args),
            .is_error = status == .err,
        } };
    }

    /// Test helper: assert feedback with `status`, freeing its content (testing allocator).
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
