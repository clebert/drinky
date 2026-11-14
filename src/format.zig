const std = @import("std");

const application = @import("application");

pub const Roots = struct {
    working_directory: []const u8 = "",
    home_directory: []const u8 = "",
};

pub fn bytes(buffer: []u8, count: usize) []const u8 {
    if (count < 1024) return std.mem.print(buffer, "{d} B", .{count}) catch unreachable;
    const tenths_kib = @divFloor(count * 10, 1024);
    if (tenths_kib < 10 * 1024) return std.mem.print(buffer, "{d}.{d} KiB", .{
        @divFloor(tenths_kib, 10),
        @mod(tenths_kib, 10),
    }) catch unreachable;
    const tenths_mib = @divFloor(count * 10, 1024 * 1024);
    return std.mem.print(buffer, "{d}.{d} MiB", .{
        @divFloor(tenths_mib, 10),
        @mod(tenths_mib, 10),
    }) catch unreachable;
}

pub fn path(
    gpa: std.mem.Allocator,
    target: []const u8,
    roots: *const Roots,
) error{OutOfMemory}![]u8 {
    const working = roots.working_directory;
    const home = roots.home_directory;
    if (application.support.paths.relativeTo(&.{
        .boundary = working,
        .target = target,
    })) |relative| return gpa.dupe(u8, relative);
    if (application.support.paths.relativeTo(&.{ .boundary = home, .target = target })) |relative|
        return gpa.print("~/{s}", .{relative});
    if (home.len > 0 and application.support.paths.contains(&.{
        .boundary = home,
        .target = target,
    })) return gpa.dupe(u8, "~");
    return gpa.dupe(u8, target);
}

pub fn durationSeconds(buffer: []u8, milliseconds: i64) []const u8 {
    const total: u64 = @intCast(@max(milliseconds, 0));
    const seconds = @divFloor(total, std.time.ms_per_s);
    if (seconds < std.time.s_per_min)
        return std.mem.print(buffer, "{d}s", .{seconds}) catch unreachable;
    return std.mem.print(buffer, "{d}m {d}s", .{
        @divFloor(seconds, std.time.s_per_min),
        @mod(seconds, std.time.s_per_min),
    }) catch unreachable;
}

pub fn coarseDuration(buffer: []u8, seconds: u64) []const u8 {
    const unit: struct { size: u64, suffix: []const u8 } = if (seconds < std.time.s_per_hour)
        .{ .size = std.time.s_per_min, .suffix = "m" }
    else if (seconds < std.time.s_per_day)
        .{ .size = std.time.s_per_hour, .suffix = "h" }
    else
        .{ .size = std.time.s_per_day, .suffix = "d" };
    return std.mem.print(buffer, "{d}{s}", .{ @divFloor(seconds, unit.size), unit.suffix }) catch
        unreachable;
}

pub fn gistLabel(gpa: std.mem.Allocator, title: []const u8) error{OutOfMemory}![]u8 {
    const copy = try gpa.dupe(u8, title);
    defer gpa.free(copy);
    return gpa.print("Gist: {s}", .{singleLine(copy)});
}

pub fn singleLine(text: []u8) []u8 {
    var length: usize = 0;
    var blank = false;
    for (text) |byte| {
        if (byte == ' ' or byte <= 0x1f or byte == 0x7f) {
            blank = length > 0;
            continue;
        }
        if (blank) {
            text[length] = ' ';
            length += 1;
            blank = false;
        }
        text[length] = byte;
        length += 1;
    }
    return text[0..length];
}

const Subcommands = struct { program: []const u8, words: u8 };
const ValueFlag = struct { program: []const u8, flag: []const u8 };

const command_wrappers = [_][]const u8{ "sudo", "env", "time", "command", "exec", "nohup" };
const command_keywords = [_][]const u8{
    "if", "then", "else", "elif", "fi", "while", "until", "do", "done", "esac", "!",
};
const command_preparations = [_][]const u8{
    "cd",   "pushd", "export", "set", "source", ".", "ulimit", "[", "[[", "test", "for", "case",
    "true", "false", ":",
};
const command_interpreters = [_][]const u8{
    "sh", "bash", "zsh", "node", "python", "python3", "ruby",
};
const command_subcommands = [_]Subcommands{
    .{ .program = "git", .words = 1 },
    .{ .program = "jj", .words = 1 },
    .{ .program = "brew", .words = 1 },
    .{ .program = "make", .words = 1 },
    .{ .program = "npx", .words = 1 },
    .{ .program = "drinky", .words = 1 },
    .{ .program = "zig", .words = 2 },
    .{ .program = "npm", .words = 2 },
    .{ .program = "pnpm", .words = 2 },
    .{ .program = "yarn", .words = 2 },
    .{ .program = "cargo", .words = 2 },
    .{ .program = "go", .words = 2 },
    .{ .program = "swift", .words = 2 },
    .{ .program = "docker", .words = 2 },
    .{ .program = "kubectl", .words = 2 },
    .{ .program = "gh", .words = 2 },
    .{ .program = "rex", .words = 2 },
};
const command_value_flags = [_]ValueFlag{
    .{ .program = "git", .flag = "-C" },
    .{ .program = "git", .flag = "-c" },
    .{ .program = "make", .flag = "-C" },
    .{ .program = "make", .flag = "-f" },
    .{ .program = "sudo", .flag = "-u" },
    .{ .program = "sudo", .flag = "-g" },
    .{ .program = "env", .flag = "-u" },
};

const command_segment_breaks = ";&|\n";
const command_word_breaks = " \t\r(){}" ++ command_segment_breaks;
const command_comment_starts = " \t\r(" ++ command_segment_breaks;

const CommandWords = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *CommandWords) ?[]const u8 {
        while (self.index < self.text.len) {
            if (self.commentStarts()) {
                self.index = std.mem.findScalarPos(u8, self.text, self.index, '\n') orelse
                    self.text.len;
                return null;
            }
            if (self.continuationStarts()) {
                self.index += 2;
                continue;
            }
            const byte = self.text[self.index];
            if (std.mem.findScalar(u8, command_word_breaks, byte) == null) break;
            if (std.mem.findScalar(u8, command_segment_breaks, byte) != null) return null;
            self.index += 1;
        }
        if (self.index == self.text.len) return null;
        const start = self.index;
        var maybe_quote: ?u8 = null;
        while (self.index < self.text.len) : (self.index += 1) {
            const byte = self.text[self.index];
            if (maybe_quote) |quote| {
                if (byte == quote) {
                    maybe_quote = null;
                } else if (byte == '\\' and quote == '"') self.index += 1;
            } else switch (byte) {
                '"', '\'', '`' => maybe_quote = byte,
                '\\' => if (self.continuationEndsWord()) break else {
                    self.index += 1;
                },
                '$' => self.index = self.substitutionEnd(),
                else => if (std.mem.findScalar(u8, command_word_breaks, byte) != null) break,
            }
        }
        self.index = @min(self.index, self.text.len);
        return self.text[start..self.index];
    }

    fn substitutionEnd(self: *const CommandWords) usize {
        const open = self.index + 1;
        if (open == self.text.len or self.text[open] != '(') return self.index;
        var depth: usize = 0;
        for (self.text[open..], open..) |byte, index| switch (byte) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        };
        return self.text.len;
    }

    fn continuationStarts(self: *const CommandWords) bool {
        return std.mem.startsWith(u8, self.text[self.index..], "\\\n");
    }

    fn continuationEndsWord(self: *const CommandWords) bool {
        if (!self.continuationStarts()) return false;
        const after = self.index + 2;
        return after == self.text.len or
            std.mem.findScalar(u8, command_word_breaks, self.text[after]) != null;
    }

    fn commentStarts(self: *const CommandWords) bool {
        if (self.text[self.index] != '#') return false;
        if (self.index == 0) return true;
        return std.mem.findScalar(u8, command_comment_starts, self.text[self.index - 1]) != null;
    }

    fn skipSegment(self: *CommandWords) void {
        while (self.next()) |_| {}
        self.index = @min(self.index + 1, self.text.len);
    }
};

pub fn mainCommand(buffer: []u8, command: []const u8) ?[]const u8 {
    var words: CommandWords = .{ .text = command };
    while (words.index < command.len) : (words.skipSegment()) {
        var maybe_program: ?[]const u8 = null;
        var maybe_wrapper: ?[]const u8 = null;
        while (words.next()) |word| {
            if (word[0] == '-') {
                const wrapper = maybe_wrapper orelse break;
                if (valueFlag(wrapper, word)) _ = words.next();
                continue;
            }
            if (assignment(word) or listed(&command_keywords, word)) continue;
            const name = std.fs.path.basename(unquoted(word));
            if (listed(&command_wrappers, name)) {
                maybe_wrapper = name;
                continue;
            }
            maybe_program = name;
            break;
        }
        const program = maybe_program orelse continue;
        if (listed(&command_preparations, program)) continue;
        if (!commandName(program)) return null;
        var writer: std.Io.Writer = .fixed(buffer);
        writer.writeAll(program) catch return null;
        if (listed(&command_interpreters, program)) {
            while (words.next()) |word| {
                if (redirection(word)) break;
                if (word[0] == '-') {
                    if (!flagWithValue(word)) break;
                    continue;
                }
                if (quoted(word) or !printable(word)) break;
                writer.print(" {s}", .{std.fs.path.basename(word)}) catch return null;
                break;
            }
            return writer.buffered();
        }
        var remaining = subcommandWords(program);
        while (remaining > 0) {
            const word = words.next() orelse break;
            if (word[0] == '-') {
                if (!valueFlag(program, word)) break;
                _ = words.next();
                continue;
            }
            if (!subcommandWord(word)) break;
            writer.print(" {s}", .{word}) catch return null;
            remaining -= 1;
        }
        return writer.buffered();
    }
    return null;
}

fn unquoted(word: []const u8) []const u8 {
    if (word.len < 2 or word[0] != word[word.len - 1] or !quoted(word[0..1])) return word;
    return word[1 .. word.len - 1];
}

fn flagWithValue(word: []const u8) bool {
    return std.mem.findScalar(u8, word, '=') != null or quoted(word);
}

fn redirection(word: []const u8) bool {
    return std.mem.findAny(u8, word, "<>") != null;
}

fn assignment(word: []const u8) bool {
    const equals = std.mem.findScalar(u8, word, '=') orelse return false;
    if (equals == 0 or std.ascii.isDigit(word[0])) return false;
    for (word[0..equals]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn commandName(word: []const u8) bool {
    return word.len > 0 and (std.ascii.isAlphanumeric(word[0]) or word[0] == '_') and
        !quoted(word) and printable(word);
}

fn printable(word: []const u8) bool {
    for (word) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn quoted(word: []const u8) bool {
    return std.mem.findAny(u8, word, "\"'") != null;
}

fn listed(list: []const []const u8, word: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, word)) return true;
    }
    return false;
}

fn subcommandWords(program: []const u8) u8 {
    for (command_subcommands) |entry| {
        if (std.mem.eql(u8, entry.program, program)) return entry.words;
    }
    return 0;
}

fn valueFlag(program: []const u8, flag: []const u8) bool {
    for (command_value_flags) |entry| {
        if (std.mem.eql(u8, entry.program, program) and std.mem.eql(u8, entry.flag, flag))
            return true;
    }
    return false;
}

fn subcommandWord(word: []const u8) bool {
    if (!std.ascii.isLower(word[0])) return false;
    for (word[1..]) |byte| {
        const allowed = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            byte == ':' or byte == '.' or byte == '_' or byte == '-';
        if (!allowed) return false;
    }
    return true;
}

test mainCommand {
    const cases = [_]struct { command: []const u8, shown: ?[]const u8 }{
        .{ .command = "git push origin main", .shown = "git push" },
        .{
            .command = "cd lib && zig build test --summary all 2>&1 | tail -20",
            .shown = "zig build test",
        },
        .{ .command = "zig build run -- --verbose", .shown = "zig build run" },
        .{ .command = "git -C ../drinky status --short", .shown = "git status" },
        .{ .command = "npm run dev", .shown = "npm run dev" },
        .{ .command = "FOO=1 npx prettier --check .", .shown = "npx prettier" },
        .{ .command = "sh scripts/check.sh", .shown = "sh check.sh" },
        .{ .command = "rg -n \"TODO\" src lib", .shown = "rg" },
        .{ .command = "git commit -m \"Add Pac-Man\"", .shown = "git commit" },
        .{ .command = "zig build -Doptimize=ReleaseFast", .shown = "zig build" },
        .{ .command = "sudo brew upgrade", .shown = "brew upgrade" },
        .{ .command = "sudo -u root make install", .shown = "make install" },
        .{ .command = "env -i HOME=/tmp node demo.js", .shown = "node demo.js" },
        .{ .command = "time -p zig build test", .shown = "zig build test" },
        .{ .command = "python3 -c \"import json; print(1)\"", .shown = "python3" },
        .{ .command = "bash -lc 'zig build'", .shown = "bash" },
        .{ .command = "FOO=1 sh -c 'sleep 30; echo done'", .shown = "sh" },
        .{ .command = "node -e console.log(1)", .shown = "node" },
        .{ .command = "/usr/bin/env node demo.js", .shown = "node demo.js" },
        .{ .command = "drinky run --model x review", .shown = "drinky run" },
        .{ .command = "make\nzig build", .shown = "make" },
        .{ .command = "(cd lib && zig build test)", .shown = "zig build test" },
        .{ .command = "for f in *.zig; do zig fmt \"$f\"; done", .shown = "zig fmt" },
        .{ .command = "if [ -f x ]; then make; fi", .shown = "make" },
        .{ .command = "[ -f build.zig ] && zig build", .shown = "zig build" },
        .{ .command = "! git diff --quiet", .shown = "git diff" },
        .{ .command = "{ zig build; } 2>&1", .shown = "zig build" },
        .{ .command = "npm --prefix web run build", .shown = "npm" },
        .{ .command = "# check the tree\ngit status", .shown = "git status" },
        .{ .command = "python3 - <<'EOF'\nprint(1)\nEOF", .shown = "python3" },
        .{ .command = "bash < script.sh", .shown = "bash" },
        .{ .command = "# note; zig build", .shown = null },
        .{ .command = "zig build test # all; rm -rf out", .shown = "zig build test" },
        .{ .command = "while true; do sleep 1; done", .shown = "sleep" },
        .{ .command = ": > log && zig build", .shown = "zig build" },
        .{ .command = "$(which zig) build", .shown = null },
        .{ .command = "FOO=$(date +%s) make", .shown = "make" },
        .{ .command = "FOO=`git rev-parse HEAD` make", .shown = "make" },
        .{ .command = "cd lib", .shown = null },
        .{ .command = "  ", .shown = null },
        .{ .command = "MSG=\"hello world\" make", .shown = "make" },
        .{ .command = "AUTH=\"Bearer sk-xyz\" curl https://example.com", .shown = "curl" },
        .{ .command = "GIT_SSH_COMMAND=\"ssh -i key\" git push", .shown = "git push" },
        .{ .command = "MSG=\"first\nsecond\" make", .shown = "make" },
        .{ .command = "MSG=\"say \\\"hi there\\\"\" make", .shown = "make" },
        .{ .command = "cd \"a;b\" && make", .shown = "make" },
        .{ .command = "\"./scripts/run.sh\" --fast", .shown = "run.sh" },
        .{ .command = "node --require='ts-node/register' app.ts", .shown = "node app.ts" },
        .{ .command = "python3 -W'ignore' script.py", .shown = "python3 script.py" },
        .{ .command = "node --max-old-space-size 4096 app.js", .shown = "node" },
        .{ .command = "[ ${#x} -gt 0 ] && make", .shown = "make" },
        .{ .command = "if [ ${#arr[@]} -eq 0 ]; then make; fi", .shown = "make" },
        .{ .command = "cd lib && \\\n  zig build test", .shown = "zig build test" },
        .{ .command = "node \\\n  app.js", .shown = "node app.js" },
        .{ .command = "zig build\\\n  test", .shown = "zig build test" },
        .{ .command = "git sta\\\ntus", .shown = "git" },
        .{ .command = "ma\\\nke", .shown = null },
        .{ .command = "\"my\ntool\" --fast", .shown = null },
        .{ .command = "node app\\\t.js", .shown = "node" },
    };
    var buffer: [64]u8 = undefined;
    for (cases) |case| {
        const shown = mainCommand(&buffer, case.command);
        if (case.shown) |expected| {
            try std.testing.expectEqualStrings(expected, shown orelse "(none)");
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown);
    }
    var tiny: [4]u8 = undefined;
    try std.testing.expect(mainCommand(&tiny, "git push") == null);
}

test path {
    const gpa = std.testing.allocator;
    const roots: Roots = .{ .working_directory = "/home/you/work", .home_directory = "/home/you" };
    const cases = [_]struct { target: []const u8, expected: []const u8 }{
        .{ .target = "/home/you/work/src/App.zig", .expected = "src/App.zig" },
        .{ .target = "/home/you/.drinky/config.json", .expected = "~/.drinky/config.json" },
        .{ .target = "/home/you", .expected = "~" },
        .{ .target = "/home/yours/a.zig", .expected = "/home/yours/a.zig" },
        .{ .target = "/etc/hosts", .expected = "/etc/hosts" },
        .{ .target = "src/App.zig", .expected = "src/App.zig" },
    };
    for (cases) |case| {
        const shown = try path(gpa, case.target, &roots);
        defer gpa.free(shown);
        try std.testing.expectEqualStrings(case.expected, shown);
    }
    const bare = try path(gpa, "/home/you/work/src/App.zig", &.{});
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/home/you/work/src/App.zig", bare);
}

test durationSeconds {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, 0));
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, 999));
    try std.testing.expectEqualStrings("1s", durationSeconds(&buffer, 1_000));
    try std.testing.expectEqualStrings("30s", durationSeconds(&buffer, 30_400));
    try std.testing.expectEqualStrings("59s", durationSeconds(&buffer, 59_999));
    try std.testing.expectEqualStrings("1m 0s", durationSeconds(&buffer, 60_000));
    try std.testing.expectEqualStrings("2m 5s", durationSeconds(&buffer, 125_400));
    try std.testing.expectEqualStrings("60m 0s", durationSeconds(&buffer, 3_600_000));
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, -1));
}

test coarseDuration {
    var buffer: [24]u8 = undefined;
    const cases = [_]struct { seconds: u64, text: []const u8 }{
        .{ .seconds = 59, .text = "0m" },
        .{ .seconds = 60, .text = "1m" },
        .{ .seconds = 3_599, .text = "59m" },
        .{ .seconds = 3_600, .text = "1h" },
        .{ .seconds = 86_399, .text = "23h" },
        .{ .seconds = 86_400, .text = "1d" },
        .{ .seconds = 40 * 86_400, .text = "40d" },
    };
    for (cases) |case|
        try std.testing.expectEqualStrings(case.text, coarseDuration(&buffer, case.seconds));
}

test bytes {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", bytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KiB", bytes(&buffer, 1024));
    try std.testing.expectEqualStrings("3.1 KiB", bytes(&buffer, 3200));
    try std.testing.expectEqualStrings("1.0 MiB", bytes(&buffer, 1024 * 1024));
}
