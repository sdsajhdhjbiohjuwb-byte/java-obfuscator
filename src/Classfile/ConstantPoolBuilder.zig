const std = @import("std");

pub fn ReadUnsignedShort(Bytes: []const u8, Offset: usize) u16 {
    return std.mem.readInt(u16, Bytes[Offset..][0..2], .big);
}

pub fn ReadUnsignedInt(Bytes: []const u8, Offset: usize) u32 {
    return std.mem.readInt(u32, Bytes[Offset..][0..4], .big);
}

pub fn WriteUnsignedShort(Writer: *std.Io.Writer, Value: u16) !void {
    var ScratchBytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &ScratchBytes, Value, .big);
    try Writer.writeAll(&ScratchBytes);
}

pub fn WriteUnsignedInt(Writer: *std.Io.Writer, Value: u32) !void {
    var ScratchBytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &ScratchBytes, Value, .big);
    try Writer.writeAll(&ScratchBytes);
}

pub const TagUtf8: u8 = 1;
pub const TagInteger: u8 = 3;
pub const TagFloat: u8 = 4;
pub const TagLong: u8 = 5;
pub const TagDouble: u8 = 6;
pub const TagClass: u8 = 7;
pub const TagString: u8 = 8;
pub const TagFieldref: u8 = 9;
pub const TagMethodref: u8 = 10;
pub const TagInterfaceMethodref: u8 = 11;
pub const TagNameAndType: u8 = 12;
pub const TagMethodHandle: u8 = 15;
pub const TagMethodType: u8 = 16;
pub const TagDynamic: u8 = 17;
pub const TagInvokeDynamic: u8 = 18;
pub const TagModule: u8 = 19;
pub const TagPackage: u8 = 20;

pub const Entry = struct {
    Tag: u8,
    Payload: []u8,
};

fn PayloadLength(Tag: u8, Bytes: []const u8, Offset: usize) !usize {
    return switch (Tag) {
        TagUtf8 => 2 + @as(usize, ReadUnsignedShort(Bytes, Offset + 1)),
        TagInteger, TagFloat, TagFieldref, TagMethodref, TagInterfaceMethodref, TagNameAndType, TagDynamic, TagInvokeDynamic => 4,
        TagLong, TagDouble => 8,
        TagClass, TagString, TagMethodType, TagModule, TagPackage => 2,
        TagMethodHandle => 3,
        else => error.UnknownConstantTag,
    };
}

pub const ConstantPool = struct {
    Entries: std.ArrayList(Entry),
    Allocator: std.mem.Allocator,

    pub fn InitEmpty(AllocatorHandle: std.mem.Allocator) !ConstantPool {
        var Entries: std.ArrayList(Entry) = .empty;
        try Entries.append(AllocatorHandle, .{ .Tag = 0, .Payload = &.{} });
        return .{ .Entries = Entries, .Allocator = AllocatorHandle };
    }

    pub fn ParseFrom(AllocatorHandle: std.mem.Allocator, Bytes: []const u8, Offset: *usize) !ConstantPool {
        const ConstantPoolCount = ReadUnsignedShort(Bytes, Offset.*);
        Offset.* += 2;
        var Entries: std.ArrayList(Entry) = .empty;
        try Entries.append(AllocatorHandle, .{ .Tag = 0, .Payload = &.{} });
        var Index: usize = 1;
        while (Index < ConstantPoolCount) {
            const Tag = Bytes[Offset.*];
            const PayloadByteCount = try PayloadLength(Tag, Bytes, Offset.*);
            const Payload = try AllocatorHandle.dupe(u8, Bytes[Offset.* + 1 .. Offset.* + 1 + PayloadByteCount]);
            try Entries.append(AllocatorHandle, .{ .Tag = Tag, .Payload = Payload });
            Offset.* += 1 + PayloadByteCount;
            if (Tag == TagLong or Tag == TagDouble) {
                try Entries.append(AllocatorHandle, .{ .Tag = 0, .Payload = &.{} });
                Index += 2;
            } else {
                Index += 1;
            }
        }
        return .{ .Entries = Entries, .Allocator = AllocatorHandle };
    }

    pub fn Serialize(Self: *const ConstantPool, Writer: *std.Io.Writer) !void {
        try WriteUnsignedShort(Writer, @intCast(Self.Entries.items.len));
        var Index: usize = 1;
        while (Index < Self.Entries.items.len) {
            const CurrentEntry = Self.Entries.items[Index];
            try Writer.writeByte(CurrentEntry.Tag);
            try Writer.writeAll(CurrentEntry.Payload);
            Index += 1;
            if (CurrentEntry.Tag == TagLong or CurrentEntry.Tag == TagDouble) Index += 1;
        }
    }

    pub fn Count(Self: *const ConstantPool) u16 {
        return @intCast(Self.Entries.items.len);
    }

    pub fn GetEntry(Self: *const ConstantPool, Index: u16) Entry {
        return Self.Entries.items[Index];
    }

    pub fn TagOf(Self: *const ConstantPool, Index: u16) u8 {
        if (Index == 0 or Index >= Self.Entries.items.len) return 0;
        return Self.Entries.items[Index].Tag;
    }

    pub fn Utf8Text(Self: *const ConstantPool, Index: u16) []const u8 {
        const CurrentEntry = Self.Entries.items[Index];
        const Length = ReadUnsignedShort(CurrentEntry.Payload, 0);
        return CurrentEntry.Payload[2 .. 2 + Length];
    }

    pub fn RefIndex(Self: *const ConstantPool, Index: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[Index].Payload, 0);
    }

    pub fn ClassNameIndex(Self: *const ConstantPool, ClassIndex: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[ClassIndex].Payload, 0);
    }

    pub fn ClassName(Self: *const ConstantPool, ClassIndex: u16) []const u8 {
        return Self.Utf8Text(Self.ClassNameIndex(ClassIndex));
    }

    pub fn NameAndTypeName(Self: *const ConstantPool, NameAndTypeIndex: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[NameAndTypeIndex].Payload, 0);
    }

    pub fn NameAndTypeDesc(Self: *const ConstantPool, NameAndTypeIndex: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[NameAndTypeIndex].Payload, 2);
    }

    pub fn RefClassIndex(Self: *const ConstantPool, ReferenceIndex: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[ReferenceIndex].Payload, 0);
    }

    pub fn RefNameAndTypeIndex(Self: *const ConstantPool, ReferenceIndex: u16) u16 {
        return ReadUnsignedShort(Self.Entries.items[ReferenceIndex].Payload, 2);
    }

    fn AppendEntry(Self: *ConstantPool, Tag: u8, Payload: []u8) !u16 {
        const NewIndex: u16 = @intCast(Self.Entries.items.len);
        try Self.Entries.append(Self.Allocator, .{ .Tag = Tag, .Payload = Payload });
        return NewIndex;
    }

    pub fn FindUtf8(Self: *const ConstantPool, SearchBytes: []const u8) ?u16 {
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag != TagUtf8) continue;
            const Length = ReadUnsignedShort(CurrentEntry.Payload, 0);
            if (std.mem.eql(u8, CurrentEntry.Payload[2 .. 2 + Length], SearchBytes)) return Index;
        }
        return null;
    }

    pub fn AddUtf8(Self: *ConstantPool, ContentBytes: []const u8) !u16 {
        if (Self.FindUtf8(ContentBytes)) |Existing| return Existing;
        const Payload = try Self.Allocator.alloc(u8, 2 + ContentBytes.len);
        std.mem.writeInt(u16, Payload[0..2], @intCast(ContentBytes.len), .big);
        @memcpy(Payload[2..], ContentBytes);
        return Self.AppendEntry(TagUtf8, Payload);
    }

    fn FindTwoIndexReference(Self: *const ConstantPool, Tag: u8, FirstIndex: u16, SecondIndex: u16) ?u16 {
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag != Tag) continue;
            if (ReadUnsignedShort(CurrentEntry.Payload, 0) == FirstIndex and ReadUnsignedShort(CurrentEntry.Payload, 2) == SecondIndex) return Index;
        }
        return null;
    }

    fn FindOneIndexReference(Self: *const ConstantPool, Tag: u8, FirstIndex: u16) ?u16 {
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag != Tag) continue;
            if (ReadUnsignedShort(CurrentEntry.Payload, 0) == FirstIndex) return Index;
        }
        return null;
    }

    fn AddOneIndexReference(Self: *ConstantPool, Tag: u8, FirstIndex: u16) !u16 {
        if (Self.FindOneIndexReference(Tag, FirstIndex)) |Existing| return Existing;
        const Payload = try Self.Allocator.alloc(u8, 2);
        std.mem.writeInt(u16, Payload[0..2], FirstIndex, .big);
        return Self.AppendEntry(Tag, Payload);
    }

    fn AddTwoIndexReference(Self: *ConstantPool, Tag: u8, FirstIndex: u16, SecondIndex: u16) !u16 {
        if (Self.FindTwoIndexReference(Tag, FirstIndex, SecondIndex)) |Existing| return Existing;
        const Payload = try Self.Allocator.alloc(u8, 4);
        std.mem.writeInt(u16, Payload[0..2], FirstIndex, .big);
        std.mem.writeInt(u16, Payload[2..4], SecondIndex, .big);
        return Self.AppendEntry(Tag, Payload);
    }

    pub fn AddClass(Self: *ConstantPool, InternalName: []const u8) !u16 {
        const NameIndex = try Self.AddUtf8(InternalName);
        return Self.AddOneIndexReference(TagClass, NameIndex);
    }

    pub fn AddString(Self: *ConstantPool, Value: []const u8) !u16 {
        const Utf8Index = try Self.AddUtf8(Value);
        return Self.AddOneIndexReference(TagString, Utf8Index);
    }

    pub fn AddNameAndType(Self: *ConstantPool, Name: []const u8, Descriptor: []const u8) !u16 {
        const NameIndex = try Self.AddUtf8(Name);
        const DescriptorIndex = try Self.AddUtf8(Descriptor);
        return Self.AddTwoIndexReference(TagNameAndType, NameIndex, DescriptorIndex);
    }

    pub fn AddNameAndTypeIndices(Self: *ConstantPool, NameIndex: u16, DescriptorIndex: u16) !u16 {
        return Self.AddTwoIndexReference(TagNameAndType, NameIndex, DescriptorIndex);
    }

    pub fn AddMethodref(Self: *ConstantPool, OwnerInternalName: []const u8, Name: []const u8, Descriptor: []const u8) !u16 {
        const ClassIndex = try Self.AddClass(OwnerInternalName);
        const NameAndTypeIndex = try Self.AddNameAndType(Name, Descriptor);
        return Self.AddTwoIndexReference(TagMethodref, ClassIndex, NameAndTypeIndex);
    }

    pub fn AddFieldref(Self: *ConstantPool, OwnerInternalName: []const u8, Name: []const u8, Descriptor: []const u8) !u16 {
        const ClassIndex = try Self.AddClass(OwnerInternalName);
        const NameAndTypeIndex = try Self.AddNameAndType(Name, Descriptor);
        return Self.AddTwoIndexReference(TagFieldref, ClassIndex, NameAndTypeIndex);
    }

    pub fn AddMethodHandle(Self: *ConstantPool, Kind: u8, ReferenceIndex: u16) !u16 {
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag == TagMethodHandle and CurrentEntry.Payload[0] == Kind and ReadUnsignedShort(CurrentEntry.Payload, 1) == ReferenceIndex) return Index;
        }
        const Payload = try Self.Allocator.alloc(u8, 3);
        Payload[0] = Kind;
        std.mem.writeInt(u16, Payload[1..3], ReferenceIndex, .big);
        return Self.AppendEntry(TagMethodHandle, Payload);
    }

    pub fn AddInvokeDynamic(Self: *ConstantPool, BootstrapMethodAttributeIndex: u16, NameAndTypeIndex: u16) !u16 {
        if (Self.FindTwoIndexReference(TagInvokeDynamic, BootstrapMethodAttributeIndex, NameAndTypeIndex)) |Existing| return Existing;
        const Payload = try Self.Allocator.alloc(u8, 4);
        std.mem.writeInt(u16, Payload[0..2], BootstrapMethodAttributeIndex, .big);
        std.mem.writeInt(u16, Payload[2..4], NameAndTypeIndex, .big);
        return Self.AppendEntry(TagInvokeDynamic, Payload);
    }

    pub fn AddInteger(Self: *ConstantPool, Value: i32) !u16 {
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag == TagInteger and ReadUnsignedInt(CurrentEntry.Payload, 0) == @as(u32, @bitCast(Value))) return Index;
        }
        const Payload = try Self.Allocator.alloc(u8, 4);
        std.mem.writeInt(u32, Payload[0..4], @bitCast(Value), .big);
        return Self.AppendEntry(TagInteger, Payload);
    }

    pub fn AddLong(Self: *ConstantPool, Value: i64) !u16 {
        const Bits: u64 = @bitCast(Value);
        var Index: u16 = 1;
        while (Index < Self.Entries.items.len) : (Index += 1) {
            const CurrentEntry = Self.Entries.items[Index];
            if (CurrentEntry.Tag == TagLong and std.mem.readInt(u64, CurrentEntry.Payload[0..8], .big) == Bits) return Index;
        }
        const Payload = try Self.Allocator.alloc(u8, 8);
        std.mem.writeInt(u64, Payload[0..8], Bits, .big);
        const NewIndex = try Self.AppendEntry(TagLong, Payload);
        try Self.Entries.append(Self.Allocator, .{ .Tag = 0, .Payload = &.{} });
        return NewIndex;
    }

    pub fn SetUtf8Content(Self: *ConstantPool, Index: u16, NewBytes: []const u8) !void {
        const Payload = try Self.Allocator.alloc(u8, 2 + NewBytes.len);
        std.mem.writeInt(u16, Payload[0..2], @intCast(NewBytes.len), .big);
        @memcpy(Payload[2..], NewBytes);
        Self.Entries.items[Index].Payload = Payload;
    }

    pub fn SetRefNameAndType(Self: *ConstantPool, ReferenceIndex: u16, NewNameAndTypeIndex: u16) void {
        std.mem.writeInt(u16, Self.Entries.items[ReferenceIndex].Payload[2..4], NewNameAndTypeIndex, .big);
    }
};
