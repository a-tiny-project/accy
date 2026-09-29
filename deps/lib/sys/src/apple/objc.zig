const std = @import("std");
const builtin = @import("builtin");

pub const Class = *opaque {};
pub const Ivar = *opaque {};
pub const SEL = *opaque {};
pub const Id = *anyopaque;
pub const BOOL = boolType(builtin.cpu.arch);

pub const nil: ?Id = null;

extern fn objc_getClass(name: [*:0]const u8) ?Class;
extern fn objc_allocateClassPair(
    superclass: Class,
    name: [*:0]const u8,
    extra_bytes: usize,
) ?Class;
extern fn objc_registerClassPair(class_value: Class) void;
extern fn objc_disposeClassPair(class_value: Class) void;
extern fn class_addIvar(
    class_value: Class,
    name: [*:0]const u8,
    size: usize,
    alignment: u8,
    types: ?[*:0]const u8,
) BOOL;
extern fn class_addMethod(
    class_value: Class,
    operation: SEL,
    implementation: *const anyopaque,
    types: [*:0]const u8,
) BOOL;
extern fn object_setInstanceVariable(
    object: Id,
    name: [*:0]const u8,
    value: ?*anyopaque,
) ?Ivar;
extern fn object_getInstanceVariable(
    object: Id,
    name: [*:0]const u8,
    value: *?*anyopaque,
) ?Ivar;
extern fn sel_registerName(name: [*:0]const u8) SEL;
extern fn objc_msgSend() void;
extern fn objc_msgSend_stret() void;
extern fn objc_autoreleasePoolPush() *anyopaque;
extern fn objc_autoreleasePoolPop(context: *anyopaque) void;

pub const AutoreleasePool = struct {
    context: *anyopaque,

    pub fn init() AutoreleasePool {
        return .{ .context = objc_autoreleasePoolPush() };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        objc_autoreleasePoolPop(self.context);
        self.* = undefined;
    }
};

pub fn lookupClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn class(name: [*:0]const u8) ?Id {
    return @ptrCast(lookupClass(name) orelse return null);
}

pub fn allocateClassPair(superclass: Class, name: [*:0]const u8) ?Class {
    return objc_allocateClassPair(superclass, name, 0);
}

pub fn registerClassPair(class_value: Class) void {
    objc_registerClassPair(class_value);
}

pub fn disposeClassPair(class_value: Class) void {
    objc_disposeClassPair(class_value);
}

pub fn addPointerIvar(class_value: Class, name: [*:0]const u8) bool {
    const pointer_alignment: u8 = @intCast(@ctz(@as(usize, @alignOf(*anyopaque))));
    return isTrue(class_addIvar(
        class_value,
        name,
        @sizeOf(*anyopaque),
        pointer_alignment,
        "^v",
    ));
}

pub fn addMethod(
    class_value: Class,
    operation: SEL,
    implementation: *const anyopaque,
    types: [*:0]const u8,
) bool {
    return isTrue(class_addMethod(class_value, operation, implementation, types));
}

pub fn setInstancePointer(
    object: Id,
    name: [*:0]const u8,
    value: ?*anyopaque,
) bool {
    return object_setInstanceVariable(object, name, value) != null;
}

pub fn instancePointer(object: Id, name: [*:0]const u8) ?*anyopaque {
    var value: ?*anyopaque = null;
    _ = object_getInstanceVariable(object, name, &value) orelse return null;
    return value;
}

pub fn selector(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn boolean(value: bool) BOOL {
    return booleanFor(builtin.cpu.arch, value);
}

pub fn isTrue(value: BOOL) bool {
    return isTrueFor(builtin.cpu.arch, value);
}

pub fn retain(target: anytype) @TypeOf(target) {
    const retained = send(Id, @ptrCast(target), selector("retain"), .{});
    return @ptrCast(retained);
}

pub fn release(target: anytype) void {
    send(void, @ptrCast(target), selector("release"), .{});
}

/// Whether `target` implements `operation`, so that optional API can be probed before it is sent.
pub fn respondsTo(target: Id, operation: SEL) bool {
    return isTrue(send(BOOL, target, selector("respondsToSelector:"), .{operation}));
}

pub fn send(comptime Return: type, target: Id, operation: SEL, arguments: anytype) Return {
    return dispatch(Return, entryForReturn(Return, builtin.cpu.arch), target, operation, arguments);
}

const Entry = enum {
    message,
    structure,
};

fn dispatch(
    comptime Return: type,
    comptime entry_kind: Entry,
    target: Id,
    operation: SEL,
    arguments: anytype,
) Return {
    const entry = if (comptime entry_kind == .structure)
        &objc_msgSend_stret
    else
        &objc_msgSend;
    const implementation: *const message(Return, @TypeOf(arguments)) = @ptrCast(entry);
    return @call(.auto, implementation, .{ target, operation } ++ arguments);
}

fn boolType(comptime arch: std.Target.Cpu.Arch) type {
    return switch (arch) {
        .aarch64 => bool,
        else => i8,
    };
}

fn booleanFor(comptime arch: std.Target.Cpu.Arch, value: bool) boolType(arch) {
    return switch (arch) {
        .aarch64 => value,
        else => @intFromBool(value),
    };
}

fn isTrueFor(comptime arch: std.Target.Cpu.Arch, value: boolType(arch)) bool {
    return switch (arch) {
        .aarch64 => value,
        else => value != 0,
    };
}

fn entryForReturn(comptime Return: type, comptime arch: std.Target.Cpu.Arch) Entry {
    return switch (@typeInfo(Return)) {
        .@"struct" => if (comptime supportedAggregateReturn(Return))
            if (arch == .x86_64 and @sizeOf(Return) > 16) .structure else .message
        else
            @compileError("Objective-C aggregate returns support only non-empty extern f64 structures"),
        else => .message,
    };
}

fn supportedAggregateReturn(comptime Aggregate: type) bool {
    const aggregate = switch (@typeInfo(Aggregate)) {
        .@"struct" => |info| info,
        else => return false,
    };
    if (aggregate.layout != .@"extern" or aggregate.field_types.len == 0) return false;
    inline for (aggregate.field_types) |field_type| {
        switch (@typeInfo(field_type)) {
            .float => if (field_type != f64) return false,
            .@"struct" => if (!supportedAggregateReturn(field_type)) return false,
            else => return false,
        }
    }
    return true;
}

/// The most explicit arguments one message takes. Metal's longest selectors take nine.
const max_message_arguments = 12;

/// The C signature of a message that takes `Arguments`, a tuple of explicit argument types, after
/// the receiver and selector.
fn message(comptime Return: type, comptime Arguments: type) type {
    const argument_types = @typeInfo(Arguments).@"struct".field_types;
    if (argument_types.len > max_message_arguments) {
        @compileError("Objective-C messages support at most twelve explicit arguments");
    }
    var parameter_types: [argument_types.len + 2]type = undefined;
    parameter_types[0] = Id;
    parameter_types[1] = SEL;
    for (argument_types, parameter_types[2..]) |argument_type, *parameter_type| {
        parameter_type.* = argument_type;
    }
    return @Fn(&parameter_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

test "Objective-C ABI scalar and pointer layouts" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(BOOL));
    try std.testing.expect(boolType(.aarch64) == bool);
    try std.testing.expect(boolType(.x86_64) == i8);
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Class));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Ivar));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(SEL));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Id));
    try std.testing.expectEqual(true, booleanFor(.aarch64, true));
    try std.testing.expectEqual(false, booleanFor(.aarch64, false));
    try std.testing.expectEqual(@as(i8, 1), booleanFor(.x86_64, true));
    try std.testing.expectEqual(@as(i8, 0), booleanFor(.x86_64, false));
    try std.testing.expect(isTrueFor(.aarch64, true));
    try std.testing.expect(isTrueFor(.x86_64, -1));
    try std.testing.expect(isTrue(boolean(true)));
    try std.testing.expect(!isTrue(boolean(false)));
}

test "Objective-C message signatures preserve exact C ABI types" {
    const Signature = message(?Id, struct { u64, BOOL });
    const info = @typeInfo(Signature).@"fn";
    try std.testing.expectEqual(std.builtin.CallingConvention.c, info.attrs.@"callconv");
    try std.testing.expect(info.return_type.? == ?Id);
    try std.testing.expect(info.param_types[0].? == Id);
    try std.testing.expect(info.param_types[1].? == SEL);
    try std.testing.expect(info.param_types[2].? == u64);
    try std.testing.expect(info.param_types[3].? == BOOL);
}

test "Objective-C dispatch exposes one message entry API" {
    try std.testing.expect(!@hasDecl(@This(), "sendStret"));
}

test "Objective-C autorelease pool has an explicit poll lifetime" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = AutoreleasePool.init();
    pool.deinit();
}

const ObjectiveCPointFixture = extern struct {
    x: f64,
    y: f64,
};

const ObjectiveCRectFixture = extern struct {
    origin: ObjectiveCPointFixture,
    size: ObjectiveCPointFixture,
};

const ObjectiveCIntegerPairFixture = extern struct {
    x: u64,
    y: u64,
};

const ObjectiveCNativePointFixture = struct {
    x: f64,
    y: f64,
};

test "Objective-C aggregate entry follows the macOS architecture ABI" {
    try std.testing.expect(supportedAggregateReturn(ObjectiveCPointFixture));
    try std.testing.expect(supportedAggregateReturn(ObjectiveCRectFixture));
    try std.testing.expect(!supportedAggregateReturn(ObjectiveCIntegerPairFixture));
    try std.testing.expect(!supportedAggregateReturn(ObjectiveCNativePointFixture));
    try std.testing.expectEqual(Entry.message, entryForReturn(ObjectiveCPointFixture, .aarch64));
    try std.testing.expectEqual(Entry.message, entryForReturn(ObjectiveCRectFixture, .aarch64));
    try std.testing.expectEqual(Entry.message, entryForReturn(ObjectiveCPointFixture, .x86_64));
    try std.testing.expectEqual(Entry.structure, entryForReturn(ObjectiveCRectFixture, .x86_64));
}
