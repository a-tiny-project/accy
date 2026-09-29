const std = @import("std");
const native_xkb = @import("xkb");

const Keysym = native_xkb.keysym.Keysym;

pub const Key = enum(u16) {
    unknown = 0,

    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave = 96,

    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,

    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,

    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,

    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,

    left_shift = 340,
    left_ctrl = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_ctrl = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,

    _,

    pub fn fromKeysym(value: Keysym) Key {
        const raw = @backingInt(value);
        if (raw >= 'a' and raw <= 'z') {
            return @fromBackingInt(@intCast(raw - 'a' + 'A'));
        }
        if (raw >= 'A' and raw <= 'Z') return @fromBackingInt(@intCast(raw));
        if (raw >= '0' and raw <= '9') return @fromBackingInt(@intCast(raw));
        if (raw >= 0xffbe and raw <= 0xffc9) {
            return @fromBackingInt(@intCast(@backingInt(Key.f1) + raw - 0xffbe));
        }
        if (raw >= 0xffb0 and raw <= 0xffb9) {
            return @fromBackingInt(@intCast(@backingInt(Key.kp_0) + raw - 0xffb0));
        }
        return printableFromKeysym(raw) orelse specialFromKeysym(raw);
    }
};

fn printableFromKeysym(value: u32) ?Key {
    return switch (value) {
        ' ' => .space,
        '\'', '"' => .apostrophe,
        ',', '<' => .comma,
        '-', '_' => .minus,
        '.', '>' => .period,
        '/', '?' => .slash,
        '!' => .@"1",
        '@' => .@"2",
        '#' => .@"3",
        '$' => .@"4",
        '%' => .@"5",
        '^' => .@"6",
        '&' => .@"7",
        '*' => .@"8",
        '(' => .@"9",
        ')' => .@"0",
        ';', ':' => .semicolon,
        '=', '+' => .equal,
        '[', '{' => .left_bracket,
        '\\', '|' => .backslash,
        ']', '}' => .right_bracket,
        '`', '~' => .grave,
        else => null,
    };
}

fn specialFromKeysym(value: u32) Key {
    return switch (value) {
        0xff1b => .escape,
        0xff0d => .enter,
        0xff09, 0xfe20 => .tab,
        0xff08 => .backspace,
        0xff63 => .insert,
        0xffff => .delete,
        0xff53 => .right,
        0xff51 => .left,
        0xff54 => .down,
        0xff52 => .up,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff50 => .home,
        0xff57 => .end,
        0xffe5 => .caps_lock,
        0xff14 => .scroll_lock,
        0xff7f => .num_lock,
        0xff61 => .print_screen,
        0xff13 => .pause,
        0xff95 => .kp_7,
        0xff96 => .kp_4,
        0xff97 => .kp_8,
        0xff98 => .kp_6,
        0xff99 => .kp_2,
        0xff9a => .kp_9,
        0xff9b => .kp_3,
        0xff9c => .kp_1,
        0xff9d => .kp_5,
        0xff9e => .kp_0,
        0xff9f, 0xffae => .kp_decimal,
        0xffaf => .kp_divide,
        0xffaa => .kp_multiply,
        0xffad => .kp_subtract,
        0xffab => .kp_add,
        0xff8d => .kp_enter,
        0xffbd => .kp_equal,
        0xffe1 => .left_shift,
        0xffe3 => .left_ctrl,
        0xffe7, 0xffe9 => .left_alt,
        0xffeb => .left_super,
        0xffe2 => .right_shift,
        0xffe4 => .right_ctrl,
        0xffe8, 0xffea => .right_alt,
        0xffec => .right_super,
        0xff67 => .menu,
        else => .unknown,
    };
}

test "keysym mapping preserves logical keys across printable levels" {
    try std.testing.expectEqual(Key.a, Key.fromKeysym(@fromBackingInt('a')));
    try std.testing.expectEqual(Key.a, Key.fromKeysym(@fromBackingInt('A')));
    try std.testing.expectEqual(Key.@"1", Key.fromKeysym(@fromBackingInt('!')));
    try std.testing.expectEqual(Key.slash, Key.fromKeysym(@fromBackingInt('?')));
    try std.testing.expectEqual(Key.f12, Key.fromKeysym(@fromBackingInt(0xffc9)));
    try std.testing.expectEqual(Key.right_super, Key.fromKeysym(@fromBackingInt(0xffec)));
    try std.testing.expectEqual(Key.unknown, Key.fromKeysym(@fromBackingInt(0xfffe)));
}

test "keysym mapping covers every keypad value and navigation alias" {
    const cases = [_]struct { value: u32, expected: Key }{
        .{ .value = 0xffb0, .expected = .kp_0 },
        .{ .value = 0xffb1, .expected = .kp_1 },
        .{ .value = 0xffb2, .expected = .kp_2 },
        .{ .value = 0xffb3, .expected = .kp_3 },
        .{ .value = 0xffb4, .expected = .kp_4 },
        .{ .value = 0xffb5, .expected = .kp_5 },
        .{ .value = 0xffb6, .expected = .kp_6 },
        .{ .value = 0xffb7, .expected = .kp_7 },
        .{ .value = 0xffb8, .expected = .kp_8 },
        .{ .value = 0xffb9, .expected = .kp_9 },
        .{ .value = 0xffae, .expected = .kp_decimal },
        .{ .value = 0xffaf, .expected = .kp_divide },
        .{ .value = 0xffaa, .expected = .kp_multiply },
        .{ .value = 0xffad, .expected = .kp_subtract },
        .{ .value = 0xffab, .expected = .kp_add },
        .{ .value = 0xff8d, .expected = .kp_enter },
        .{ .value = 0xffbd, .expected = .kp_equal },
        .{ .value = 0xff95, .expected = .kp_7 },
        .{ .value = 0xff96, .expected = .kp_4 },
        .{ .value = 0xff97, .expected = .kp_8 },
        .{ .value = 0xff98, .expected = .kp_6 },
        .{ .value = 0xff99, .expected = .kp_2 },
        .{ .value = 0xff9a, .expected = .kp_9 },
        .{ .value = 0xff9b, .expected = .kp_3 },
        .{ .value = 0xff9c, .expected = .kp_1 },
        .{ .value = 0xff9d, .expected = .kp_5 },
        .{ .value = 0xff9e, .expected = .kp_0 },
        .{ .value = 0xff9f, .expected = .kp_decimal },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, Key.fromKeysym(@fromBackingInt(case.value)));
    }
}
