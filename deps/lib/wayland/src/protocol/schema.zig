const std = @import("std");

pub const Direction = enum {
    request,
    event,
};

pub const Kind = enum {
    int,
    uint,
    fixed,
    string,
    object,
    new_id,
    array,
    fd,
};

pub const Argument = struct {
    name: []const u8,
    kind: Kind,
    interface: ?[]const u8,
    enumeration: ?[]const u8,
    nullable: bool,
};

pub const Message = struct {
    name: []const u8,
    opcode: u16,
    since: u32,
    deprecated_since: ?u32,
    destructor: bool,
    signature: []const u8,
    descriptor_count: u8,
    minimum_payload_size: u16,
    arguments: []const Argument,

    pub fn supportedBy(self: Message, version: u32) bool {
        return version >= self.since;
    }

    pub fn argument(self: Message, name: []const u8) ?*const Argument {
        for (self.arguments) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn newIdCount(self: Message) usize {
        var count: usize = 0;
        for (self.arguments) |candidate| {
            if (candidate.kind == .new_id) count += 1;
        }
        return count;
    }
};

pub const Entry = struct {
    name: []const u8,
    value: u32,
    since: u32,
    deprecated_since: ?u32,
};

pub const Enumeration = struct {
    name: []const u8,
    since: u32,
    bitfield: bool,
    entries: []const Entry,

    pub fn entry(self: Enumeration, value: u32) ?*const Entry {
        for (self.entries) |*candidate| {
            if (candidate.value == value) return candidate;
        }
        return null;
    }
};

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enumerations: []const Enumeration,

    pub fn request(self: Interface, opcode: u16) ?*const Message {
        return findMessage(self.requests, opcode);
    }

    pub fn event(self: Interface, opcode: u16) ?*const Message {
        return findMessage(self.events, opcode);
    }

    pub fn enumeration(self: Interface, name: []const u8) ?*const Enumeration {
        for (self.enumerations) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub fn findInterface(interfaces: []const Interface, name: []const u8) ?*const Interface {
    for (interfaces) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

fn findMessage(messages: []const Message, opcode: u16) ?*const Message {
    if (opcode >= messages.len) return null;
    const message = &messages[opcode];
    if (message.opcode != opcode) return null;
    return message;
}

test "schema lookup preserves opcode, version, and enum meaning" {
    const messages = [_]Message{.{
        .name = "create",
        .opcode = 0,
        .since = 2,
        .deprecated_since = null,
        .destructor = false,
        .signature = "2n",
        .descriptor_count = 0,
        .minimum_payload_size = 4,
        .arguments = &.{.{
            .name = "id",
            .kind = .new_id,
            .interface = "created",
            .enumeration = null,
            .nullable = false,
        }},
    }};
    const entries = [_]Entry{.{
        .name = "ready",
        .value = 7,
        .since = 1,
        .deprecated_since = null,
    }};
    const enumerations = [_]Enumeration{.{
        .name = "state",
        .since = 1,
        .bitfield = false,
        .entries = &entries,
    }};
    const interfaces = [_]Interface{.{
        .name = "owner",
        .version = 2,
        .requests = &messages,
        .events = &.{},
        .enumerations = &enumerations,
    }};

    const interface = findInterface(&interfaces, "owner").?;
    try std.testing.expect(interface.request(1) == null);
    const message = interface.request(0).?;
    try std.testing.expect(!message.supportedBy(1));
    try std.testing.expect(message.supportedBy(2));
    try std.testing.expectEqual(@as(usize, 1), message.newIdCount());
    try std.testing.expectEqual(Kind.new_id, message.argument("id").?.kind);
    try std.testing.expectEqualStrings("ready", interface.enumeration("state").?.entry(7).?.name);
}
