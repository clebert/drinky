const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

pub fn cost(usage: *const core.Provider.Usage, maybe_model: ?*const accounts.Model) ?f64 {
    const amount = usage.cost_usd orelse amount: {
        const model = maybe_model orelse return null;
        break :amount model.cost(usage) orelse return null;
    };
    if (!std.math.isFinite(amount) or amount < 0) return null;
    return @min(amount, core.Provider.amount_usd_max);
}
