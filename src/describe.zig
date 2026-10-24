const std = @import("std");
const application = @import("application");
const core = @import("core");
const reference = @import("reference.zig");

pub const terminal_instructions =
    "Drinky renders your answer as Markdown in a terminal, so keep it short.";
pub const run_instructions =
    "Drinky writes your final answer to stdout without a terminal. " ++
    "Write your answer as Markdown, and keep it short.";

const config_keys = struct {
    const verbose = application.support.config.keyPath("interface.verbose");
    const window_pages = application.support.config.keyPath("interface.window_pages");
    const gauge_percent_warning = application.support.config.keyPath(
        "interface.gauge_percent_warning",
    );
    const gauge_percent_error = application.support.config.keyPath("interface.gauge_percent_error");
    const bash_timeout = application.support.config.keyPath("bash.timeout_ms");
};

const head =
    \\## Commands
    \\
    \\The user types a command line into the editor, and that line reaches no model. Drinky runs
    \\it locally. You cannot run a slash command, so name the line that the user must type.
    \\Drinky refuses an unknown command, an unknown skill, and an argument that a command does
    \\not accept. A second Enter sends the refused line to the model as a message.
    \\
    \\
;

const key_head =
    \\
    \\## Key bindings
    \\
    \\The intro keeps one row and removes controls from right to left as the viewport narrows.
    \\The complete list of intro keys follows:
    \\
    \\
;

pub fn compose(gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    write(&output.writer) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(head);
    try writeCommands(writer);
    try writeKeys(writer);
    try writePreferences(writer);
    try writeHeadless(writer);
}

fn writeCommands(writer: *std.Io.Writer) !void {
    for (reference.summaries) |summary| {
        try writer.print("- `/{s}` \u{2014} {s}.", .{ summary.name, summary.summary });
        if (summary.alias.len > 0)
            try writer.print(" The line `{s}` runs it too.", .{summary.alias});
        if (summary.tail.len > 0)
            try writer.print(" It takes {s} as trailing text.", .{summary.tail});
        try writer.writeByte('\n');
    }
    try writer.writeAll(
        "\nA command refuses text after its name unless its row names trailing text. " ++
            "The " ++ reference.line(.verbose) ++ " command also works while a turn runs. " ++
            "During a turn, the line `/` or `" ++ reference.line(.help) ++ "` lists the " ++
            "commands that work during a turn. " ++
            "Drinky refuses other commands during a turn. The draft stays in both cases.\n",
    );
    try writer.print(
        \\
        \\`/verbose` toggles the displayed detail for the current session, even during a turn.
        \\Verbose starts off by default. The config key `{[verbose]s}` can change that default.
        \\The command changes no config file and sends no model message.
        \\Each toggle clears terminal scrollback and repaints the complete transcript without a
        \\warning.
        \\A terminal reset also repaints the complete transcript.
        \\Both verbosity states use one transcript style.
        \\The gaps between transcript blocks stay the same.
        \\User messages use a purple background with one padding row above and below.
        \\They preserve blank lines and source indentation.
        \\Picker selection highlights stay outside the transcript.
        \\The complete `Tool: name (state)` identity uses dim text and takes the status color.
        \\The `Stopped`, `Unreadable`, and `Skipped` details of a search use dim yellow text.
        \\File windows, omitted matches, and truncated output use neutral metadata.
        \\The complete `Agent: work (activity or status)` identity uses dim text.
        \\An open work identity uses cyan, and a finished work identity takes the status color.
        \\Other metadata and command text use dim text with the default foreground color.
        \\Tool error sentences use dim text with the default foreground color.
        \\The `complete` status uses green, and `failed` uses red.
        \\The tool statuses `partial` and `canceled` use yellow.
        \\The work statuses `truncated` and `canceled` use yellow too.
        \\The `queued`, `streaming`, and `running` statuses use cyan.
        \\
        \\Verbose on shows complete thinking text, a row for each tool call, and complete bash
        \\commands.
        \\Complete commands keep their source line breaks.
        \\Verbose off folds each run of thinking and tool calls into one work row.
        \\Agent text, a session event, or a user note ends a run. A new model step does not end it.
        \\The open work row shows the activity in parentheses and the time of the run.
        \\Each work row shows the count of finished tool calls and the received bytes.
        \\The open work row updates these values while the run continues.
        \\The received bytes count the thinking text and the arguments of finished tool calls.
        \\The activity is `thinking` while thinking is active.
        \\Otherwise, it lists each unfinished tool name once, without a call count.
        \\The list includes calls that stream, wait in the queue, or run.
        \\The activity is `waiting` when no thinking or unfinished tool call exists.
        \\The row reserves no activity width and adds no activity padding.
        \\The open run stays below the transcript.
        \\The final status is `complete`, `canceled`, `failed`, or `truncated`.
        \\The transcript keeps thinking after a cancellation or failure.
        \\A cancel while tools run keeps the tool calls of the reply in the transcript and in the
        \\model conversation. Each call that did not complete gets the status `canceled`.
        \\A cancel while the model streams removes each tool call of the unfinished reply.
        \\A toggle changes no stored text and does not change the model conversation.
        \\
        \\Tool metadata stays on one row, with the tool name and state first.
        \\The row removes lower-priority segments as the viewport narrows.
        \\It never removes the first segment, and it truncates that segment only when necessary.
        \\Time has the next priority, followed by the bash exit code, file or pattern, limit
        \\details, counts, and secondary measures.
        \\Received bytes and timeout values have the lowest priority.
        \\A running call with a time limit shows its time and the limit.
        \\After the call, the time comes from the tool.
        \\`bash`, `find`, and `grep` measure it, except after an early failure.
        \\A canceled call that started shows the time until the cancel.
        \\A search that stops at a limit or skips entries shows `partial`.
        \\A file window or truncated output still shows `complete`.
        \\Bash commands and complete tool error sentences appear below the metadata.
        \\A command starts with `$ ` in a two-column gutter.
        \\Each further command line starts with two spaces.
        \\A wrapped command row starts with `↪ `.
        \\Source indentation stays after the gutter.
        \\At a width of two columns, the gutter has one column.
        \\At a width of one column, the row has no gutter.
        \\Tool error sentences start at the left edge.
        \\Complete tool error sentences wrap, even at very small widths.
        \\Work rows start with `Agent: work (activity)` while open and `Agent: work (status)` after
        \\completion.
        \\The time has the next priority, followed by the tool count and the received bytes.
        \\A work row truncates the value in parentheses only when its complete identity
        \\does not fit.
        \\It keeps the complete prefix and closing parenthesis when at least 15 columns remain.
        \\Below 15 columns, it truncates the complete identity.
        \\The intro and user notes use one row.
        \\Session events can use multiple rows.
        \\User and model messages keep their complete text.
        \\
        \\`/rewind` lists the prompts of the conversation, with the oldest prompt first. A row
        \\holds a user message or the typed line of a skill command. A retry gets no row.
        \\Enter drops the chosen turn and every later turn. It returns the line to the editor
        \\as editable text. Tool changes and the cost stay. When a turn that the rewind
        \\drops ran `write`, `edit`, or `bash`, Enter warns first and rewinds on the second press.
        \\
        \\`/handoff` prepares a concise handoff for the current task with the current model.
        \\The request holds each user prompt and the final answer of its turn. It omits tool
        \\calls, tool results, reasoning, and intermediate texts, so it stays small and can work
        \\after a context overflow. It offers no tools and uses the effort of normal turns. A last
        \\user message asks for the handoff, and an optional instruction after the command joins
        \\it. The command leaves the conversation unchanged and streams the handoff into a
        \\read-only page.
        \\Enter applies a complete handoff. Drinky clears the conversation as /new does and sends
        \\the handoff as a normal user message. The model resumes the task and asks for any user
        \\decision that still blocks it. Normal rewind, retry, and canceled-turn edit behavior
        \\applies.
        \\Rewind cannot recover the old conversation after Apply.
        \\Esc, Ctrl+C, and Ctrl+D cancel generation or discard the preview. Each exit closes only
        \\the page and restores the original command with its instruction to the editor.
        \\Drinky cannot apply a failed or truncated handoff.
        \\Every invocation generates a fresh preview.
        \\The handoff has no fixed word count. It preserves the goal, constraints, decisions,
        \\completed work, verification results, remaining work, and pending user decisions.
        \\
        \\`/tldr` shortens the last answer with the current model. The request holds only that
        \\answer. It uses the effort of normal turns.
        \\It opens a page and streams the short version into it. Until the first text arrives,
        \\the page shows a wait line as `Agent: work (waiting) · Time: 0s · Received: 0 B`. The
        \\time ticks every second. The state changes to thinking when reasoning text arrives, and
        \\Received counts its bytes. A failed attempt adds its note below the line. `/handoff`
        \\shows the same wait line. The wait line uses the transcript work-row layout.
        \\It stays on one row and removes Received before Time as the terminal narrows.
        \\It shortens the identity only when the identity cannot fit.
        \\The complete identity uses dim cyan text. Metadata uses dim default foreground text.
        \\The notes use the transcript symbols and severity colors. A retry note uses cyan with ℹ.
        \\A failure note or an incomplete reply note uses red with ⚠.
        \\The notes stay separate from the model text in both page presentations.
        \\The transcript and the model conversation stay unchanged.
        \\The cost of the request joins the session cost. Esc stops the request and closes the page.
        \\Drinky keeps the short version of one answer, so the next `/tldr` for the same answer
        \\shows it at once. When the request fails, the page shows the failure.
        \\
    , .{ .verbose = config_keys.verbose });
}

fn writeKeys(writer: *std.Io.Writer) !void {
    try writer.writeAll(key_head);
    for (reference.key_hints) |hint| try writer.print("- {s}\n", .{hint});
    try writer.print(
        \\
        \\The prompt takes these keys:
        \\
        \\- Enter sends the line. A refused line stays in the editor. After Drinky refuses a
        \\  command line, a second Enter sends that line as a message.
        \\- Ctrl+C clears the editor. A second press within {d} milliseconds quits Drinky.
        \\- Ctrl+D quits at an empty editor. Ctrl+D with a draft warns first and quits on the
        \\  second press.
        \\- Within {d} milliseconds after a Ctrl+D that ended a step, a page, a sign-in, or a turn,
        \\  Ctrl+D warns first.
        \\- Ctrl+N acts on the offer that the caption above the editor names. Under `Failed turn`,
        \\  Ctrl+N asks the model to continue from the committed work. The draft stays. Under
        \\  `Canceled turn`, Ctrl+N removes the canceled turn from the conversation and returns its
        \\  line to the editor as editable text. Tool changes stay. After a turn that ran
        \\  `write`, `edit`, or `bash`, Ctrl+N warns first and removes the turn on the second
        \\  press.
        \\- Esc dismisses a waiting offer. A dismissed canceled turn stays in the conversation. A
        \\  new turn, `/new`, and a rewind with `/rewind` dismiss the offer too.
        \\
        \\A sign-in takes these keys:
        \\
        \\- Enter replays a callback URL. Drinky refuses every other line.
        \\- Esc or Ctrl+D cancels the sign-in and keeps the draft.
        \\- Ctrl+C clears a draft, and it cancels the sign-in at an empty editor.
        \\
        \\A running turn takes these keys:
        \\
        \\- Enter runs `/verbose` and clears its command line. Enter on `/` or `/help` lists the
        \\  commands that work during a turn and keeps the line. Other slash commands get a
        \\  refusal. Enter sends no message. Drinky shows the notice `Drinky sends no message
        \\  while a turn runs. The draft stays.` and keeps the line.
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
    , .{ reference.repeat_window_ms, reference.repeat_window_ms });
}

fn writePreferences(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        "\n## Terminal preferences\n\n" ++
            "The config key `" ++ config_keys.verbose ++ "` sets the initial detail level. " ++
            "The value true shows complete thinking text, tool rows, and bash commands. " ++
            "The value false folds each run of thinking and tool calls into one work row. " ++
            "The /verbose command changes only the current session.\n\n" ++
            "The config key `" ++ config_keys.window_pages ++ "` sets the pages of the newest " ++
            "conversation that Drinky keeps on the screen. One page is one window height. " ++
            "Each frame measures and paints each kept row again. " ++
            "A higher count keeps more of the conversation and costs more work per frame. " ++
            "A verbosity toggle or terminal reset repaints the complete transcript.\n\n" ++
            "The config keys `" ++ config_keys.gauge_percent_warning ++ "` and " ++
            "`" ++ config_keys.gauge_percent_error ++ "` set the warning and error colors. " ++
            "The context gauge and quota windows use those thresholds.\n",
    );
}

fn writeHeadless(writer: *std.Io.Writer) !void {
    try writer.print(
        \\
        \\## Headless mode
        \\
        \\`drinky run` answers one prompt without a terminal. It is not a slash command, so you
        \\can start it through the `bash` tool. A run can review your work as a second agent.
        \\
        \\- A run reads the prompt from stdin and writes the text of its final reply to stdout.
        \\- A run through the `bash` tool adds its available costs to the parent session total.
        \\  Each model attempt reports its cost when it ends, including a failed attempt with usage.
        \\  A run uses its own model prices unless the provider reports a charge.
        \\  A run adds no summary to the transcript or tool output.
        \\  Keep the bash invocation open with `wait` for background runs.
        \\- The `--model` flag and the `--effort` flag are required.
        \\- The `--model` flag takes an `account/model` value. The command `drinky models` lists
        \\  the values of each signed-in account with a saved model list. The user fetches a list
        \\  with `/model`.
        \\- The `--effort` flag takes {[levels]s}. Drinky uses the nearest
        \\  level that the model takes.
        \\- Each `bash` command gets `{[model_variable]s}` with the `account/model` value of this
        \\  session. It also gets `{[effort_variable]s}` with the effort level that the user chose.
        \\  Both follow `/model` and `/effort`.
        \\- A run starts with an empty conversation. It sees no part of this conversation, so the
        \\  prompt must hold the whole task.
        \\- A run uses the config file, the instruction files, the skills, and the tools of a
        \\  session. It saves no choice and signs in to no account.
        \\- The skill list of a run leaves out each skill that sets `drinky-run: hidden` in the
        \\  block map of its `metadata`.
        \\- A run drops the start reports of a session, such as an unknown config key or an
        \\  instruction file that Drinky cannot read.
        \\- A failure of the run goes to stderr, and the exit code is then 1. A run that stops at
        \\  a limit also fails, but its last reply text still reaches stdout.
        \\- A run can take longer than the `{[timeout_key]s}` limit. Give the `bash` call a
        \\  `timeout_seconds` value that covers the run.
        \\- A run sets `{[nested_variable]s}` for its commands. Drinky refuses to start a run where
        \\  that variable is set, so a run cannot start another run.
        \\
        \\Quote the delimiter of the heredoc, so that the shell does not change the prompt:
        \\
        \\```sh
        \\drinky run --model "${[model_variable]s}" --effort "${[effort_variable]s}" <<'EOF'
        \\Review the uncommitted changes.
        \\EOF
        \\```
        \\
    , .{
        .levels = application.reference.effort_levels,
        .timeout_key = config_keys.bash_timeout,
        .model_variable = application.support.environment.model,
        .effort_variable = application.support.environment.effort,
        .nested_variable = application.reference.nested,
    });
}

test "the native reference avoids shared text and preserves facts across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkReference,
        .{},
    );
}

fn checkReference(gpa: std.mem.Allocator) !void {
    const text = try compose(gpa);
    defer gpa.free(text);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(
        u8,
        text,
        "Answer a question about Drinky from this document.",
    ));
    const commands = std.mem.find(u8, text, "## Commands").?;
    const keys = std.mem.find(u8, text, "## Key bindings").?;
    const preferences = std.mem.find(u8, text, "## Terminal preferences").?;
    const headless = std.mem.find(u8, text, "## Headless mode").?;
    try std.testing.expect(commands < keys and keys < preferences and preferences < headless);
    for (reference.summaries) |summary| {
        const row = try gpa.print("- `/{s}` — {s}.", .{ summary.name, summary.summary });
        defer gpa.free(row);
        try std.testing.expect(std.mem.find(u8, text[commands..keys], row) != null);
    }
    for (reference.key_hints) |hint|
        try std.testing.expect(std.mem.find(u8, text[keys..preferences], hint) != null);
    const repeat = try gpa.print("{d} milliseconds", .{reference.repeat_window_ms});
    defer gpa.free(repeat);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text[keys..preferences], repeat));
    for ([_][]const u8{
        config_keys.verbose,               config_keys.window_pages,
        config_keys.gauge_percent_warning, config_keys.gauge_percent_error,
    }) |key| try std.testing.expect(std.mem.find(u8, text[preferences..headless], key) != null);
    for ([_][]const u8{
        application.reference.effort_levels,    application.support.environment.model,
        application.support.environment.effort, application.reference.nested,
        "available costs",                      "no summary",
    }) |fact| try std.testing.expect(std.mem.find(u8, text[headless..], fact) != null);
}
