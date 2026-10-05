const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const command = @import("command/root.zig");
const Config = @import("Config.zig");

const Options = struct {
    config: *const Config,
    effort_default: core.Provider.Effort,
    key_hints: []const []const u8,
    repeat_window_ms: i64,
};

const head =
    \\# Drinky
    \\
    \\Drinky is a terminal coding agent. This document holds the facts of the harness: its
    \\commands, its config file, its keys, and the files that it discovers. Answer a question
    \\about Drinky from this document.
    \\
    \\## Commands
    \\
    \\The user types a command line into the editor, and that line reaches no model. Drinky runs
    \\it locally. You cannot run a command, so name the line that the user must type. Drinky
    \\refuses an unknown command, an unknown skill, and a command with an argument. A second Enter
    \\then sends the refused line to the model as a message.
    \\
    \\
;

const key_head =
    \\
    \\## Key bindings
    \\
    \\The intro line of every session shows these keys:
    \\
    \\
;

const discovery =
    \\
    \\## Discovery
    \\
    \\Drinky discovers the files below at startup alone, and it watches no directory. A new file,
    \\a changed skill name, and a changed skill description all wait for the next start of Drinky.
    \\An instruction file goes into the system prompt at that start, so an edit to one reaches
    \\the next start too. Drinky loads the body of a skill on demand, so an edit inside a
    \\`SKILL.md` body reaches the session that runs now.
    \\
    \\- Instructions: each exact-case `AGENTS.md` file from the Git root down to the working
    \\  directory, in that order. Outside a repository Drinky reads that one directory.
    \\- Skills: `~/.agents/skills/`, then `.agents/skills/` from the Git root down to the working
    \\  directory. Outside a repository Drinky looks in that one directory.
    \\- Drinky searches each skills directory at any depth for a `SKILL.md` file, and it follows a
    \\  directory symbolic link.
    \\- The front matter of a `SKILL.md` file carries a `name` and a `description`. Drinky
    \\  advertises both, and it loads the instructions on demand.
    \\
;

const repository =
    \\
    \\## Repository
    \\
    \\The source of Drinky is at https://github.com/clebert/drinky. Read the source for a question
    \\that this document does not answer.
    \\
;

pub fn compose(gpa: std.mem.Allocator, options: *const Options) error{OutOfMemory}![]u8 {
    const configuration = try options.config.document(gpa, options.effort_default);
    defer gpa.free(configuration);
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    write(&output.writer, options, configuration) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn write(
    writer: *std.Io.Writer,
    options: *const Options,
    configuration: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll(head);
    try writeCommands(writer);
    try writer.writeByte('\n');
    try writer.writeAll(configuration);
    try writeKeys(writer, options);
    try writer.writeAll(discovery);
    try writeSkillRules(writer);
    try writer.writeAll(repository);
}

fn writeCommands(writer: *std.Io.Writer) !void {
    for (command.summaries) |summary| {
        try writer.print("- `/{s}` \u{2014} {s}.", .{ summary.name, summary.summary });
        if (summary.alias.len > 0)
            try writer.print(" The line `{s}` runs it too.", .{summary.alias});
        if (summary.tail.len > 0)
            try writer.print(" It takes {s} as trailing text.", .{summary.tail});
        try writer.writeByte('\n');
    }
    try writer.writeAll(
        "\nA command refuses text after its name unless its row names trailing text. " ++
            "Drinky refuses every command while a turn runs, and the draft stays.\n",
    );
}

fn writeKeys(writer: *std.Io.Writer, options: *const Options) !void {
    try writer.writeAll(key_head);
    for (options.key_hints) |hint| try writer.print("- {s}\n", .{hint});
    try writer.print(
        \\
        \\The prompt takes these keys:
        \\
        \\- Enter sends the line. After Drinky refuses a command line, a second Enter sends that
        \\  line as a message.
        \\- Ctrl+C clears the editor. A second press within {d} milliseconds quits Drinky.
        \\- Ctrl+D quits at an empty editor. Ctrl+D with a draft warns first and quits on the
        \\  second press.
        \\- Within {d} milliseconds after a Ctrl+D that ended a step, a page, a sign-in, or a turn,
        \\  Ctrl+D warns first.
        \\
        \\A sign-in takes these keys:
        \\
        \\- Enter replays a callback URL. Drinky refuses every other line.
        \\- Esc or Ctrl+D cancels the sign-in and keeps the draft.
        \\- Ctrl+C clears a draft, and it cancels the sign-in at an empty editor.
        \\
        \\A running turn takes these keys:
        \\
        \\- Enter sends no message. Drinky shows the notice `Drinky sends no message while a turn
        \\  runs. The draft stays.` and keeps the line. A slash command gets its refusal instead.
        \\- Esc cancels the turn. Esc with a draft warns first and cancels on the second press.
        \\- When a notice other than that warning replaces the status line, Esc first clears the
        \\  notice.
        \\- Ctrl+D cancels the turn at once.
        \\- Ctrl+C clears a draft, and it cancels the turn at an empty editor.
        \\
        \\This section names the keys of the prompt, a sign-in, and a turn. A full-window page
        \\states its own keys in its header, and the editor carries the movement keys of a text
        \\field.
        \\
    , .{ options.repeat_window_ms, options.repeat_window_ms });
}

fn writeSkillRules(writer: *std.Io.Writer) !void {
    try writer.print(
        \\- Drinky skips and reports a `SKILL.md` file above the window of one `read` call. The
        \\  window is {d} lines or {d} KiB, so one call always holds a whole skill.
        \\- On a name clash a project skill wins over a user skill, and the closest copy wins over a
        \\  copy farther up.
        \\- The `user_instructions` key adds instruction files that no walk finds, and the
        \\  `required_skills` key pairs a path pattern with a skill.
        \\
    , .{ tools.read.lines_max, @divExact(tools.read.bytes_max, 1024) });
}

test "the document orders its sections and states each command, key hint, window, and limit" {
    const gpa = std.testing.allocator;
    var config: Config = .{
        .path = try gpa.dupe(u8, "/unused/config.json"),
        .user_instructions = .init(gpa, .user),
    };
    defer config.deinit(gpa);
    const text = try compose(gpa, &.{
        .config = &config,
        .effort_default = .xhigh,
        .key_hints = &.{ "Enter: Send", "Ctrl+D: Quit" },
        .repeat_window_ms = 500,
    });
    defer gpa.free(text);

    const commands = std.mem.indexOf(u8, text, "## Commands").?;
    const configuration = std.mem.indexOf(u8, text, "## Config file").?;
    const keys = std.mem.indexOf(u8, text, "## Key bindings").?;
    const discovery_index = std.mem.indexOf(u8, text, "## Discovery").?;
    const repository_index = std.mem.indexOf(u8, text, "## Repository").?;
    try std.testing.expect(commands < configuration);
    try std.testing.expect(configuration < keys);
    try std.testing.expect(keys < discovery_index);
    try std.testing.expect(discovery_index < repository_index);

    for (command.summaries) |summary| {
        const row = try std.fmt.allocPrint(
            gpa,
            "- `/{s}` \u{2014} {s}.",
            .{ summary.name, summary.summary },
        );
        defer gpa.free(row);
        try std.testing.expect(std.mem.indexOf(u8, text[commands..configuration], row) != null);
    }
    const path = "/unused/config.json";
    try std.testing.expect(std.mem.indexOf(u8, text[configuration..keys], path) != null);
    const hints = "- Enter: Send\n- Ctrl+D: Quit\n";
    try std.testing.expect(std.mem.indexOf(u8, text[keys..discovery_index], hints) != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, text[keys..discovery_index], "500 milliseconds"),
    );
    const window = try std.fmt.allocPrint(gpa, "{d} lines or {d} KiB", .{
        tools.read.lines_max,
        @divExact(tools.read.bytes_max, 1024),
    });
    defer gpa.free(window);
    try std.testing.expect(std.mem.indexOf(u8, text[discovery_index..], window) != null);
}
