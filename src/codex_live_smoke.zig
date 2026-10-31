//! Live smoke test for native function calls through the ChatGPT Codex API.
//!
//! Run with `zig build codex-live-test`. The harness uses local OAuth and one
//! in-memory tool.

const std = @import("std");
const compat = @import("compat");
const nullclaw = @import("nullclaw");

const Allocator = std.mem.Allocator;
const Config = nullclaw.config.Config;
const Agent = nullclaw.agent.Agent;
const Tool = nullclaw.tools.Tool;
const ToolResult = nullclaw.tools.ToolResult;
const ToolArgs = nullclaw.tools.JsonObjectMap;

const SMOKE_VALUE = "codex-native-tool-smoke";
const SMOKE_OUTPUT = "LIVE_ECHO_RESULT: codex-native-tool-smoke";
const SMOKE_PROMPT = "Call live_echo exactly once with value `codex-native-tool-smoke`. " ++
    "After the tool returns, reply with the exact tool result string and nothing else.";

const LiveSmokeConfig = struct {
    model: []const u8 = "gpt-6.1-sol",
    log_codex_exchange: bool = true,
};
const live_smoke_config = LiveSmokeConfig{};

const EchoState = struct {
    calls: usize = 0,
    received_expected_value: bool = false,
};

const LiveEchoTool = struct {
    state: *EchoState,

    pub const tool_name = "live_echo";
    pub const tool_description = "Return a fixed prefix and the supplied value for the Codex native tool smoke test.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"],\"additionalProperties\":false}";
    pub const vtable = nullclaw.tools.ToolVTable(@This());

    fn tool(self: *LiveEchoTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *LiveEchoTool, allocator: Allocator, args: ToolArgs) !ToolResult {
        const value = nullclaw.tools.getString(args, "value") orelse return error.MissingSmokeValue;
        self.state.calls += 1;
        self.state.received_expected_value = std.mem.eql(u8, value, SMOKE_VALUE);
        return .{
            .success = true,
            .output = try std.fmt.allocPrint(allocator, "LIVE_ECHO_RESULT: {s}", .{value}),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    compat.initProcess(init);
    const allocator = std.heap.page_allocator;
    const model = live_smoke_config.model;

    var codex = nullclaw.providers.openai_codex.OpenAiCodexProvider.init(allocator, null);
    defer codex.provider().deinit();
    codex.setExchangeLogging(live_smoke_config.log_codex_exchange);
    if (codex.access_token == null) return error.CodexCredentialsUnavailable;

    var cfg = Config{
        .workspace_dir = "/tmp/nullclaw-codex-live-smoke",
        .config_path = "/tmp/nullclaw-codex-live-smoke/config.json",
        .allocator = allocator,
        .default_provider = "openai-codex",
        .default_model = model,
        .memory = .{ .backend = "none", .auto_save = false },
        .agent = .{
            .max_tool_iterations = 3,
            .max_history_messages = 20,
            .message_timeout_secs = 120,
            .compact_context = false,
            .enable_pii_redaction = false,
        },
    };

    var echo_state = EchoState{};
    var echo_tool = LiveEchoTool{ .state = &echo_state };
    const tools = [_]Tool{echo_tool.tool()};
    var observer_state = nullclaw.observability.NoopObserver{};
    var agent = try Agent.fromConfig(
        allocator,
        &cfg,
        codex.provider(),
        &tools,
        null,
        observer_state.observer(),
    );
    defer agent.deinit();

    const response = try agent.turn(SMOKE_PROMPT);
    defer allocator.free(response);

    if (echo_state.calls != 1) return error.ExpectedExactlyOneNativeToolExecution;
    if (!echo_state.received_expected_value) return error.UnexpectedToolArguments;
    if (std.mem.indexOf(u8, response, SMOKE_OUTPUT) == null) return error.FinalReplyMissingToolOutput;

    var native_call_id: ?[]const u8 = null;
    for (agent.history.items) |message| {
        if (message.role == .assistant and message.tool_calls.len > 0) {
            native_call_id = message.tool_calls[0].id;
            break;
        }
    }
    const call_id = native_call_id orelse return error.NoStructuredNativeFunctionCallRecorded;

    var matching_result = false;
    for (agent.history.items) |message| {
        if (message.role == .tool) {
            if (message.tool_call_id) |id| {
                if (std.mem.eql(u8, id, call_id) and std.mem.eql(u8, message.content, SMOKE_OUTPUT)) {
                    matching_result = true;
                    break;
                }
            }
        }
    }
    if (!matching_result) return error.NoMatchingFunctionCallOutputRecorded;

    std.debug.print("PASS: Codex made native call {s}; live_echo ran once and its result reached the final reply.\n", .{call_id});
}
