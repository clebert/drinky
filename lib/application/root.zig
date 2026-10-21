const std = @import("std");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const accounts = @import("accounts");
const controller = @import("Controller.zig");

pub const Controller = controller.Handle;
pub const Options = controller.Options;
pub const Startup = controller.Startup;
pub const Command = controller.Command;
pub const Event = controller.Event;
pub const Sink = controller.Sink;
pub const Mail = controller.Mail;
pub const Mailbox = controller.Mailbox;
pub const Response = controller.Response;
pub const Confirmation = @import("Message.zig").Confirmation;
pub const SkillLoaded = core.Session.Event.SkillLoaded;

pub const Snapshot = @import("Snapshot.zig");
pub const Interaction = @import("Interaction.zig");
pub const model_list = @import("model_list.zig");
pub const Record = @import("Record.zig");
pub const Live = @import("Live.zig");
pub const Picker = @import("Picker.zig");
pub const Page = @import("Page.zig");
pub const Statistics = @import("Surface.zig").Statistics;
pub const Settings = @import("Settings.zig");
pub const Message = @import("Message.zig");
pub const Choice = @import("Choice.zig");
pub const Usage = core.Provider.Usage;
pub const Quota = core.Provider.Quota;
pub const Credits = core.Provider.Credits;
pub const Effort = core.Provider.Effort;
pub const Failure = core.Provider.Failure;
pub const Outcome = core.Session.Outcome;
pub const ToolOutput = core.Tool.Output;
pub const ToolCondition = core.Tool.Condition;
pub const ToolDescription = tools.Registry.Description;
pub const Directories = accounts.json_store.Directories;
pub const Transport = providers.Transport;
pub const Browser = accounts.oauth.login.Browser;
pub const Loopback = accounts.oauth.callback.Loopback;
pub const CostReporter = tools.CostPipe.Writer;
pub const CostReportError = tools.CostPipe.Error;
pub const cost_report_environment = tools.CostPipe.environment;
pub const branch_bytes_max = @import("project.zig").head_bytes_max;
pub const reference = @import("reference.zig");
pub const support = struct {
    pub const repeat = core.text.repeat;
    pub const pluralSuffix = core.text.pluralSuffix;
    pub const timeout = core.timeout.run;
    pub const duration = tools.format.duration;
    pub const entryNoun = tools.walk.entryNoun;
    pub const diagnostic = @import("escape.zig").diagnostic;
    pub const format = @import("format.zig");
    pub const failureText = @import("turn_text.zig").failureText;
    pub const truncated = @import("turn_text.zig").truncated;
    pub const exhausted = @import("turn_text.zig").exhausted;
    pub const outOfMemory = core.fatal.outOfMemory;
};

pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Config.zig");
    _ = @import("describe.zig");
    _ = @import("discovery/root.zig");
    _ = @import("command/root.zig");
    _ = @import("system_prompt.zig");
    _ = @import("sources.zig");
    _ = @import("Transcript.zig");
    _ = @import("reducer.zig");
}
