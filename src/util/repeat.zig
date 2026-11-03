pub fn repeat(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    var result: [pattern.len * count]u8 = undefined;
    if (pattern.len == 1) {
        @memset(&result, pattern[0]);
    } else {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            @memcpy(result[i * pattern.len ..][0..pattern.len], pattern);
        }
    }
    return result;
}
