#include <metal_stdlib>
using namespace metal;

struct textured_vertex_in {
    float3 a0 [[attribute(0)]];
    float2 a1 [[attribute(1)]];
    float4 a2 [[attribute(2)]];
};

struct textured_vertex_out {
    float4 position [[position]];
    float2 l0 [[user(locn0)]];
    float4 l1 [[user(locn1)]];
};

vertex textured_vertex_out textured_vertex(
    textured_vertex_in choir_in [[stage_in]]
) {
    textured_vertex_out choir_out = {};
    const float v0 = as_type<float>(0x3F800000u);
    choir_out.position = float4(choir_in.a0.x, choir_in.a0.y, choir_in.a0.z, v0);
    choir_out.position.y = -choir_out.position.y;
    choir_out.l0 = float2(choir_in.a1.x, choir_in.a1.y);
    choir_out.l1 = float4(choir_in.a2.x, choir_in.a2.y, choir_in.a2.z, choir_in.a2.w);
    return choir_out;
}

struct textured_fragment_in {
    float2 l0 [[user(locn0)]];
    float4 l1 [[user(locn1)]];
};

struct textured_fragment_out {
    float4 c0 [[color(0)]];
};

fragment textured_fragment_out textured_fragment(
    textured_fragment_in choir_in [[stage_in]],
    texture2d<float> choir_texture0 [[texture(0)]],
    sampler choir_sampler0 [[sampler(0)]]
) {
    textured_fragment_out choir_out = {};
    const float4 v0 = choir_texture0.sample(choir_sampler0, float2(choir_in.l0.x, choir_in.l0.y));
    const float v1 = choir_in.l1.x * v0.x;
    const float v2 = choir_in.l1.y * v0.y;
    const float v3 = choir_in.l1.z * v0.z;
    const float v4 = choir_in.l1.w * v0.w;
    choir_out.c0 = float4(v1, v2, v3, v4);
    return choir_out;
}
