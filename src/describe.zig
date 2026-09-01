//! Composition of the document that the `describe_drinky` tool returns: one
//! section per topic of the harness. The app owns the text, because the app owns
//! the commands, the config file, the keys, and the discovery rules that the
//! sections state. The model reads it instead of its own memory of Drinky.

const std = @import("std");

const ai = @import("ai");

const Config = @import("Config.zig");

/// What the app holds and the document states: the config file, the effort
/// level that the app compiles in, the key hints of the intro line, and the
/// window of the double Ctrl+C.
pub const Options = struct {
    config: *const Config,
    /// The effort level a session starts on when no file and no state names one.
    effort_default: ai.llm.Effort,
    /// The key hints of the intro line, in the order the line shows them.
    key_hints: []const []const u8,
    /// The window in which a second Ctrl+C quits, in milliseconds.
    ctrl_c_window_ms: i64,
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
    \\it locally. You cannot run a command, so name the line that the user must type.
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

/// Build the whole document. The caller owns the text and keeps it alive for the
/// session, because the agent hands it to every tool call.
pub fn compose(gpa: std.mem.Allocator, options: *const Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    try output.writer.writeAll(head);
    try writeCommands(&output.writer);
    const configuration = try options.config.document(gpa, options.effort_default);
    defer gpa.free(configuration);
    try output.writer.writeByte('\n');
    try output.writer.writeAll(configuration);
    try writeKeys(&output.writer, options);
    try output.writer.writeAll(discovery);
    try writeSkillCap(&output.writer);
    try output.writer.writeAll(repository);
    return output.toOwnedSlice();
}

/// One row per command, from the registry that runs them. A row also names the
/// line that runs the same command, such as the bare `/` of the command list, and
/// the text that the command takes. The row then holds the whole shape of a line.
fn writeCommands(writer: *std.Io.Writer) !void {
    for (ai.command.summaries) |command| {
        try writer.print("- `/{s}` \u{2014} {s}.", .{ command.name, command.summary });
        if (command.alias.len > 0)
            try writer.print(" The line `{s}` runs it too.", .{command.alias});
        if (command.tail.len > 0)
            try writer.print(" It takes {s} as trailing text.", .{command.tail});
        try writer.writeByte('\n');
    }
    try writer.writeAll("\nEvery other command refuses text after its name.\n");
}

/// The key hints of the intro line, then the keys of the prompt and of a
/// running turn. The hints come from the same constant that the intro line
/// shows. One key can mean two things, so each list states its own mode.
fn writeKeys(writer: *std.Io.Writer, options: *const Options) !void {
    try writer.writeAll(key_head);
    for (options.key_hints) |hint| try writer.print("- {s}\n", .{hint});
    try writer.print(
        \\
        \\The prompt takes these keys:
        \\
        \\- Enter sends the line.
        \\- Ctrl+C clears the editor. A second press within {d} milliseconds quits Drinky.
        \\- Ctrl+D quits at an empty editor. Ctrl+D with a draft warns first and quits on the
        \\  second press.
        \\- Ctrl+N asks the model to continue a failed turn that committed work.
        \\- Esc discards a waiting retry.
        \\
        \\A running turn takes these keys:
        \\
        \\- Enter queues the line as a steering message.
        \\- Ctrl+P moves the queued steering messages back into the editor.
        \\- Esc cancels the turn. Esc with a draft warns first and cancels on the second press.
        \\- Ctrl+D cancels the turn at once.
        \\- Ctrl+C clears a draft, and it cancels the turn at an empty editor.
        \\
        \\This section names the keys of the prompt and of a turn. A full-window page states
        \\its own keys in its header, and the editor carries the movement keys of a text
        \\field.
        \\
    , .{options.ctrl_c_window_ms});
}

/// The size cap of a skill file, from the window of the one `read` call that
/// must hold it. A larger file is skipped, so the cap belongs to the rules.
fn writeSkillCap(writer: *std.Io.Writer) !void {
    try writer.print(
        \\- A `SKILL.md` file above the window of one `read` call, {d} lines or {d} KiB, is skipped
        \\  and reported. One call then always holds a whole skill.
        \\- On a name clash a project skill wins over a user skill, and the closest copy wins over a
        \\  copy farther up.
        \\- The `user_instructions` key adds instruction files that no walk finds, and the
        \\  `required_skills` key pairs a path pattern with a skill.
        \\
    , .{ ai.tool.read_lines_max, @divExact(ai.tool.read_bytes_max, 1024) });
}

test "the document states every command, key, and discovery rule" {
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
        .ctrl_c_window_ms = 500,
    });
    defer gpa.free(text);

    // One section per topic, in one order.
    const commands = std.mem.indexOf(u8, text, "## Commands").?;
    const configuration = std.mem.indexOf(u8, text, "## Configuration").?;
    const keys = std.mem.indexOf(u8, text, "## Key bindings").?;
    const discovery_index = std.mem.indexOf(u8, text, "## Discovery").?;
    const repository_index = std.mem.indexOf(u8, text, "## Repository").?;
    try std.testing.expect(commands < configuration);
    try std.testing.expect(configuration < keys);
    try std.testing.expect(keys < discovery_index);
    try std.testing.expect(discovery_index < repository_index);

    // Every command of the registry reaches the document, the skill line with
    // its tail. The config section keeps its own keys under the section head.
    for (ai.command.summaries) |command| {
        const row = try std.fmt.allocPrint(gpa, "- `/{s}` \u{2014} ", .{command.name});
        defer gpa.free(row);
        try std.testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "as trailing text") != null);
    // A line that carries no name opens a list, so the rows name both such lines.
    try std.testing.expect(std.mem.indexOf(u8, text, "The line `/` runs it too.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The line `/skill:` runs it too.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`bash.timeout_ms`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/unused/config.json") != null);

    // Every list opens under a blank line, so the Markdown reads as a list.
    try std.testing.expect(std.mem.indexOf(u8, text, "must type.\n\n- `/effort`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "these keys:\n\n- Enter: Send\n") != null);

    // The keys come from the intro line, and each mode states its own keys after
    // them. One key can mean two things, so the lists must stay apart.
    try std.testing.expect(std.mem.indexOf(u8, text, "- Ctrl+D: Quit\n") != null);
    const prompt = std.mem.indexOf(u8, text, "The prompt takes these keys:").?;
    const turn = std.mem.indexOf(u8, text, "A running turn takes these keys:").?;
    try std.testing.expect(prompt < turn);
    // The quit rule and the retry belong to the prompt alone, and the steering
    // recall and the cancel belong to the turn alone.
    try std.testing.expect(std.mem.indexOf(u8, text[prompt..turn], "within 500 milli") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[prompt..turn], "Ctrl+N asks") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[turn..], "Ctrl+P moves") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[turn..],
        "cancels the turn at once",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text[turn..discovery_index], "Ctrl+N") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[turn..discovery_index],
        "milliseconds",
    ) == null);

    // The discovery rules carry no config key, so only this document holds them.
    try std.testing.expect(std.mem.indexOf(u8, text, "`AGENTS.md`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~/.agents/skills/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2000 lines or 50 KiB") != null);
    // A skill body loads on demand, so the section must not promise a restart
    // for every change that a user makes.
    try std.testing.expect(std.mem.indexOf(u8, text, "reaches the session that runs now") != null);
    // The keys of a page and of the editor stay out, so the section says so.
    try std.testing.expect(std.mem.indexOf(u8, text, "own keys in its header") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "https://github.com/clebert/drinky",
    ) != null);
}
