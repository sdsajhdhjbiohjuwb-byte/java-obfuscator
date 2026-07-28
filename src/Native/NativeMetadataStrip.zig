const std = @import("std");

fn ReadU16(Bytes: []const u8, Offset: usize) u16 {
    return std.mem.readInt(u16, Bytes[Offset..][0..2], .little);
}

fn ReadU32(Bytes: []const u8, Offset: usize) u32 {
    return std.mem.readInt(u32, Bytes[Offset..][0..4], .little);
}

fn ReadU64(Bytes: []const u8, Offset: usize) u64 {
    return std.mem.readInt(u64, Bytes[Offset..][0..8], .little);
}

fn WriteU16(Bytes: []u8, Offset: usize, Value: u16) void {
    std.mem.writeInt(u16, Bytes[Offset..][0..2], Value, .little);
}

fn WriteU64(Bytes: []u8, Offset: usize, Value: u64) void {
    std.mem.writeInt(u64, Bytes[Offset..][0..8], Value, .little);
}

fn NameMatches(Table: []const u8, NameOffset: u32, Candidate: []const u8) bool {
    if (NameOffset >= Table.len) return false;
    const Slice = Table[NameOffset..];
    const End = std.mem.indexOfScalar(u8, Slice, 0) orelse Slice.len;
    return std.mem.eql(u8, Slice[0..End], Candidate);
}

fn ShouldScrubName(Table: []const u8, NameOffset: u32) bool {
    if (NameOffset >= Table.len) return false;
    const Slice = Table[NameOffset..];
    const End = std.mem.indexOfScalar(u8, Slice, 0) orelse Slice.len;
    const Name = Slice[0..End];
    if (std.mem.eql(u8, Name, ".comment")) return true;
    if (std.mem.startsWith(u8, Name, ".note")) return true;
    return false;
}

fn ScrubElf64(Bytes: []u8) void {
    if (Bytes.len < 64) return;
    const SectionHeaderOffset = ReadU64(Bytes, 0x28);
    const SectionHeaderEntrySize = ReadU16(Bytes, 0x3A);
    const SectionHeaderCount = ReadU16(Bytes, 0x3C);
    const SectionNameIndex = ReadU16(Bytes, 0x3E);
    if (SectionHeaderOffset == 0 or SectionHeaderCount == 0) return;
    if (SectionHeaderEntrySize < 64) return;
    const TableBytes = @as(u64, SectionHeaderEntrySize) * @as(u64, SectionHeaderCount);
    if (SectionHeaderOffset + TableBytes > Bytes.len) return;
    if (SectionNameIndex >= SectionHeaderCount) return;

    const NameHeader = SectionHeaderOffset + @as(u64, SectionNameIndex) * SectionHeaderEntrySize;
    const NameTableOffset = ReadU64(Bytes, @intCast(NameHeader + 0x18));
    const NameTableSize = ReadU64(Bytes, @intCast(NameHeader + 0x20));
    if (NameTableOffset + NameTableSize > Bytes.len) return;
    const NameTable = Bytes[@intCast(NameTableOffset)..@intCast(NameTableOffset + NameTableSize)];

    var Index: u16 = 0;
    while (Index < SectionHeaderCount) : (Index += 1) {
        const Header = SectionHeaderOffset + @as(u64, Index) * SectionHeaderEntrySize;
        const NameOffset = ReadU32(Bytes, @intCast(Header + 0x00));
        const SectionType = ReadU32(Bytes, @intCast(Header + 0x04));
        const Flags = ReadU64(Bytes, @intCast(Header + 0x08));
        const FileOffset = ReadU64(Bytes, @intCast(Header + 0x18));
        const Size = ReadU64(Bytes, @intCast(Header + 0x20));
        const Allocated = (Flags & 0x2) != 0;
        const NoBits = SectionType == 8;
        if (Allocated or NoBits) continue;
        if (FileOffset == 0 or FileOffset + Size > Bytes.len) continue;
        if (ShouldScrubName(NameTable, NameOffset)) {
            @memset(Bytes[@intCast(FileOffset)..@intCast(FileOffset + Size)], 0);
        }
    }

    var Scan: usize = 0;
    const Producer = "Linker: LLD";
    while (Scan + Producer.len <= Bytes.len) : (Scan += 1) {
        if (std.mem.eql(u8, Bytes[Scan .. Scan + Producer.len], Producer)) {
            var End = Scan;
            while (End < Bytes.len and Bytes[End] != 0) : (End += 1) {}
            @memset(Bytes[Scan..End], 0);
        }
    }

    @memset(NameTable, 0);
    @memset(Bytes[@intCast(SectionHeaderOffset)..@intCast(SectionHeaderOffset + TableBytes)], 0);
    WriteU64(Bytes, 0x28, 0);
    WriteU16(Bytes, 0x3A, 0);
    WriteU16(Bytes, 0x3C, 0);
    WriteU16(Bytes, 0x3E, 0);
}

pub fn Scrub(Bytes: []u8) void {
    if (Bytes.len >= 4 and Bytes[0] == 0x7F and Bytes[1] == 'E' and Bytes[2] == 'L' and Bytes[3] == 'F') {
        if (Bytes[4] == 2) ScrubElf64(Bytes);
    }
}

test "elf comment scrub is a no-op on non-elf input" {
    var Data = [_]u8{ 'M', 'Z', 0, 0, 1, 2, 3, 4 };
    const Copy = Data;
    Scrub(&Data);
    try std.testing.expectEqualSlices(u8, &Copy, &Data);
}
