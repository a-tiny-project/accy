/// One invocation increments a device counter and writes its previous value
/// at that index. The output witnesses order within and across replays.
pub const ptx =
    \\.version 6.0
    \\.target sm_52
    \\.address_size 64
    \\.visible .entry sequence_counter(.param .u64 counter, .param .u64 output)
    \\{
    \\    .reg .b32 %r<3>;
    \\    .reg .b64 %rd<7>;
    \\    ld.param.u64 %rd1, [counter];
    \\    ld.param.u64 %rd2, [output];
    \\    cvta.to.global.u64 %rd3, %rd1;
    \\    cvta.to.global.u64 %rd4, %rd2;
    \\    ld.global.u32 %r1, [%rd3];
    \\    mul.wide.u32 %rd5, %r1, 4;
    \\    add.u64 %rd6, %rd4, %rd5;
    \\    st.global.u32 [%rd6], %r1;
    \\    add.u32 %r2, %r1, 1;
    \\    st.global.u32 [%rd3], %r2;
    \\    ret;
    \\}
;
