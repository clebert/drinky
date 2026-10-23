const std = @import("std");
const core = @import("core");
const tools = @import("tools");
const Config = @import("Config.zig");

const Options = struct {
    config: *const Config,
    effort_default: core.Provider.Effort,
    frontend_reference: []const u8,
};

const head =
    "# Drinky\n\nDrinky is a coding agent. This document describes the harness.\n" ++
    "Answer a question about Drinky from this document.\n\n";

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
    \\- `disable-model-invocation: true` in the front matter keeps a skill out of the skill list
    \\  in the system prompt. An explicit skill invocation can still load it.
    \\- A `drinky-run: hidden` entry in the `metadata` map of the front matter keeps a skill out
    \\  of the skill list in the system prompt of a run. A session still lists it.
    \\- Drinky reads `metadata` only as a block map, with one indented `key: value` line for each
    \\  entry. Drinky ignores a value on the `metadata:` line itself and reports it at startup.
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
    try writer.writeAll(std.mem.trimEnd(u8, options.frontend_reference, "\r\n"));
    try writer.writeAll("\n\n");
    try writer.writeAll(configuration);
    try writer.writeAll(discovery);
    try writeSkillRules(writer);
    try writer.writeAll(repository);
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

test "the shared reference separates frontend text from config and preserves discovery facts" {
    const gpa = std.testing.allocator;
    var config: Config = .{
        .path = try gpa.dupe(u8, "/unused/config.json"),
        .user_instructions = .init(gpa, .user),
    };
    defer config.deinit(gpa);
    const text = try compose(gpa, &.{
        .config = &config,
        .effort_default = .xhigh,
        .frontend_reference = "## Client controls\n\nClient-specific controls.\n",
    });
    defer gpa.free(text);
    const frontend = std.mem.find(u8, text, "## Client controls").?;
    const configuration = std.mem.find(u8, text, "## Config file").?;
    try std.testing.expectEqualStrings(".\n\n", text[configuration - 3 .. configuration]);
    const discovery_index = std.mem.find(u8, text, "## Discovery").?;
    const repository_index = std.mem.find(u8, text, "## Repository").?;
    try std.testing.expect(frontend < configuration);
    try std.testing.expect(configuration < discovery_index and discovery_index < repository_index);
    try std.testing.expect(std.mem.find(u8, text, config.path) != null);
    const window = try gpa.print("{d} lines or {d} KiB", .{
        tools.read.lines_max, @divExact(tools.read.bytes_max, 1024),
    });
    defer gpa.free(window);
    const discovery_text = text[discovery_index..repository_index];
    try std.testing.expect(std.mem.find(u8, discovery_text, window) != null);
}
