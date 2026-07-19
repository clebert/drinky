//! Ambient session state handed to every slash-command handler, mirroring the
//! tool Context.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");

gpa: std.mem.Allocator,
agent: *Agent,
/// For account-qualified model selection.
accounts: *Accounts,
