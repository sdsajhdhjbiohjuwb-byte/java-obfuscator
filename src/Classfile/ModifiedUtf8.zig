const std = @import("std");

pub fn Decode(AllocatorHandle: std.mem.Allocator, Bytes: []const u8) ![]u16 {
    var Output: std.ArrayList(u16) = .empty;
    var Index: usize = 0;
    while (Index < Bytes.len) {
        const Byte = Bytes[Index];
        if (Byte & 0x80 == 0) {
            try Output.append(AllocatorHandle, Byte);
            Index += 1;
        } else if (Byte & 0xE0 == 0xC0) {
            try Output.append(AllocatorHandle, (@as(u16, Byte & 0x1F) << 6) | @as(u16, Bytes[Index + 1] & 0x3F));
            Index += 2;
        } else {
            try Output.append(AllocatorHandle, (@as(u16, Byte & 0x0F) << 12) | (@as(u16, Bytes[Index + 1] & 0x3F) << 6) | @as(u16, Bytes[Index + 2] & 0x3F));
            Index += 3;
        }
    }
    return Output.toOwnedSlice(AllocatorHandle);
}

pub fn CallerKey(AllocatorHandle: std.mem.Allocator, InternalName: []const u8) !i32 {
    const Units = try Decode(AllocatorHandle, InternalName);
    var HashValue: u32 = 0;
    for (Units) |Unit| {
        const Character: u32 = if (Unit == '/') '.' else Unit;
        HashValue = HashValue *% 31 +% Character;
    }
    return @bitCast(HashValue);
}
