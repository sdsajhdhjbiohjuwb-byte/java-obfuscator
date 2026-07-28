const std = @import("std");
const Flate = std.compress.flate;

pub const ArchiveEntry = struct {
    Name: []const u8,
    Method: u16,
    Crc32: u32,
    CompressedSize: u32,
    UncompressedSize: u32,
    CompressedData: []const u8,
};

const EndOfCentralDirectorySignature: u32 = 0x06054b50;
const CentralDirectorySignature: u32 = 0x02014b50;

fn ReadUnsignedShort(ScratchBuffer: []const u8, Offset: usize) u16 {
    return std.mem.readInt(u16, ScratchBuffer[Offset..][0..2], .little);
}
fn ReadUnsignedInt(ScratchBuffer: []const u8, Offset: usize) u32 {
    return std.mem.readInt(u32, ScratchBuffer[Offset..][0..4], .little);
}

pub fn Read(AllocatorHandle: std.mem.Allocator, Data: []const u8) ![]ArchiveEntry {
    if (Data.len < 22) return error.NotAZip;

    var ScanPosition: usize = Data.len - 22;
    var FoundEndOfCentralDirectory = false;
    while (true) {
        if (ReadUnsignedInt(Data, ScanPosition) == EndOfCentralDirectorySignature) {
            FoundEndOfCentralDirectory = true;
            break;
        }
        if (ScanPosition == 0) break;
        ScanPosition -= 1;
    }
    if (!FoundEndOfCentralDirectory) return error.NoEndOfCentralDirectory;

    const TotalEntries = ReadUnsignedShort(Data, ScanPosition + 10);
    const CentralDirectoryOffset = ReadUnsignedInt(Data, ScanPosition + 16);

    var EntryList: std.ArrayList(ArchiveEntry) = .empty;
    var Offset: usize = CentralDirectoryOffset;
    var Index: usize = 0;
    while (Index < TotalEntries) : (Index += 1) {
        if (Offset + 46 > Data.len or ReadUnsignedInt(Data, Offset) != CentralDirectorySignature) break;
        const Method = ReadUnsignedShort(Data, Offset + 10);
        const CyclicRedundancyCheck = ReadUnsignedInt(Data, Offset + 16);
        const CompressedSize = ReadUnsignedInt(Data, Offset + 20);
        const UncompressedSize = ReadUnsignedInt(Data, Offset + 24);
        const NameLength = ReadUnsignedShort(Data, Offset + 28);
        const ExtraLength = ReadUnsignedShort(Data, Offset + 30);
        const CommentLength = ReadUnsignedShort(Data, Offset + 32);
        const LocalHeaderOffset = ReadUnsignedInt(Data, Offset + 42);
        const Name = Data[Offset + 46 ..][0..NameLength];

        const LocalNameLength = ReadUnsignedShort(Data, LocalHeaderOffset + 26);
        const LocalExtraLength = ReadUnsignedShort(Data, LocalHeaderOffset + 28);
        const DataStart = LocalHeaderOffset + 30 + @as(usize, LocalNameLength) + @as(usize, LocalExtraLength);
        const CompressedData = Data[DataStart..][0..CompressedSize];

        Offset += 46 + @as(usize, NameLength) + @as(usize, ExtraLength) + @as(usize, CommentLength);

        if (Name.len > 0 and Name[Name.len - 1] == '/') continue;

        try EntryList.append(AllocatorHandle, .{
            .Name = try AllocatorHandle.dupe(u8, Name),
            .Method = Method,
            .Crc32 = CyclicRedundancyCheck,
            .CompressedSize = CompressedSize,
            .UncompressedSize = UncompressedSize,
            .CompressedData = CompressedData,
        });
    }
    return try EntryList.toOwnedSlice(AllocatorHandle);
}

pub fn Inflate(AllocatorHandle: std.mem.Allocator, Entry: ArchiveEntry) ![]u8 {
    if (Entry.Method == 0) return try AllocatorHandle.dupe(u8, Entry.CompressedData);
    if (Entry.UncompressedSize == 0) return &.{};

    var InputReader = std.Io.Reader.fixed(Entry.CompressedData);
    const Window = try AllocatorHandle.alloc(u8, Flate.max_window_len);
    var Decompressor = Flate.Decompress.init(&InputReader, .raw, Window);
    const Output = try AllocatorHandle.alloc(u8, Entry.UncompressedSize);
    try Decompressor.reader.readSliceAll(Output);
    return Output;
}
