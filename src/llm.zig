//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types, so the agent loop and tools depend only on
//! this module — never on a specific provider. Pure data: no state, no I/O.

pub const Role = enum { user, assistant };

pub const Block = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,

    pub const ToolUse = struct {
        id: []const u8,
        name: []const u8,
        /// Raw JSON object for the tool input; empty means an empty object.
        input_json: []const u8,
    };

    pub const ToolResult = struct {
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
};

pub const Message = struct {
    role: Role,
    blocks: []const Block,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema object for the tool's input.
    schema_json: []const u8,
};

pub const Request = struct {
    model: []const u8,
    tokens_max: u32,
    system: []const u8,
    messages: []const Message,
    tools: []const Tool,
};

/// A decoded fragment of a streamed assistant reply.
pub const Event = union(enum) {
    text: []const u8,
    tool_use: struct { id: []const u8, name: []const u8 },
    input_json: []const u8,
    stop: ?[]const u8,
};
