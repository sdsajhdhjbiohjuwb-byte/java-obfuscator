const std = @import("std");

const WindowSize: usize = 4096;
const MinimumMatch: usize = 3;
const MaximumMatch: usize = 18;

fn FindMatch(Source: []const u8, Index: usize) struct { Length: usize, Offset: usize } {
    const MaximumLength = @min(MaximumMatch, Source.len - Index);
    if (MaximumLength < MinimumMatch) return .{ .Length = 0, .Offset = 0 };
    const Start = if (Index > WindowSize) Index - WindowSize else 0;
    var BestLength: usize = 0;
    var BestOffset: usize = 0;
    var SearchIndex = Start;
    while (SearchIndex < Index) : (SearchIndex += 1) {
        var Length: usize = 0;
        while (Length < MaximumLength and Source[SearchIndex + Length] == Source[Index + Length]) Length += 1;
        if (Length > BestLength) {
            BestLength = Length;
            BestOffset = Index - SearchIndex;
            if (Length == MaximumLength) break;
        }
    }
    return .{ .Length = BestLength, .Offset = BestOffset };
}

pub fn Compress(Allocator: std.mem.Allocator, Source: []const u8) ![]u8 {
    var Output: std.ArrayList(u8) = .empty;
    var Header: [4]u8 = undefined;
    std.mem.writeInt(u32, &Header, @intCast(Source.len), .big);
    try Output.appendSlice(Allocator, &Header);
    var Index: usize = 0;
    while (Index < Source.len) {
        const FlagPosition = Output.items.len;
        try Output.append(Allocator, 0);
        var Flag: u8 = 0;
        var BitIndex: u3 = 0;
        while (Index < Source.len) {
            const Match = FindMatch(Source, Index);
            if (Match.Length >= MinimumMatch) {
                Flag |= @as(u8, 1) << BitIndex;
                const Encoded: u16 = (@as(u16, @intCast(Match.Offset - 1)) << 4) | @as(u16, @intCast(Match.Length - MinimumMatch));
                try Output.append(Allocator, @intCast(Encoded >> 8));
                try Output.append(Allocator, @intCast(Encoded & 0xFF));
                Index += Match.Length;
            } else {
                try Output.append(Allocator, Source[Index]);
                Index += 1;
            }
            if (BitIndex == 7) break;
            BitIndex += 1;
        }
        Output.items[FlagPosition] = Flag;
    }
    return Output.toOwnedSlice(Allocator);
}

pub fn Decompress(Output: []u8, Compressed: []const u8) void {
    var InputPosition: usize = 4;
    var OutputPosition: usize = 0;
    while (OutputPosition < Output.len) {
        const Flag = Compressed[InputPosition];
        InputPosition += 1;
        var BitIndex: u3 = 0;
        while (OutputPosition < Output.len) {
            if ((Flag >> BitIndex) & 1 == 1) {
                const Encoded: u16 = (@as(u16, Compressed[InputPosition]) << 8) | @as(u16, Compressed[InputPosition + 1]);
                InputPosition += 2;
                const Offset: usize = (Encoded >> 4) + 1;
                const Length: usize = (Encoded & 0xF) + MinimumMatch;
                var CopyIndex: usize = 0;
                while (CopyIndex < Length) : (CopyIndex += 1) {
                    Output[OutputPosition] = Output[OutputPosition - Offset];
                    OutputPosition += 1;
                }
            } else {
                Output[OutputPosition] = Compressed[InputPosition];
                InputPosition += 1;
                OutputPosition += 1;
            }
            if (BitIndex == 7) break;
            BitIndex += 1;
        }
    }
}

pub fn OriginalLength(Compressed: []const u8) u32 {
    return std.mem.readInt(u32, Compressed[0..4], .big);
}

test "lz round-trips" {
    const Allocator = std.testing.allocator;
    var PseudoRandom = std.Random.DefaultPrng.init(0xABCDEF);
    var Iteration: usize = 0;
    while (Iteration < 200) : (Iteration += 1) {
        const Length = PseudoRandom.random().uintLessThan(usize, 3000);
        const Source = try Allocator.alloc(u8, Length);
        defer Allocator.free(Source);
        for (Source) |*Byte| Byte.* = PseudoRandom.random().intRangeAtMost(u8, 0, if (PseudoRandom.random().boolean()) 4 else 255);
        const Compressed = try Compress(Allocator, Source);
        defer Allocator.free(Compressed);
        const Output = try Allocator.alloc(u8, Length);
        defer Allocator.free(Output);
        Decompress(Output, Compressed);
        try std.testing.expectEqualSlices(u8, Source, Output);
    }
}
