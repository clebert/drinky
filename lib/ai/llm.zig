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

/// One entry in the flat, ordered conversation history. Every provider
/// translates its wire format to and from this list; the agent loop appends
/// items in the exact order the model produced them (reasoning first, then text
/// and tool calls interleaved as streamed) and a provider serializer replays
/// them one-item-one-block, sharing a role envelope over a run of same-role
/// items but never reordering or concatenating.
pub const Item = union(enum) {
    /// A user or assistant text turn.
    message: Message,
    /// One run of model reasoning (assistant-only).
    reasoning: Reasoning,
    /// The model asking to call a tool (assistant-only).
    tool_call: ToolCall,
    /// The outcome of a tool call, fed back on the input side.
    tool_result: ToolResult,

    pub const Message = struct {
        role: Role,
        text: []const u8,
    };

    /// A run of model reasoning, carried back verbatim on later turns so the
    /// provider accepts the tool calls that followed it.
    pub const Reasoning = struct {
        /// Human-visible reasoning/summary; empty when redacted or none.
        text: []const u8,
        /// Opaque token round-tripped unchanged so the provider can verify the
        /// reasoning: Anthropic `signature` / redacted `data`, or OpenAI
        /// `encrypted_content`. Never cross-fed between providers.
        blob: []const u8,
        /// The reasoning was withheld by the provider's safety filter; `text` is
        /// empty and `blob` holds its encrypted payload.
        redacted: bool = false,
        /// OpenAI reasoning-item id, needed to replay the item under
        /// `store:false`; empty for Anthropic.
        id: []const u8 = "",
        /// Which provider produced `blob`, so a serializer only replays its own
        /// and drops a foreign reasoning item whole.
        origin: Provider,
    };

    pub const ToolCall = struct {
        /// Unified call key: Anthropic `tool_use.id` == OpenAI `call_id`.
        call_id: []const u8,
        name: []const u8,
        /// Raw JSON object for the arguments; empty means an empty object.
        arguments_json: []const u8,
    };

    pub const ToolResult = struct {
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
    };
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
    items: []const Item,
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
    thinking: Thinking,
    /// The opaque blob closing the current reasoning run, carried back verbatim.
    thinking_blob: Blob,
    /// A complete redacted reasoning block: its opaque encrypted payload.
    thinking_redacted: Blob,
    tool_use: struct { call_id: []const u8, name: []const u8 },
    input_json: []const u8,
    stop: Stop,

    /// A reasoning text delta tagged with its reasoning-item id (empty for
    /// Anthropic; OpenAI's server-assigned `reasoning.id`).
    pub const Thinking = struct {
        id: []const u8 = "",
        text: []const u8,
    };

    /// An opaque reasoning blob (signature, redacted payload, or encrypted
    /// content) tagged with its reasoning-item id (empty for Anthropic).
    pub const Blob = struct {
        id: []const u8 = "",
        blob: []const u8,
    };

    /// End of an assistant message: why it ended, and its cumulative usage.
    pub const Stop = struct {
        reason: ?[]const u8,
        usage: Usage,
    };
};
