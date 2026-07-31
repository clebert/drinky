//! Ambient session state that every slash-command handler receives. It mirrors
//! the tool Context.

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
/// Runtime-discovered skills. Null in command tests that do not need them.
skill_registry: ?*const skills.Registry = null,

/// A slash command's result. Notice, event, picker, and prompt allocations
/// transfer to the caller. The app owns account and conversation actions. A
/// notice lasts until the next user action. An event belongs in the transcript.
pub const Outcome = union(enum) {
    notice: Message,
    event: Message,
    pick: Pick,
    /// Submit an expanded skill instruction as a user turn. The app records the
    /// skill marker and optional task when it sends `content` to the model.
    prompt: Prompt,
    /// Authenticate this subscription account, then switch to it. The app owns
    /// the flow (it must suspend the tty around the OAuth browser callback).
    login: llm.Account,
    /// Drop this subscription account's stored credentials. A logout of the
    /// active account hands the session to the next authenticated one, or
    /// forces a login.
    logout: llm.Account,
    /// Switch to this already-authenticated account. The app owns the switch so
    /// its configured per-account default model applies.
    switch_account: llm.Account,
    /// Clear conversation and presentation state but keep the configuration.
    new_conversation,
    /// Show the complete provider-neutral system prompt assembled by the app.
    show_system_prompt,

    pub const Severity = enum { information, failure };

    pub const Message = struct {
        /// Owned by the caller's allocator.
        content: []const u8,
        severity: Severity,
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

    /// A request to open a picker. A selection routes straight to `select`.
    /// `options` (each row and the slice) transfers to the app. The app frees
    /// them when the picker closes. The request borrows the title and the
    /// cancellation message. `current`, if set, is the row to mark and
    /// preselect.
    pub const Pick = struct {
        select: *const fn (*Context, usize) anyerror!Outcome,
        title: []const u8,
        cancellation_message: []const u8,
        options: []const []const u8,
        current: ?usize,
    };

    /// Builds a picker's owned rows. When the build fails, it frees the rows already built.
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

    /// A transient notice whose content is `format` rendered with `args`.
    pub fn reportNotice(
        gpa: std.mem.Allocator,
        severity: Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return report(.notice, gpa, severity, format, args);
    }

    /// A transcript event whose content is `format` rendered with `args`.
    pub fn reportEvent(
        gpa: std.mem.Allocator,
        severity: Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return report(.event, gpa, severity, format, args);
    }

    fn report(
        comptime destination: enum { notice, event },
        gpa: std.mem.Allocator,
        severity: Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        const message: Message = .{
            .content = try std.fmt.allocPrint(gpa, format, args),
            .severity = severity,
        };
        return switch (destination) {
            .notice => .{ .notice = message },
            .event => .{ .event = message },
        };
    }

    /// Test helper: assert a notice and free its content (testing allocator).
    pub fn expectNotice(outcome: Outcome, severity: Severity) !void {
        return expectNoticeContaining(outcome, severity, "");
    }

    /// `expectNotice` plus a substring check on the content.
    pub fn expectNoticeContaining(
        outcome: Outcome,
        severity: Severity,
        needle: []const u8,
    ) !void {
        switch (outcome) {
            .notice => |notice| try expectMessage(&notice, severity, needle),
            else => return error.ExpectedNotice,
        }
    }

    /// Test helper: assert an event and free its content (testing allocator).
    pub fn expectEvent(outcome: Outcome, severity: Severity) !void {
        switch (outcome) {
            .event => |event| try expectMessage(&event, severity, ""),
            else => return error.ExpectedEvent,
        }
    }

    fn expectMessage(message: *const Message, severity: Severity, needle: []const u8) !void {
        defer std.testing.allocator.free(message.content);
        try std.testing.expectEqual(severity, message.severity);
        try std.testing.expect(std.mem.indexOf(u8, message.content, needle) != null);
    }
};
