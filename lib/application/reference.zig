const core = @import("core");

pub const effort_default: core.Provider.Effort = .xhigh;
pub const blank_bytes = " \t\r\n";
pub const effort_levels = levels: {
    const names = @typeInfo(core.Provider.Effort).@"enum".field_names;
    var text: []const u8 = "";
    for (names, 0..) |name, index| {
        const separator = if (index == 0) "" else if (index + 1 == names.len) ", or " else ", ";
        text = text ++ separator ++ name;
    }
    break :levels text;
};

pub const nested = "DRINKY_RUN";
