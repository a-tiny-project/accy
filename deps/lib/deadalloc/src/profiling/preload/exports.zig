const abi = @import("abi.zig");

comptime {
    @export(&abi.malloc, .{ .name = "malloc" });
    @export(&abi.free, .{ .name = "free" });
    @export(&abi.calloc, .{ .name = "calloc" });
    @export(&abi.__libc_malloc, .{ .name = "__libc_malloc" });
    @export(&abi.__libc_calloc, .{ .name = "__libc_calloc" });
    @export(&abi.__libc_free, .{ .name = "__libc_free" });
    @export(&abi.cfree, .{ .name = "cfree" });
    @export(&abi.realloc, .{ .name = "realloc" });
    @export(&abi.reallocarray, .{ .name = "reallocarray" });
    @export(&abi.aligned_alloc, .{ .name = "aligned_alloc" });
    @export(&abi.posix_memalign, .{ .name = "posix_memalign" });
    @export(&abi.memalign, .{ .name = "memalign" });
    @export(&abi.__libc_memalign, .{ .name = "__libc_memalign" });
    @export(&abi.valloc, .{ .name = "valloc" });
    @export(&abi.pvalloc, .{ .name = "pvalloc" });
    @export(&abi.__libc_realloc, .{ .name = "__libc_realloc" });
    @export(&abi.malloc_usable_size, .{ .name = "malloc_usable_size" });
    @export(&abi.mallopt, .{ .name = "mallopt" });
    @export(&abi.strdup, .{ .name = "strdup" });
    @export(&abi.strndup, .{ .name = "strndup" });
    @export(&abi._Znwm, .{ .name = "_Znwm" });
    @export(&abi._Znam, .{ .name = "_Znam" });
    @export(&abi._ZnwmRKSt9nothrow_t, .{ .name = "_ZnwmRKSt9nothrow_t" });
    @export(&abi._ZnamRKSt9nothrow_t, .{ .name = "_ZnamRKSt9nothrow_t" });
    @export(&abi._ZnwmSt11align_val_t, .{ .name = "_ZnwmSt11align_val_t" });
    @export(&abi._ZnamSt11align_val_t, .{ .name = "_ZnamSt11align_val_t" });
    @export(&abi._ZnwmSt11align_val_tRKSt9nothrow_t, .{
        .name = "_ZnwmSt11align_val_tRKSt9nothrow_t",
    });
    @export(&abi._ZnamSt11align_val_tRKSt9nothrow_t, .{
        .name = "_ZnamSt11align_val_tRKSt9nothrow_t",
    });
    @export(&abi._ZdlPv, .{ .name = "_ZdlPv" });
    @export(&abi._ZdaPv, .{ .name = "_ZdaPv" });
    @export(&abi._ZdlPvm, .{ .name = "_ZdlPvm" });
    @export(&abi._ZdaPvm, .{ .name = "_ZdaPvm" });
    @export(&abi._ZdlPvSt11align_val_t, .{ .name = "_ZdlPvSt11align_val_t" });
    @export(&abi._ZdaPvSt11align_val_t, .{ .name = "_ZdaPvSt11align_val_t" });
    @export(&abi._ZdlPvmSt11align_val_t, .{ .name = "_ZdlPvmSt11align_val_t" });
    @export(&abi._ZdaPvmSt11align_val_t, .{ .name = "_ZdaPvmSt11align_val_t" });
    @export(&abi._ZdlPvSt11align_val_tRKSt9nothrow_t, .{
        .name = "_ZdlPvSt11align_val_tRKSt9nothrow_t",
    });
    @export(&abi._ZdaPvSt11align_val_tRKSt9nothrow_t, .{
        .name = "_ZdaPvSt11align_val_tRKSt9nothrow_t",
    });
}

test {
    _ = abi;
}
