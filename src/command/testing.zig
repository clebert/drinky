const std = @import("std");

const accounts = @import("accounts");

const Choice = @import("../Choice.zig");
const discovery = @import("../discovery/root.zig");
const Message = @import("../Message.zig");
const testing = @import("../testing.zig");
const Turns = @import("../Turns.zig");
const Context = @import("Context.zig");

pub const no_skills: discovery.skills.Registry = .init(std.testing.allocator);

pub const Rig = struct {
    account_rig: accounts.testing.Rig,
    choice: Choice,
    remembered: [accounts.Account.table.len]?[]const u8,
    skill_registry: *const discovery.skills.Registry,
    turns: Turns,

    const Options = struct {
        variables: []const [2][]const u8 = &.{},
        store: ?[]const u8 = null,
        skill_registry: *const discovery.skills.Registry = &no_skills,
    };

    pub fn init(self: *Rig, options: *const Options) !void {
        try self.account_rig.init(std.testing.allocator, std.testing.io, &.{
            .variables = options.variables,
            .store = options.store,
        });
        self.choice = .{ .effort = .high };
        self.remembered = @splat(null);
        self.skill_registry = options.skill_registry;
        self.turns = .init(std.testing.allocator);
    }

    pub fn deinit(self: *Rig) void {
        self.turns.deinit();
        self.account_rig.deinit();
    }

    pub fn registry(self: *Rig) *accounts.Registry {
        return &self.account_rig.registry;
    }

    pub fn context(self: *Rig) Context {
        return .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .choice = &self.choice,
            .account_registry = &self.account_rig.registry,
            .remembered_model_names = &self.remembered,
            .skill_registry = self.skill_registry,
            .system_prompt = "",
            .sources_page = "",
            .turns = &self.turns,
        };
    }
};

pub const Discovered = struct {
    tree: testing.Tree,
    registry: discovery.skills.Registry,

    pub const Skill = struct {
        name: []const u8,
        description: []const u8,
    };

    pub fn init() !Discovered {
        return initWith(&.{
            .{ .name = "omega", .description = "The last skill. It sorts second." },
            .{ .name = "alpha", .description = "The first skill. It sorts first." },
        });
    }

    pub fn initWith(skills: []const Skill) !Discovered {
        var tree: testing.Tree = try .init();
        errdefer tree.deinit();
        for (skills, 1..) |skill, index| {
            var buffer: [64]u8 = undefined;
            const parent = try std.fmt.bufPrint(
                &buffer,
                "user/{d:0>2}-{s}",
                .{ index, skill.name },
            );
            try tree.skill(parent, &.{ .name = skill.name, .description = skill.description });
        }
        try tree.directory("work");
        const registry = try discovery.skills.discover(std.testing.allocator, std.testing.io, &.{
            .user_root = try tree.path("user"),
            .project_start = try tree.path("work"),
            .project_root = null,
        });
        return .{ .tree = tree, .registry = registry };
    }

    pub fn deinit(self: *Discovered) void {
        self.registry.deinit();
        self.tree.deinit();
    }
};

pub fn selectRow(
    pick: *const Context.Outcome.Pick,
    context: *Context,
    index: usize,
) Context.Error!Context.Outcome {
    return pick.select(context, .{ .payload = pick.payload, .row = index });
}

pub fn expectReopen(context: *Context, pick: *const Context.Outcome.Pick) !void {
    const reopened = try expectPick(try pick.reopen.?.run(context));
    defer reopened.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pick.title, reopened.title);
    try std.testing.expectEqual(pick.options.len, reopened.options.len);
    for (pick.options, reopened.options) |*option, *again| {
        try std.testing.expectEqualStrings(option.name, again.name);
    }
    try std.testing.expect(reopened.reopen.?.eql(pick.reopen.?));
}

pub fn expectMessage(
    message: *const Message,
    severity: Message.Severity,
    needle: []const u8,
) !void {
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqual(severity, message.severity);
    try std.testing.expect(std.mem.indexOf(u8, message.content, needle) != null);
}

pub fn expectNotice(
    outcome: Context.Outcome,
    severity: Message.Severity,
    needle: []const u8,
) !void {
    switch (outcome) {
        .notice => |notice| try expectMessage(&notice, severity, needle),
        else => {
            release(&outcome);
            return error.ExpectedNotice;
        },
    }
}

pub fn expectRefusal(
    outcome: Context.Outcome,
    severity: Message.Severity,
    needle: []const u8,
) !void {
    switch (outcome) {
        .refusal => |refusal| try expectMessage(&refusal, severity, needle),
        else => {
            release(&outcome);
            return error.ExpectedRefusal;
        },
    }
}

pub fn expectEvent(
    outcome: Context.Outcome,
    severity: Message.Severity,
    needle: []const u8,
) !void {
    switch (outcome) {
        .event => |event| try expectMessage(&event, severity, needle),
        else => {
            release(&outcome);
            return error.ExpectedEvent;
        },
    }
}

pub fn expectPick(outcome: Context.Outcome) !Context.Outcome.Pick {
    switch (outcome) {
        .pick => |pick| return pick,
        else => {
            release(&outcome);
            return error.ExpectedPick;
        },
    }
}

fn release(outcome: *const Context.Outcome) void {
    const gpa = std.testing.allocator;
    switch (outcome.*) {
        .notice, .refusal, .event => |*message| message.deinit(gpa),
        .pick => |*pick| pick.deinit(gpa),
        .prompt => |*prompt| prompt.deinit(gpa),
        .editor_text => |text| gpa.free(text),
        .page, .login, .logout, .fetch, .new_conversation, .rewind => {},
    }
}
