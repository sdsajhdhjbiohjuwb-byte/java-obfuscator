const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const RenameKeepSetAnalyzer = @import("RenameKeepSetAnalyzer.zig");
const IdentifierGenerator = @import("IdentifierGenerator.zig");
const MemberKey = @import("MemberKey.zig");

pub const Registry = struct {
    Map: std.StringHashMap([]const u8),
    Super: std.StringHashMap([]const u8),
    Declares: std.StringHashMap(void),

    pub fn Get(Self: *const Registry, AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8, Descriptor: []const u8) ?[]const u8 {
        const Key = MemberKey.Qualified(AllocatorHandle, Owner, Name, Descriptor) catch return null;
        return Self.Map.get(Key);
    }

    pub fn ResolveReference(Self: *const Registry, AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8, Descriptor: []const u8) ?[]const u8 {
        var Current = Owner;
        var Guard: usize = 0;
        while (Guard < 64) : (Guard += 1) {
            const Key = MemberKey.Qualified(AllocatorHandle, Current, Name, Descriptor) catch return null;
            if (Self.Declares.contains(Key)) return Self.Map.get(Key);
            const Parent = Self.Super.get(Current) orelse return null;
            Current = Parent;
        }
        return null;
    }
};

pub fn Build(AllocatorHandle: std.mem.Allocator, Classes: []const *ClassFileModel.ClassFile, Safelist: *const std.StringHashMap(void)) !Registry {
    var Map = std.StringHashMap([]const u8).init(AllocatorHandle);
    var Super = std.StringHashMap([]const u8).init(AllocatorHandle);
    var Declares = std.StringHashMap(void).init(AllocatorHandle);
    for (Classes) |CurrentClass| {
        const IsEnum = RenameKeepSetAnalyzer.IsEnumClass(CurrentClass);
        const Owner = CurrentClass.ThisName();
        if (CurrentClass.SuperClass != 0) {
            try Super.put(Owner, CurrentClass.ConstantPool.ClassName(CurrentClass.SuperClass));
        }
        for (CurrentClass.Fields.items) |Field| {
            try Declares.put(try MemberKey.Qualified(AllocatorHandle, Owner, CurrentClass.ConstantPool.Utf8Text(Field.NameIndex), CurrentClass.ConstantPool.Utf8Text(Field.DescriptorIndex)), {});
        }
        for (CurrentClass.Methods.items) |Member| {
            try Declares.put(try MemberKey.Qualified(AllocatorHandle, Owner, CurrentClass.ConstantPool.Utf8Text(Member.NameIndex), CurrentClass.ConstantPool.Utf8Text(Member.DescriptorIndex)), {});
        }

        var UsedNames = std.StringHashMap(void).init(AllocatorHandle);
        for (CurrentClass.Fields.items) |Field| try UsedNames.put(CurrentClass.ConstantPool.Utf8Text(Field.NameIndex), {});
        for (CurrentClass.Methods.items) |Member| try UsedNames.put(CurrentClass.ConstantPool.Utf8Text(Member.NameIndex), {});

        var Members: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
        for (CurrentClass.Fields.items) |Field| {
            if (RenameKeepSetAnalyzer.RenamableMember(CurrentClass, Field, IsEnum) and !Safelist.contains(CurrentClass.ConstantPool.Utf8Text(Field.NameIndex)))
                try Members.append(AllocatorHandle, Field);
        }
        for (CurrentClass.Methods.items) |Member| {
            if (RenameKeepSetAnalyzer.RenamableMember(CurrentClass, Member, IsEnum) and !Safelist.contains(CurrentClass.ConstantPool.Utf8Text(Member.NameIndex)))
                try Members.append(AllocatorHandle, Member);
        }
        if (Members.items.len == 0) continue;

        var Counter: usize = 0;
        for (Members.items) |Member| {
            const Name = CurrentClass.ConstantPool.Utf8Text(Member.NameIndex);
            const Descriptor = CurrentClass.ConstantPool.Utf8Text(Member.DescriptorIndex);
            var NewName = try IdentifierGenerator.AbcName(AllocatorHandle, Counter);
            Counter += 1;
            while (UsedNames.contains(NewName)) {
                NewName = try IdentifierGenerator.AbcName(AllocatorHandle, Counter);
                Counter += 1;
            }
            try UsedNames.put(NewName, {});
            try Map.put(try MemberKey.Qualified(AllocatorHandle, Owner, Name, Descriptor), NewName);
        }
    }
    return .{ .Map = Map, .Super = Super, .Declares = Declares };
}

pub fn Apply(AllocatorHandle: std.mem.Allocator, CurrentClass: *ClassFileModel.ClassFile, RenameRegistry: *const Registry) !void {
    const Owner = CurrentClass.ThisName();

    for (CurrentClass.Fields.items) |*Field| {
        const Name = CurrentClass.ConstantPool.Utf8Text(Field.NameIndex);
        const Descriptor = CurrentClass.ConstantPool.Utf8Text(Field.DescriptorIndex);
        if (RenameRegistry.Get(AllocatorHandle, Owner, Name, Descriptor)) |NewName| Field.NameIndex = try CurrentClass.ConstantPool.AddUtf8(NewName);
    }
    for (CurrentClass.Methods.items) |*Member| {
        const Name = CurrentClass.ConstantPool.Utf8Text(Member.NameIndex);
        const Descriptor = CurrentClass.ConstantPool.Utf8Text(Member.DescriptorIndex);
        if (RenameRegistry.Get(AllocatorHandle, Owner, Name, Descriptor)) |NewName| Member.NameIndex = try CurrentClass.ConstantPool.AddUtf8(NewName);
    }

    const EntryCount = CurrentClass.ConstantPool.Count();
    var Index: u16 = 1;
    while (Index < EntryCount) : (Index += 1) {
        const Entry = CurrentClass.ConstantPool.Entries.items[Index];
        if (Entry.Tag != ConstantPoolBuilder.TagMethodref and Entry.Tag != ConstantPoolBuilder.TagFieldref and Entry.Tag != ConstantPoolBuilder.TagInterfaceMethodref) continue;
        const ClassIndex = CurrentClass.ConstantPool.RefClassIndex(Index);
        const NameAndTypeIndex = CurrentClass.ConstantPool.RefNameAndTypeIndex(Index);
        const ReferenceOwner = CurrentClass.ConstantPool.ClassName(ClassIndex);
        const ReferenceName = CurrentClass.ConstantPool.Utf8Text(CurrentClass.ConstantPool.NameAndTypeName(NameAndTypeIndex));
        const DescriptorIndex = CurrentClass.ConstantPool.NameAndTypeDesc(NameAndTypeIndex);
        const ReferenceDescriptor = CurrentClass.ConstantPool.Utf8Text(DescriptorIndex);
        if (RenameRegistry.ResolveReference(AllocatorHandle, ReferenceOwner, ReferenceName, ReferenceDescriptor)) |NewName| {
            const NewNameIndex = try CurrentClass.ConstantPool.AddUtf8(NewName);
            const NewNameAndType = try CurrentClass.ConstantPool.AddNameAndTypeIndices(NewNameIndex, DescriptorIndex);
            CurrentClass.ConstantPool.SetRefNameAndType(Index, NewNameAndType);
        }
    }
}
