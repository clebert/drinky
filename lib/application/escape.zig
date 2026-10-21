const std = @import("std");

const core = @import("core");

const diagnostic_bytes_max = 96;
const display_bytes_max = 4 * std.Io.Dir.max_path_bytes + 1024;

pub fn diagnostic(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    return escaped(gpa, text, diagnostic_bytes_max);
}

pub fn display(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    return escaped(gpa, text, display_bytes_max);
}

fn escaped(
    gpa: std.mem.Allocator,
    text: []const u8,
    input_bytes_max: usize,
) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < text.len and index < input_bytes_max) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        const sequence_valid = length >= 1 and index + length <= text.len and
            index + length <= input_bytes_max and
            std.unicode.utf8ValidateSlice(text[index..][0..length]);
        const codepoint = if (sequence_valid)
            std.unicode.utf8Decode(text[index..][0..length]) catch unreachable
        else
            0;
        if (sequence_valid and codepointPrintable(codepoint)) {
            output.writer.writeAll(text[index..][0..length]) catch return error.OutOfMemory;
            index += length;
        } else {
            output.writer.print("\\x{x:0>2}", .{text[index]}) catch return error.OutOfMemory;
            index += 1;
        }
    }
    if (index < text.len) output.writer.writeAll("…") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn codepointPrintable(codepoint: u21) bool {
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return false;
    return switch (codepoint) {
        0x00ad,
        0x0600...0x0605,
        0x061c,
        0x06dd,
        0x070f,
        0x0890...0x0891,
        0x08e2,
        0x180e,
        0x200b...0x200f,
        0x2028...0x202e,
        0x2060...0x2064,
        0x2066...0x206f,
        0xfeff,
        0xfff9...0xfffb,
        0x110bd,
        0x110cd,
        0x13430...0x1343f,
        0x1bca0...0x1bca3,
        0x1d173...0x1d17a,
        0xe0001,
        0xe0020...0xe007f,
        => false,
        else => true,
    };
}

test display {
    const gpa = std.testing.allocator;
    const shown = try display(gpa, "/tmp/line\n\xe2\x80\xaereordered\xe2\x80\xa8next");
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(
        "/tmp/line\\x0a\\xe2\\x80\\xaereordered\\xe2\\x80\\xa8next",
        shown,
    );

    const oversized = try display(gpa, core.text.repeat("x", display_bytes_max + 1));
    defer gpa.free(oversized);
    try std.testing.expectEqual(display_bytes_max + "…".len, oversized.len);
    try std.testing.expect(std.mem.endsWith(u8, oversized, "…"));
}

test diagnostic {
    const gpa = std.testing.allocator;
    const tail = core.text.repeat("b", diagnostic_bytes_max);
    const shown = try diagnostic(gpa, "a\xc2\x9b\xe2\x80\xae\xff" ++ tail);
    defer gpa.free(shown);
    try std.testing.expect(std.mem.startsWith(u8, shown, "a\\xc2\\x9b\\xe2\\x80\\xae\\xff"));
    try std.testing.expect(std.mem.endsWith(u8, shown, "b…"));
}
