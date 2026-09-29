const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const protocol = @import("../root.zig");
const value = @import("root.zig");

pub const Error = error{
    DescriptorCountMismatch,
    IncompletePayload,
    InvalidAlignment,
    InvalidDescriptor,
    InvalidInterface,
    InvalidNewId,
    InvalidObject,
    InvalidString,
    InvalidUtf8,
    InvalidVersion,
    MessageTooLarge,
    PayloadTooSmall,
    TrailingDescriptors,
    TrailingPayload,
};

pub const Decoder = struct {
    metadata: *const protocol.schema.Message,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,
    byte_offset: usize = 0,
    descriptor_offset: usize = 0,

    pub fn init(
        metadata: *const protocol.schema.Message,
        payload: []const u8,
        descriptors: []const sys.fd.Descriptor,
    ) Error!Decoder {
        if (payload.len % 4 != 0) return error.InvalidAlignment;
        if (payload.len > value.maximum_payload_size) return error.MessageTooLarge;
        if (payload.len < metadata.minimum_payload_size) return error.PayloadTooSmall;
        if (descriptors.len != metadata.descriptor_count) return error.DescriptorCountMismatch;
        return .{
            .metadata = metadata,
            .payload = payload,
            .descriptors = descriptors,
        };
    }

    pub fn signed(self: *Decoder) Error!i32 {
        const bytes = try self.word();
        return std.mem.readInt(i32, bytes, builtin.cpu.arch.endian());
    }

    pub fn unsigned(self: *Decoder) Error!u32 {
        const bytes = try self.word();
        return std.mem.readInt(u32, bytes, builtin.cpu.arch.endian());
    }

    pub fn fixed(self: *Decoder) Error!value.Fixed {
        return .fromRaw(try self.signed());
    }

    pub fn string(self: *Decoder) Error![]const u8 {
        return (try self.optionalString()) orelse error.InvalidString;
    }

    pub fn optionalString(self: *Decoder) Error!?[]const u8 {
        const length = try self.unsigned();
        if (length == 0) return null;
        const bytes = try self.delimited(length);
        if (bytes[bytes.len - 1] != 0) return error.InvalidString;
        const text = bytes[0 .. bytes.len - 1];
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidString;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return text;
    }

    pub fn object(self: *Decoder) Error!value.ObjectId {
        return value.ObjectId.init(try self.unsigned()) catch return error.InvalidObject;
    }

    pub fn optionalObject(self: *Decoder) Error!?value.ObjectId {
        const raw = try self.unsigned();
        return if (raw == 0) null else value.ObjectId.init(raw) catch return error.InvalidObject;
    }

    pub fn newId(self: *Decoder) Error!value.NewId {
        return value.NewId.init(try self.unsigned()) catch return error.InvalidNewId;
    }

    pub fn dynamicNewId(self: *Decoder) Error!value.DynamicNewId {
        const interface = try self.string();
        if (interface.len == 0) return error.InvalidInterface;
        const version = try self.unsigned();
        if (version == 0) return error.InvalidVersion;
        return .{
            .interface = interface,
            .version = version,
            .id = try self.newId(),
        };
    }

    pub fn array(self: *Decoder) Error![]const u8 {
        return self.delimited(try self.unsigned());
    }

    pub fn descriptor(self: *Decoder) Error!sys.fd.Descriptor {
        if (self.descriptor_offset == self.descriptors.len) return error.IncompletePayload;
        const item = self.descriptors[self.descriptor_offset];
        if (item < 0) return error.InvalidDescriptor;
        self.descriptor_offset += 1;
        return item;
    }

    pub fn finish(self: *const Decoder) Error!void {
        if (self.byte_offset != self.payload.len) return error.TrailingPayload;
        if (self.descriptor_offset != self.descriptors.len) return error.TrailingDescriptors;
    }

    fn word(self: *Decoder) Error!*const [4]u8 {
        if (self.payload.len - self.byte_offset < 4) return error.IncompletePayload;
        const bytes: *const [4]u8 = self.payload[self.byte_offset..][0..4];
        self.byte_offset += 4;
        return bytes;
    }

    fn delimited(self: *Decoder, length: u32) Error![]const u8 {
        const rounded = std.math.add(usize, length, 3) catch return error.IncompletePayload;
        const padded_len = rounded & ~@as(usize, 3);
        if (padded_len > self.payload.len - self.byte_offset) return error.IncompletePayload;
        const bytes = self.payload[self.byte_offset..][0..length];
        self.byte_offset += padded_len;
        return bytes;
    }
};

test "decoder accepts undefined nonzero padding" {
    const metadata: protocol.schema.Message = .{
        .name = "array",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "a",
        .descriptor_count = 0,
        .minimum_payload_size = 4,
        .arguments = &.{},
    };
    const payload = [_]u8{ 1, 0, 0, 0, 7, 0xaa, 0xbb, 0xcc };
    var decoder = try Decoder.init(&metadata, &payload, &.{});
    try std.testing.expectEqualSlices(u8, &.{7}, try decoder.array());
    try decoder.finish();
}

test "decoder rejects malformed strings and trailing values" {
    const metadata: protocol.schema.Message = .{
        .name = "string",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "s",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &.{},
    };
    const unterminated = [_]u8{ 4, 0, 0, 0, 'a', 'b', 'c', 'd' };
    var first = try Decoder.init(&metadata, &unterminated, &.{});
    try std.testing.expectError(error.InvalidString, first.string());

    const embedded = [_]u8{ 4, 0, 0, 0, 'a', 0, 'b', 0 };
    var second = try Decoder.init(&metadata, &embedded, &.{});
    try std.testing.expectError(error.InvalidString, second.string());

    const trailing = [_]u8{ 2, 0, 0, 0, 'a', 0, 0, 0, 9, 0, 0, 0 };
    var third = try Decoder.init(&metadata, &trailing, &.{});
    try std.testing.expectEqualStrings("a", try third.string());
    try std.testing.expectError(error.TrailingPayload, third.finish());
}

test "decoder rejects truncated lengths and wire nulls for required IDs" {
    const string_metadata: protocol.schema.Message = .{
        .name = "string",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "s",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &.{},
    };
    const truncated = [_]u8{ 5, 0, 0, 0, 'a', 0, 0, 0 };
    var string_decoder = try Decoder.init(&string_metadata, &truncated, &.{});
    try std.testing.expectError(error.IncompletePayload, string_decoder.string());

    const object_metadata: protocol.schema.Message = .{
        .name = "ids",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "on",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &.{},
    };
    const null_ids = @as([8]u8, @splat(0));
    var object_decoder = try Decoder.init(&object_metadata, &null_ids, &.{});
    try std.testing.expectError(error.InvalidObject, object_decoder.object());
    var new_id_decoder = try Decoder.init(&object_metadata, &null_ids, &.{});
    try std.testing.expectError(error.InvalidNewId, new_id_decoder.newId());
}

test "decoder accounts for descriptors independently and exactly" {
    const metadata: protocol.schema.Message = .{
        .name = "descriptor",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "h",
        .descriptor_count = 1,
        .minimum_payload_size = 0,
        .arguments = &.{},
    };
    try std.testing.expectError(
        error.DescriptorCountMismatch,
        Decoder.init(&metadata, &.{}, &.{}),
    );
    var decoder = try Decoder.init(&metadata, &.{}, &.{41});
    try std.testing.expectError(error.TrailingDescriptors, decoder.finish());
    try std.testing.expectEqual(@as(sys.fd.Descriptor, 41), try decoder.descriptor());
    try decoder.finish();
}

test "decoder rejects unaligned and undersized payloads at the message boundary" {
    const metadata: protocol.schema.Message = .{
        .name = "word",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "u",
        .descriptor_count = 0,
        .minimum_payload_size = 4,
        .arguments = &.{},
    };
    try std.testing.expectError(error.InvalidAlignment, Decoder.init(&metadata, &.{ 0, 0, 0, 0, 0 }, &.{}));
    try std.testing.expectError(error.PayloadTooSmall, Decoder.init(&metadata, &.{}, &.{}));
}
