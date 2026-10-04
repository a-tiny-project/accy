//! Counter kernel for the live ordered-replay witness.
//! Assembled with SPIRV-Tools for Vulkan 1.1 and validated by spirv-val.
// OpCapability Shader
// OpMemoryModel Logical GLSL450
// OpEntryPoint GLCompute %main "sequence_counter"
// OpDecorate %group_x SpecId 0
// OpDecorate %group_y SpecId 1
// OpDecorate %group_z SpecId 2
// OpDecorate %group BuiltIn WorkgroupSize
// OpMemberDecorate %Counter 0 Offset 0
// OpDecorate %Counter Block
// OpDecorate %counter DescriptorSet 0
// OpDecorate %counter Binding 0
// OpDecorate %Values ArrayStride 4
// OpMemberDecorate %Output 0 Offset 0
// OpDecorate %Output Block
// OpDecorate %output DescriptorSet 0
// OpDecorate %output Binding 1
// %void = OpTypeVoid
// %fn = OpTypeFunction %void
// %uint = OpTypeInt 32 0
// %uint3 = OpTypeVector %uint 3
// %group_x = OpSpecConstant %uint 1
// %group_y = OpSpecConstant %uint 1
// %group_z = OpSpecConstant %uint 1
// %group = OpSpecConstantComposite %uint3 %group_x %group_y %group_z
// %zero = OpConstant %uint 0
// %one = OpConstant %uint 1
// %Counter = OpTypeStruct %uint
// %storage_counter = OpTypePointer StorageBuffer %Counter
// %counter = OpVariable %storage_counter StorageBuffer
// %storage_uint = OpTypePointer StorageBuffer %uint
// %Values = OpTypeRuntimeArray %uint
// %Output = OpTypeStruct %Values
// %storage_output = OpTypePointer StorageBuffer %Output
// %output = OpVariable %storage_output StorageBuffer
// %main = OpFunction %void None %fn
// %entry = OpLabel
// %counter_ptr = OpAccessChain %storage_uint %counter %zero
// %value = OpLoad %uint %counter_ptr
// %output_ptr = OpAccessChain %storage_uint %output %zero %value
// OpStore %output_ptr %value
// %next = OpIAdd %uint %value %one
// OpStore %counter_ptr %next
// OpReturn
// OpFunctionEnd

pub const words = [_]u32{
    0x07230203, 0x00010300, 0x00070000, 0x00000019, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
    0x00000000, 0x00000001, 0x0008000f, 0x00000005, 0x00000001, 0x75716573, 0x65636e65, 0x756f635f,
    0x7265746e, 0x00000000, 0x00040047, 0x00000002, 0x00000001, 0x00000000, 0x00040047, 0x00000003,
    0x00000001, 0x00000001, 0x00040047, 0x00000004, 0x00000001, 0x00000002, 0x00040047, 0x00000005,
    0x0000000b, 0x00000019, 0x00050048, 0x00000006, 0x00000000, 0x00000023, 0x00000000, 0x00030047,
    0x00000006, 0x00000002, 0x00040047, 0x00000007, 0x00000022, 0x00000000, 0x00040047, 0x00000007,
    0x00000021, 0x00000000, 0x00040047, 0x00000008, 0x00000006, 0x00000004, 0x00050048, 0x00000009,
    0x00000000, 0x00000023, 0x00000000, 0x00030047, 0x00000009, 0x00000002, 0x00040047, 0x0000000a,
    0x00000022, 0x00000000, 0x00040047, 0x0000000a, 0x00000021, 0x00000001, 0x00020013, 0x0000000b,
    0x00030021, 0x0000000c, 0x0000000b, 0x00040015, 0x0000000d, 0x00000020, 0x00000000, 0x00040017,
    0x0000000e, 0x0000000d, 0x00000003, 0x00040032, 0x0000000d, 0x00000002, 0x00000001, 0x00040032,
    0x0000000d, 0x00000003, 0x00000001, 0x00040032, 0x0000000d, 0x00000004, 0x00000001, 0x00060033,
    0x0000000e, 0x00000005, 0x00000002, 0x00000003, 0x00000004, 0x0004002b, 0x0000000d, 0x0000000f,
    0x00000000, 0x0004002b, 0x0000000d, 0x00000010, 0x00000001, 0x0003001e, 0x00000006, 0x0000000d,
    0x00040020, 0x00000011, 0x0000000c, 0x00000006, 0x0004003b, 0x00000011, 0x00000007, 0x0000000c,
    0x00040020, 0x00000012, 0x0000000c, 0x0000000d, 0x0003001d, 0x00000008, 0x0000000d, 0x0003001e,
    0x00000009, 0x00000008, 0x00040020, 0x00000013, 0x0000000c, 0x00000009, 0x0004003b, 0x00000013,
    0x0000000a, 0x0000000c, 0x00050036, 0x0000000b, 0x00000001, 0x00000000, 0x0000000c, 0x000200f8,
    0x00000014, 0x00050041, 0x00000012, 0x00000015, 0x00000007, 0x0000000f, 0x0004003d, 0x0000000d,
    0x00000016, 0x00000015, 0x00060041, 0x00000012, 0x00000017, 0x0000000a, 0x0000000f, 0x00000016,
    0x0003003e, 0x00000017, 0x00000016, 0x00050080, 0x0000000d, 0x00000018, 0x00000016, 0x00000010,
    0x0003003e, 0x00000015, 0x00000018, 0x000100fd, 0x00010038,
};
