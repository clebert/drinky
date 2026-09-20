const std = @import("std");

const ai = @import("ai");

const Config = @import("Config.zig");

pub const Options = struct {
    config: *const Config,
    effort_default: ai.llm.Effort,
    key_hints: []const []const u8,
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

fn writeCommands(writer: *std.Io.Writer) !void {
    for (ai.command.summaries) |command| {
        try writer.print("- `/{s}` \u{2014} {s}.", .{ command.name, command.summary });
        if (command.alias.len > 0)
            try writer.print(" The line `{s}` runs it too.", .{command.alias});
        if (command.tail.len > 0)
            try writer.print(" It takes {s} as trailing text.", .{command.tail});
        if (!command.remote)
            try writer.writeAll(" It runs in the terminal alone, never from an attached Telegram bot.");
        if (command.during_turn)
            try writer.writeAll(" It runs during a turn too.");
        try writer.writeByte('\n');
    }
    try writer.writeAll(
        "\nA command refuses text after its name unless its row names trailing text. A command " ++
            "waits for the end of a turn unless its row says that it runs during a turn.\n",
    );
}

fn writeKeys(writer: *std.Io.Writer, options: *const Options) !void {
    try writer.writeAll(key_head);
    for (options.key_hints) |hint| try writer.print("- {s}\n", .{hint});
    try writer.print(
        \\
        \\The prompt takes these keys:
        \\
        \\- Enter sends the line.
        \\- Tab opens the prompt history picker over the draft when `prompt_history.enabled` is `true`.
        \\  Enter there appends the selected prompt to the draft as editable text.
        \\  Esc closes the list and keeps the draft.
        \\- Ctrl+C clears the editor. A second press within {d} milliseconds quits Drinky.
        \\- Ctrl+D quits at an empty editor. Ctrl+D with a draft warns first and quits on the
        \\  second press.
        \\- Ctrl+N acts on the recovery offer that the caption above the editor names. Under
        \\  `Failed turn`, Ctrl+N asks the model to continue from the committed work. Under
        \\  `Canceled turn`, Ctrl+N removes the canceled turn from the conversation and returns
        \\  its prompt and steering messages to the editor as editable text. Tool changes stay.
        \\  A turn that ran `write`, `edit`, or `bash` warns first and removes on the second
        \\  press. The chat and the prompt history keep their records of the removed turn.
        \\- Esc dismisses a waiting recovery offer. A dismissed canceled turn stays in the
        \\  conversation.
        \\
        \\A sign-in takes these keys:
        \\
        \\- Enter replays a callback URL. Drinky refuses every other line.
        \\- Esc or Ctrl+D cancels the sign-in and keeps the draft.
        \\- Ctrl+C clears a draft, and it cancels the sign-in at an empty editor.
        \\
        \\A running turn takes these keys:
        \\
        \\- Enter queues the line as a steering message.
        \\- Tab opens no prompt history. Drinky shows the notice `Prompt history cannot open while
        \\  a turn runs.` instead.
        \\- Ctrl+P moves the queued steering messages back into the editor, above the draft and
        \\  in the order the user sent them.
        \\- Esc cancels the turn. Esc first restores the status line. Esc with a draft warns first
        \\  and cancels on the second press.
        \\- Ctrl+D cancels the turn at once.
        \\- Ctrl+C clears a draft, and it cancels the turn at an empty editor.
        \\
        \\This section names the keys of the prompt, a sign-in, and a turn. A full-window page
        \\states its own keys in its header, and the editor carries the movement keys of a text
        \\field.
        \\
    , .{options.ctrl_c_window_ms});
}

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

    const commands = std.mem.indexOf(u8, text, "## Commands").?;
    const configuration = std.mem.indexOf(u8, text, "## Configuration").?;
    const keys = std.mem.indexOf(u8, text, "## Key bindings").?;
    const discovery_index = std.mem.indexOf(u8, text, "## Discovery").?;
    const repository_index = std.mem.indexOf(u8, text, "## Repository").?;
    try std.testing.expect(commands < configuration);
    try std.testing.expect(configuration < keys);
    try std.testing.expect(keys < discovery_index);
    try std.testing.expect(discovery_index < repository_index);

    for (ai.command.summaries) |command| {
        const row = try std.fmt.allocPrint(gpa, "- `/{s}` \u{2014} ", .{command.name});
        defer gpa.free(row);
        try std.testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "as trailing text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The line `/` runs it too.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The line `/skill:` runs it too.") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "- `/login` \u{2014} Sign in or switch the account. It runs in the terminal alone",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- `/new` \u{2014} Clear the conversation.\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "- `/status` \u{2014} State the session. It runs during a turn too.\n",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, text, " It runs during a turn too."),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "unless its row says that it runs during a turn",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### Keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`bash.timeout_ms`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/unused/config.json") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "must type.\n\n- `/effort`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "these keys:\n\n- Enter: Send\n") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "- Ctrl+D: Quit\n") != null);
    const prompt = std.mem.indexOf(u8, text, "The prompt takes these keys:").?;
    const login = std.mem.indexOf(u8, text, "A sign-in takes these keys:").?;
    const turn = std.mem.indexOf(u8, text, "A running turn takes these keys:").?;
    try std.testing.expect(prompt < login);
    try std.testing.expect(login < turn);
    try std.testing.expect(std.mem.indexOf(u8, text[prompt..login], "within 500 milli") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[prompt..login],
        "Under\n  `Failed turn`, Ctrl+N asks the model to continue",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[prompt..login],
        "`Canceled turn`, Ctrl+N removes the canceled turn",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text[prompt..login], "Tool changes stay.") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[prompt..login],
        "- Tab opens the prompt history picker over the draft when " ++
            "`prompt_history.enabled` is `true`.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[turn..],
        "- Tab opens no prompt history. Drinky shows the notice " ++
            "`Prompt history cannot open while\n  a turn runs.` instead.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`prompt_history.enabled`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[login..turn], "replays a callback URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[login..turn], "cancels the sign-in") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[turn..], "Ctrl+P moves") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text[turn..],
        "Esc first restores the status line.",
    ) != null);
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

    try std.testing.expect(std.mem.indexOf(u8, text, "`AGENTS.md`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~/.agents/skills/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2000 lines or 50 KiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "reaches the session that runs now") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "own keys in its header") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "https://github.com/clebert/drinky",
    ) != null);
}
