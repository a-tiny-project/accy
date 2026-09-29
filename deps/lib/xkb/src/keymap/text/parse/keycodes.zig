const state = @import("state.zig");

pub fn section(parser: *state.Parser) state.Error!void {
    _ = try parser.expect(.left_brace);
    while (!try parser.take(.right_brace)) {
        const token = try parser.next();
        switch (token.tag) {
            .key_name => {
                _ = try parser.expect(.equal);
                const code = try parser.number();
                _ = try parser.expect(.semicolon);
                try parser.keycodes.append(parser.allocator, .{
                    .name = token.text,
                    .code = code,
                });
            },
            .word => if (state.keywordEqual(token.text, "alias")) {
                const name = (try parser.expect(.key_name)).text;
                _ = try parser.expect(.equal);
                const target = (try parser.expect(.key_name)).text;
                _ = try parser.expect(.semicolon);
                try parser.aliases.append(parser.allocator, .{
                    .name = name,
                    .target = target,
                });
            } else {
                try parser.skipStatement();
            },
            else => return error.InvalidSyntax,
        }
    }
    _ = try parser.expect(.semicolon);
}
