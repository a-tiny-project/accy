export var tldr_macho_probe_data: u64 = 7;

extern fn tldr_macho_probe_external(value: u64) callconv(.c) u64;

export fn tldr_macho_probe_call(value: u64) callconv(.c) u64 {
    return tldr_macho_probe_external(value) + tldr_macho_probe_data;
}
