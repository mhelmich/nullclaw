pub const Field = struct {
    name: [:0]const u8,
    type: type,
};

pub fn fields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]Field {
    const info = @typeInfo(T).@"struct";
    var result: [info.field_names.len]Field = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, field_type, i| {
        result[i] = .{ .name = name, .type = field_type };
    }
    return result;
}
