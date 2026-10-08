const std = @import("std");

const download = @import("download.zig");

const version = "0.31.2";
const corpus_url = "https://spec.commonmark.org/" ++ version ++ "/spec.json";
const license_url = "https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt";
const corpus_output_path = "lib/markdown/commonmark_spec.json";
const license_output_path = "lib/markdown/COMMONMARK_LICENSE";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const corpus = try download.bytes(arena, &client, corpus_url);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = corpus_output_path, .data = corpus });

    const license = try download.bytes(arena, &client, license_url);
    var notice: std.Io.Writer.Allocating = .init(arena);
    try notice.writer.print(license_header, .{ version, version });
    try notice.writer.writeAll(license);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = license_output_path,
        .data = notice.written(),
    });

    std.debug.print("wrote {s} from CommonMark {s}\n", .{ corpus_output_path, version });
    std.debug.print("wrote {s}\n", .{license_output_path});
}

const license_header =
    \\The corpus in commonmark_spec.json holds the examples of the CommonMark Spec, version {s},
    \\by John MacFarlane, from https://spec.commonmark.org/{s}/. The spec distributes them under the
    \\Creative Commons Attribution-ShareAlike 4.0 International license below. Drinky stores the
    \\examples without change.
    \\
    \\
;
