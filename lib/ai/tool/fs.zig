//! Filesystem helpers shared by the mutating tools.

const std = @import("std");

/// Create or replace `sub_path` with `data` atomically. The bytes go to a
/// temporary file in the same directory, and a rename moves it over the
/// destination. A canceled or crashed write leaves the existing file untouched
/// rather than truncated.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, options: Options) !void {
    var atomic = try dir.createFileAtomic(io, options.sub_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, options.data);
    try atomic.replace(io);
}

pub const Options = struct {
    sub_path: []const u8,
    data: []const u8,
};

/// A copy of `std.testing.io` whose chosen file operation fails with
/// `error.Canceled`. Tool tests use it to prove a cancel in the file phase
/// propagates and does not degrade into an ordinary tool-error result. It
/// shares the real io's userdata, so every other operation passes through
/// untouched.
pub const CancelIo = struct {
    vtable: std.Io.VTable,

    pub fn init(target: enum { file_open, file_write }) CancelIo {
        var vtable = std.testing.io.vtable.*;
        switch (target) {
            .file_open => vtable.dirOpenFile = openFile,
            .file_write => vtable.operate = operate,
        }
        return .{ .vtable = vtable };
    }

    pub fn io(self: *const CancelIo) std.Io {
        return .{ .userdata = std.testing.io.userdata, .vtable = &self.vtable };
    }

    fn openFile(
        _: ?*anyopaque,
        _: std.Io.Dir,
        _: []const u8,
        _: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        return error.Canceled;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming) return error.Canceled;
        return std.testing.io.vtable.operate(userdata, operation);
    }
};
