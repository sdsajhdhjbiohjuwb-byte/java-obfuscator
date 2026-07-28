const std = @import("std");
const Flate = std.compress.flate;
const ArchiveEntry = @import("JavaArchiveReader.zig").ArchiveEntry;

const LocalFileHeaderSignature: u32 = 0x04034b50;
const CentralDirectorySignature: u32 = 0x02014b50;
const EndOfCentralDirectorySignature: u32 = 0x06054b50;

pub fn Crc32(DataBytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(DataBytes);
}

pub fn Deflate(AllocatorHandle: std.mem.Allocator, DataBytes: []const u8) ![]u8 {
    var OutputBuffer = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, @max(64, DataBytes.len / 2 + 64));
    const WindowBuffer = try AllocatorHandle.alloc(u8, Flate.max_window_len);
    var Compressor = try Flate.Compress.init(&OutputBuffer.writer, WindowBuffer, .raw, Flate.Compress.Options.default);
    try Compressor.writer.writeAll(DataBytes);
    try Compressor.finish();
    return OutputBuffer.written();
}

pub fn Pack(AllocatorHandle: std.mem.Allocator, EntryName: []const u8, DataBytes: []const u8) !ArchiveEntry {
    const CompressedData = try Deflate(AllocatorHandle, DataBytes);
    if (CompressedData.len >= DataBytes.len) {
        return .{
            .Name = try AllocatorHandle.dupe(u8, EntryName),
            .Method = 0,
            .Crc32 = Crc32(DataBytes),
            .CompressedSize = @intCast(DataBytes.len),
            .UncompressedSize = @intCast(DataBytes.len),
            .CompressedData = try AllocatorHandle.dupe(u8, DataBytes),
        };
    }
    return .{
        .Name = try AllocatorHandle.dupe(u8, EntryName),
        .Method = 8,
        .Crc32 = Crc32(DataBytes),
        .CompressedSize = @intCast(CompressedData.len),
        .UncompressedSize = @intCast(DataBytes.len),
        .CompressedData = CompressedData,
    };
}

fn WriteUnsignedShort(OutputWriter: *std.Io.Writer, Value: u16) !void {
    var ByteBuffer: [2]u8 = undefined;
    std.mem.writeInt(u16, &ByteBuffer, Value, .little);
    try OutputWriter.writeAll(&ByteBuffer);
}
fn WriteUnsignedInt(OutputWriter: *std.Io.Writer, Value: u32) !void {
    var ByteBuffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &ByteBuffer, Value, .little);
    try OutputWriter.writeAll(&ByteBuffer);
}

pub fn Write(AllocatorHandle: std.mem.Allocator, Entries: []const ArchiveEntry) ![]u8 {
    var OutputBuffer = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, 64 * 1024);
    const WriterHandle = &OutputBuffer.writer;
    const LocalHeaderOffsets = try AllocatorHandle.alloc(u32, Entries.len);

    for (Entries, 0..) |Entry, Index| {
        LocalHeaderOffsets[Index] = @intCast(WriterHandle.end);
        try WriteUnsignedInt(WriterHandle, LocalFileHeaderSignature);
        try WriteUnsignedShort(WriterHandle, 20);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, Entry.Method);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, 0x21);
        try WriteUnsignedInt(WriterHandle, Entry.Crc32);
        try WriteUnsignedInt(WriterHandle, Entry.CompressedSize);
        try WriteUnsignedInt(WriterHandle, Entry.UncompressedSize);
        try WriteUnsignedShort(WriterHandle, @intCast(Entry.Name.len));
        try WriteUnsignedShort(WriterHandle, 0);
        try WriterHandle.writeAll(Entry.Name);
        try WriterHandle.writeAll(Entry.CompressedData);
    }

    const CentralDirectoryOffset: u32 = @intCast(WriterHandle.end);
    for (Entries, 0..) |Entry, Index| {
        try WriteUnsignedInt(WriterHandle, CentralDirectorySignature);
        try WriteUnsignedShort(WriterHandle, 20);
        try WriteUnsignedShort(WriterHandle, 20);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, Entry.Method);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, 0x21);
        try WriteUnsignedInt(WriterHandle, Entry.Crc32);
        try WriteUnsignedInt(WriterHandle, Entry.CompressedSize);
        try WriteUnsignedInt(WriterHandle, Entry.UncompressedSize);
        try WriteUnsignedShort(WriterHandle, @intCast(Entry.Name.len));
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedShort(WriterHandle, 0);
        try WriteUnsignedInt(WriterHandle, 0);
        try WriteUnsignedInt(WriterHandle, LocalHeaderOffsets[Index]);
        try WriterHandle.writeAll(Entry.Name);
    }
    const CentralDirectorySize: u32 = @intCast(@as(u32, @intCast(WriterHandle.end)) - CentralDirectoryOffset);

    try WriteUnsignedInt(WriterHandle, EndOfCentralDirectorySignature);
    try WriteUnsignedShort(WriterHandle, 0);
    try WriteUnsignedShort(WriterHandle, 0);
    try WriteUnsignedShort(WriterHandle, @intCast(Entries.len));
    try WriteUnsignedShort(WriterHandle, @intCast(Entries.len));
    try WriteUnsignedInt(WriterHandle, CentralDirectorySize);
    try WriteUnsignedInt(WriterHandle, CentralDirectoryOffset);
    try WriteUnsignedShort(WriterHandle, 0);

    return OutputBuffer.written();
}
