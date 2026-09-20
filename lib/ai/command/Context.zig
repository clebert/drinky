const std = @import("std");

const llm = @import("../llm.zig");
const skills = @import("../skills.zig");
const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const Model = @import("../Model.zig");

const Context = @This();

gpa: std.mem.Allocator,
io: std.Io,
agent: *Agent,
accounts: *Accounts,
remembered_models: ?*const std.EnumArray(llm.Account, ?Model) = null,
skill_registry: ?*const skills.Registry = null,
remote_bots: []const []const u8 = &.{},
remote: bool = false,

pub const Outcome = union(enum) {
    notice: Message,
    refusal: Message,
    event: Message,
    pick: Pick,
    prompt: Prompt,
    editor_text: []const u8,
    login_picker,
    login: llm.Account,
    logout: llm.Account,
    switch_account: llm.Account,
    credential_replaced: llm.Account,
    fetch: llm.Account,
    new_conversation,
    show_sources,
    show_status,
    show_system_prompt,
    remote_attach: usize,
    remote_add,
    remote_remove: usize,

    pub const Severity = enum { information, warning, failure };

    pub const Message = struct {
        content: []const u8,
        severity: Severity,

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
        source: []const u8,

        pub fn deinit(self: *const Prompt, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.arguments);
            gpa.free(self.content);
            gpa.free(self.source);
        }
    };

    pub const Pick = struct {
        select: *const fn (*Context, Selection) anyerror!Outcome,
        title: []const u8,
        cancellation_message: []const u8,
        options: []const Option,
        current: ?usize,
        preselected: ?usize = null,
        payload: usize = 0,
        report: ?Message = null,
        reopen: ?Opener = null,

        pub const Option = struct {
            name: []const u8,
            extra: ?[]const u8 = null,
            extra_pressure: bool = false,
            tag: ?[]const u8 = null,
            tag_pressure: bool = false,

            pub fn deinit(self: *const Option, gpa: std.mem.Allocator) void {
                gpa.free(self.name);
                if (self.extra) |extra| gpa.free(extra);
                if (self.tag) |tag| gpa.free(tag);
            }
        };

        pub const Selection = struct {
            payload: usize,
            row: usize,

            pub fn ofRow(row: usize) Selection {
                return .{ .payload = 0, .row = row };
            }
        };
    };

    pub const Opener = *const fn (*Context) anyerror!Outcome;

    pub const Options = struct {
        gpa: std.mem.Allocator,
        rows: std.ArrayList(Pick.Option) = .empty,

        pub fn deinit(self: *Options) void {
            for (self.rows.items) |*row| row.deinit(self.gpa);
            self.rows.deinit(self.gpa);
        }

        pub fn add(self: *Options, option: Pick.Option) !void {
            try self.rows.append(self.gpa, option);
        }

        pub fn print(self: *Options, comptime format: []const u8, args: anytype) !void {
            const name = try std.fmt.allocPrint(self.gpa, format, args);
            errdefer self.gpa.free(name);
            try self.add(.{ .name = name });
        }

        pub fn addExtra(
            self: *Options,
            extra_pressure: bool,
            name: []const u8,
            comptime extra_format: []const u8,
            extra_args: anytype,
        ) !void {
            const name_copy = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(name_copy);
            const extra = try std.fmt.allocPrint(self.gpa, extra_format, extra_args);
            errdefer self.gpa.free(extra);
            try self.add(.{ .name = name_copy, .extra = extra, .extra_pressure = extra_pressure });
        }

        pub fn addExtraPrint(
            self: *Options,
            extra_pressure: bool,
            comptime name_format: []const u8,
            name_args: anytype,
            comptime extra_format: []const u8,
            extra_args: anytype,
        ) !void {
            const name = try std.fmt.allocPrint(self.gpa, name_format, name_args);
            errdefer self.gpa.free(name);
            const extra = try std.fmt.allocPrint(self.gpa, extra_format, extra_args);
            errdefer self.gpa.free(extra);
            try self.add(.{ .name = name, .extra = extra, .extra_pressure = extra_pressure });
        }

        pub fn addTag(
            self: *Options,
            tag_pressure: bool,
            name: []const u8,
            tag: []const u8,
        ) !void {
            const name_copy = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(name_copy);
            const tag_copy = try self.gpa.dupe(u8, tag);
            errdefer self.gpa.free(tag_copy);
            try self.add(.{ .name = name_copy, .tag = tag_copy, .tag_pressure = tag_pressure });
        }

        pub fn toOwnedSlice(self: *Options) ![]const Pick.Option {
            return self.rows.toOwnedSlice(self.gpa);
        }
    };

    pub fn reportNotice(
        gpa: std.mem.Allocator,
        severity: Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return report(.notice, gpa, severity, format, args);
    }

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

    pub fn expectNotice(outcome: Outcome, severity: Severity) !void {
        return expectNoticeContaining(outcome, severity, "");
    }

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

    pub fn expectRefusal(outcome: Outcome, severity: Severity) !void {
        return expectRefusalContaining(outcome, severity, "");
    }

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

    pub fn expectEvent(outcome: Outcome, severity: Severity) !void {
        switch (outcome) {
            .event => |event| try event.expect(severity, ""),
            else => return error.ExpectedEvent,
        }
    }
};
