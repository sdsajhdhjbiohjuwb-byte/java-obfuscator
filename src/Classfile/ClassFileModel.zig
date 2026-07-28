const std = @import("std");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");

pub const ConstantPool = ConstantPoolBuilder.ConstantPool;
pub const ReadUnsignedShort = ConstantPoolBuilder.ReadUnsignedShort;
pub const ReadUnsignedInt = ConstantPoolBuilder.ReadUnsignedInt;
pub const WriteUnsignedShort = ConstantPoolBuilder.WriteUnsignedShort;
pub const WriteUnsignedInt = ConstantPoolBuilder.WriteUnsignedInt;

pub const Magic: u32 = 0xCAFEBABE;

pub const Attribute = struct {
    NameIndex: u16,
    Info: []u8,
};

pub const MemberInfo = struct {
    AccessFlags: u16,
    NameIndex: u16,
    DescriptorIndex: u16,
    Attributes: std.ArrayList(Attribute),
};

pub const ClassFile = struct {
    Allocator: std.mem.Allocator,
    Minor: u16,
    Major: u16,
    ConstantPool: ConstantPool,
    AccessFlags: u16,
    ThisClass: u16,
    SuperClass: u16,
    Interfaces: std.ArrayList(u16),
    Fields: std.ArrayList(MemberInfo),
    Methods: std.ArrayList(MemberInfo),
    Attributes: std.ArrayList(Attribute),

    pub fn ThisName(Self: *const ClassFile) []const u8 {
        return Self.ConstantPool.ClassName(Self.ThisClass);
    }
};

pub fn ParseAttributes(AllocatorHandle: std.mem.Allocator, Bytes: []const u8, Offset: *usize) !std.ArrayList(Attribute) {
    const Count = ReadUnsignedShort(Bytes, Offset.*);
    Offset.* += 2;
    var List: std.ArrayList(Attribute) = .empty;
    var Index: usize = 0;
    while (Index < Count) : (Index += 1) {
        const NameIndex = ReadUnsignedShort(Bytes, Offset.*);
        const Length = ReadUnsignedInt(Bytes, Offset.* + 2);
        const Info = try AllocatorHandle.dupe(u8, Bytes[Offset.* + 6 .. Offset.* + 6 + Length]);
        try List.append(AllocatorHandle, .{ .NameIndex = NameIndex, .Info = Info });
        Offset.* += 6 + Length;
    }
    return List;
}

fn ParseMembers(AllocatorHandle: std.mem.Allocator, Bytes: []const u8, Offset: *usize) !std.ArrayList(MemberInfo) {
    const Count = ReadUnsignedShort(Bytes, Offset.*);
    Offset.* += 2;
    var List: std.ArrayList(MemberInfo) = .empty;
    var Index: usize = 0;
    while (Index < Count) : (Index += 1) {
        const AccessFlags = ReadUnsignedShort(Bytes, Offset.*);
        const NameIndex = ReadUnsignedShort(Bytes, Offset.* + 2);
        const DescriptorIndex = ReadUnsignedShort(Bytes, Offset.* + 4);
        Offset.* += 6;
        const AttributeList = try ParseAttributes(AllocatorHandle, Bytes, Offset);
        try List.append(AllocatorHandle, .{
            .AccessFlags = AccessFlags,
            .NameIndex = NameIndex,
            .DescriptorIndex = DescriptorIndex,
            .Attributes = AttributeList,
        });
    }
    return List;
}

pub fn FindAttribute(AttributeSlice: []const Attribute, Pool: *const ConstantPool, Name: []const u8) ?usize {
    for (AttributeSlice, 0..) |AttributeItem, Index| {
        if (std.mem.eql(u8, Pool.Utf8Text(AttributeItem.NameIndex), Name)) return Index;
    }
    return null;
}

pub fn Parse(AllocatorHandle: std.mem.Allocator, Bytes: []const u8) !ClassFile {
    if (Bytes.len < 10 or ReadUnsignedInt(Bytes, 0) != Magic) return error.NotAClassFile;
    const Minor = ReadUnsignedShort(Bytes, 4);
    const Major = ReadUnsignedShort(Bytes, 6);
    var Offset: usize = 8;
    const Pool = try ConstantPool.ParseFrom(AllocatorHandle, Bytes, &Offset);

    const AccessFlags = ReadUnsignedShort(Bytes, Offset);
    const ThisClass = ReadUnsignedShort(Bytes, Offset + 2);
    const SuperClass = ReadUnsignedShort(Bytes, Offset + 4);
    Offset += 6;

    const InterfaceCount = ReadUnsignedShort(Bytes, Offset);
    Offset += 2;
    var Interfaces: std.ArrayList(u16) = .empty;
    var Index: usize = 0;
    while (Index < InterfaceCount) : (Index += 1) {
        try Interfaces.append(AllocatorHandle, ReadUnsignedShort(Bytes, Offset));
        Offset += 2;
    }

    const Fields = try ParseMembers(AllocatorHandle, Bytes, &Offset);
    const Methods = try ParseMembers(AllocatorHandle, Bytes, &Offset);
    const Attributes = try ParseAttributes(AllocatorHandle, Bytes, &Offset);

    return .{
        .Allocator = AllocatorHandle,
        .Minor = Minor,
        .Major = Major,
        .ConstantPool = Pool,
        .AccessFlags = AccessFlags,
        .ThisClass = ThisClass,
        .SuperClass = SuperClass,
        .Interfaces = Interfaces,
        .Fields = Fields,
        .Methods = Methods,
        .Attributes = Attributes,
    };
}

pub fn SerializeAttributes(OutputWriter: *std.Io.Writer, AttributeSlice: []const Attribute) !void {
    try WriteUnsignedShort(OutputWriter, @intCast(AttributeSlice.len));
    for (AttributeSlice) |AttributeItem| {
        try WriteUnsignedShort(OutputWriter, AttributeItem.NameIndex);
        try WriteUnsignedInt(OutputWriter, @intCast(AttributeItem.Info.len));
        try OutputWriter.writeAll(AttributeItem.Info);
    }
}

fn SerializeMembers(OutputWriter: *std.Io.Writer, Members: []const MemberInfo) !void {
    try WriteUnsignedShort(OutputWriter, @intCast(Members.len));
    for (Members) |Member| {
        try WriteUnsignedShort(OutputWriter, Member.AccessFlags);
        try WriteUnsignedShort(OutputWriter, Member.NameIndex);
        try WriteUnsignedShort(OutputWriter, Member.DescriptorIndex);
        try SerializeAttributes(OutputWriter, Member.Attributes.items);
    }
}

pub fn Serialize(AllocatorHandle: std.mem.Allocator, ClassFileReference: *const ClassFile) ![]u8 {
    var Output = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, 64 * 1024);
    const OutputWriter = &Output.writer;
    try WriteUnsignedInt(OutputWriter, Magic);
    try WriteUnsignedShort(OutputWriter, ClassFileReference.Minor);
    try WriteUnsignedShort(OutputWriter, ClassFileReference.Major);
    try ClassFileReference.ConstantPool.Serialize(OutputWriter);
    try WriteUnsignedShort(OutputWriter, ClassFileReference.AccessFlags);
    try WriteUnsignedShort(OutputWriter, ClassFileReference.ThisClass);
    try WriteUnsignedShort(OutputWriter, ClassFileReference.SuperClass);
    try WriteUnsignedShort(OutputWriter, @intCast(ClassFileReference.Interfaces.items.len));
    for (ClassFileReference.Interfaces.items) |Interface| try WriteUnsignedShort(OutputWriter, Interface);
    try SerializeMembers(OutputWriter, ClassFileReference.Fields.items);
    try SerializeMembers(OutputWriter, ClassFileReference.Methods.items);
    try SerializeAttributes(OutputWriter, ClassFileReference.Attributes.items);
    return Output.written();
}
