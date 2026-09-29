//! Restricted standalone assembly closure, not instruction correctness. The caller
//! binds these same bytes to committed origin, Linux, the pinned integrated assembler
//! and an effective configuration without external macros or extra assembly flags.
const std = @import("std");

pub const maximum_source_bytes = 64 * 1024;
pub const maximum_line_bytes = 1024;
pub const maximum_lines = 4096;
pub const maximum_definitions = 16;
pub const maximum_conditional_depth = 8;
pub const maximum_tokens_per_line = 256;
/// Every token consumes at least one source byte. Lookup work counts definition
/// comparisons, with room for checking both a token's role and its numeric value.
pub const maximum_token_work = maximum_source_bytes;
pub const maximum_macro_work = maximum_token_work * maximum_definitions * 2;
pub const maximum_constant = std.math.maxInt(u32);
pub const maximum_alignment_exponent = 16;
pub const maximum_dwarf_register = 31;

pub const Error = error{
    UnqualifiedCompilerAssemblyInputs,
    UnqualifiedCompilerAssemblySyntax,
    CompilerAssemblySourceTooLarge,
    CompilerAssemblyLineTooLong,
    CompilerAssemblyLinesExceeded,
    CompilerAssemblyDefinitionsExceeded,
    CompilerAssemblyConditionalDepthExceeded,
    CompilerAssemblyTokensExceeded,
    CompilerAssemblyWorkExceeded,
};

/// No allocation, recursion, preprocessing, file access or source rewriting.
/// LF terminates a line; a final LF does not create an extra empty line.
/// Comments, strings and line continuations are outside this restricted grammar.
pub fn validate(bytes: []const u8, arch: std.Target.Cpu.Arch) Error!void {
    if (arch != .x86_64 and arch != .aarch64)
        return error.UnqualifiedCompilerAssemblyInputs;
    if (bytes.len > maximum_source_bytes) return error.CompilerAssemblySourceTooLarge;
    var state: State = .{ .arch = arch };
    var start: usize = 0;
    var lines: usize = 0;
    while (start < bytes.len) {
        if (lines == maximum_lines) return error.CompilerAssemblyLinesExceeded;
        lines += 1;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        if (end - start > maximum_line_bytes) return error.CompilerAssemblyLineTooLong;
        var tokens: [maximum_tokens_per_line][]const u8 = undefined;
        const count = try state.tokenize(bytes[start..end], &tokens);
        if (count != 0) try state.line(tokens[0..count]);
        start = if (end == bytes.len) end else end + 1;
    }
    if (state.depth != 0) return error.UnqualifiedCompilerAssemblySyntax;
}

const Cursor = struct {
    tokens: []const []const u8,
    index: usize = 0,

    fn take(self: *Cursor) Error![]const u8 {
        if (self.index == self.tokens.len) return error.UnqualifiedCompilerAssemblySyntax;
        defer self.index += 1;
        return self.tokens[self.index];
    }

    fn eat(self: *Cursor, text: []const u8) bool {
        if (self.index == self.tokens.len or !std.mem.eql(u8, self.tokens[self.index], text)) return false;
        self.index += 1;
        return true;
    }

    fn expect(self: *Cursor, text: []const u8) Error!void {
        if (!self.eat(text)) return error.UnqualifiedCompilerAssemblySyntax;
    }

    fn end(self: *const Cursor) Error!void {
        if (self.index != self.tokens.len) return error.UnqualifiedCompilerAssemblySyntax;
    }
};

const Definition = struct {
    name: []const u8,
    value: i64,
    kind: enum { number, breg },
    branches: u4,
};

const Conditional = struct {
    parent: u4,
    selected: u4,
    had_else: bool = false,
};

const Register = enum { general, floating };

const State = struct {
    arch: std.Target.Cpu.Arch,
    definitions: [maximum_definitions]Definition = undefined,
    definition_count: usize = 0,
    conditionals: [maximum_conditional_depth]Conditional = undefined,
    depth: usize = 0,
    /// Four combinations of (__MACH__, __clang__), including inactive Linux
    /// branches. A numeric use must have a prior definition on every reaching
    /// combination. Duplicate definitions are refused even in disjoint branches.
    branches: u4 = 0b1111,
    token_work: usize = 0,
    macro_work: usize = 0,

    /// Refuses comments, quotes, splices, semicolons, CR, NUL, non-ASCII and
    /// alternate CPP spellings before any token can take a statement role.
    fn tokenize(self: *State, line_bytes: []const u8, output: *[maximum_tokens_per_line][]const u8) Error!usize {
        std.debug.assert(line_bytes.len <= maximum_line_bytes);
        var count: usize = 0;
        var offset: usize = 0;
        while (offset < line_bytes.len) {
            const byte = line_bytes[offset];
            if (byte == ' ' or byte == '\t') {
                offset += 1;
                continue;
            }
            const start = offset;
            if (letter(byte) or byte == '.' or std.ascii.isDigit(byte)) {
                offset += 1;
                while (offset < line_bytes.len and (letter(line_bytes[offset]) or std.ascii.isDigit(line_bytes[offset])))
                    offset += 1;
                if (byte == '.' and (offset == start + 1 or !letter(line_bytes[start + 1])))
                    return error.UnqualifiedCompilerAssemblySyntax;
            } else {
                switch (byte) {
                    '#', '%', '$', '(', ')', '[', ']', ',', ':', '+', '-', '~', '*', '!' => offset += 1,
                    else => return error.UnqualifiedCompilerAssemblySyntax,
                }
            }
            if (count == output.len) return error.CompilerAssemblyTokensExceeded;
            if (self.token_work == maximum_token_work) return error.CompilerAssemblyWorkExceeded;
            self.token_work += 1;
            output[count] = line_bytes[start..offset];
            count += 1;
        }
        return count;
    }

    /// CPP sees the identifier after "." too. No numeric definition may take
    /// an assembler directive, instruction, register or label role.
    fn line(self: *State, tokens: []const []const u8) Error!void {
        var cursor: Cursor = .{ .tokens = tokens };
        const first = try cursor.take();
        if (std.mem.eql(u8, first, "#")) {
            try self.preprocessor(&cursor);
        } else if (first[0] == '.') {
            try self.plain(first[1..]);
            try self.directive(first, &cursor);
        } else {
            try self.plain(first);
            if (!cursor.eat(":")) {
                if (self.arch == .x86_64) try self.amd64(first, &cursor) else try self.arm64(first, &cursor);
            }
        }
        try cursor.end();
    }

    fn preprocessor(self: *State, cursor: *Cursor) Error!void {
        const command = try cursor.take();
        if (std.mem.eql(u8, command, "define")) return self.define(cursor);
        if (std.mem.eql(u8, command, "else")) {
            try cursor.end();
            if (self.depth == 0) return error.UnqualifiedCompilerAssemblySyntax;
            const frame = &self.conditionals[self.depth - 1];
            if (frame.had_else) return error.UnqualifiedCompilerAssemblySyntax;
            frame.had_else = true;
            self.branches = frame.parent & ~frame.selected;
            return;
        }
        if (std.mem.eql(u8, command, "endif")) {
            try cursor.end();
            if (self.depth == 0) return error.UnqualifiedCompilerAssemblySyntax;
            self.depth -= 1;
            self.branches = self.conditionals[self.depth].parent;
            return;
        }
        const selected: u4 = if (std.mem.eql(u8, command, "ifdef")) blk: {
            try cursor.expect("__MACH__");
            break :blk 0b1100;
        } else if (std.mem.eql(u8, command, "if")) blk: {
            const negated = cursor.eat("!");
            try cursor.expect("defined");
            try cursor.expect("(");
            try cursor.expect(if (negated) "__clang__" else "__MACH__");
            try cursor.expect(")");
            break :blk if (negated) 0b0101 else 0b1100;
        } else return error.UnqualifiedCompilerAssemblySyntax;
        try cursor.end();
        if (self.depth == maximum_conditional_depth) return error.CompilerAssemblyConditionalDepthExceeded;
        self.conditionals[self.depth] = .{ .parent = self.branches, .selected = selected };
        self.depth += 1;
        self.branches &= selected;
    }

    /// Object replacement lists are literal-only: no aliases, recursive
    /// expansion, calls, token paste, stringification or statement tokens.
    fn define(self: *State, cursor: *Cursor) Error!void {
        const name = try cursor.take();
        try self.plain(name);
        if (self.definition_count == maximum_definitions) return error.CompilerAssemblyDefinitionsExceeded;
        var definition: Definition = .{ .name = name, .value = 0, .kind = .number, .branches = self.branches };
        if (std.mem.eql(u8, name, "DW_OP_breg")) {
            const open = try cursor.take();
            if (!std.mem.eql(u8, open, "(") or @intFromPtr(open.ptr) != @intFromPtr(name.ptr) + name.len)
                return error.UnqualifiedCompilerAssemblySyntax;
            try cursor.expect("r");
            try cursor.expect(")");
            try cursor.expect("(");
            definition.value = try literal(try cursor.take());
            if (definition.value > 255 - maximum_dwarf_register) return error.UnqualifiedCompilerAssemblySyntax;
            try cursor.expect("+");
            try cursor.expect("r");
            try cursor.expect(")");
            definition.kind = .breg;
        } else {
            definition.value = try signedLiteral(cursor);
        }
        try cursor.end();
        self.definitions[self.definition_count] = definition;
        self.definition_count += 1;
    }

    fn lookup(self: *State, name: []const u8) Error!?Definition {
        for (self.definitions[0..self.definition_count]) |definition| {
            if (self.macro_work == maximum_macro_work) return error.CompilerAssemblyWorkExceeded;
            self.macro_work += 1;
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    fn plain(self: *State, name: []const u8) Error!void {
        if (name.len == 0 or !letter(name[0]) or std.mem.startsWith(u8, name, "__"))
            return error.UnqualifiedCompilerAssemblySyntax;
        if (try self.lookup(name) != null) return error.UnqualifiedCompilerAssemblySyntax;
    }

    fn scalar(self: *State, cursor: *Cursor) Error!i64 {
        const token = try cursor.take();
        if (std.ascii.isDigit(token[0])) return literal(token);
        const definition = (try self.lookup(token)) orelse return error.UnqualifiedCompilerAssemblySyntax;
        if (definition.kind != .number or self.branches & ~definition.branches != 0)
            return error.UnqualifiedCompilerAssemblySyntax;
        return definition.value;
    }

    fn number(self: *State, cursor: *Cursor) Error!i64 {
        const negative = cursor.eat("-");
        const positive = if (!negative) cursor.eat("+") else false;
        const complement = if (!negative and !positive) cursor.eat("~") else false;
        var value: i64 = undefined;
        if (cursor.index < cursor.tokens.len and std.mem.eql(u8, cursor.tokens[cursor.index], "DW_OP_breg")) {
            const definition = (try self.lookup(try cursor.take())) orelse return error.UnqualifiedCompilerAssemblySyntax;
            if (definition.kind != .breg or self.branches & ~definition.branches != 0)
                return error.UnqualifiedCompilerAssemblySyntax;
            try cursor.expect("(");
            const argument = try self.scalar(cursor);
            if (argument < 0 or argument > maximum_dwarf_register) return error.UnqualifiedCompilerAssemblySyntax;
            try cursor.expect(")");
            value = definition.value + argument;
        } else value = try self.scalar(cursor);
        return if (negative) -value else if (complement) ~value else value;
    }

    fn directive(self: *State, name: []const u8, cursor: *Cursor) Error!void {
        if (std.mem.eql(u8, name, ".global")) return self.plain(try cursor.take());
        if (std.mem.eql(u8, name, ".type")) {
            try self.plain(try cursor.take());
            try cursor.expect(",");
            try cursor.expect("%");
            const kind = try cursor.take();
            try self.plain(kind);
            if (!std.mem.eql(u8, kind, "function")) return error.UnqualifiedCompilerAssemblySyntax;
        } else if (std.mem.eql(u8, name, ".align")) {
            const value = try self.number(cursor);
            if (value < 0 or value > maximum_alignment_exponent) return error.UnqualifiedCompilerAssemblySyntax;
        } else if (std.mem.eql(u8, name, ".cfi_adjust_cfa_offset")) {
            _ = try self.number(cursor);
        } else if (std.mem.eql(u8, name, ".cfi_offset") or std.mem.eql(u8, name, ".cfi_rel_offset")) {
            _ = try self.register(try cursor.take());
            try cursor.expect(",");
            _ = try self.number(cursor);
        } else if (std.mem.eql(u8, name, ".cfi_escape")) {
            while (true) {
                const value = try self.number(cursor);
                if (value < 0 or value > 255) return error.UnqualifiedCompilerAssemblySyntax;
                if (!cursor.eat(",")) break;
            }
        } else if (!oneOf(name, &.{ ".cfi_startproc", ".cfi_endproc", ".cfi_signal_frame", ".cfi_remember_state", ".cfi_restore_state" })) {
            return error.UnqualifiedCompilerAssemblySyntax;
        }
    }

    fn register(self: *State, name: []const u8) Error!Register {
        try self.plain(name);
        if (self.arch == .x86_64) {
            if (oneOf(name, &.{ "rax", "rbx", "rcx", "rdx", "rdi", "rsi", "rsp", "rbp", "rip", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" }))
                return .general;
        } else {
            if (oneOf(name, &.{ "sp", "fp", "lr" })) return .general;
            if (name.len >= 2 and (name[0] == 'x' or name[0] == 'd')) {
                for (name[1..]) |byte| if (!std.ascii.isDigit(byte))
                    return error.UnqualifiedCompilerAssemblySyntax;
                const index = literal(name[1..]) catch return error.UnqualifiedCompilerAssemblySyntax;
                if (index <= (if (name[0] == 'x') @as(i64, 30) else 31))
                    return if (name[0] == 'x') .general else .floating;
            }
        }
        return error.UnqualifiedCompilerAssemblySyntax;
    }

    fn xregister(self: *State, cursor: *Cursor) Error!void {
        try cursor.expect("%");
        _ = try self.register(try cursor.take());
    }

    fn xmemory(self: *State, cursor: *Cursor) Error!void {
        if (!cursor.eat("(")) {
            _ = try self.number(cursor);
            try cursor.expect("(");
        }
        try self.xregister(cursor);
        try cursor.expect(")");
    }

    fn xoperand(self: *State, cursor: *Cursor, immediate: bool) Error!void {
        if (immediate and cursor.eat("$")) {
            _ = try self.number(cursor);
        } else if (cursor.index < cursor.tokens.len and std.mem.eql(u8, cursor.tokens[cursor.index], "%")) {
            try self.xregister(cursor);
        } else try self.xmemory(cursor);
    }

    fn indirect(self: *State, cursor: *Cursor) Error!void {
        try cursor.expect("*");
        try self.xoperand(cursor, false);
    }

    fn amd64(self: *State, name: []const u8, cursor: *Cursor) Error!void {
        if (std.mem.eql(u8, name, "movq")) {
            try self.xoperand(cursor, true);
            try cursor.expect(",");
            try self.xoperand(cursor, false);
        } else if (std.mem.eql(u8, name, "leaq")) {
            try self.xmemory(cursor);
            try cursor.expect(",");
            try self.xregister(cursor);
        } else if (std.mem.eql(u8, name, "xor")) {
            try self.xregister(cursor);
            try cursor.expect(",");
            try self.xregister(cursor);
        } else if (oneOf(name, &.{ "andq", "subq" })) {
            try cursor.expect("$");
            _ = try self.number(cursor);
            try cursor.expect(",");
            try self.xregister(cursor);
        } else if (oneOf(name, &.{ "stmxcsr", "fnstcw", "ldmxcsr", "fldcw" })) {
            try self.xmemory(cursor);
        } else if (oneOf(name, &.{ "pushq", "popq" })) {
            try self.xregister(cursor);
        } else if (oneOf(name, &.{ "callq", "jmpq" })) {
            try self.indirect(cursor);
        } else if (std.mem.eql(u8, name, "jmp")) {
            if (cursor.index < cursor.tokens.len and std.mem.eql(u8, cursor.tokens[cursor.index], "*")) {
                try self.indirect(cursor);
            } else try self.plain(try cursor.take());
        } else if (!oneOf(name, &.{ "ret", "ud2" })) return error.UnqualifiedCompilerAssemblySyntax;
    }

    fn general(self: *State, cursor: *Cursor) Error!void {
        if (try self.register(try cursor.take()) != .general) return error.UnqualifiedCompilerAssemblySyntax;
    }

    fn amemory(self: *State, cursor: *Cursor) Error!void {
        try cursor.expect("[");
        try self.general(cursor);
        if (cursor.eat(",")) {
            try cursor.expect("#");
            _ = try self.number(cursor);
        }
        try cursor.expect("]");
        if (!cursor.eat("!") and cursor.eat(",")) {
            try cursor.expect("#");
            _ = try self.number(cursor);
        }
    }

    fn arm64(self: *State, name: []const u8, cursor: *Cursor) Error!void {
        if (oneOf(name, &.{ "stp", "ldp" })) {
            const first = try self.register(try cursor.take());
            try cursor.expect(",");
            if (try self.register(try cursor.take()) != first) return error.UnqualifiedCompilerAssemblySyntax;
            try cursor.expect(",");
            try self.amemory(cursor);
        } else if (oneOf(name, &.{ "str", "ldr" })) {
            _ = try self.register(try cursor.take());
            try cursor.expect(",");
            try self.amemory(cursor);
        } else if (std.mem.eql(u8, name, "mov")) {
            try self.general(cursor);
            try cursor.expect(",");
            if (cursor.eat("#")) {
                _ = try self.number(cursor);
            } else try self.general(cursor);
        } else if (oneOf(name, &.{ "sub", "add", "and" })) {
            try self.general(cursor);
            try cursor.expect(",");
            try self.general(cursor);
            try cursor.expect(",");
            try cursor.expect("#");
            _ = try self.number(cursor);
        } else if (oneOf(name, &.{ "mrs", "msr" })) {
            const read = std.mem.eql(u8, name, "mrs");
            if (read) {
                try self.general(cursor);
                try cursor.expect(",");
            }
            const system = try cursor.take();
            try self.plain(system);
            if (!oneOf(system, &.{ "fpcr", "fpsr" })) return error.UnqualifiedCompilerAssemblySyntax;
            if (!read) {
                try cursor.expect(",");
                try self.general(cursor);
            }
        } else if (oneOf(name, &.{ "br", "blr" })) {
            try self.general(cursor);
        } else if (std.mem.eql(u8, name, "brk")) {
            try cursor.expect("#");
            _ = try self.number(cursor);
        } else if (std.mem.eql(u8, name, "b")) {
            try self.plain(try cursor.take());
        } else if (!std.mem.eql(u8, name, "ret")) return error.UnqualifiedCompilerAssemblySyntax;
    }
};

fn letter(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

/// Decimal or hex only, without octal, suffixes, floats or digit separators.
fn literal(text: []const u8) Error!i64 {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return error.UnqualifiedCompilerAssemblySyntax;
    const hex = std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X");
    if (!hex and text.len > 1 and text[0] == '0') return error.UnqualifiedCompilerAssemblySyntax;
    const digits = if (hex) text[2..] else text;
    if (digits.len == 0) return error.UnqualifiedCompilerAssemblySyntax;
    for (digits) |byte| {
        if (hex) {
            if (!std.ascii.isHex(byte)) return error.UnqualifiedCompilerAssemblySyntax;
        } else if (!std.ascii.isDigit(byte)) return error.UnqualifiedCompilerAssemblySyntax;
    }
    const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return error.UnqualifiedCompilerAssemblySyntax;
    return value;
}

fn signedLiteral(cursor: *Cursor) Error!i64 {
    const negative = cursor.eat("-");
    const positive = if (!negative) cursor.eat("+") else false;
    const complement = if (!negative and !positive) cursor.eat("~") else false;
    const value = try literal(try cursor.take());
    return if (negative) -value else if (complement) ~value else value;
}

const testing = std.testing;

test "compiler binding assembly: both retained architecture sources and changed operands" {
    try testing.expectEqual(@as(usize, 1732), saved_amd64.len);
    try testing.expectEqual(@as(usize, 2259), saved_arm64.len);
    try validate(saved_amd64, .x86_64);
    try validate(saved_arm64, .aarch64);
    try validate(".global changed\nchanged:\nmovq $2, %r10\nmovq %r10, 72(%rdi)\njmp changed\n", .x86_64);
    try validate(".align 3\n.global changed\nchanged:\nmov x2, #3\nstr x2, [sp, #24]\nb changed\n", .aarch64);
    try validate("#define OFFSET 24\nmovq OFFSET(%rsp), %rax\n", .x86_64);
    try validate("#define VALUE 0xffffffff\nmov x0, #VALUE\n", .aarch64);
    try validate("#define DW_OP_breg(r) (0x71+r)\n#define REG 30\n.cfi_startproc\n.cfi_escape DW_OP_breg(REG), +0, 255\n.cfi_endproc\n", .aarch64);
}

test "compiler binding assembly: conditional definitions retain branch provenance" {
    try validate("#ifdef __MACH__\n#define N 1\n.cfi_adjust_cfa_offset N\n#else\nret\n#endif\n", .x86_64);
    try validate("#if !defined(__clang__)\nret\n#else\n#if defined(__MACH__)\nret\n#endif\n#endif\n", .aarch64);
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(
        "#ifdef __MACH__\n#define N 1\n#endif\n.cfi_adjust_cfa_offset N\n",
        .x86_64,
    ));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(
        "#ifdef __MACH__\n#define N 1\n#else\n.cfi_adjust_cfa_offset N\n#endif\n",
        .x86_64,
    ));
}

test "compiler binding assembly: acquisition and alternate preprocessing syntax always refuse" {
    const rejected = [_][]const u8{
        "#include <x>\n",
        "#include \"x\"\n",
        ".include x\n",
        ".incbin x\n",
        "#import x\n",
        "#pragma once\n",
        "#line 1\n",
        "#if __has_include(x)\n#endif\n",
        "#ifdef __MACH__\n#include <x>\n#endif\n",
        "#if defined(__MACH__)\nret\n#else\n.incbin x\n#endif\n",
        "#if !defined(__clang__)\n.include x\n#endif\n",
        "#ifdef __MACH__\n#if !defined(__clang__)\n# import x\n#endif\n#endif\n",
        "#define N .incbin\nN x\n",
        "#define N 1; .include x\n",
        "#define D .\nD include x\n",
        "#define N inc ## bin\n",
        "#define DW_OP_breg(r) #r\n",
        "#define DW_OP_breg(r) (0x70+r); .incbin x\n",
        "#define N __has_include(x)\n",
        "#define N M\n",
        "#define N N\n",
        "#define N 1\n#define N 2\n",
        "#define __MACH__ 0\n",
        "#define global 1\n.global symbol\n",
        "#define movq 1\nmovq %rax, %rbx\n",
        "#define symbol 1\nsymbol:\n",
        "#define rdi 1\nmovq %rdi, %rax\n",
        "#define function 1\n.type symbol,%function\n",
        "#define DW_OP_breg (r) (0x70+r)\n",
        "#define DW_OP_breg(r) (0x70+r)\n.cfi_escape DW_OP_breg(DW_OP_breg(1))\n",
        "#define DW_OP_breg(r) (0x70+r)\n.cfi_escape DW_OP_breg(32)\n",
        "#define DW_OP_breg(r) (0xf0+r)\n",
        "#inc\\\nlude x\n",
        ".inc\\\nbin x\n",
        "#in/**/clude x\n",
        ".inc/**/bin x\n",
        "#/**/include x\n",
        "/* comment */ret\n",
        "// comment\nret\n",
        "%:include x\n",
        "??=include x\n",
        "ret; .incbin x\n",
        "ret\x00\n",
        "ret\r\n",
        "ret\x0b\n",
        "ret\xc2\xa0\n",
        ".ascii \"x\"\n",
        ".section .text\n",
        ".macro N\n.endm\n",
        ".rept 1\nret\n.endr\n",
        ".irp N,1\n.endr\n",
        ".cfi_escape 256\n",
        ".cfi_escape 0,\n",
        ".cfi_startproc 1\n",
        ".align 17\n",
        "movq $0x100000000, %rax\n",
        "movq $08, %rax\n",
        "movq $1u, %rax\n",
        "movq $__LINE__, %rax\n",
    };
    for (rejected) |source| {
        try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(source, .x86_64));
    }
}

test "compiler binding assembly: malformed conditional structure refuses" {
    const rejected = [_][]const u8{
        "#else\n",
        "#endif\n",
        "#ifdef __MACH__\nret\n",
        "#ifdef __MACH__\n#else\n#else\n#endif\n",
        "#ifdef __MACH__\n#endif\n#endif\n",
        "#if defined(__MACH__)\n#elif defined(__clang__)\n#endif\n",
        "#if defined(__MACH__) || 1\n#endif\n",
        "#ifdef __MACH__ extra\n#endif\n",
        "#if defined(__MACH__\n#endif\n",
        "#ifdef UNKNOWN\n#endif\n",
        "#ifdef __MACH__\n#else extra\n#endif\n",
        "#ifdef __MACH__\n#endif extra\n",
    };
    for (rejected) |source| {
        try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(source, .x86_64));
    }
}

test "compiler binding assembly: architecture and operand grammar are explicit" {
    try testing.expectError(error.UnqualifiedCompilerAssemblyInputs, validate("ret\n", .riscv64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(saved_amd64, .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate(saved_arm64, .x86_64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("mov x31, #0\n", .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("mov x0x10, #0\n", .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("mov x0, #0, #1\n", .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("mov x0, %rax\n", .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("mrs x0, unknown\n", .aarch64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("movq %rax %rbx\n", .x86_64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("movq %rax, file\n", .x86_64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("callq file\n", .x86_64));
    try testing.expectError(error.UnqualifiedCompilerAssemblySyntax, validate("name: ret\n", .x86_64));
}

test "compiler binding assembly: source byte bound has a structurally valid exact positive" {
    var bytes: [maximum_source_bytes + 1]u8 = @splat(' ');
    for (0..maximum_source_bytes / maximum_line_bytes) |index| {
        const start = index * maximum_line_bytes;
        @memcpy(bytes[start..][0..3], "ret");
        bytes[start + maximum_line_bytes - 1] = '\n';
    }
    try validate(bytes[0..maximum_source_bytes], .x86_64);
    bytes[maximum_source_bytes] = '\n';
    try testing.expectError(error.CompilerAssemblySourceTooLarge, validate(&bytes, .x86_64));
}

test "compiler binding assembly: line byte and line count bounds preserve exact positives" {
    var line_bytes: [maximum_line_bytes + 1]u8 = @splat(' ');
    @memcpy(line_bytes[0..3], "ret");
    try validate(line_bytes[0..maximum_line_bytes], .x86_64);
    try testing.expectError(error.CompilerAssemblyLineTooLong, validate(&line_bytes, .x86_64));
    var source: TestSource = .{};
    for (0..maximum_lines) |_| source.append("ret\n");
    try validate(source.written(), .x86_64);
    source.append("ret\n");
    try testing.expectError(error.CompilerAssemblyLinesExceeded, validate(source.written(), .x86_64));
}

test "compiler binding assembly: conditional depth has an exact balanced positive" {
    var source: TestSource = .{};
    for (0..maximum_conditional_depth) |_| source.append("#ifdef __MACH__\n");
    source.append("ret\n");
    for (0..maximum_conditional_depth) |_| source.append("#endif\n");
    try validate(source.written(), .x86_64);
    source = .{};
    for (0..maximum_conditional_depth + 1) |_| source.append("#ifdef __MACH__\n");
    source.append("ret\n");
    for (0..maximum_conditional_depth + 1) |_| source.append("#endif\n");
    try testing.expectError(error.CompilerAssemblyConditionalDepthExceeded, validate(source.written(), .x86_64));
}

test "compiler binding assembly: definition bound includes numeric and function definitions" {
    var source: TestSource = .{};
    source.append("#define DW_OP_breg(r) (0x70+r)\n");
    for (0..maximum_definitions - 1) |index| {
        var buffer: [64]u8 = undefined;
        source.append(try std.fmt.bufPrint(&buffer, "#define D{d} {d}\n", .{ index, index }));
    }
    source.append(".cfi_startproc\n.cfi_escape DW_OP_breg(D14)\n.cfi_endproc\n");
    try validate(source.written(), .x86_64);
    source.append("#define OVER 1\n");
    try testing.expectError(error.CompilerAssemblyDefinitionsExceeded, validate(source.written(), .x86_64));
}

test "compiler binding assembly: token bound has exact and next structurally valid lines" {
    var source: TestSource = .{};
    source.append(".cfi_startproc\n.cfi_escape ");
    for (0..maximum_tokens_per_line / 2 - 1) |_| source.append("0,");
    source.append("0\n.cfi_endproc\n");
    try validate(source.written(), .x86_64);
    source = .{};
    source.append(".cfi_startproc\n.cfi_escape +");
    for (0..maximum_tokens_per_line / 2 - 1) |_| source.append("0,");
    source.append("0\n.cfi_endproc\n");
    try testing.expectError(error.CompilerAssemblyTokensExceeded, validate(source.written(), .x86_64));
}

const TestSource = struct {
    bytes: [maximum_source_bytes + 1]u8 = undefined,
    len: usize = 0,

    fn append(self: *TestSource, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn written(self: *const TestSource) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Exact retained amd64 test input, including its final LF.
const saved_amd64 =
    \\#ifdef __MACH__
    \\.global _mp_setjmp
    \\.global _mp_longjmp
    \\.global _mp_stack_enter
    \\#else
    \\.global mp_setjmp
    \\.global mp_longjmp
    \\.global mp_stack_enter
    \\.type mp_setjmp,%function
    \\.type mp_longjmp,%function
    \\.type mp_stack_enter,%function
    \\#endif
    \\
    \\_mp_setjmp:
    \\mp_setjmp:
    \\  movq    (%rsp), %rax
    \\  leaq    8(%rsp), %rcx
    \\
    \\  movq    %rax,  0(%rdi)
    \\  movq    %rbx,  8(%rdi)
    \\  movq    %rcx, 16(%rdi)
    \\  movq    %rbp, 24(%rdi)
    \\  movq    %r12, 32(%rdi)
    \\  movq    %r13, 40(%rdi)
    \\  movq    %r14, 48(%rdi)
    \\  movq    %r15, 56(%rdi)
    \\
    \\  stmxcsr 64(%rdi)
    \\  fnstcw  68(%rdi)
    \\
    \\  xor     %rax, %rax
    \\  ret
    \\
    \\_mp_longjmp:
    \\mp_longjmp:
    \\  movq   8(%rdi), %rbx
    \\  movq  16(%rdi), %rsp
    \\  movq  24(%rdi), %rbp
    \\  movq  32(%rdi), %r12
    \\  movq  40(%rdi), %r13
    \\  movq  48(%rdi), %r14
    \\  movq  56(%rdi), %r15
    \\
    \\  ldmxcsr 64(%rdi)
    \\  fldcw   68(%rdi)
    \\
    \\  movq  $1, %rax
    \\  jmpq  *(%rdi)
    \\
    \\#define DW_def_cfa_expression     0x0F
    \\#define DW_OP_deref               0x06
    \\#define DW_OP_breg(r)             (0x70+r)
    \\#define DW_REG_rip                16
    \\#define DW_REG_rsp                7
    \\
    \\_mp_stack_enter:
    \\mp_stack_enter:
    \\  .cfi_startproc
    \\  .cfi_signal_frame
    \\
    \\  pushq    %rcx
    \\  .cfi_adjust_cfa_offset 8
    \\  .cfi_remember_state
    \\
    \\  .cfi_escape DW_def_cfa_expression, 4, DW_OP_breg(DW_REG_rsp), 0, DW_OP_deref, DW_OP_deref
    \\  .cfi_offset rip, 0
    \\  .cfi_offset rbx, 8
    \\  .cfi_offset rsp, 16
    \\  .cfi_offset rbp, 24
    \\  .cfi_offset r12, 32
    \\  .cfi_offset r13, 40
    \\  .cfi_offset r14, 48
    \\  .cfi_offset r15, 56
    \\
    \\  movq    8(%rsp), %rax
    \\  andq    $~0x0F, %rdi
    \\  subq    $16, %rdi
    \\  movq    %rax, 8(%rdi)
    \\  movq    %rcx, 0(%rdi)
    \\  movq    %rdi, %rsp
    \\
    \\  movq    %r9, %rdi
    \\  movq    %rsp, %rsi
    \\  callq   *%r8
    \\
    \\  ud2
    \\
    \\  .cfi_restore_state
    \\  popq    %rdi
    \\  movq    (%rdi), %rdi
    \\  jmp     mp_longjmp
    \\
    \\  .cfi_endproc
    \\
;

/// Exact retained arm64 test input, including its final LF.
const saved_arm64 =
    \\.align 2
    \\.global mp_setjmp
    \\.global mp_longjmp
    \\.global mp_stack_enter
    \\
    \\#if defined(__MACH__)
    \\.global _mp_setjmp
    \\.global _mp_longjmp
    \\.global _mp_stack_enter
    \\#endif
    \\
    \\#if !defined(__clang__)
    \\.type mp_setjmp,%function
    \\.type mp_longjmp,%function
    \\.type mp_stack_enter,%function
    \\#endif
    \\
    \\_mp_setjmp:
    \\mp_setjmp:
    \\  stp   x18, x19, [x0], #16
    \\  stp   x20, x21, [x0], #16
    \\  stp   x22, x23, [x0], #16
    \\  stp   x24, x25, [x0], #16
    \\  stp   x26, x27, [x0], #16
    \\  stp   x28, x29, [x0], #16
    \\  mov   x10, sp
    \\  stp   x30, x10, [x0], #16
    \\  mrs   x10, fpcr
    \\  mrs   x11, fpsr
    \\  stp   x10, x11, [x0], #16
    \\  stp   d8,  d9,  [x0], #16
    \\  stp   d10, d11, [x0], #16
    \\  stp   d12, d13, [x0], #16
    \\  stp   d14, d15, [x0], #16
    \\  mov   x0, #0
    \\  ret
    \\
    \\_mp_longjmp:
    \\mp_longjmp:
    \\  ldp   x18, x19, [x0], #16
    \\  ldp   x20, x21, [x0], #16
    \\  ldp   x22, x23, [x0], #16
    \\  ldp   x24, x25, [x0], #16
    \\  ldp   x26, x27, [x0], #16
    \\  ldp   x28, x29, [x0], #16
    \\  ldp   x30, x10, [x0], #16
    \\  mov   sp, x10
    \\  ldp   x10, x11, [x0], #16
    \\  msr   fpcr, x10
    \\  msr   fpsr, x11
    \\  ldp   d8,  d9,  [x0], #16
    \\  ldp   d10, d11, [x0], #16
    \\  ldp   d12, d13, [x0], #16
    \\  ldp   d14, d15, [x0], #16
    \\  mov   x0, #1
    \\  br    x30
    \\
    \\#define DW_def_cfa_expression     0x0F
    \\#define DW_OP_deref               0x06
    \\#define DW_OP_breg(r)             (0x70+r)
    \\#define DW_REG_sp                 31
    \\
    \\_mp_stack_enter:
    \\mp_stack_enter:
    \\  .cfi_startproc
    \\  .cfi_signal_frame
    \\
    \\  stp     fp, lr, [sp, #-16]!
    \\  .cfi_adjust_cfa_offset 32
    \\  .cfi_rel_offset lr, 24
    \\  .cfi_rel_offset fp, 16
    \\
    \\  mov     fp, sp
    \\  sub     sp, sp, #16
    \\  str     x3, [sp, #8]
    \\  .cfi_remember_state
    \\
    \\  .cfi_escape DW_def_cfa_expression, 4, DW_OP_breg(DW_REG_sp), 8, DW_OP_deref, DW_OP_deref
    \\  .cfi_offset sp, 104
    \\  .cfi_offset x30, 96
    \\  .cfi_offset x29, 88
    \\  .cfi_offset x18, 0
    \\  .cfi_offset x19, 8
    \\  .cfi_offset x20, 16
    \\  .cfi_offset x21, 24
    \\  .cfi_offset x22, 32
    \\  .cfi_offset x23, 40
    \\  .cfi_offset x24, 48
    \\  .cfi_offset x25, 56
    \\  .cfi_offset x26, 64
    \\  .cfi_offset x27, 72
    \\  .cfi_offset x28, 80
    \\
    \\  and     sp, x0, #~31
    \\  sub     sp, sp, #32
    \\  stp     x29, x30, [sp, #16]
    \\  str     x3, [sp, #8]
    \\  add     x29, sp, #16
    \\
    \\  mov     x0, x5
    \\  mov     x1, fp
    \\  blr     x4
    \\
    \\  brk     #0
    \\
    \\  .cfi_restore_state
    \\  ldr     x0, [sp, #8]
    \\  ldr     x0, [x0]
    \\  b       mp_longjmp
    \\
    \\  .cfi_endproc
    \\
;
