#include <metal_stdlib>
using namespace metal;

struct indexed_vertex_out {
    float4 position [[position]];
    uint l0 [[user(locn0)]];
    float2 l1 [[user(locn1)]];
};

vertex indexed_vertex_out indexed_vertex(
    uint choir_vertex_id [[vertex_id]],
    uint choir_instance_id [[instance_id]],
    texture2d<float> choir_texture1 [[texture(1)]],
    sampler choir_sampler1 [[sampler(1)]]
) {
    indexed_vertex_out choir_out = {};
    const float v0 = float(choir_vertex_id);
    const float v1 = float(choir_instance_id);
    const float v2 = as_type<float>(0x00000000u);
    const float4 v3 = choir_texture1.sample(choir_sampler1, float2(v0, v1), level(v2));
    choir_out.position = float4(v0, v1, v3.x, v3.w);
    choir_out.position.y = -choir_out.position.y;
    choir_out.l0 = choir_instance_id;
    choir_out.l1 = float2(v3.y, v3.z);
    return choir_out;
}

struct indexed_fragment_in {
    float4 position [[position]];
    uint l0 [[user(locn0), flat]];
    float2 l1 [[user(locn1)]];
};

struct indexed_fragment_out {
    float4 c0 [[color(0)]];
    uint c1 [[color(1)]];
};

fragment indexed_fragment_out indexed_fragment(
    indexed_fragment_in choir_in [[stage_in]],
    bool choir_front_facing [[front_facing]]
) {
    indexed_fragment_out choir_out = {};
    const float v0 = dfdx(choir_in.l1.x);
    const float v1 = dfdy(choir_in.l1.y);
    const float v2 = fwidth(choir_in.position.x);
    const float v3 = choir_front_facing ? v0 : v1;
    const float v4 = v3 + v2;
    const float v5 = float(choir_in.l0);
    choir_out.c0 = float4(v5, v4, choir_in.position.y, choir_in.position.w);
    if (choir_front_facing) {
        choir_out.c1 = choir_in.l0;
    } else {
    }
    return choir_out;
}
