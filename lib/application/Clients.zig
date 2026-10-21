const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

const Choice = @import("Choice.zig");

const Clients = @This();

gpa: std.mem.Allocator,
leases: std.ArrayList(Lease),
current: ?Current,
configured: ?Choice,

const Current = struct {
    client: *accounts.Client,
    account: usize,
};

const Lease = struct {
    client: *accounts.Client,
    setups: usize,
};

pub fn init(gpa: std.mem.Allocator) Clients {
    return .{ .gpa = gpa, .leases = .empty, .current = null, .configured = null };
}

pub fn deinit(self: *Clients) void {
    for (self.leases.items) |lease| self.destroy(lease.client);
    self.leases.deinit(self.gpa);
    self.* = undefined;
}

pub fn select(
    self: *Clients,
    registry: *accounts.Registry,
    maybe_account: ?usize,
) error{ SignedOut, OutOfMemory }!void {
    const current_account = if (self.current) |current| current.account else null;
    if (maybe_account == current_account) return;
    self.close();
    const account = maybe_account orelse return;
    try self.leases.ensureUnusedCapacity(self.gpa, 1);
    const client = try self.gpa.create(accounts.Client);
    errdefer self.gpa.destroy(client);
    try registry.open(client, account);
    self.leases.appendAssumeCapacity(.{ .client = client, .setups = 0 });
    self.current = .{ .client = client, .account = account };
}

pub fn close(self: *Clients) void {
    self.current = null;
    self.configured = null;
    self.sweep();
}

pub fn addSetup(self: *Clients, choice: *const Choice) void {
    const current = self.current.?;
    self.configured = choice.*;
    for (self.leases.items) |*lease| {
        if (lease.client != current.client) continue;
        lease.setups += 1;
        return;
    }
    unreachable;
}

pub fn release(self: *Clients, provider: core.Provider) void {
    for (self.leases.items) |*lease| {
        if (lease.client.provider().ptr != provider.ptr) continue;
        lease.setups -= 1;
        break;
    } else unreachable;
    self.sweep();
}

fn sweep(self: *Clients) void {
    const current_client = if (self.current) |current| current.client else null;
    var index = self.leases.items.len;
    while (index > 0) {
        index -= 1;
        const lease = self.leases.items[index];
        if (lease.setups > 0 or lease.client == current_client) continue;
        self.destroy(lease.client);
        _ = self.leases.swapRemove(index);
    }
}

fn destroy(self: *Clients, client: *accounts.Client) void {
    client.deinit();
    self.gpa.destroy(client);
}
