#include <metal_stdlib>
using namespace metal;

struct pushed_vertex_in {
    float3 a0 [[attribute(0)]];
    float4 a2 [[attribute(2)]];
};

struct pushed_vertex_out {
    float4 position [[position]];
    float4 l0 [[user(locn0)]];
};

vertex pushed_vertex_out pushed_vertex(
    pushed_vertex_in choir_in [[stage_in]],
    constant uint* choir_push [[buffer(30)]]
) {
    pushed_vertex_out choir_out = {};
    const float v0 = choir_in.a0.x * as_type<float>(choir_push[2]);
    const float v1 = v0 + as_type<float>(choir_push[0]);
    const float v2 = choir_in.a0.y * as_type<float>(choir_push[2]);
    const float v3 = v2 + as_type<float>(choir_push[1]);
    const float v4 = as_type<float>(0x3F800000u);
    choir_out.position = float4(v1, v3, choir_in.a0.z, v4);
    choir_out.position.y = -choir_out.position.y;
    choir_out.l0 = float4(choir_in.a2.x, choir_in.a2.y, choir_in.a2.z, choir_in.a2.w);
    return choir_out;
}

struct pushed_fragment_in {
    float4 l0 [[user(locn0)]];
};

struct pushed_fragment_out {
    float4 c0 [[color(0)]];
};

fragment pushed_fragment_out pushed_fragment(
    pushed_fragment_in choir_in [[stage_in]],
    constant uint4* choir_uniform1 [[buffer(17)]],
    constant uint* choir_push [[buffer(30)]]
) {
    pushed_fragment_out choir_out = {};
    const float v0 = as_type<float>(choir_uniform1[0].x) * as_type<float>(choir_uniform1[1].x);
    const float v1 = as_type<float>(choir_uniform1[0].y) * as_type<float>(choir_uniform1[1].y);
    const float v2 = as_type<float>(choir_uniform1[0].z) * as_type<float>(choir_uniform1[1].z);
    const float v3 = as_type<float>(choir_uniform1[0].w) * as_type<float>(choir_uniform1[1].w);
    const float v4 = v0 * choir_in.l0.x;
    const float v5 = v1 * choir_in.l0.y;
    const float v6 = v2 * choir_in.l0.z;
    const float v7 = v3 * choir_in.l0.w;
    const float v8 = v4 * as_type<float>(choir_push[3]);
    const float v9 = v5 * as_type<float>(choir_push[3]);
    const float v10 = v6 * as_type<float>(choir_push[3]);
    choir_out.c0 = float4(v8, v9, v10, v7);
    return choir_out;
}
