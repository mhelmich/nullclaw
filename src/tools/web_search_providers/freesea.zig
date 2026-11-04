const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const log = std.log.scoped(.web_search);

pub fn execute(
    allocator: std.mem.Allocator,
    query: []const u8,
    count: usize,
    api_key: []const u8,
    timeout_secs: u64,
) (common.ProviderSearchError || error{OutOfMemory})!common.ToolResult {
    const timeout_str = try common.timeoutToString(allocator, timeout_secs);
    defer allocator.free(timeout_str);

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const body_json = try std.json.Stringify.valueAlloc(allocator, .{
        .query = query,
        .max_results = count,
    }, .{});
    defer allocator.free(body_json);

    const headers = [_][]const u8{
        auth_header,
        "Content-Type: application/json",
        "Accept: application/json",
    };
    const body = common.curlPostJson(allocator, "https://freesea.dev/v1/search", body_json, &headers, timeout_str) catch |err| {
        common.logRequestError("freesea", query, err);
        return err;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const results_value = object.get("results") orelse return error.InvalidResponse;
    const results = switch (results_value) {
        .array => |value| value.items,
        else => return error.InvalidResponse,
    };
    if (!builtin.is_test) {
        log.info("Freesea search returned {d} results, {d} labeled sponsored ads", .{
            results.len,
            countSponsoredResults(results),
        });
    }
    return formatResults(allocator, query, results);
}

fn countSponsoredResults(results: []const std.json.Value) usize {
    var sponsored_count: usize = 0;
    for (results) |result| {
        const item = switch (result) {
            .object => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, common.extractString(item, "type") orelse "", "sponsored")) {
            sponsored_count += 1;
        }
    }
    return sponsored_count;
}

pub fn formatResults(allocator: std.mem.Allocator, query: []const u8, results: []const std.json.Value) !common.ToolResult {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(allocator, "Results for: {s}\n\n", .{query});

    var count: usize = 0;
    for (results) |result| {
        const item = switch (result) {
            .object => |value| value,
            else => continue,
        };
        const title = common.extractString(item, "title") orelse "(no title)";
        const url = common.extractString(item, "url") orelse "(no url)";
        const content = common.extractString(item, "content") orelse "";
        const sponsored = if (common.extractString(item, "type")) |kind| std.mem.eql(u8, kind, "sponsored") else false;
        count += 1;
        if (sponsored) {
            try output.print(allocator, "{d}. [SPONSORED] {s}\n   {s}\n", .{ count, title, url });
            if (common.extractString(item, "disclosure")) |disclosure| {
                try output.print(allocator, "   Sponsored disclosure: {s}\n", .{disclosure});
            } else {
                try output.appendSlice(allocator, "   Sponsored result.\n");
            }
            if (common.extractString(item, "incentive")) |incentive| {
                try output.print(allocator, "   Incentive: {s}\n", .{incentive});
            } else if (item.get("incentive")) |incentive_value| {
                if (incentive_value == .object) {
                    const incentive = incentive_value.object;
                    if (common.extractString(incentive, "benefit")) |benefit| {
                        try output.print(allocator, "   Incentive: {s}", .{benefit});
                        if (common.extractString(incentive, "code")) |code| {
                            try output.print(allocator, " (code: {s})", .{code});
                        }
                        try output.append(allocator, '\n');
                    }
                }
            }
        } else {
            try output.print(allocator, "{d}. {s}\n   {s}\n", .{ count, title, url });
        }
        if (content.len > 0) try output.print(allocator, "   {s}\n", .{content});
        try output.append(allocator, '\n');
    }
    if (count == 0) return common.noWebResults(allocator);
    return common.ToolResult.ok(try output.toOwnedSlice(allocator));
}

test "freesea formatting preserves sponsored labels, incentive and URL" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[{\"title\":\"Offer\",\"url\":\"https://freesea.dev/go/example\",\"content\":\"Try it\",\"type\":\"sponsored\",\"disclosure\":\"Paid placement\",\"incentive\":{\"kind\":\"code\",\"code\":\"SAVE10\",\"benefit\":\"10% off\"}}]", .{});
    defer parsed.deinit();
    const result = try formatResults(std.testing.allocator, "example", parsed.value.array.items);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[SPONSORED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Paid placement") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "10% off") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SAVE10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://freesea.dev/go/example") != null);
}

test "freesea counts results labeled sponsored" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[{\"type\":\"organic\"},{\"type\":\"sponsored\"},{\"type\":\"sponsored\"}]", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), countSponsoredResults(parsed.value.array.items));
}
