const std = @import("std");
const memory = @import("memory.zig");
const shifts = @import("shift.zig");

pub const BlockPackingType = enum {
    bit_packed,
    frame_of_reference,
};

pub fn Pack8(comptime bits: usize) type {
    validateBits(u8, bits);
    return Packer(u8, bits);
}

pub fn Pack16(comptime bits: usize) type {
    validateBits(u16, bits);
    return Packer(u16, bits);
}

pub fn Pack32(comptime bits: usize) type {
    validateBits(u32, bits);
    return Packer(u32, bits);
}

pub fn Pack64(comptime bits: usize) type {
    validateBits(u64, bits);
    return Packer(u64, bits);
}

pub fn pack(
    comptime D: type,
    comptime bits: usize,
    raw: []const D.Lane,
    packed_output: []D.Lane,
) void {
    packBlock(D, bits, raw, packed_output, 0, .bit_packed);
}

pub fn unpack(
    comptime D: type,
    comptime bits: usize,
    packed_input: []const D.Lane,
    raw: []D.Lane,
) void {
    unpackBlock(D, bits, packed_input, raw, 0, .bit_packed);
}

pub fn packFrame(
    comptime D: type,
    comptime bits: usize,
    raw: []const D.Lane,
    packed_output: []D.Lane,
    frame: D.Lane,
) void {
    requireFrameLane(D.Lane);
    packBlock(D, bits, raw, packed_output, frame, .frame_of_reference);
}

pub fn unpackFrame(
    comptime D: type,
    comptime bits: usize,
    packed_input: []const D.Lane,
    raw: []D.Lane,
    frame: D.Lane,
) void {
    requireFrameLane(D.Lane);
    unpackBlock(D, bits, packed_input, raw, frame, .frame_of_reference);
}

fn Packer(comptime T: type, comptime bits: usize) type {
    return struct {
        pub fn pack(
            _: @This(),
            comptime D: type,
            raw: []const T,
            packed_output: []T,
        ) void {
            requireTag(D, T);
            packBlock(D, bits, raw, packed_output, 0, .bit_packed);
        }

        pub fn unpack(
            _: @This(),
            comptime D: type,
            packed_input: []const T,
            raw: []T,
        ) void {
            requireTag(D, T);
            unpackBlock(D, bits, packed_input, raw, 0, .bit_packed);
        }

        pub fn packFrame(
            _: @This(),
            comptime D: type,
            raw: []const T,
            packed_output: []T,
            frame: T,
        ) void {
            requireTag(D, T);
            requireFrameLane(T);
            packBlock(D, bits, raw, packed_output, frame, .frame_of_reference);
        }

        pub fn unpackFrame(
            _: @This(),
            comptime D: type,
            packed_input: []const T,
            raw: []T,
            frame: T,
        ) void {
            requireTag(D, T);
            requireFrameLane(T);
            unpackBlock(D, bits, packed_input, raw, frame, .frame_of_reference);
        }
    };
}

const layout8_1 =
    "\x00\x01\x02\x03\x04\x05\x06\x07";

const layout8_2 =
    "\x00\x01\x08\x09\x02\x03\x0A\x0B\x04\x05\x0C\x0D\x06\x07\x0E\x0F";

const layout8_3 =
    "\x00\x01\x02\x08\x09\x0A\x10\x11\x12\x16\x17\x0E\x03\x04\x05\x0B\x0C\x0D" ++
    "\x13\x14\x15\x0F\x06\x07";

const layout8_4 =
    "\x00\x01\x02\x03\x08\x09\x0A\x0B\x04\x05\x06\x07\x0C\x0D\x0E\x0F\x10\x11" ++
    "\x12\x13\x18\x19\x1A\x1B\x14\x15\x16\x17\x1C\x1D\x1E\x1F";

const layout8_5 =
    "\x00\x01\x02\x03\x04\x08\x09\x0A\x0B\x0C\x10\x11\x12\x13\x14\x18\x19\x1A" ++
    "\x1B\x1C\x20\x21\x05\x06\x07\x22\x23\x0D\x0E\x0F\x24\x25\x15\x16\x17\x26" ++
    "\x27\x1D\x1E\x1F";

const layout8_6 =
    "\x00\x01\x02\x03\x04\x05\x08\x09\x0A\x0B\x0C\x0D\x10\x11\x12\x13\x14\x15" ++
    "\x16\x17\x0E\x0F\x06\x07\x18\x19\x1A\x1B\x1C\x1D\x20\x21\x22\x23\x24\x25" ++
    "\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x26\x27\x1E\x1F";

const layout8_7 =
    "\x00\x01\x02\x03\x04\x05\x06\x08\x09\x0A\x0B\x0C\x0D\x0E\x10\x11\x12\x13" ++
    "\x14\x15\x16\x18\x19\x1A\x1B\x1C\x1D\x1E\x20\x21\x22\x23\x24\x25\x26\x28" ++
    "\x29\x2A\x2B\x2C\x2D\x2E\x30\x31\x32\x33\x34\x35\x36\x37\x2F\x27\x1F\x17" ++
    "\x0F\x07";

const layout8_8 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11" ++
    "\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23" ++
    "\x24\x25\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x30\x31\x32\x33\x34\x35" ++
    "\x36\x37\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F";

const layout16_1 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F";

const layout16_2 =
    "\x00\x01\x10\x11\x02\x03\x12\x13\x04\x05\x14\x15\x06\x07\x16\x17\x08\x09" ++
    "\x18\x19\x0A\x0B\x1A\x1B\x0C\x0D\x1C\x1D\x0E\x0F\x1E\x1F";

const layout16_3 =
    "\x00\x01\x02\x10\x11\x12\x20\x21\x22\x03\x04\x05\x13\x14\x15\x23\x24\x25" ++
    "\x06\x07\x08\x16\x17\x18\x26\x27\x28\x09\x0A\x0B\x19\x1A\x1B\x29\x2A\x2B" ++
    "\x0C\x0D\x0E\x1C\x1D\x1E\x2C\x2D\x2E\x0F\x1F\x2F";

const layout16_4 =
    "\x00\x01\x02\x03\x10\x11\x12\x13\x04\x05\x06\x07\x14\x15\x16\x17\x08\x09" ++
    "\x0A\x0B\x18\x19\x1A\x1B\x0C\x0D\x0E\x0F\x1C\x1D\x1E\x1F\x20\x21\x22\x23" ++
    "\x30\x31\x32\x33\x24\x25\x26\x27\x34\x35\x36\x37\x28\x29\x2A\x2B\x38\x39" ++
    "\x3A\x3B\x2C\x2D\x2E\x2F\x3C\x3D\x3E\x3F";

const layout16_5 =
    "\x00\x01\x02\x03\x04\x10\x11\x12\x13\x14\x20\x21\x22\x23\x24\x30\x31\x32" ++
    "\x33\x34\x40\x41\x42\x43\x44\x05\x06\x07\x08\x09\x15\x16\x17\x18\x19\x25" ++
    "\x26\x27\x28\x29\x35\x36\x37\x38\x39\x45\x46\x47\x48\x49\x0A\x0B\x0C\x0D" ++
    "\x0E\x1A\x1B\x1C\x1D\x1E\x2A\x2B\x2C\x2D\x2E\x3A\x3B\x3C\x3D\x3E\x4A\x4B" ++
    "\x4C\x4D\x4E\x0F\x1F\x2F\x3F\x4F";

const layout16_6 =
    "\x00\x01\x02\x03\x04\x05\x10\x11\x12\x13\x14\x15\x20\x21\x22\x23\x24\x25" ++
    "\x0C\x0D\x0E\x0F\x1C\x1D\x06\x07\x08\x09\x0A\x0B\x16\x17\x18\x19\x1A\x1B" ++
    "\x26\x27\x28\x29\x2A\x2B\x1E\x1F\x2C\x2D\x2E\x2F\x30\x31\x32\x33\x34\x35" ++
    "\x40\x41\x42\x43\x44\x45\x50\x51\x52\x53\x54\x55\x3C\x3D\x3E\x3F\x4C\x4D" ++
    "\x36\x37\x38\x39\x3A\x3B\x46\x47\x48\x49\x4A\x4B\x56\x57\x58\x59\x5A\x5B" ++
    "\x4E\x4F\x5C\x5D\x5E\x5F";

const layout16_7 =
    "\x00\x01\x02\x03\x04\x05\x06\x10\x11\x12\x13\x14\x15\x16\x20\x21\x22\x23" ++
    "\x24\x25\x26\x30\x31\x32\x33\x34\x35\x36\x40\x41\x42\x43\x44\x45\x46\x50" ++
    "\x51\x52\x53\x54\x55\x56\x60\x61\x62\x63\x64\x65\x66\x0E\x0F\x1E\x1F\x2E" ++
    "\x2F\x3E\x07\x08\x09\x0A\x0B\x0C\x0D\x17\x18\x19\x1A\x1B\x1C\x1D\x27\x28" ++
    "\x29\x2A\x2B\x2C\x2D\x37\x38\x39\x3A\x3B\x3C\x3D\x47\x48\x49\x4A\x4B\x4C" ++
    "\x4D\x57\x58\x59\x5A\x5B\x5C\x5D\x67\x68\x69\x6A\x6B\x6C\x6D\x3F\x4E\x4F" ++
    "\x5E\x5F\x6E\x6F";

const layout16_8 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x10\x11\x12\x13\x14\x15\x16\x17\x08\x09" ++
    "\x0A\x0B\x0C\x0D\x0E\x0F\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23" ++
    "\x24\x25\x26\x27\x30\x31\x32\x33\x34\x35\x36\x37\x28\x29\x2A\x2B\x2C\x2D" ++
    "\x2E\x2F\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\x40\x41\x42\x43\x44\x45\x46\x47" ++
    "\x50\x51\x52\x53\x54\x55\x56\x57\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\x58\x59" ++
    "\x5A\x5B\x5C\x5D\x5E\x5F\x60\x61\x62\x63\x64\x65\x66\x67\x70\x71\x72\x73" ++
    "\x74\x75\x76\x77\x68\x69\x6A\x6B\x6C\x6D\x6E\x6F\x78\x79\x7A\x7B\x7C\x7D" ++
    "\x7E\x7F";

const layout16_9 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x10\x11\x12\x13\x14\x15\x16\x17\x18" ++
    "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x30\x31\x32\x33\x34\x35\x36\x37\x38" ++
    "\x40\x41\x42\x43\x44\x45\x46\x47\x48\x50\x51\x52\x53\x54\x55\x56\x57\x58" ++
    "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x70\x71\x72\x73\x74\x75\x76\x77\x78" ++
    "\x09\x0A\x0B\x0C\x0D\x0E\x0F\x80\x81\x19\x1A\x1B\x1C\x1D\x1E\x1F\x82\x83" ++
    "\x29\x2A\x2B\x2C\x2D\x2E\x2F\x84\x85\x39\x3A\x3B\x3C\x3D\x3E\x3F\x86\x87" ++
    "\x49\x4A\x4B\x4C\x4D\x4E\x4F\x88\x89\x59\x5A\x5B\x5C\x5D\x5E\x5F\x8A\x8B" ++
    "\x69\x6A\x6B\x6C\x6D\x6E\x6F\x8C\x8D\x79\x7A\x7B\x7C\x7D\x7E\x7F\x8E\x8F";

const layout16_10 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x10\x11\x12\x13\x14\x15\x16\x17" ++
    "\x18\x19\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x30\x31\x32\x33\x34\x35" ++
    "\x36\x37\x38\x39\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x50\x51\x52\x53" ++
    "\x54\x55\x56\x57\x58\x59\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x70\x71" ++
    "\x72\x73\x74\x75\x76\x77\x78\x79\x0A\x0B\x0C\x0D\x0E\x0F\x80\x81\x82\x83" ++
    "\x1A\x1B\x1C\x1D\x1E\x1F\x84\x85\x86\x87\x2A\x2B\x2C\x2D\x2E\x2F\x88\x89" ++
    "\x8A\x8B\x3A\x3B\x3C\x3D\x3E\x3F\x8C\x8D\x8E\x8F\x4A\x4B\x4C\x4D\x4E\x4F" ++
    "\x90\x91\x92\x93\x5A\x5B\x5C\x5D\x5E\x5F\x94\x95\x96\x97\x6A\x6B\x6C\x6D" ++
    "\x6E\x6F\x98\x99\x9A\x9B\x7A\x7B\x7C\x7D\x7E\x7F\x9C\x9D\x9E\x9F";

const layout16_11 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x80\x81\x82\x08\x09\x0A\x0B\x0C\x0D\x0E" ++
    "\x0F\x90\x91\x92\x10\x11\x12\x13\x14\x15\x16\x17\xA0\xA1\xA2\x18\x19\x1A" ++
    "\x1B\x1C\x1D\x1E\x1F\x83\x84\x85\x20\x21\x22\x23\x24\x25\x26\x27\x93\x94" ++
    "\x95\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\xA3\xA4\xA5\x30\x31\x32\x33\x34\x35" ++
    "\x36\x37\x86\x87\x88\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\x96\x97\x98\x40\x41" ++
    "\x42\x43\x44\x45\x46\x47\xA6\xA7\xA8\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\x89" ++
    "\x8A\x8B\x50\x51\x52\x53\x54\x55\x56\x57\x99\x9A\x9B\x58\x59\x5A\x5B\x5C" ++
    "\x5D\x5E\x5F\xA9\xAA\xAB\x60\x61\x62\x63\x64\x65\x66\x67\x8C\x8D\x8E\x68" ++
    "\x69\x6A\x6B\x6C\x6D\x6E\x6F\x9C\x9D\x9E\x70\x71\x72\x73\x74\x75\x76\x77" ++
    "\xAC\xAD\xAE\x78\x79\x7A\x7B\x7C\x7D\x7E\x7F\x8F\x9F\xAF";

const layout16_12 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x10\x11\x12\x13\x14\x15" ++
    "\x16\x17\x18\x19\x1A\x1B\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2A\x2B" ++
    "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3A\x3B\x40\x41\x42\x43\x44\x45" ++
    "\x46\x47\x48\x49\x4A\x4B\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5A\x5B" ++
    "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6A\x6B\x70\x71\x72\x73\x74\x75" ++
    "\x76\x77\x78\x79\x7A\x7B\x0C\x0D\x0E\x0F\x80\x81\x82\x83\x84\x85\x86\x87" ++
    "\x1C\x1D\x1E\x1F\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F\x2C\x2D\x2E\x2F\x90\x91" ++
    "\x92\x93\x94\x95\x96\x97\x3C\x3D\x3E\x3F\x98\x99\x9A\x9B\x9C\x9D\x9E\x9F" ++
    "\x4C\x4D\x4E\x4F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\x5C\x5D\x5E\x5F\xA8\xA9" ++
    "\xAA\xAB\xAC\xAD\xAE\xAF\x6C\x6D\x6E\x6F\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7" ++
    "\x7C\x7D\x7E\x7F\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF";

const layout16_13 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x80\x81\x82\x83\x84\x08\x09\x0A\x0B\x0C" ++
    "\x0D\x0E\x0F\x90\x91\x92\x93\x94\x10\x11\x12\x13\x14\x15\x16\x17\xA0\xA1" ++
    "\xA2\xA3\xA4\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\xB0\xB1\xB2\xB3\xB4\x20\x21" ++
    "\x22\x23\x24\x25\x26\x27\xC0\xC1\xC2\xC3\xC4\x28\x29\x2A\x2B\x2C\x2D\x2E" ++
    "\x2F\x85\x86\x87\x88\x89\x30\x31\x32\x33\x34\x35\x36\x37\x95\x96\x97\x98" ++
    "\x99\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\xA5\xA6\xA7\xA8\xA9\x40\x41\x42\x43" ++
    "\x44\x45\x46\x47\xB5\xB6\xB7\xB8\xB9\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\xC5" ++
    "\xC6\xC7\xC8\xC9\x50\x51\x52\x53\x54\x55\x56\x57\x8A\x8B\x8C\x8D\x8E\x58" ++
    "\x59\x5A\x5B\x5C\x5D\x5E\x5F\x9A\x9B\x9C\x9D\x9E\x60\x61\x62\x63\x64\x65" ++
    "\x66\x67\xAA\xAB\xAC\xAD\xAE\x68\x69\x6A\x6B\x6C\x6D\x6E\x6F\xBA\xBB\xBC" ++
    "\xBD\xBE\x70\x71\x72\x73\x74\x75\x76\x77\xCA\xCB\xCC\xCD\xCE\x78\x79\x7A" ++
    "\x7B\x7C\x7D\x7E\x7F\x8F\x9F\xAF\xBF\xCF";

const layout16_14 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x10\x11\x12\x13" ++
    "\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x20\x21\x22\x23\x24\x25\x26\x27" ++
    "\x28\x29\x2A\x2B\x2C\x2D\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3A\x3B" ++
    "\x3C\x3D\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4A\x4B\x4C\x4D\x50\x51" ++
    "\x52\x53\x54\x55\x56\x57\x58\x59\x5A\x5B\x5C\x5D\x60\x61\x62\x63\x64\x65" ++
    "\x66\x67\x68\x69\x6A\x6B\x6C\x6D\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79" ++
    "\x7A\x7B\x7C\x7D\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D" ++
    "\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9D\xA0\xA1\xA2\xA3" ++
    "\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7" ++
    "\xB8\xB9\xBA\xBB\xBC\xBD\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB" ++
    "\xCC\xCD\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\x0E\x0F" ++
    "\x1E\x1F\x2E\x2F\x3E\x3F\x4E\x4F\x5E\x5F\x6E\x6F\x7E\x7F\x8E\x8F\x9E\x9F" ++
    "\xAE\xAF\xBE\xBF\xCE\xCF\xDE\xDF";

const layout16_15 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x10\x11\x12" ++
    "\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x20\x21\x22\x23\x24\x25" ++
    "\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x30\x31\x32\x33\x34\x35\x36\x37\x38" ++
    "\x39\x3A\x3B\x3C\x3D\x3E\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4A\x4B" ++
    "\x4C\x4D\x4E\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5A\x5B\x5C\x5D\x5E" ++
    "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6A\x6B\x6C\x6D\x6E\x70\x71\x72" ++
    "\x73\x74\x75\x76\x77\x78\x79\x7A\x7B\x7C\x7D\x7E\x80\x81\x82\x83\x84\x85" ++
    "\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x90\x91\x92\x93\x94\x95\x96\x97\x98" ++
    "\x99\x9A\x9B\x9C\x9D\x9E\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB" ++
    "\xAC\xAD\xAE\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE" ++
    "\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xD0\xD1\xD2" ++
    "\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xE0\xE1\xE2\xE3\xE4\xE5" ++
    "\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\x0F\x1F\x2F\x3F\x4F\x5F\x6F\x7F\x8F" ++
    "\x9F\xAF\xBF\xCF\xDF\xEF";

const layout16_16 =
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11" ++
    "\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23" ++
    "\x24\x25\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x30\x31\x32\x33\x34\x35" ++
    "\x36\x37\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\x40\x41\x42\x43\x44\x45\x46\x47" ++
    "\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59" ++
    "\x5A\x5B\x5C\x5D\x5E\x5F\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6A\x6B" ++
    "\x6C\x6D\x6E\x6F\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7A\x7B\x7C\x7D" ++
    "\x7E\x7F\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F" ++
    "\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9D\x9E\x9F\xA0\xA1" ++
    "\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3" ++
    "\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5" ++
    "\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7" ++
    "\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9" ++
    "\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFB" ++
    "\xFC\xFD\xFE\xFF";

fn specializedLayout(comptime T: type, comptime bits: usize) []const u8 {
    if (T == u8) return switch (bits) {
        1 => layout8_1,
        2 => layout8_2,
        3 => layout8_3,
        4 => layout8_4,
        5 => layout8_5,
        6 => layout8_6,
        7 => layout8_7,
        8 => layout8_8,
        else => unreachable,
    };
    if (T == u16) return switch (bits) {
        1 => layout16_1,
        2 => layout16_2,
        3 => layout16_3,
        4 => layout16_4,
        5 => layout16_5,
        6 => layout16_6,
        7 => layout16_7,
        8 => layout16_8,
        9 => layout16_9,
        10 => layout16_10,
        11 => layout16_11,
        12 => layout16_12,
        13 => layout16_13,
        14 => layout16_14,
        15 => layout16_15,
        16 => layout16_16,
        else => unreachable,
    };
    unreachable;
}

fn packBlock(
    comptime D: type,
    comptime bits: usize,
    raw: []const D.Lane,
    packed_output: []D.Lane,
    frame: D.Lane,
    comptime packing_type: BlockPackingType,
) void {
    validateBits(D.Lane, bits);
    const lane_bits = @bitSizeOf(D.Lane);
    const raw_count = lane_bits * D.lane_count;
    const packed_count = bits * D.lane_count;
    std.debug.assert(raw.len >= raw_count);
    std.debug.assert(packed_output.len >= packed_count);
    if (D.Lane == u8 or D.Lane == u16) {
        packSpecialized(D, bits, raw, packed_output, frame, packing_type);
        return;
    }
    @memset(packed_output[0..packed_count], 0);
    const value_mask = mask(D.Lane, bits);

    var raw_position: usize = 0;
    while (raw_position < lane_bits) : (raw_position += 1) {
        const bit_position = raw_position * bits;
        const packed_position = bit_position / lane_bits;
        const shift = bit_position % lane_bits;
        var lane_index: usize = 0;
        while (lane_index < D.lane_count) : (lane_index += 1) {
            const raw_value = raw[raw_position * D.lane_count + lane_index];
            const delta = if (packing_type == .frame_of_reference)
                raw_value -% frame
            else
                raw_value;
            const value = delta & value_mask;
            packed_output[packed_position * D.lane_count + lane_index] |= value << @intCast(shift);
            if (shift + bits > lane_bits) {
                packed_output[(packed_position + 1) * D.lane_count + lane_index] |=
                    value >> @intCast(lane_bits - shift);
            }
        }
    }
}

fn unpackBlock(
    comptime D: type,
    comptime bits: usize,
    packed_input: []const D.Lane,
    raw: []D.Lane,
    frame: D.Lane,
    comptime packing_type: BlockPackingType,
) void {
    validateBits(D.Lane, bits);
    const lane_bits = @bitSizeOf(D.Lane);
    const raw_count = lane_bits * D.lane_count;
    const packed_count = bits * D.lane_count;
    std.debug.assert(packed_input.len >= packed_count);
    std.debug.assert(raw.len >= raw_count);
    if (D.Lane == u8 or D.Lane == u16) {
        unpackSpecialized(D, bits, packed_input, raw, frame, packing_type);
        return;
    }
    const value_mask = mask(D.Lane, bits);

    var raw_position: usize = 0;
    while (raw_position < lane_bits) : (raw_position += 1) {
        const bit_position = raw_position * bits;
        const packed_position = bit_position / lane_bits;
        const shift = bit_position % lane_bits;
        var lane_index: usize = 0;
        while (lane_index < D.lane_count) : (lane_index += 1) {
            var value = packed_input[packed_position * D.lane_count + lane_index] >>
                @intCast(shift);
            if (shift + bits > lane_bits) {
                value |= packed_input[(packed_position + 1) * D.lane_count + lane_index] <<
                    @intCast(lane_bits - shift);
            }
            value &= value_mask;
            raw[raw_position * D.lane_count + lane_index] = if (packing_type == .frame_of_reference)
                value +% frame
            else
                value;
        }
    }
}

fn packSpecialized(
    comptime D: type,
    comptime bits: usize,
    raw: []const D.Lane,
    packed_output: []D.Lane,
    frame: D.Lane,
    comptime packing_type: BlockPackingType,
) void {
    const lane_bits = @bitSizeOf(D.Lane);
    const layout = comptime specializedLayout(D.Lane, bits);
    const one: D.Vector = @splat(1);
    const frame_vector: D.Vector = @splat(frame);
    var packed_vectors: [bits]D.Vector = undefined;
    inline for (0..bits) |packed_position| packed_vectors[packed_position] = @splat(0);
    inline for (0..lane_bits) |raw_position| {
        const loaded = memory.load(D, raw[raw_position * D.lane_count ..]);
        const value = if (packing_type == .frame_of_reference) loaded -% frame_vector else loaded;
        inline for (0..bits) |raw_bit| {
            const target = comptime layout[raw_position * bits + raw_bit];
            const packed_position = target / lane_bits;
            const packed_bit = target % lane_bits;
            const source_bit = shifts.shiftRight(D, raw_bit, value) & one;
            packed_vectors[packed_position] |= shifts.shiftLeft(D, packed_bit, source_bit);
        }
    }
    inline for (0..bits) |packed_position| {
        memory.store(
            D,
            packed_vectors[packed_position],
            packed_output[packed_position * D.lane_count ..],
        );
    }
}

fn unpackSpecialized(
    comptime D: type,
    comptime bits: usize,
    packed_input: []const D.Lane,
    raw: []D.Lane,
    frame: D.Lane,
    comptime packing_type: BlockPackingType,
) void {
    const lane_bits = @bitSizeOf(D.Lane);
    const layout = comptime specializedLayout(D.Lane, bits);
    const one: D.Vector = @splat(1);
    const frame_vector: D.Vector = @splat(frame);
    var packed_vectors: [bits]D.Vector = undefined;
    inline for (0..bits) |packed_position| {
        packed_vectors[packed_position] = memory.load(
            D,
            packed_input[packed_position * D.lane_count ..],
        );
    }
    inline for (0..lane_bits) |raw_position| {
        var value: D.Vector = @splat(0);
        inline for (0..bits) |raw_bit| {
            const target = comptime layout[raw_position * bits + raw_bit];
            const packed_position = target / lane_bits;
            const packed_bit = target % lane_bits;
            const source_bit = shifts.shiftRight(
                D,
                packed_bit,
                packed_vectors[packed_position],
            ) & one;
            value |= shifts.shiftLeft(D, raw_bit, source_bit);
        }
        if (packing_type == .frame_of_reference) value +%= frame_vector;
        memory.store(D, value, raw[raw_position * D.lane_count ..]);
    }
}

fn mask(comptime T: type, comptime bits: usize) T {
    return if (bits == @bitSizeOf(T))
        std.math.maxInt(T)
    else
        (@as(T, 1) << @intCast(bits)) - 1;
}

fn validateBits(comptime T: type, comptime bits: usize) void {
    if (T != u8 and T != u16 and T != u32 and T != u64) {
        @compileError("bit packing requires unsigned 8/16/32/64-bit lanes");
    }
    if (bits == 0 or bits > @bitSizeOf(T)) {
        @compileError("bit width must be between one and the lane width");
    }
}

fn requireFrameLane(comptime T: type) void {
    if (T != u32 and T != u64) {
        @compileError("frame-of-reference packing requires u32 or u64 lanes");
    }
}

fn requireTag(comptime D: type, comptime T: type) void {
    if (D.Lane != T) @compileError("packer lane type does not match the SIMD descriptor");
}

const oracle_hash_u8 = [_]u64{
    0x445918642857068F, 0xA2E4FE0A8A14645B, 0x952FDA26DE4D792F, 0xB7BF9F362C0CC2B3,
    0x888934B9B5BC81FF, 0xDF7BF05E7FDCE12B, 0x344B817F42FBD8FF, 0x588B57EFBE2BAE23,
};

const oracle_hash_u16 = [_]u64{
    0x412F38E60A3CD08F, 0xEF96D0ABD29EC45B, 0x627759D35900D62F, 0xFA781CA1B06284B3,
    0xBD4F00CB3F53D547, 0x98A63232BE8E75AB, 0xA903B5A48D192C7F, 0xA230A9F866EE8BE3,
    0x018616763CCB1757, 0xEACDF92E97167616, 0x06AC8D9059C57FB8, 0xB86437886F0F9903,
    0x67977F03A663B6F1, 0x5647B715CFAFCAAB, 0x69A4F125B793851F, 0x4B37C2B78CCFC343,
};

const oracle_hash_u32 = [_]u64{
    0xB3354FB2D7F2D08F, 0x42F087AE2A9CC45B, 0x5972FCB2F9794613, 0xED03FC46532B8AB3,
    0x84A0BFE381C2F757, 0xF018D415C434DB43, 0x2443042D91E8E0B3, 0x6D41781B4610E063,
    0x9BE0E3E300DD518E, 0xA613F8C73B542DB2, 0xF8AEF7BBAE35BEE9, 0x8F92C8F960FA27A9,
    0x60A6BDEF4DE3FA67, 0x667E2E78D4CADAB1, 0xD8498FA419F8BF52, 0xC559A5FE19F318C3,
    0x8F8EA26B41F6016B, 0x88E6559D50D10263, 0x8EFBC2B179E4694D, 0xF83B77CDF5854777,
    0x4B83773A8F52DE0D, 0x682957C60438F230, 0x60353F206E4FFE71, 0xB20962337FD39C41,
    0x0673EB84C964F944, 0xA3CFBEBF7C61193D, 0x3A4F9B326F105DD9, 0xF4EB6C89143E37C8,
    0x38F4AB6AD8D682F1, 0xF324F956F06F8E01, 0xB992364C045D5303, 0x3FDA92E7E83F9F03,
};

const oracle_hash_u64 = [_]u64{
    0xC8A8DCA8D7F2D08F, 0x08E2700E2A9CC45B, 0x37EABE436B850113, 0x79F5332A532B8AB3,
    0xDB591C66FD7121F7, 0x94E4C2AE06E22A93, 0x14210EB8EFF3E75B, 0xEFC6FF814A51DFE3,
    0xDA72BC45D3E32E94, 0xF5AA2A9F19B60B3C, 0x2B181B3B80DBBAA2, 0xE63B8A505E8A3462,
    0x44201D6A24AAE5B7, 0x2CF59E306D441E61, 0x94D9A488800573CD, 0xFF891666E4767643,
    0x04168531C674F955, 0x7D27C1DB1380D32F, 0x0CCAC46C02118B7F, 0xD60AFE3159F79979,
    0x99F8EE3C99B6BD2F, 0x649BEC6B0E0136FE, 0x9CECEEA047198D7F, 0x86A2E33909530A0A,
    0xB2865857B6E3EEEB, 0x165969A6F121AC62, 0x5511C1396CE42712, 0x694E2CCA74020E5A,
    0x544456B8F9B097F4, 0x9DB5804D02E2CA3D, 0x83D888FE728BEDD6, 0xE4B8A887810A4503,
    0xFFC2C812130D501C, 0x0ED2A63580423C5C, 0x54E3235B193C65F9, 0x2B37B16E74E37DF8,
    0xAAB1D0697C96DC1A, 0x83D31DFEE1812CB8, 0xE6949409F6ED05D7, 0xAB437BF1CBDE0730,
    0x6C8955286D33AFF4, 0x6E097DF511FA164D, 0x038FCCD2E9080CE9, 0xBF7E70C7ECB2908F,
    0x993D69BA5CC7E02D, 0xA80588E548FA85AD, 0xE6D63E9C95655C29, 0xCD938593440CA85F,
    0xBB6E36D2BAE57E0C, 0x10D328E57C2058F3, 0x306B03883B04466D, 0x8907055B3577A03C,
    0xF3A6156D447F76B5, 0x477FF22DD2B46117, 0x3DE2513B9F77B864, 0x0669522BED043B13,
    0x772E5DB310C890B4, 0x567A883C61807F42, 0x8A7252BA46FD7A70, 0xD45002AE6C337D49,
    0x13EDD158B3AD5098, 0x9E693F0D7EE3B312, 0x9CFB0C5BAA6CE324, 0xE867F97A86993A83,
};

fn hashPacked(comptime T: type, values: []const T) u64 {
    var hash: u64 = 1469598103934665603;
    for (values) |value| {
        hash ^= @as(u64, value);
        hash *%= 1099511628211;
    }
    return hash;
}

fn verifyOracleHash(comptime T: type, comptime bits: usize, expected: u64) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const lane_bits = @bitSizeOf(T);
    const raw_count = lane_bits * D.lane_count;
    const packed_count = bits * D.lane_count;
    const value_mask = mask(T, bits);
    var raw: [raw_count]T = undefined;
    var packed_values: [packed_count]T = undefined;
    for (&raw, 0..) |*value, index| {
        const i: u64 = @intCast(index);
        const mixed = (i *% 0x9E37_79B9_7F4A_7C15) ^
            ((i +% 0x51) *% 0xD1B5_4A32_D192_ED03);
        value.* = @as(T, @truncate(mixed)) & value_mask;
    }
    const P = switch (T) {
        u8 => Pack8(bits),
        u16 => Pack16(bits),
        u32 => Pack32(bits),
        u64 => Pack64(bits),
        else => unreachable,
    };
    (P{}).pack(D, &raw, &packed_values);
    try std.testing.expectEqual(expected, hashPacked(T, &packed_values));
    if (T == u32 or T == u64) {
        const frame: T = @truncate(0x1020_3040_5060_7080);
        for (&raw, 0..) |*value, index| {
            const i: u64 = @intCast(index);
            const mixed = (i *% 0x9E37_79B9_7F4A_7C15) ^
                ((i +% 0x51) *% 0xD1B5_4A32_D192_ED03);
            value.* = frame +% (@as(T, @truncate(mixed)) & value_mask);
        }
        (P{}).packFrame(D, &raw, &packed_values, frame);
        try std.testing.expectEqual(expected, hashPacked(T, &packed_values));
    }
}

fn verifyRoundTrip(comptime T: type, comptime bits: usize) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const lane_bits = @bitSizeOf(T);
    const raw_count = lane_bits * D.lane_count;
    const packed_count = bits * D.lane_count;
    const value_mask = mask(T, bits);
    var raw: [raw_count]T = undefined;
    var restored: [raw_count]T = undefined;
    var packed_values: [packed_count]T = undefined;
    for (&raw, 0..) |*value, index| {
        const mixed = @as(T, @truncate(index *% 0x9e37 +% 0x51)) ^
            @as(T, @truncate(index >> 1));
        value.* = mixed & value_mask;
    }

    const P = switch (T) {
        u8 => Pack8(bits),
        u16 => Pack16(bits),
        u32 => Pack32(bits),
        u64 => Pack64(bits),
        else => unreachable,
    };
    (P{}).pack(D, &raw, &packed_values);
    (P{}).unpack(D, &packed_values, &restored);
    try std.testing.expectEqualSlices(T, &raw, &restored);
}

fn verifyFrameRoundTrip(comptime T: type, comptime bits: usize) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const lane_bits = @bitSizeOf(T);
    const raw_count = lane_bits * D.lane_count;
    const packed_count = bits * D.lane_count;
    const value_mask = mask(T, bits);
    const frame: T = 0x1020_3040;
    var raw: [raw_count]T = undefined;
    var restored: [raw_count]T = undefined;
    var packed_values: [packed_count]T = undefined;
    for (&raw, 0..) |*value, index| {
        const delta = (@as(T, @truncate(index *% 0x9e37 +% 0x51))) & value_mask;
        value.* = frame +% delta;
    }

    const P = if (T == u32) Pack32(bits) else Pack64(bits);
    (P{}).packFrame(D, &raw, &packed_values, frame);
    (P{}).unpackFrame(D, &packed_values, &restored, frame);
    try std.testing.expectEqualSlices(T, &raw, &restored);
}

test "Highway bit pack round trips every Pack8 and Pack16 width" {
    inline for (1..9) |bits| try verifyRoundTrip(u8, bits);
    inline for (1..17) |bits| try verifyRoundTrip(u16, bits);
}

test "Highway bit pack round trips every Pack32 and Pack64 width" {
    inline for (1..33) |bits| try verifyRoundTrip(u32, bits);
    inline for (1..65) |bits| try verifyRoundTrip(u64, bits);
}

test "Highway frame-of-reference packing round trips every wide width" {
    inline for (1..33) |bits| try verifyFrameRoundTrip(u32, bits);
    inline for (1..65) |bits| try verifyFrameRoundTrip(u64, bits);
}

test "Highway packed output matches the pinned implementation at every width" {
    inline for (1..9) |bits| try verifyOracleHash(u8, bits, oracle_hash_u8[bits - 1]);
    inline for (1..17) |bits| try verifyOracleHash(u16, bits, oracle_hash_u16[bits - 1]);
    inline for (1..33) |bits| try verifyOracleHash(u32, bits, oracle_hash_u32[bits - 1]);
    inline for (1..65) |bits| try verifyOracleHash(u64, bits, oracle_hash_u64[bits - 1]);
}

test "Highway specialized layouts are complete bit permutations" {
    inline for (.{ u8, u16 }) |T| {
        inline for (1..@bitSizeOf(T) + 1) |bits| {
            const layout = specializedLayout(T, bits);
            var seen: [@bitSizeOf(T) * bits]bool = @splat(false);
            for (layout) |target| {
                try std.testing.expect(target < seen.len);
                try std.testing.expect(!seen[target]);
                seen[target] = true;
            }
            for (seen) |present| try std.testing.expect(present);
        }
    }
}

test "Highway Pack8 layout matches the pinned implementation" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u8, 4);
    var raw: [8 * D.lane_count]u8 = undefined;
    for (0..8) |position| {
        for (0..D.lane_count) |lane_index| {
            raw[position * D.lane_count + lane_index] = @truncate((position + lane_index) & 7);
        }
    }
    var packed_values: [3 * D.lane_count]u8 = undefined;
    (Pack8(3){}).pack(D, &raw, &packed_values);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0x29, 0x32, 0x7B }, packed_values[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xA9, 0x72, 0xFB, 0x44 }, packed_values[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xF2, 0x3B, 0x44, 0x8D }, packed_values[8..12]);
}
