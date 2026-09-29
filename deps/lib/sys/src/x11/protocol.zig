const std = @import("std");

pub const Opcode = enum(u8) {
    create_window = 1,
    change_window_attributes = 2,
    destroy_window = 4,
    map_window = 8,
    unmap_window = 10,
    configure_window = 12,
    intern_atom = 16,
    change_property = 18,
    get_property = 20,
    set_selection_owner = 22,
    convert_selection = 24,
    send_event = 25,
    get_input_focus = 43,
    open_font = 45,
    close_font = 46,
    create_pixmap = 53,
    free_pixmap = 54,
    create_gc = 55,
    free_gc = 60,
    copy_area = 62,
    put_image = 72,
    get_image = 73,
    create_glyph_cursor = 94,
    free_cursor = 95,
    query_extension = 98,
    get_keyboard_mapping = 101,
};

pub const EventCode = enum(u8) {
    @"error" = 0,
    reply = 1,
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion_notify = 6,
    enter_notify = 7,
    leave_notify = 8,
    focus_in = 9,
    focus_out = 10,
    expose = 12,
    destroy_notify = 17,
    unmap_notify = 18,
    map_notify = 19,
    configure_notify = 22,
    property_notify = 28,
    selection_clear = 29,
    selection_request = 30,
    selection_notify = 31,
    client_message = 33,
    _,
};

pub const event_mask = struct {
    pub const key_press: u32 = 0x0000_0001;
    pub const key_release: u32 = 0x0000_0002;
    pub const button_press: u32 = 0x0000_0004;
    pub const button_release: u32 = 0x0000_0008;
    pub const enter_window: u32 = 0x0000_0010;
    pub const leave_window: u32 = 0x0000_0020;
    pub const pointer_motion: u32 = 0x0000_0040;
    pub const exposure: u32 = 0x0000_8000;
    pub const structure_notify: u32 = 0x0002_0000;
    pub const focus_change: u32 = 0x0020_0000;
    pub const property_change: u32 = 0x0040_0000;
};

pub const state_mask = struct {
    pub const shift: u16 = 0x0001;
    pub const lock: u16 = 0x0002;
    pub const control: u16 = 0x0004;
    pub const mod1: u16 = 0x0008;
    pub const mod4: u16 = 0x0040;
};

pub const window_class_input_output: u16 = 1;
pub const window_value_back_pixel: u32 = 0x0000_0002;
pub const window_value_event_mask: u32 = 0x0000_0800;
pub const property_replace: u8 = 0;
pub const format_zpixmap: u8 = 2;
pub const configure_value_width: u16 = 0x0004;
pub const configure_value_height: u16 = 0x0008;
pub const window_value_cursor: u32 = 0x0000_4000;
pub const current_time: u32 = 0;
pub const atom_none: u32 = 0;
pub const minimum_request_byte_count = 56;
pub const maximum_request_byte_count = @as(usize, std.math.maxInt(u16)) * 4;
pub const setup_request_byte_count = 48;
pub const maximum_setup_response_byte_count = @as(usize, std.math.maxInt(u16)) * 4;
pub const maximum_reply_extra_byte_count = @as(u64, std.math.maxInt(u32)) * 4;
pub const maximum_keyboard_mapping_reply_byte_count =
    @as(usize, std.math.maxInt(u8)) * std.math.maxInt(u8) * 4;
pub const reply_discard_scratch_byte_count = 4096;

pub const RequestError = error{
    RequestCapacityExceeded,
    RequestLengthOverflow,
};

pub const Request = struct {
    storage: []u8,
    limit: usize,
    len: usize = 0,
    rejection_count: u64 = 0,

    pub fn init(storage: []u8, limit: usize) Request {
        std.debug.assert(limit > 0);
        std.debug.assert(limit <= storage.len);
        std.debug.assert(limit <= maximum_request_byte_count);
        std.debug.assert(limit % 4 == 0);
        return .{
            .storage = storage,
            .limit = limit,
        };
    }

    pub fn reset(self: *Request) void {
        std.debug.assert(self.len <= self.limit);
        self.len = 0;
    }

    pub fn bytes(self: *const Request) []const u8 {
        std.debug.assert(self.len <= self.limit);
        return self.storage[0..self.len];
    }

    pub fn byteCapacity(self: *const Request) usize {
        return self.limit;
    }

    pub fn reserve(self: *Request, additional: usize) RequestError!void {
        std.debug.assert(self.len <= self.limit);
        const total = std.math.add(usize, self.len, additional) catch {
            self.reject();
            return error.RequestCapacityExceeded;
        };
        if (total > self.limit) {
            self.reject();
            return error.RequestCapacityExceeded;
        }
    }

    pub fn capacityRejectionCount(self: *const Request) u64 {
        return self.rejection_count;
    }

    fn appendSliceAssumeCapacity(self: *Request, data: []const u8) void {
        std.debug.assert(data.len <= self.limit - self.len);
        @memcpy(self.storage[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn appendByteAssumeCapacity(self: *Request, byte: u8) void {
        std.debug.assert(self.len < self.limit);
        self.storage[self.len] = byte;
        self.len += 1;
    }

    fn appendZeroesAssumeCapacity(self: *Request, count: usize) void {
        std.debug.assert(count <= self.limit - self.len);
        @memset(self.storage[self.len..][0..count], 0);
        self.len += count;
    }

    fn reject(self: *Request) void {
        self.rejection_count +|= 1;
    }
};

pub fn pad4(len: usize) usize {
    return (4 - (len % 4)) % 4;
}

fn requestUnits(byte_len: usize) u16 {
    std.debug.assert(byte_len % 4 == 0);
    std.debug.assert(byte_len <= maximum_request_byte_count);
    return @intCast(byte_len / 4);
}

pub const Writer = struct {
    request: *Request,

    pub fn init(request: *Request, byte_count: usize) RequestError!Writer {
        try request.reserve(byte_count);
        return .{ .request = request };
    }

    pub fn u8v(self: Writer, value: u8) RequestError!void {
        self.request.appendByteAssumeCapacity(value);
    }

    pub fn u16v(self: Writer, value: u16) RequestError!void {
        var scratch: [2]u8 = undefined;
        std.mem.writeInt(u16, &scratch, value, .little);
        self.request.appendSliceAssumeCapacity(&scratch);
    }

    pub fn i16v(self: Writer, value: i16) RequestError!void {
        try self.u16v(@bitCast(value));
    }

    pub fn u32v(self: Writer, value: u32) RequestError!void {
        var scratch: [4]u8 = undefined;
        std.mem.writeInt(u32, &scratch, value, .little);
        self.request.appendSliceAssumeCapacity(&scratch);
    }

    pub fn bytes(self: Writer, value: []const u8) RequestError!void {
        self.request.appendSliceAssumeCapacity(value);
    }

    pub fn paddedBytes(self: Writer, value: []const u8) RequestError!void {
        try self.bytes(value);
        try self.zeroes(pad4(value.len));
    }

    pub fn zeroes(self: Writer, count: usize) RequestError!void {
        self.request.appendZeroesAssumeCapacity(count);
    }
};

fn paddedRequestBytes(base: usize, bytes: usize) RequestError!usize {
    const unpadded = std.math.add(usize, base, bytes) catch
        return error.RequestLengthOverflow;
    return std.math.add(usize, unpadded, pad4(bytes)) catch
        return error.RequestLengthOverflow;
}

fn u16Length(len: usize) RequestError!u16 {
    if (len > std.math.maxInt(u16)) return error.RequestLengthOverflow;
    return @intCast(len);
}

fn requestHeader(writer: Writer, opcode: Opcode, data: u8, units: u16) RequestError!void {
    try writer.u8v(@backingInt(opcode));
    try writer.u8v(data);
    try writer.u16v(units);
}

pub fn setupRequest(
    request: *Request,
    auth_name: []const u8,
    auth_data: []const u8,
) RequestError!void {
    var byte_count = try paddedRequestBytes(12, auth_name.len);
    byte_count = try paddedRequestBytes(byte_count, auth_data.len);
    const writer = try Writer.init(request, byte_count);
    try writer.u8v(0x6C);
    try writer.u8v(0);
    try writer.u16v(11);
    try writer.u16v(0);
    try writer.u16v(try u16Length(auth_name.len));
    try writer.u16v(try u16Length(auth_data.len));
    try writer.u16v(0);
    try writer.paddedBytes(auth_name);
    try writer.paddedBytes(auth_data);
}

pub const CreateWindow = struct {
    window: u32,
    parent: u32,
    depth: u8,
    visual: u32,
    x: i16 = 0,
    y: i16 = 0,
    width: u16,
    height: u16,
    background_pixel: u32 = 0,
    events: u32,
};

pub fn createWindow(buffer: *Request, request: CreateWindow) RequestError!void {
    const writer = try Writer.init(buffer, 40);
    try requestHeader(writer, .create_window, request.depth, 8 + 2);
    try writer.u32v(request.window);
    try writer.u32v(request.parent);
    try writer.i16v(request.x);
    try writer.i16v(request.y);
    try writer.u16v(request.width);
    try writer.u16v(request.height);
    try writer.u16v(0);
    try writer.u16v(window_class_input_output);
    try writer.u32v(request.visual);
    try writer.u32v(window_value_back_pixel | window_value_event_mask);
    try writer.u32v(request.background_pixel);
    try writer.u32v(request.events);
}

pub fn windowRequest(buffer: *Request, opcode: Opcode, window: u32) RequestError!void {
    const writer = try Writer.init(buffer, 8);
    try requestHeader(writer, opcode, 0, 2);
    try writer.u32v(window);
}

pub fn changeCursor(buffer: *Request, window: u32, cursor: u32) RequestError!void {
    const writer = try Writer.init(buffer, 16);
    try requestHeader(writer, .change_window_attributes, 0, 4);
    try writer.u32v(window);
    try writer.u32v(window_value_cursor);
    try writer.u32v(cursor);
}

pub fn internAtom(buffer: *Request, name: []const u8) RequestError!void {
    const payload = try paddedRequestBytes(8, name.len);
    const name_len = try u16Length(name.len);
    const writer = try Writer.init(buffer, payload);
    try requestHeader(writer, .intern_atom, 0, requestUnits(payload));
    try writer.u16v(name_len);
    try writer.u16v(0);
    try writer.paddedBytes(name);
}

pub const ChangeProperty = struct {
    window: u32,
    property: u32,
    property_type: u32,
    format: u8,
    data: []const u8,
};

pub fn changeProperty(buffer: *Request, request: ChangeProperty) RequestError!void {
    const payload = try paddedRequestBytes(24, request.data.len);
    const writer = try Writer.init(buffer, payload);
    try requestHeader(writer, .change_property, property_replace, requestUnits(payload));
    try writer.u32v(request.window);
    try writer.u32v(request.property);
    try writer.u32v(request.property_type);
    try writer.u8v(request.format);
    try writer.zeroes(3);
    try writer.u32v(@intCast(request.data.len / (request.format / 8)));
    try writer.paddedBytes(request.data);
}

pub const GetProperty = struct {
    window: u32,
    property: u32,
    property_type: u32,
    long_offset: u32 = 0,
    long_length: u32,
    delete: bool = false,
};

pub fn getProperty(buffer: *Request, request: GetProperty) RequestError!void {
    const writer = try Writer.init(buffer, 24);
    try requestHeader(writer, .get_property, @intFromBool(request.delete), 6);
    try writer.u32v(request.window);
    try writer.u32v(request.property);
    try writer.u32v(request.property_type);
    try writer.u32v(request.long_offset);
    try writer.u32v(request.long_length);
}

pub fn setSelectionOwner(
    buffer: *Request,
    owner: u32,
    selection: u32,
) RequestError!void {
    const writer = try Writer.init(buffer, 16);
    try requestHeader(writer, .set_selection_owner, 0, 4);
    try writer.u32v(owner);
    try writer.u32v(selection);
    try writer.u32v(current_time);
}

pub const ConvertSelection = struct {
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
};

pub fn convertSelection(buffer: *Request, request: ConvertSelection) RequestError!void {
    const writer = try Writer.init(buffer, 24);
    try requestHeader(writer, .convert_selection, 0, 6);
    try writer.u32v(request.requestor);
    try writer.u32v(request.selection);
    try writer.u32v(request.target);
    try writer.u32v(request.property);
    try writer.u32v(current_time);
}

pub const ClientMessage = struct {
    window: u32,
    message_type: u32,
    data: [5]u32,
};

pub fn sendClientMessage(
    buffer: *Request,
    destination: u32,
    destination_mask: u32,
    message: ClientMessage,
) RequestError!void {
    var raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.client_message);
    raw[1] = 32;
    std.mem.writeInt(u32, raw[4..8], message.window, .little);
    std.mem.writeInt(u32, raw[8..12], message.message_type, .little);
    for (message.data, 0..) |word, i| {
        std.mem.writeInt(u32, raw[12 + i * 4 ..][0..4], word, .little);
    }
    try sendEvent(buffer, destination, destination_mask, &raw);
}

pub const SelectionNotify = struct {
    time: u32,
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
};

pub fn sendSelectionNotify(
    buffer: *Request,
    selection: SelectionNotify,
) RequestError!void {
    var raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.selection_notify);
    std.mem.writeInt(u32, raw[4..8], selection.time, .little);
    std.mem.writeInt(u32, raw[8..12], selection.requestor, .little);
    std.mem.writeInt(u32, raw[12..16], selection.selection, .little);
    std.mem.writeInt(u32, raw[16..20], selection.target, .little);
    std.mem.writeInt(u32, raw[20..24], selection.property, .little);
    try sendEvent(buffer, selection.requestor, 0, &raw);
}

pub fn sendEvent(
    buffer: *Request,
    destination: u32,
    destination_mask: u32,
    raw: *const [message_length]u8,
) RequestError!void {
    const writer = try Writer.init(buffer, 44);
    try requestHeader(writer, .send_event, 0, 11);
    try writer.u32v(destination);
    try writer.u32v(destination_mask);
    try writer.bytes(raw);
}

pub fn configureSize(buffer: *Request, window: u32, width: u16, height: u16) RequestError!void {
    const writer = try Writer.init(buffer, 20);
    try requestHeader(writer, .configure_window, 0, 5);
    try writer.u32v(window);
    try writer.u16v(configure_value_width | configure_value_height);
    try writer.u16v(0);
    try writer.u32v(width);
    try writer.u32v(height);
}

pub fn createGc(buffer: *Request, gc: u32, drawable: u32) RequestError!void {
    const writer = try Writer.init(buffer, 16);
    try requestHeader(writer, .create_gc, 0, 4);
    try writer.u32v(gc);
    try writer.u32v(drawable);
    try writer.u32v(0);
}

pub fn freeResource(buffer: *Request, opcode: Opcode, id: u32) RequestError!void {
    const writer = try Writer.init(buffer, 8);
    try requestHeader(writer, opcode, 0, 2);
    try writer.u32v(id);
}

pub const CreatePixmap = struct {
    depth: u8,
    pixmap: u32,
    drawable: u32,
    width: u16,
    height: u16,
};

pub fn createPixmap(buffer: *Request, request: CreatePixmap) RequestError!void {
    const writer = try Writer.init(buffer, 16);
    try requestHeader(writer, .create_pixmap, request.depth, 4);
    try writer.u32v(request.pixmap);
    try writer.u32v(request.drawable);
    try writer.u16v(request.width);
    try writer.u16v(request.height);
}

pub const CopyArea = struct {
    source: u32,
    destination: u32,
    gc: u32,
    source_x: i16 = 0,
    source_y: i16 = 0,
    destination_x: i16 = 0,
    destination_y: i16 = 0,
    width: u16,
    height: u16,
};

pub fn copyArea(buffer: *Request, request: CopyArea) RequestError!void {
    const writer = try Writer.init(buffer, 28);
    try requestHeader(writer, .copy_area, 0, 7);
    try writer.u32v(request.source);
    try writer.u32v(request.destination);
    try writer.u32v(request.gc);
    try writer.i16v(request.source_x);
    try writer.i16v(request.source_y);
    try writer.i16v(request.destination_x);
    try writer.i16v(request.destination_y);
    try writer.u16v(request.width);
    try writer.u16v(request.height);
}

pub fn getInputFocus(buffer: *Request) RequestError!void {
    const writer = try Writer.init(buffer, 4);
    try requestHeader(writer, .get_input_focus, 0, 1);
}

pub const ErrorPacket = struct {
    code: u8,
    sequence: u16,
    /// Preserves bytes 4 to 7 without interpretation. Alloc errors leave these
    /// bytes unused, so they cannot identify a resource for Alloc.
    value: u32,
    minor_opcode: u16,
    major_opcode: u8,

    pub fn decode(bytes: *const [message_length]u8) ErrorPacket {
        std.debug.assert(bytes[0] == 0);
        return .{
            .code = bytes[1],
            .sequence = readU16(bytes, 2),
            .value = readU32(bytes, 4),
            .minor_opcode = readU16(bytes, 8),
            .major_opcode = bytes[10],
        };
    }
};

pub const PutImageRows = struct {
    drawable: u32,
    gc: u32,
    width: u16,
    row_count: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    pixels: []const u8,
};

pub fn putImageRows(buffer: *Request, request: PutImageRows) RequestError!void {
    const payload = try paddedRequestBytes(24, request.pixels.len);
    const writer = try Writer.init(buffer, payload);
    try requestHeader(writer, .put_image, format_zpixmap, requestUnits(payload));
    try writer.u32v(request.drawable);
    try writer.u32v(request.gc);
    try writer.u16v(request.width);
    try writer.u16v(request.row_count);
    try writer.i16v(request.dst_x);
    try writer.i16v(request.dst_y);
    try writer.u8v(0);
    try writer.u8v(request.depth);
    try writer.u16v(0);
    try writer.paddedBytes(request.pixels);
}

pub const GetImage = struct {
    drawable: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

pub fn getImage(buffer: *Request, request: GetImage) RequestError!void {
    const writer = try Writer.init(buffer, 20);
    try requestHeader(writer, .get_image, format_zpixmap, 5);
    try writer.u32v(request.drawable);
    try writer.i16v(request.x);
    try writer.i16v(request.y);
    try writer.u16v(request.width);
    try writer.u16v(request.height);
    try writer.u32v(0xFFFF_FFFF);
}

pub fn openFont(buffer: *Request, font: u32, name: []const u8) RequestError!void {
    const payload = try paddedRequestBytes(12, name.len);
    const name_len = try u16Length(name.len);
    const writer = try Writer.init(buffer, payload);
    try requestHeader(writer, .open_font, 0, requestUnits(payload));
    try writer.u32v(font);
    try writer.u16v(name_len);
    try writer.u16v(0);
    try writer.paddedBytes(name);
}

pub const GlyphCursor = struct {
    cursor: u32,
    font: u32,
    glyph: u16,
};

pub fn createGlyphCursor(buffer: *Request, request: GlyphCursor) RequestError!void {
    const writer = try Writer.init(buffer, 32);
    try requestHeader(writer, .create_glyph_cursor, 0, 8);
    try writer.u32v(request.cursor);
    try writer.u32v(request.font);
    try writer.u32v(request.font);
    try writer.u16v(request.glyph);
    try writer.u16v(request.glyph + 1);
    try writer.u16v(0);
    try writer.u16v(0);
    try writer.u16v(0);
    try writer.u16v(0xFFFF);
    try writer.u16v(0xFFFF);
    try writer.u16v(0xFFFF);
}

pub fn queryExtension(buffer: *Request, name: []const u8) RequestError!void {
    const payload = try paddedRequestBytes(8, name.len);
    const name_len = try u16Length(name.len);
    const writer = try Writer.init(buffer, payload);
    try requestHeader(writer, .query_extension, 0, requestUnits(payload));
    try writer.u16v(name_len);
    try writer.u16v(0);
    try writer.paddedBytes(name);
}

pub fn getKeyboardMapping(buffer: *Request, first_keycode: u8, count: u8) RequestError!void {
    const writer = try Writer.init(buffer, 8);
    try requestHeader(writer, .get_keyboard_mapping, 0, 2);
    try writer.u8v(first_keycode);
    try writer.u8v(count);
    try writer.u16v(0);
}

pub const Setup = struct {
    resource_id_base: u32,
    resource_id_mask: u32,
    max_request_units: u32,
    image_byte_order_msb: bool,
    min_keycode: u8,
    max_keycode: u8,
    root: u32,
    root_depth: u8,
    root_visual: u32,
    root_width: u16,
    root_height: u16,
    visual_depth: u8,
    visual: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
};

pub const SetupError = error{
    SetupFailed,
    SetupTruncated,
    NoUsableScreen,
    NoUsableVisual,
};

const SetupReader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn skip(self: *SetupReader, count: usize) SetupError!void {
        if (self.index + count > self.bytes.len) return error.SetupTruncated;
        self.index += count;
    }

    fn u8v(self: *SetupReader) SetupError!u8 {
        if (self.index + 1 > self.bytes.len) return error.SetupTruncated;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    fn u16v(self: *SetupReader) SetupError!u16 {
        if (self.index + 2 > self.bytes.len) return error.SetupTruncated;
        const value = std.mem.readInt(u16, self.bytes[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    fn u32v(self: *SetupReader) SetupError!u32 {
        if (self.index + 4 > self.bytes.len) return error.SetupTruncated;
        const value = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }
};

pub fn parseSetup(body: []const u8, screen_index: u32) SetupError!Setup {
    var reader = SetupReader{ .bytes = body };
    var setup: Setup = undefined;

    try reader.skip(4);
    setup.resource_id_base = try reader.u32v();
    setup.resource_id_mask = try reader.u32v();
    try reader.skip(4);
    const vendor_len = try reader.u16v();
    setup.max_request_units = try reader.u16v();
    const screen_count = try reader.u8v();
    const format_count = try reader.u8v();
    setup.image_byte_order_msb = (try reader.u8v()) != 0;
    try reader.skip(3);
    setup.min_keycode = try reader.u8v();
    setup.max_keycode = try reader.u8v();
    try reader.skip(4);
    try reader.skip(vendor_len + pad4(vendor_len));
    try reader.skip(@as(usize, format_count) * 8);

    if (screen_index >= screen_count) return error.NoUsableScreen;

    var screen: u32 = 0;
    while (screen < screen_count) : (screen += 1) {
        const root = try reader.u32v();
        try reader.skip(16);
        const width = try reader.u16v();
        const height = try reader.u16v();
        try reader.skip(8);
        const root_visual = try reader.u32v();
        try reader.skip(2);
        const root_depth = try reader.u8v();
        const depth_count = try reader.u8v();

        const selected = screen == screen_index;
        if (selected) {
            setup.root = root;
            setup.root_depth = root_depth;
            setup.root_visual = root_visual;
            setup.root_width = width;
            setup.root_height = height;
            setup.visual = 0;
        }

        var depth_index: u8 = 0;
        while (depth_index < depth_count) : (depth_index += 1) {
            const depth = try reader.u8v();
            try reader.skip(1);
            const visual_count = try reader.u16v();
            try reader.skip(4);

            var visual_index: u16 = 0;
            while (visual_index < visual_count) : (visual_index += 1) {
                const visual_id = try reader.u32v();
                const class = try reader.u8v();
                try reader.skip(3);
                const red_mask = try reader.u32v();
                const green_mask = try reader.u32v();
                const blue_mask = try reader.u32v();
                try reader.skip(4);

                if (selected and class == 4 and (depth == 24 or depth == 32)) {
                    const replace = setup.visual == 0 or visual_id == setup.root_visual;
                    if (replace) {
                        setup.visual = visual_id;
                        setup.visual_depth = depth;
                        setup.red_mask = red_mask;
                        setup.green_mask = green_mask;
                        setup.blue_mask = blue_mask;
                    }
                }
            }
        }

        if (selected and setup.visual == 0) return error.NoUsableVisual;
    }

    return setup;
}

pub const KeyEvent = struct {
    keycode: u8,
    x: i16,
    y: i16,
    state: u16,
};

pub const ButtonEvent = struct {
    button: u8,
    x: i16,
    y: i16,
    state: u16,
};

pub const MotionEvent = struct {
    x: i16,
    y: i16,
    state: u16,
};

pub const ConfigureEvent = struct {
    window: u32,
    width: u16,
    height: u16,
};

pub const ClientMessageEvent = struct {
    window: u32,
    message_type: u32,
    data: [5]u32,
};

pub const SelectionEvent = struct {
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
};

pub const SelectionRequestEvent = struct {
    time: u32,
    owner: u32,
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
};

pub const SelectionClearEvent = struct {
    owner: u32,
    selection: u32,
};

pub const FocusEvent = struct {
    focused: bool,
    mode: u8,
};

pub const Message = union(enum) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    button_press: ButtonEvent,
    button_release: ButtonEvent,
    motion: MotionEvent,
    configure: ConfigureEvent,
    client_message: ClientMessageEvent,
    selection_clear: SelectionClearEvent,
    selection_request: SelectionRequestEvent,
    selection_notify: SelectionEvent,
    focus: FocusEvent,
    enter,
    leave,
    expose,
    destroy_notify,
    protocol_error: u8,
    reply,
    ignored,
};

pub const message_length = 32;

pub fn decodeMessage(bytes: *const [message_length]u8) Message {
    const code: EventCode = @fromBackingInt(@intCast(bytes[0] & 0x7F));
    return switch (code) {
        .@"error" => .{ .protocol_error = bytes[1] },
        .reply => .reply,
        .key_press => .{ .key_press = decodeKey(bytes) },
        .key_release => .{ .key_release = decodeKey(bytes) },
        .button_press => .{ .button_press = decodeButton(bytes) },
        .button_release => .{ .button_release = decodeButton(bytes) },
        .motion_notify => .{ .motion = .{
            .x = readI16(bytes, 24),
            .y = readI16(bytes, 26),
            .state = readU16(bytes, 28),
        } },
        .configure_notify => .{ .configure = .{
            .window = readU32(bytes, 8),
            .width = readU16(bytes, 20),
            .height = readU16(bytes, 22),
        } },
        .client_message => blk: {
            var data: [5]u32 = undefined;
            for (&data, 0..) |*word, i| {
                word.* = readU32(bytes, 12 + i * 4);
            }
            break :blk .{ .client_message = .{
                .window = readU32(bytes, 4),
                .message_type = readU32(bytes, 8),
                .data = data,
            } };
        },
        .selection_clear => .{ .selection_clear = .{
            .owner = readU32(bytes, 8),
            .selection = readU32(bytes, 12),
        } },
        .selection_request => .{ .selection_request = .{
            .time = readU32(bytes, 4),
            .owner = readU32(bytes, 8),
            .requestor = readU32(bytes, 12),
            .selection = readU32(bytes, 16),
            .target = readU32(bytes, 20),
            .property = readU32(bytes, 24),
        } },
        .selection_notify => .{ .selection_notify = .{
            .requestor = readU32(bytes, 8),
            .selection = readU32(bytes, 12),
            .target = readU32(bytes, 16),
            .property = readU32(bytes, 20),
        } },
        .focus_in => .{ .focus = .{ .focused = true, .mode = bytes[8] } },
        .focus_out => .{ .focus = .{ .focused = false, .mode = bytes[8] } },
        .enter_notify => .enter,
        .leave_notify => .leave,
        .expose => .expose,
        .destroy_notify => .destroy_notify,
        else => .ignored,
    };
}

fn decodeKey(bytes: *const [message_length]u8) KeyEvent {
    return .{
        .keycode = bytes[1],
        .x = readI16(bytes, 24),
        .y = readI16(bytes, 26),
        .state = readU16(bytes, 28),
    };
}

fn decodeButton(bytes: *const [message_length]u8) ButtonEvent {
    return .{
        .button = bytes[1],
        .x = readI16(bytes, 24),
        .y = readI16(bytes, 26),
        .state = readU16(bytes, 28),
    };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readI16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(readU16(bytes, offset));
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

test "pad4 rounds byte lengths to protocol units" {
    try std.testing.expectEqual(@as(usize, 0), pad4(0));
    try std.testing.expectEqual(@as(usize, 3), pad4(1));
    try std.testing.expectEqual(@as(usize, 2), pad4(2));
    try std.testing.expectEqual(@as(usize, 1), pad4(3));
    try std.testing.expectEqual(@as(usize, 0), pad4(4));
}

test "setup request frames auth strings with padding" {
    var storage: [setup_request_byte_count]u8 = undefined;
    var request = Request.init(&storage, storage.len);

    try setupRequest(&request, "MIT-MAGIC-COOKIE-1", "0123456789abcdef");
    const bytes = request.bytes();
    try std.testing.expectEqual(@as(usize, 12 + 20 + 16), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x6C), bytes[0]);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, bytes[2..4], .little));
    try std.testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", bytes[12..30]);
    try std.testing.expectEqual(@as(u8, 0), bytes[30]);
    try std.testing.expectEqual(@as(u8, 0), bytes[31]);
}

test "requests encode lengths in four byte units" {
    var storage: [64]u8 = undefined;
    var request = Request.init(&storage, storage.len);

    try internAtom(&request, "WM_PROTOCOLS");
    try std.testing.expectEqual(@as(usize, 20), request.bytes().len);
    try std.testing.expectEqual(@as(u8, @backingInt(Opcode.intern_atom)), request.bytes()[0]);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, request.bytes()[2..4], .little));
    try std.testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, request.bytes()[4..6], .little));

    request.reset();
    try createWindow(&request, .{
        .window = 2,
        .parent = 1,
        .depth = 24,
        .visual = 3,
        .width = 640,
        .height = 480,
        .events = event_mask.key_press,
    });
    try std.testing.expectEqual(@as(usize, 40), request.bytes().len);
    try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, request.bytes()[2..4], .little));
}

test "clipboard owner and notify requests retain selection protocol fields" {
    var storage: [64]u8 = undefined;
    var request = Request.init(&storage, storage.len);

    try setSelectionOwner(&request, 0x1122_3344, 0x5566_7788);
    var bytes = request.bytes();
    try std.testing.expectEqual(@as(usize, 16), bytes.len);
    try std.testing.expectEqual(
        @as(u8, @backingInt(Opcode.set_selection_owner)),
        bytes[0],
    );
    try std.testing.expectEqual(@as(u16, 4), readU16(bytes, 2));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), readU32(bytes, 4));
    try std.testing.expectEqual(@as(u32, 0x5566_7788), readU32(bytes, 8));
    try std.testing.expectEqual(current_time, readU32(bytes, 12));

    request.reset();
    try sendSelectionNotify(&request, .{
        .time = 0x0102_0304,
        .requestor = 0x1112_1314,
        .selection = 0x2122_2324,
        .target = 0x3132_3334,
        .property = 0x4142_4344,
    });
    bytes = request.bytes();
    try std.testing.expectEqual(@as(usize, 44), bytes.len);
    try std.testing.expectEqual(@as(u8, @backingInt(Opcode.send_event)), bytes[0]);
    try std.testing.expectEqual(@as(u32, 0x1112_1314), readU32(bytes, 4));
    try std.testing.expectEqual(
        @as(u8, @backingInt(EventCode.selection_notify)),
        bytes[12],
    );
    try std.testing.expectEqual(@as(u32, 0x0102_0304), readU32(bytes, 16));
    try std.testing.expectEqual(@as(u32, 0x1112_1314), readU32(bytes, 20));
    try std.testing.expectEqual(@as(u32, 0x2122_2324), readU32(bytes, 24));
    try std.testing.expectEqual(@as(u32, 0x3132_3334), readU32(bytes, 28));
    try std.testing.expectEqual(@as(u32, 0x4142_4344), readU32(bytes, 32));
}

test "minimum connection request storage admits the largest fixed batch" {
    var storage: [minimum_request_byte_count]u8 = undefined;
    var request = Request.init(&storage, storage.len);
    try createWindow(&request, .{
        .window = 2,
        .parent = 1,
        .depth = 24,
        .visual = 3,
        .width = 640,
        .height = 480,
        .events = event_mask.key_press,
    });
    try createGc(&request, 4, 2);
    try std.testing.expectEqual(minimum_request_byte_count, request.bytes().len);
    const expected = storage;
    try std.testing.expectError(
        error.RequestCapacityExceeded,
        windowRequest(&request, .map_window, 2),
    );
    try std.testing.expectEqualSlices(u8, &expected, request.bytes());
}

test "put image rows pads pixel payloads" {
    var storage: [32]u8 = undefined;
    var buffer = Request.init(&storage, storage.len);

    const pixels = @as([8]u8, @splat(0xAB));
    try putImageRows(&buffer, .{
        .drawable = 5,
        .gc = 6,
        .width = 2,
        .row_count = 1,
        .dst_x = 4,
        .dst_y = 3,
        .depth = 24,
        .pixels = &pixels,
    });
    const bytes = buffer.bytes();
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[2..4], .little));
    try std.testing.expectEqual(@as(u8, format_zpixmap), bytes[1]);
    try std.testing.expectEqual(@as(i16, 4), std.mem.readInt(i16, bytes[16..18], .little));
    try std.testing.expectEqual(@as(i16, 3), std.mem.readInt(i16, bytes[18..20], .little));
}

test "request capacity rejects before mutation and saturates status" {
    var storage: [20]u8 = undefined;
    var request = Request.init(&storage, storage.len);
    try internAtom(&request, "WM_PROTOCOLS");
    const expected = storage;
    try std.testing.expectError(
        error.RequestCapacityExceeded,
        windowRequest(&request, .map_window, 1),
    );
    try std.testing.expectEqualSlices(u8, &expected, request.bytes());
    try std.testing.expectEqual(@as(u64, 1), request.capacityRejectionCount());

    request.reset();
    try std.testing.expectError(
        error.RequestCapacityExceeded,
        createWindow(&request, .{
            .window = 2,
            .parent = 1,
            .depth = 24,
            .visual = 3,
            .width = 640,
            .height = 480,
            .events = event_mask.key_press,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), request.bytes().len);

    request.rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.RequestCapacityExceeded,
        createWindow(&request, .{
            .window = 2,
            .parent = 1,
            .depth = 24,
            .visual = 3,
            .width = 640,
            .height = 480,
            .events = event_mask.key_press,
        }),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), request.capacityRejectionCount());
    try std.testing.expectError(
        error.RequestLengthOverflow,
        u16Length(@as(usize, std.math.maxInt(u16)) + 1),
    );
    try std.testing.expectError(
        error.RequestLengthOverflow,
        paddedRequestBytes(std.math.maxInt(usize), 1),
    );
}

test "decode message reads key and configure events" {
    var raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.key_press);
    raw[1] = 38;
    std.mem.writeInt(u16, raw[24..26], 100, .little);
    std.mem.writeInt(u16, raw[26..28], 200, .little);
    std.mem.writeInt(u16, raw[28..30], state_mask.shift, .little);

    const key = decodeMessage(&raw);
    try std.testing.expectEqual(@as(u8, 38), key.key_press.keycode);
    try std.testing.expectEqual(@as(i16, 100), key.key_press.x);
    try std.testing.expectEqual(state_mask.shift, key.key_press.state);

    raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.configure_notify);
    std.mem.writeInt(u32, raw[8..12], 77, .little);
    std.mem.writeInt(u16, raw[20..22], 1280, .little);
    std.mem.writeInt(u16, raw[22..24], 800, .little);

    const configure = decodeMessage(&raw);
    try std.testing.expectEqual(@as(u32, 77), configure.configure.window);
    try std.testing.expectEqual(@as(u16, 1280), configure.configure.width);
    try std.testing.expectEqual(@as(u16, 800), configure.configure.height);
}

test "decode message retains clipboard clear and request fields" {
    var raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.selection_clear);
    std.mem.writeInt(u32, raw[8..12], 0x0102_0304, .little);
    std.mem.writeInt(u32, raw[12..16], 0x1112_1314, .little);
    const clear = decodeMessage(&raw).selection_clear;
    try std.testing.expectEqual(@as(u32, 0x0102_0304), clear.owner);
    try std.testing.expectEqual(@as(u32, 0x1112_1314), clear.selection);

    raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.selection_request);
    std.mem.writeInt(u32, raw[4..8], 0x0102_0304, .little);
    std.mem.writeInt(u32, raw[8..12], 0x1112_1314, .little);
    std.mem.writeInt(u32, raw[12..16], 0x2122_2324, .little);
    std.mem.writeInt(u32, raw[16..20], 0x3132_3334, .little);
    std.mem.writeInt(u32, raw[20..24], 0x4142_4344, .little);
    std.mem.writeInt(u32, raw[24..28], 0x5152_5354, .little);
    const selection = decodeMessage(&raw).selection_request;
    try std.testing.expectEqual(@as(u32, 0x0102_0304), selection.time);
    try std.testing.expectEqual(@as(u32, 0x1112_1314), selection.owner);
    try std.testing.expectEqual(@as(u32, 0x2122_2324), selection.requestor);
    try std.testing.expectEqual(@as(u32, 0x3132_3334), selection.selection);
    try std.testing.expectEqual(@as(u32, 0x4142_4344), selection.target);
    try std.testing.expectEqual(@as(u32, 0x5152_5354), selection.property);
}

test "decode message surfaces errors and unknown codes" {
    var raw = @as([message_length]u8, @splat(0));
    raw[0] = @backingInt(EventCode.@"error");
    raw[1] = 9;
    try std.testing.expectEqual(@as(u8, 9), decodeMessage(&raw).protocol_error);

    raw[0] = 99;
    try std.testing.expectEqual(Message.ignored, decodeMessage(&raw));
}

test "pixmap publication and barrier requests match core wire bytes" {
    var storage: [64]u8 = undefined;
    var request = Request.init(&storage, storage.len);
    try createPixmap(&request, .{ .depth = 24, .pixmap = 0x11223344, .drawable = 0x55667788, .width = 0x1234, .height = 0x5678 });
    try std.testing.expectEqualSlices(u8, &.{ 53, 24, 4, 0, 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55, 0x34, 0x12, 0x78, 0x56 }, request.bytes());
    request.reset();
    try copyArea(&request, .{ .source = 0x11223344, .destination = 0x55667788, .gc = 0x99aabbcc, .source_x = -2, .source_y = 3, .destination_x = 4, .destination_y = -5, .width = 0x1234, .height = 0x5678 });
    try std.testing.expectEqualSlices(u8, &.{ 62, 0, 7, 0, 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55, 0xcc, 0xbb, 0xaa, 0x99, 0xfe, 0xff, 3, 0, 4, 0, 0xfb, 0xff, 0x34, 0x12, 0x78, 0x56 }, request.bytes());
    request.reset();
    try freeResource(&request, .free_pixmap, 0x11223344);
    try getInputFocus(&request);
    try std.testing.expectEqualSlices(u8, &.{ 54, 0, 2, 0, 0x44, 0x33, 0x22, 0x11, 43, 0, 1, 0 }, request.bytes());
}

test "error packet retains sequence opcode and uninterpreted value" {
    var bytes: [message_length]u8 = @splat(0);
    @memcpy(bytes[0..11], &[_]u8{ 0, 11, 0xfe, 0xff, 0x44, 0x33, 0x22, 0x11, 0x34, 0x12, 53 });
    try std.testing.expectEqual(ErrorPacket{ .code = 11, .sequence = 65534, .value = 0x11223344, .minor_opcode = 0x1234, .major_opcode = 53 }, ErrorPacket.decode(&bytes));
}
