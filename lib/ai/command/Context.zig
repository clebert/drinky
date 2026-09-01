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
/// Runtime-discovered skills. Null in the command tests that do not need them.
skill_registry: ?*const skills.Registry = null,
/// The host hook that states a wait. Null in the command tests that do not need
/// it.
wait: ?Wait = null,

/// The host hook that a command calls before a step that blocks. A command runs
/// on the thread that paints and reads the keys, so a network step stops the
/// whole interface. The line the host paints tells the user what that stop is.
pub const Wait = struct {
    /// The host state that `paint` writes through. The host owns it.
    host: *anyopaque,
    paint: *const fn (*anyopaque, []const u8) void,
};

/// A slash command's result. Notice, event, picker, and prompt allocations
/// transfer to the caller. The app owns account and conversation actions. A
/// notice lasts until the next user action. An event belongs in the transcript.
pub const Outcome = union(enum) {
    notice: Message,
    /// Drinky did not run this slash line. The app shows the message, keeps the line
    /// in the editor, sends nothing to the model, and opens no picker. The line can
    /// hold text that the user still needs.
    refusal: Message,
    event: Message,
    pick: Pick,
    /// Submit an expanded skill instruction as a user turn. The app records the
    /// skill head and the optional task when it sends `content` to the model.
    prompt: Prompt,
    /// Write this text into the editor in place of the draft. A picked line that
    /// takes an argument lands here, so the user completes it and sends it. The
    /// bytes transfer to the caller.
    editor_text: []const u8,
    /// Authenticate this account, then switch to it. The app owns the flow. It
    /// must suspend the tty around the OAuth browser callback.
    login: llm.Account,
    /// Drop this account's stored credentials. A logout of the
    /// active account hands the session to the next authenticated one, or
    /// forces a login.
    logout: llm.Account,
    /// Switch to this already-authenticated account. The app owns the switch so
    /// the model that account ran last applies. An account that ran none takes
    /// no model, and the user picks one.
    switch_account: llm.Account,
    /// The credential store of this account held the credential of another
    /// principal, so the step stopped before its model request. The app drops
    /// the evidence of the replaced principal and reports the step that
    /// follows. A turn that meets the same replacement takes that transition.
    credential_replaced: llm.Account,
    /// Clear conversation and presentation state but keep the configuration.
    new_conversation,
    /// Show the complete provider-neutral system prompt assembled by the app.
    show_system_prompt,

    pub const Severity = enum { information, warning, failure };

    pub const Message = struct {
        /// Owned by the caller's allocator.
        content: []const u8,
        severity: Severity,

        /// A message whose content is `format` rendered with `args`.
        pub fn print(
            gpa: std.mem.Allocator,
            severity: Severity,
            comptime format: []const u8,
            args: anytype,
        ) !Message {
            return .{
                .content = try std.fmt.allocPrint(gpa, format, args),
                .severity = severity,
            };
        }

        /// Test helper: assert the severity and a substring, then free the content
        /// (testing allocator).
        pub fn expect(self: *const Message, severity: Severity, needle: []const u8) !void {
            defer std.testing.allocator.free(self.content);
            try std.testing.expectEqual(severity, self.severity);
            try std.testing.expect(std.mem.indexOf(u8, self.content, needle) != null);
        }
    };

    pub const Prompt = struct {
        name: []const u8,
        arguments: []const u8,
        content: []const u8,
        /// The file that Drinky expanded into `content`. The transcript box names
        /// it, because `content` itself never reaches the screen.
        source: []const u8,

        pub fn deinit(self: *const Prompt, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.arguments);
            gpa.free(self.content);
            gpa.free(self.source);
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
        /// A line the app records beside this picker, or null where the step
        /// reports nothing. A step that both reports and opens a list needs it.
        /// A cache write that failed must not close a list that arrived. The
        /// content transfers to the app.
        report: ?Message = null,
        /// Build this same picker again, or null where the picker cannot return.
        /// A picker that a row of this one opens keeps the opener, so Esc there
        /// returns here. The app owns that trail, so a step names itself alone
        /// and knows nothing of the step above it.
        reopen: ?Opener = null,
    };

    /// Build one picker from the live state. A selector takes the row index
    /// alone and holds no earlier choice, so a step of a stepped command needs
    /// one opener for each value of the choice that reached it.
    pub const Opener = *const fn (*Context) anyerror!Outcome;

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
        const message: Message = try Message.print(gpa, severity, format, args);
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
            .notice => |notice| try notice.expect(severity, needle),
            else => return error.ExpectedNotice,
        }
    }

    /// Test helper: assert a refusal and free its content (testing allocator).
    pub fn expectRefusal(outcome: Outcome, severity: Severity) !void {
        return expectRefusalContaining(outcome, severity, "");
    }

    /// `expectRefusal` plus a substring check on the content.
    pub fn expectRefusalContaining(
        outcome: Outcome,
        severity: Severity,
        needle: []const u8,
    ) !void {
        switch (outcome) {
            .refusal => |refusal| try refusal.expect(severity, needle),
            else => return error.ExpectedRefusal,
        }
    }

    /// Test helper: assert an event and free its content (testing allocator).
    pub fn expectEvent(outcome: Outcome, severity: Severity) !void {
        switch (outcome) {
            .event => |event| try event.expect(severity, ""),
            else => return error.ExpectedEvent,
        }
    }
};

/// State the wait of a model fetch of `account`. The requests of a fetch run on
/// the thread that paints and reads the keys, so the interface stops until they
/// end. The line states that stop, so it never reads as a hang.
pub fn stateFetchWait(self: *const Context, account: llm.Account) !void {
    if (self.wait == null) return;
    const text = try std.fmt.allocPrint(
        self.gpa,
        "Drinky fetches the model list of {s}. The interface waits for the provider.",
        .{account.label()},
    );
    defer self.gpa.free(text);
    self.stateWait(text);
}

/// State `text` as the wait of the step that follows, or do nothing where the
/// host paints none.
fn stateWait(self: *const Context, text: []const u8) void {
    const wait = self.wait orelse return;
    wait.paint(wait.host, text);
}

test stateFetchWait {
    const Host = struct {
        text: [128]u8 = undefined,
        length: usize = 0,

        fn paint(host: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(host));
            @memcpy(self.text[0..text.len], text);
            self.length = text.len;
        }
    };
    var host: Host = .{};
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };

    // Without a host hook the call paints nothing and reports no failure.
    try context.stateFetchWait(.openai_api);
    try std.testing.expectEqual(@as(usize, 0), host.length);

    context.wait = .{ .host = &host, .paint = Host.paint };
    try context.stateFetchWait(.openai_api);
    try std.testing.expectEqualStrings(
        "Drinky fetches the model list of OpenAI API. The interface waits for the provider.",
        host.text[0..host.length],
    );
}
