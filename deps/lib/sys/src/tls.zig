const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const fd = @import("fd.zig");
const linux = @import("linux.zig");
const time = @import("time.zig");

const posix = std.posix;
const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

pub const required_capabilities = capabilities.noLibc(&.{ .descriptors, .filesystem, .random, .time, .tls });

pub const Client = std.crypto.tls.Client;
pub const Certificate = std.crypto.Certificate;
pub const Bundle = Certificate.Bundle;
pub const BundleLock = std.Io.RwLock;
pub const Authority = @FieldType(Client.Options, "ca");

pub const EntropyError = error{Unavailable};

const BundleLocalError = error{
    Unavailable,
    FileNotFound,
    CertificateAuthorityBundleTooBig,
    MissingEndCertificateMarker,
};

pub const BundleError =
    BundleLocalError ||
    std.mem.Allocator.Error ||
    std.base64.Error ||
    Bundle.ParseCertError;

const certificate_bundle_max_bytes = 16 * 1024 * 1024;

pub fn bundleAuthority(allocator: std.mem.Allocator, lock: *BundleLock, bundle: *Bundle) Authority {
    return .{ .bundle = .{
        .gpa = allocator,
        .io = std.Options.debug_io,
        .lock = lock,
        .bundle = bundle,
    } };
}

pub fn fillEntropy(buffer: []u8) EntropyError!void {
    switch (builtin.os.tag) {
        .linux => return fillLinuxEntropy(buffer),
        else => {
            std.Options.debug_io.random(buffer);
            return;
        },
    }
}

pub fn realtimeNow() std.Io.Timestamp {
    const nanoseconds = time.realNanoseconds() orelse
        return std.Io.Clock.real.now(std.Options.debug_io);
    return std.Io.Timestamp.fromNanoseconds(std.math.cast(i96, nanoseconds) orelse saturatedNanoseconds(nanoseconds));
}

pub fn loadSystemBundle(bundle: *Bundle, allocator: std.mem.Allocator) BundleError!void {
    switch (builtin.os.tag) {
        .linux => return loadLinuxSystemBundle(bundle, allocator),
        else => {
            bundle.rescan(allocator, std.Options.debug_io, realtimeNow()) catch return error.Unavailable;
            return;
        },
    }
}

fn fillLinuxEntropy(buffer: []u8) EntropyError!void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const rc = linux.getRandom(buffer[filled..]);
        switch (linux.errno(rc)) {
            .success => {
                if (rc == 0) return error.Unavailable;
                filled += rc;
            },
            .intr => {},
            else => return error.Unavailable,
        }
    }
}

fn saturatedNanoseconds(nanoseconds: i128) i96 {
    if (nanoseconds < 0) return std.math.minInt(i96);
    return std.math.maxInt(i96);
}

fn loadLinuxSystemBundle(bundle: *Bundle, allocator: std.mem.Allocator) BundleError!void {
    const cert_file_paths = [_][]const u8{
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/pki/tls/cacert.pem",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        "/etc/ssl/cert.pem",
    };

    bundle.bytes.clearRetainingCapacity();
    bundle.map.clearRetainingCapacity();

    const now = realtimeNow().toSeconds();
    for (cert_file_paths) |path| {
        loadBundleFromPath(bundle, allocator, path, now) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
        bundle.bytes.shrinkAndFree(allocator, bundle.bytes.items.len);
        return;
    }

    return error.FileNotFound;
}

fn loadBundleFromPath(bundle: *Bundle, allocator: std.mem.Allocator, path: []const u8, now_seconds: i64) BundleError!void {
    const pem = try readFileAlloc(allocator, path);
    defer allocator.free(pem);
    try loadBundleFromPem(bundle, allocator, pem, now_seconds);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) BundleError![]u8 {
    const descriptor = posix.openat(posix.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Unavailable,
    };
    defer fd.close(descriptor);

    var bytes = std.ArrayListUnmanaged(u8).empty;
    errdefer bytes.deinit(allocator);

    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = fd.read(descriptor, &buffer) catch return error.Unavailable;
        if (count == 0) break;
        if (bytes.items.len + count > certificate_bundle_max_bytes) return error.CertificateAuthorityBundleTooBig;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }

    return bytes.toOwnedSlice(allocator);
}

fn loadBundleFromPem(bundle: *Bundle, allocator: std.mem.Allocator, pem: []const u8, now_seconds: i64) BundleError!void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;
        const encoded_cert = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        const decoded_size_upper_bound = encoded_cert.len / 4 * 3 + 3;
        const needed_capacity = std.math.cast(u32, decoded_size_upper_bound) orelse
            return error.CertificateAuthorityBundleTooBig;
        try bundle.bytes.ensureUnusedCapacity(allocator, needed_capacity);
        const dest = bundle.bytes.allocatedSlice()[decoded_start..][0..decoded_size_upper_bound];
        bundle.bytes.items.len += try base64.decode(dest, encoded_cert);
        try bundle.parseCert(allocator, decoded_start, now_seconds);
    }
}

test "TLS entropy source fills caller buffer" {
    var entropy: [Client.Options.entropy_len]u8 = undefined;
    try fillEntropy(&entropy);
}

test "system certificate bundle loader is callable" {
    var bundle: Bundle = .empty;
    defer bundle.deinit(std.testing.allocator);

    loadSystemBundle(&bundle, std.testing.allocator) catch |err| switch (err) {
        error.FileNotFound, error.Unavailable => return error.SkipZigTest,
        else => |other| return other,
    };
    try std.testing.expect(bundle.bytes.items.len != 0);
}
