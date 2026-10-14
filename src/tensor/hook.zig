pub fn attach(
    comptime name: []const u8,
    hooks: anytype,
    next: anytype,
) if (has(@TypeOf(hooks), name)) @TypeOf(@field(hooks, name).attach(next)) else @TypeOf(next) {
    if (comptime has(@TypeOf(hooks), name)) return @field(hooks, name).attach(next);
    return next;
}

pub fn has(comptime Hooks: type, comptime name: []const u8) bool {
    return switch (@typeInfo(Hooks)) {
        .@"struct" => @hasField(Hooks, name),
        else => false,
    };
}
