pub export fn tiny_alloc_no_dependence_exercise(value: u8) callconv(.c) u8 {
    return value ^ 0x5a;
}
