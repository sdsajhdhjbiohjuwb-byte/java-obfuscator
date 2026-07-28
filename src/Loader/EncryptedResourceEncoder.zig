const std = @import("std");
const InstructionSetArchitecture = @import("../Vm/InstructionSetArchitecture.zig");

pub fn EncryptedResourceEncoder(AllocatorHandle: std.mem.Allocator, InputBytes: []const u8, Key: i32, Secrets: InstructionSetArchitecture.Secrets) ![]u8 {
    const OutputBytes = try AllocatorHandle.alloc(u8, InputBytes.len);
    const KeyBits: u32 = @bitCast(Key);
    for (InputBytes, 0..) |Byte, Index| {
        OutputBytes[Index] = Byte ^ InstructionSetArchitecture.KeystreamByte(@intCast(Index), KeyBits, Secrets);
    }
    return OutputBytes;
}
