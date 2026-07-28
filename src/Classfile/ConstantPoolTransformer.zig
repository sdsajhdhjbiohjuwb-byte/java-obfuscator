const std = @import("std");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");

pub fn ApplyClassRename(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, RenameMapping: Mapping) !void {
    var Index: u16 = 1;
    while (Index < Pool.Count()) : (Index += 1) {
        if (Pool.Entries.items[Index].Tag != ConstantPoolBuilder.TagUtf8) continue;
        const OldContent = Pool.Utf8Text(Index);
        const NewContent = try RemapUtf8(AllocatorHandle, OldContent, RenameMapping);
        if (!std.mem.eql(u8, OldContent, NewContent)) try Pool.SetUtf8Content(Index, NewContent);
    }
}

pub fn Transform(ArenaAllocator: std.mem.Allocator, ClassBytes: []const u8, RenameMapping: Mapping) ![]u8 {
    const Bytes = ClassBytes;
    if (Bytes.len < 10 or std.mem.readInt(u32, Bytes[0..4], .big) != 0xCAFEBABE)
        return error.NotAClassFile;

    const ConstantPoolCount = std.mem.readInt(u16, Bytes[8..10], .big);

    var Output = try std.Io.Writer.Allocating.initCapacity(ArenaAllocator, Bytes.len + 64);
    const Writer = &Output.writer;
    try Writer.writeAll(Bytes[0..10]);

    var Offset: usize = 10;
    var Index: usize = 1;
    while (Index < ConstantPoolCount) : (Index += 1) {
        const Tag = Bytes[Offset];
        const Start = Offset;
        switch (Tag) {
            1 => {
                const Length = std.mem.readInt(u16, Bytes[Offset + 1 ..][0..2], .big);
                const Content = Bytes[Offset + 3 ..][0..Length];
                const NewContent = try RemapUtf8(ArenaAllocator, Content, RenameMapping);
                try Writer.writeByte(1);
                var LengthBytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &LengthBytes, @intCast(NewContent.len), .big);
                try Writer.writeAll(&LengthBytes);
                try Writer.writeAll(NewContent);
                Offset = Offset + 3 + Length;
            },
            7, 8, 16, 19, 20 => {
                try Writer.writeAll(Bytes[Start .. Start + 3]);
                Offset += 3;
            },
            15 => {
                try Writer.writeAll(Bytes[Start .. Start + 4]);
                Offset += 4;
            },
            3, 4, 9, 10, 11, 12, 17, 18 => {
                try Writer.writeAll(Bytes[Start .. Start + 5]);
                Offset += 5;
            },
            5, 6 => {
                try Writer.writeAll(Bytes[Start .. Start + 9]);
                Offset += 9;
                Index += 1;
            },
            else => return error.UnknownConstantTag,
        }
    }

    try Writer.writeAll(Bytes[Offset..]);
    return Output.written();
}

fn IsIdent(Character: u8) bool {
    return (Character >= 'A' and Character <= 'Z') or (Character >= 'a' and Character <= 'z') or
        (Character >= '0' and Character <= '9') or Character == '_' or Character == '$';
}

pub fn RemapUtf8(ArenaAllocator: std.mem.Allocator, SourceBytes: []const u8, RenameMapping: Mapping) ![]u8 {
    if (SourceBytes.len == 0) return try ArenaAllocator.dupe(u8, SourceBytes);

    var Output = try std.Io.Writer.Allocating.initCapacity(ArenaAllocator, SourceBytes.len + 16);
    const Writer = &Output.writer;

    var Position: usize = 0;
    while (Position < SourceBytes.len) {
        var BestLength: usize = 0;
        var BestReplacement: []const u8 = &.{};

        for (RenameMapping.Pairs) |Pair| {
            const OldInternal = Pair.OldInternal;
            if (OldInternal.len > BestLength and Position + OldInternal.len <= SourceBytes.len and std.mem.eql(u8, SourceBytes[Position .. Position + OldInternal.len], OldInternal)) {
                const LeftOk = (Position == 0) or (SourceBytes[Position - 1] == 'L');
                const RightChar: u8 = if (Position + OldInternal.len < SourceBytes.len) SourceBytes[Position + OldInternal.len] else 0;
                const RightOk = (Position + OldInternal.len == SourceBytes.len) or RightChar == ';' or RightChar == '$' or RightChar == '<';
                if (LeftOk and RightOk) {
                    BestLength = OldInternal.len;
                    BestReplacement = Pair.NewInternal;
                }
            }

            const OldDotted = Pair.OldDotted;
            if (OldDotted.len > BestLength and Position + OldDotted.len <= SourceBytes.len and std.mem.eql(u8, SourceBytes[Position .. Position + OldDotted.len], OldDotted)) {
                const LeftChar: u8 = if (Position == 0) 0 else SourceBytes[Position - 1];
                const LeftOk = (Position == 0) or (!IsIdent(LeftChar) and LeftChar != '.' and LeftChar != '/');
                const RightChar: u8 = if (Position + OldDotted.len < SourceBytes.len) SourceBytes[Position + OldDotted.len] else 0;
                const RightOk = (Position + OldDotted.len == SourceBytes.len) or (!IsIdent(RightChar) and RightChar != '.');
                if (LeftOk and RightOk) {
                    BestLength = OldDotted.len;
                    BestReplacement = Pair.NewDotted;
                }
            }
        }

        if (BestLength > 0) {
            try Writer.writeAll(BestReplacement);
            Position += BestLength;
        } else {
            try Writer.writeByte(SourceBytes[Position]);
            Position += 1;
        }
    }

    return Output.written();
}
