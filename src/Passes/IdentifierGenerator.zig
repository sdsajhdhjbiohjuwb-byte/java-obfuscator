const std = @import("std");

const AbcSet = "abcdefghijklmnopqrstuvwxyz";
const LetterSet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const HexSet = "0123456789abcdef";

pub fn AbcName(AllocatorHandle: std.mem.Allocator, Count: usize) ![]u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    try ScratchBuffer.append(AllocatorHandle, AbcSet[Count % AbcSet.len]);
    var Quotient = Count / AbcSet.len;
    while (Quotient > 0) {
        try ScratchBuffer.append(AllocatorHandle, AbcSet[Quotient % AbcSet.len]);
        Quotient /= AbcSet.len;
    }
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

pub fn RandomLetters(AllocatorHandle: std.mem.Allocator, RandomSource: std.Random, Count: usize) ![]u8 {
    const ScratchBuffer = try AllocatorHandle.alloc(u8, Count);
    for (ScratchBuffer) |*ByteSlot| ByteSlot.* = LetterSet[RandomSource.intRangeLessThan(usize, 0, LetterSet.len)];
    return ScratchBuffer;
}

pub fn HexLicense(AllocatorHandle: std.mem.Allocator, RandomSource: std.Random) ![]u8 {
    const GroupSizes = [_]usize{ 8, 4, 4, 4, 12 };
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    for (GroupSizes, 0..) |GroupSize, GroupIndex| {
        if (GroupIndex != 0) try ScratchBuffer.append(AllocatorHandle, '-');
        var Index: usize = 0;
        while (Index < GroupSize) : (Index += 1) try ScratchBuffer.append(AllocatorHandle, HexSet[RandomSource.intRangeLessThan(usize, 0, HexSet.len)]);
    }
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

test "AbcName is injective and lowercase-alpha" {
    const AllocatorHandle = std.testing.allocator;
    var SeenNames = std.StringHashMap(void).init(AllocatorHandle);
    defer {
        var Iterator = SeenNames.keyIterator();
        while (Iterator.next()) |Key| AllocatorHandle.free(Key.*);
        SeenNames.deinit();
    }
    var Index: usize = 0;
    while (Index < 5000) : (Index += 1) {
        const Name = try AbcName(AllocatorHandle, Index);
        for (Name) |Character| try std.testing.expect(Character >= 'a' and Character <= 'z');
        try std.testing.expect(!SeenNames.contains(Name));
        try SeenNames.put(Name, {});
    }
}

test "HexLicense shape" {
    const AllocatorHandle = std.testing.allocator;
    var PseudoRandom = std.Random.DefaultPrng.init(1234);
    const LicenseString = try HexLicense(AllocatorHandle, PseudoRandom.random());
    defer AllocatorHandle.free(LicenseString);
    try std.testing.expectEqual(@as(usize, 36), LicenseString.len);
    try std.testing.expectEqual(@as(u8, '-'), LicenseString[8]);
    try std.testing.expectEqual(@as(u8, '-'), LicenseString[13]);
    try std.testing.expectEqual(@as(u8, '-'), LicenseString[18]);
    try std.testing.expectEqual(@as(u8, '-'), LicenseString[23]);
}
