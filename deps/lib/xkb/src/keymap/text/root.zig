const compile_data = @import("compile.zig");

pub const document = @import("document.zig");
pub const lexer = @import("lexer.zig");

pub const Error = compile_data.Error;
pub const Compiled = compile_data.Compiled;
pub const compile = compile_data.compile;
