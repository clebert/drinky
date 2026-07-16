//! Ambient state handed to every slash-command handler. Carries the session's
//! agent so a command can read and reconfigure it, mirroring the tool Context —
//! it grows as commands need more of the session without changing any handler
//! signature.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");

gpa: std.mem.Allocator,
agent: *Agent,
/// The session's account registry: which accounts are authenticated and the
/// client to switch to for one, so a command can select an account-qualified
/// model.
accounts: *Accounts,
