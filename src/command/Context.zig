const std = @import("std");

const accounts = @import("accounts");

const Choice = @import("../Choice.zig");
const discovery = @import("../discovery/root.zig");
const Message = @import("../Message.zig");
const Turns = @import("../Turns.zig");
const ui = @import("../ui/root.zig");

const Context = @This();

gpa: std.mem.Allocator,
io: std.Io,
choice: *Choice,
account_registry: *accounts.Registry,
remembered_model_names: *const [accounts.Account.table.len]?[]const u8,
skill_registry: *const discovery.skills.Registry,
system_prompt: []const u8,
sources_page: []const u8,
turns: *const Turns,

pub const Error = error{OutOfMemory};

pub const Outcome = union(enum) {
    notice: Message,
    refusal: Message,
    event: Message,
    pick: Pick,
    prompt: Prompt,
    editor_text: []const u8,
    page: ui.Page.Options,
    login: usize,
    logout: usize,
    fetch: usize,
    new_conversation,
    toggle_compact,
    rewind: usize,

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
        select: *const fn (*Context, Selection) Error!Outcome,
        title: []const u8,
        cancellation_message: []const u8,
        options: []const ui.Picker.Option,
        current: ?usize,
        preselected: ?usize = null,
        payload: usize = 0,
        report: ?Message = null,
        reopen: ?Opener = null,

        pub const Selection = struct {
            payload: usize,
            row: usize,
        };

        pub fn deinit(self: *const Pick, gpa: std.mem.Allocator) void {
            for (self.options) |*option| option.deinit(gpa);
            gpa.free(self.options);
            if (self.report) |report| report.deinit(gpa);
        }
    };

    pub const Opener = struct {
        open: *const fn (*Context, usize) Error!Outcome,
        payload: usize = 0,

        pub fn run(self: Opener, context: *Context) Error!Outcome {
            return self.open(context, self.payload);
        }

        pub fn eql(self: Opener, other: Opener) bool {
            return self.open == other.open and self.payload == other.payload;
        }
    };

    pub const Options = struct {
        gpa: std.mem.Allocator,
        rows: std.ArrayList(ui.Picker.Option) = .empty,

        pub fn deinit(self: *Options) void {
            for (self.rows.items) |*row| row.deinit(self.gpa);
            self.rows.deinit(self.gpa);
        }

        fn add(self: *Options, option: ui.Picker.Option) !void {
            try self.rows.append(self.gpa, option);
        }

        pub fn print(self: *Options, comptime format: []const u8, args: anytype) !void {
            const name = try self.gpa.print(format, args);
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
            const extra = try self.gpa.print(extra_format, extra_args);
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
            const name = try self.gpa.print(name_format, name_args);
            errdefer self.gpa.free(name);
            const extra = try self.gpa.print(extra_format, extra_args);
            errdefer self.gpa.free(extra);
            try self.add(.{ .name = name, .extra = extra, .extra_pressure = extra_pressure });
        }

        pub fn addTag(
            self: *Options,
            row: *const struct { name: []const u8, tag: []const u8, tag_pressure: bool = false },
        ) !void {
            const name_copy = try self.gpa.dupe(u8, row.name);
            errdefer self.gpa.free(name_copy);
            const tag_copy = try self.gpa.dupe(u8, row.tag);
            errdefer self.gpa.free(tag_copy);
            try self.add(.{ .name = name_copy, .tag = tag_copy, .tag_pressure = row.tag_pressure });
        }

        pub fn toOwnedSlice(self: *Options) ![]const ui.Picker.Option {
            return self.rows.toOwnedSlice(self.gpa);
        }
    };

    pub fn reportNotice(
        gpa: std.mem.Allocator,
        severity: Message.Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return .{ .notice = try Message.print(gpa, severity, format, args) };
    }

    pub fn reportEvent(
        gpa: std.mem.Allocator,
        severity: Message.Severity,
        comptime format: []const u8,
        args: anytype,
    ) !Outcome {
        return .{ .event = try Message.print(gpa, severity, format, args) };
    }
};
