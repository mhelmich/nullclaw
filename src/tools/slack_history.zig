//! Read recent messages from a Slack conversation using conversations.history.

const std = @import("std");
const http_util = @import("../http_util.zig");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const MAX_LIMIT: i64 = 100;
const DEFAULT_LIMIT: i64 = 20;
const API_URL = "https://slack.com/api/conversations.history";

pub const SlackHistoryTool = struct {
    bot_token: []const u8,

    pub const tool_name = "slack_history";
    pub const tool_description = "Read recent messages from a Slack conversation the configured bot can access. Requires a Slack conversation ID such as C123..., G123..., or D123....";
    pub const tool_params =
        \\{"type":"object","properties":{"channel_id":{"type":"string","description":"Slack conversation ID (C..., G..., or D...)"},"limit":{"type":"integer","minimum":1,"maximum":100,"default":20,"description":"Maximum messages to return"},"oldest":{"type":"string","description":"Optional oldest message timestamp, for example 1712345678.000001"},"latest":{"type":"string","description":"Optional latest message timestamp"}},"required":["channel_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SlackHistoryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SlackHistoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const channel_id = root.getString(args, "channel_id") orelse
            return ToolResult.fail("Missing required 'channel_id' parameter");
        if (!validChannelId(channel_id)) return ToolResult.fail("channel_id must be a Slack conversation ID containing only letters and digits");

        const limit = root.getInt(args, "limit") orelse DEFAULT_LIMIT;
        if (limit < 1 or limit > MAX_LIMIT) return ToolResult.fail("limit must be between 1 and 100");

        const oldest = root.getString(args, "oldest");
        const latest = root.getString(args, "latest");
        if (oldest) |ts| if (!validTimestamp(ts)) return ToolResult.fail("oldest must be a Slack timestamp containing digits and at most one decimal point");
        if (latest) |ts| if (!validTimestamp(ts)) return ToolResult.fail("latest must be a Slack timestamp containing digits and at most one decimal point");

        var url_buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&url_buf);
        writer.print("{s}?channel={s}&limit={d}", .{ API_URL, channel_id, limit }) catch
            return ToolResult.fail("Slack history request parameters are too long");
        if (oldest) |ts| writer.print("&oldest={s}", .{ts}) catch return ToolResult.fail("Slack history request parameters are too long");
        if (latest) |ts| writer.print("&latest={s}", .{ts}) catch return ToolResult.fail("Slack history request parameters are too long");

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{self.bot_token});
        defer allocator.free(auth_header);
        const response = http_util.curlGet(allocator, writer.buffered(), &.{auth_header}, "30") catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Slack history request failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = message };
        };
        defer allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch
            return ToolResult.fail("Slack returned an invalid JSON response");
        defer parsed.deinit();
        if (parsed.value != .object) return ToolResult.fail("Slack returned an invalid history response");
        const obj = parsed.value.object;
        const ok = obj.get("ok") orelse return ToolResult.fail("Slack history response is missing its status");
        if (ok != .bool or !ok.bool) {
            const code = if (obj.get("error")) |v| if (v == .string) v.string else "unknown_error" else "unknown_error";
            const needed = if (obj.get("needed")) |v| if (v == .string) v.string else null else null;
            const provided = if (obj.get("provided")) |v| if (v == .string) v.string else null else null;
            if (needed) |n| {
                if (provided) |p| {
                    const message = try std.fmt.allocPrint(allocator, "Slack conversations.history failed: {s} (needed={s}, provided={s}); confirm the bot has the required history scope and is a member of the conversation", .{ code, n, p });
                    return .{ .success = false, .output = "", .error_msg = message };
                }
                const message = try std.fmt.allocPrint(allocator, "Slack conversations.history failed: {s} (needed={s}); confirm the bot has the required history scope and is a member of the conversation", .{ code, n });
                return .{ .success = false, .output = "", .error_msg = message };
            }
            const message = try std.fmt.allocPrint(allocator, "Slack conversations.history failed: {s}; confirm the bot has the required history scope and is a member of the conversation", .{code});
            return .{ .success = false, .output = "", .error_msg = message };
        }

        const messages = obj.get("messages") orelse return ToolResult.fail("Slack history response has no messages field");
        if (messages != .array) return ToolResult.fail("Slack history response has an invalid messages field");
        if (messages.array.items.len == 0) return ToolResult.ok("No messages found in that time range.");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (messages.array.items, 0..) |item, index| {
            if (item != .object) continue;
            const msg = item.object;
            const ts = stringField(msg, "ts") orelse "unknown-time";
            const user = stringField(msg, "user") orelse "unknown-user";
            const text = stringField(msg, "text") orelse "";
            const line = try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ ts, user, text });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
            if (index + 1 < messages.array.items.len) try output.append(allocator, '\n');
        }
        return .{ .success = true, .output = try output.toOwnedSlice(allocator) };
    }
};

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn validChannelId(value: []const u8) bool {
    if (value.len < 2 or value.len > 64) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn validTimestamp(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    var dots: usize = 0;
    for (value) |c| {
        if (c == '.') {
            dots += 1;
            if (dots > 1) return false;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "Slack history validates channel and timestamp arguments" {
    try std.testing.expect(validChannelId("C123ABC"));
    try std.testing.expect(!validChannelId("C123&latest=1"));
    try std.testing.expect(validTimestamp("1712345678.000001"));
    try std.testing.expect(!validTimestamp("1&limit=100"));
}
