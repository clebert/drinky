const std = @import("std");

const View = @import("View.zig");

const Device = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buffer: []u8) std.Io.File.ReadStreamingError!usize,
    waitResize: *const fn (ptr: *anyopaque) std.Io.File.ReadStreamingError!void,
    size: *const fn (ptr: *anyopaque) ?View.Size,
    setAlternateScreen: *const fn (ptr: *anyopaque, enabled: bool) std.Io.Writer.Error!void,
    writer: *const fn (ptr: *anyopaque) *std.Io.Writer,
};

pub fn read(self: Device, buffer: []u8) std.Io.File.ReadStreamingError!usize {
    return self.vtable.read(self.ptr, buffer);
}

pub fn waitResize(self: Device) std.Io.File.ReadStreamingError!void {
    return self.vtable.waitResize(self.ptr);
}

pub fn size(self: Device) ?View.Size {
    return self.vtable.size(self.ptr);
}

pub fn setAlternateScreen(self: Device, enabled: bool) std.Io.Writer.Error!void {
    return self.vtable.setAlternateScreen(self.ptr, enabled);
}

pub fn writer(self: Device) *std.Io.Writer {
    return self.vtable.writer(self.ptr);
}
