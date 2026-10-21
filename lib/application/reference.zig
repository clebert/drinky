const std = @import("std");
const core = @import("core");

pub const effort_default: core.Provider.Effort = .xhigh;
pub const repeat_window_ms = 500;
pub const fetch_wait_text = "Drinky fetches the model list.";
pub const key_hints = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};
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

pub fn singleLine(text: []u8) []u8 {
    var length: usize = 0;
    var blank = false;
    for (text) |byte| {
        if (byte == ' ' or byte <= 0x1f or byte == 0x7f) {
            blank = length > 0;
            continue;
        }
        if (blank) {
            text[length] = ' ';
            length += 1;
            blank = false;
        }
        text[length] = byte;
        length += 1;
    }
    return text[0..length];
}

pub const nested = "DRINKY_RUN";
pub const nested_refusal = "Drinky cannot start drinky run inside another drinky run process.";
pub const prompt_missing = "Drinky received no prompt on stdin.";
pub const prompt_not_utf8 = "Drinky cannot use the prompt because it is not valid UTF-8.";
pub const models_missing = "No signed-in account has a saved model list. Sign in and fetch a " ++
    "list with /model in Drinky.";

pub fn promptRefusal(prompt: []const u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(prompt)) return prompt_not_utf8;
    if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0) return prompt_missing;
    return null;
}
