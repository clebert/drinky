const core = @import("core");

pub const nested = "DRINKY_RUN";
pub const model = "DRINKY_MODEL";
pub const effort = "DRINKY_EFFORT";

pub fn variables(
    model_value: []const u8,
    effort_value: core.Provider.Effort,
) [2]core.Runner.Variable {
    return .{
        .{ .name = model, .value = model_value },
        .{ .name = effort, .value = @tagName(effort_value) },
    };
}
