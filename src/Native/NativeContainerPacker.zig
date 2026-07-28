const std = @import("std");
const Flate = std.compress.flate;

pub const Magic: u32 = 0x4E545631;
pub const TagWindowsX64: u8 = 1;
pub const TagLinuxX64: u8 = 2;
pub const TagMacosX64: u8 = 3;
pub const TagWindowsArm64: u8 = 4;
pub const TagLinuxArm64: u8 = 5;
pub const TagMacosArm64: u8 = 6;

pub const LibraryHash = struct { Tag: u8, Hash: i64 };

fn AppendU32BE(Allocator: std.mem.Allocator, Out: *std.ArrayList(u8), Value: u32) !void {
    var Buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &Buffer, Value, .big);
    try Out.appendSlice(Allocator, &Buffer);
}

fn DeflateBest(Allocator: std.mem.Allocator, Data: []const u8) ![]u8 {
    var Out = try std.Io.Writer.Allocating.initCapacity(Allocator, @max(64, Data.len / 2 + 64));
    const Window = try Allocator.alloc(u8, Flate.max_window_len);
    var Compressor = try Flate.Compress.init(&Out.writer, Window, .raw, Flate.Compress.Options.best);
    try Compressor.writer.writeAll(Data);
    try Compressor.finish();
    return Out.written();
}

pub const RawSlice = struct { Tag: u8, Raw: []const u8 };

pub fn PackRawSlices(Allocator: std.mem.Allocator, Slices: []const RawSlice) ![]u8 {
    const CompressedSlices = try Allocator.alloc([]u8, Slices.len);
    for (Slices, 0..) |Slice, Index| CompressedSlices[Index] = try DeflateBest(Allocator, Slice.Raw);
    var Out: std.ArrayList(u8) = .empty;
    try AppendU32BE(Allocator, &Out, Magic);
    try Out.append(Allocator, @intCast(Slices.len));
    try Out.append(Allocator, 0);
    for (Slices, 0..) |Slice, Index| {
        try Out.append(Allocator, Slice.Tag);
        try AppendU32BE(Allocator, &Out, @intCast(Slice.Raw.len));
        try AppendU32BE(Allocator, &Out, @intCast(CompressedSlices[Index].len));
    }
    for (CompressedSlices) |CompressedSlice| try Out.appendSlice(Allocator, CompressedSlice);
    return Out.toOwnedSlice(Allocator);
}
