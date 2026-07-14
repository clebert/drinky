//! The provider-neutral conversation model. Every provider translates its wire
//! format to and from these types, so the agent loop and tools depend only on
//! this module — never on a specific provider. Pure data: no state, no I/O.

/// The model providers the agent core supports: the neutral tag the `provider`
/// module keys its `Client` union on, and that `models` tags each table entry
/// with, so both can name a provider without depending on a concrete client.
pub const Provider = enum { anthropic };

pub const Role = enum { user, assistant };

/// A named reasoning-effort level passed through to the provider, which picks
/// the actual thinking depth itself (Anthropic maps it to `output_config.effort`
/// under adaptive thinking; OpenAI to its reasoning-effort control). `off` turns
/// reasoning off; the rest match Anthropic's effort ladder.
pub const Effort = enum { off, low, medium, high, xhigh, max };

pub const Block = union(enum) {
    thinking: Thinking,
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,

    /// A run of model reasoning, carried back verbatim on later turns so the
    /// provider accepts the tool calls that followed it.
    pub const Thinking = struct {
        /// Human-readable reasoning; empty for a redacted or omitted block.
        text: []const u8,
        /// Opaque token round-tripped unchanged so the provider can verify the
        /// reasoning: a signature for a normal block, the encrypted payload for
        /// a redacted one (told apart by `redacted`).
        signature: []const u8,
        /// The reasoning was withheld by the provider's safety filter; `text` is
        /// empty and `signature` holds its encrypted payload.
        redacted: bool = false,
    };

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
    parameters: []const Parameter,
};

pub const Parameter = struct {
    name: []const u8,
    type: Type,
    description: []const u8,
    required: bool = false,

    pub const Type = enum { string, integer, boolean };
};

pub const Request = struct {
    model: []const u8,
    tokens_max: u32,
    system: []const u8,
    messages: []const Message,
    tools: []const Tool,
    effort: Effort = .off,
};

/// Token counts for one assistant message. `input` is uncached prompt tokens;
/// the full billed prompt is `input + cache_read + cache_write`.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,

    /// Field-wise sum, for accumulating several messages' usage.
    pub fn plus(self: Usage, other: Usage) Usage {
        return .{
            .input = self.input + other.input,
            .output = self.output + other.output,
            .cache_read = self.cache_read + other.cache_read,
            .cache_write = self.cache_write + other.cache_write,
        };
    }
};

/// A decoded fragment of a streamed assistant reply.
pub const Event = union(enum) {
    text: []const u8,
    /// A chunk of streamed reasoning text.
    thinking: []const u8,
    /// The signature closing the current reasoning run, carried back verbatim.
    thinking_signature: []const u8,
    /// A complete redacted reasoning block: its opaque encrypted payload.
    thinking_redacted: []const u8,
    tool_use: struct { id: []const u8, name: []const u8 },
    input_json: []const u8,
    stop: Stop,

    /// End of an assistant message: why it ended, and its cumulative usage.
    pub const Stop = struct {
        reason: ?[]const u8,
        usage: Usage,
    };
};
