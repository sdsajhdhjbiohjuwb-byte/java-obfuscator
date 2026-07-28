const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const RenameKeepSetAnalyzer = @import("RenameKeepSetAnalyzer.zig");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const MemberKey = @import("MemberKey.zig");

pub const DeadSet = struct {
    Map: std.StringHashMap(void),

    pub fn Contains(Self: *const DeadSet, AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8, Descriptor: []const u8) bool {
        const Key = MemberKey.Qualified(AllocatorHandle, Owner, Name, Descriptor) catch return false;
        return Self.Map.contains(Key);
    }
};

fn IsMemberRemovable(AllocatorHandle: std.mem.Allocator, ClassFileEntry: *const ClassFileModel.ClassFile, Member: ClassFileModel.MemberInfo, IsEnum: bool, MethodHandleProtectedSet: *const std.StringHashMap(void)) bool {
    const Name = ClassFileEntry.ConstantPool.Utf8Text(Member.NameIndex);
    if (std.mem.eql(u8, Name, "<init>") or std.mem.eql(u8, Name, "<clinit>")) return false;
    if ((Member.AccessFlags & AccessFlags.AccessNative) != 0) return false;
    if ((Member.AccessFlags & (AccessFlags.AccessPublic | AccessFlags.AccessProtected)) != 0) return false;
    if (IsEnum and (std.mem.eql(u8, Name, "values") or std.mem.eql(u8, Name, "valueOf") or std.mem.eql(u8, Name, "$VALUES"))) return false;
    if (std.mem.eql(u8, Name, "serialVersionUID")) return false;
    if (RenameKeepSetAnalyzer.IsSerializationCallback(Name)) return false;
    const Descriptor = ClassFileEntry.ConstantPool.Utf8Text(Member.DescriptorIndex);
    if (std.mem.eql(u8, Name, "main") and (Member.AccessFlags & AccessFlags.AccessStatic) != 0 and std.mem.eql(u8, Descriptor, "([Ljava/lang/String;)V")) return false;
    const IsMethod = Descriptor.len > 0 and Descriptor[0] == '(';
    if (IsMethod) {
        if ((Member.AccessFlags & AccessFlags.AccessStatic) == 0 and (Member.AccessFlags & AccessFlags.AccessPrivate) == 0) return false;
    } else {
        if ((Member.AccessFlags & AccessFlags.AccessPrivate) == 0) return false;
    }
    const Key = MemberKey.Signature(AllocatorHandle, Name, Descriptor) catch return false;
    if (MethodHandleProtectedSet.contains(Key)) return false;
    return true;
}

pub fn Analyze(AllocatorHandle: std.mem.Allocator, Classes: []const *ClassFileModel.ClassFile) !DeadSet {
    var Referenced = std.StringHashMap(void).init(AllocatorHandle);
    for (Classes) |ClassFileEntry| {
        var Index: u16 = 1;
        while (Index < ClassFileEntry.ConstantPool.Count()) : (Index += 1) {
            const Entry = ClassFileEntry.ConstantPool.Entries.items[Index];
            if (Entry.Tag != ConstantPoolBuilder.TagMethodref and Entry.Tag != ConstantPoolBuilder.TagFieldref and Entry.Tag != ConstantPoolBuilder.TagInterfaceMethodref) continue;
            const Owner = ClassFileEntry.ConstantPool.ClassName(ClassFileEntry.ConstantPool.RefClassIndex(Index));
            const NameAndTypeIndex = ClassFileEntry.ConstantPool.RefNameAndTypeIndex(Index);
            const Name = ClassFileEntry.ConstantPool.Utf8Text(ClassFileEntry.ConstantPool.NameAndTypeName(NameAndTypeIndex));
            const Descriptor = ClassFileEntry.ConstantPool.Utf8Text(ClassFileEntry.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
            try Referenced.put(try MemberKey.Qualified(AllocatorHandle, Owner, Name, Descriptor), {});
        }
    }

    var MethodHandleProtectedSet = try RenameKeepSetAnalyzer.CollectMethodHandleTargets(AllocatorHandle, Classes);

    var Dead = std.StringHashMap(void).init(AllocatorHandle);
    for (Classes) |ClassFileEntry| {
        const IsEnum = RenameKeepSetAnalyzer.IsEnumClass(ClassFileEntry);
        const Owner = ClassFileEntry.ThisName();
        for (ClassFileEntry.Fields.items) |Field| {
            if (!IsMemberRemovable(AllocatorHandle, ClassFileEntry, Field, IsEnum, &MethodHandleProtectedSet)) continue;
            const Key = try MemberKey.Qualified(AllocatorHandle, Owner, ClassFileEntry.ConstantPool.Utf8Text(Field.NameIndex), ClassFileEntry.ConstantPool.Utf8Text(Field.DescriptorIndex));
            if (!Referenced.contains(Key)) try Dead.put(Key, {});
        }
        for (ClassFileEntry.Methods.items) |Member| {
            if (!IsMemberRemovable(AllocatorHandle, ClassFileEntry, Member, IsEnum, &MethodHandleProtectedSet)) continue;
            const Key = try MemberKey.Qualified(AllocatorHandle, Owner, ClassFileEntry.ConstantPool.Utf8Text(Member.NameIndex), ClassFileEntry.ConstantPool.Utf8Text(Member.DescriptorIndex));
            if (!Referenced.contains(Key)) try Dead.put(Key, {});
        }
    }
    return .{ .Map = Dead };
}

pub fn Apply(AllocatorHandle: std.mem.Allocator, ClassFileEntry: *ClassFileModel.ClassFile, Dead: *const DeadSet) !usize {
    if (Dead.Map.count() == 0) return 0;
    const Owner = ClassFileEntry.ThisName();
    var Removed: usize = 0;

    var KeptFields: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    for (ClassFileEntry.Fields.items) |Field| {
        if (Dead.Contains(AllocatorHandle, Owner, ClassFileEntry.ConstantPool.Utf8Text(Field.NameIndex), ClassFileEntry.ConstantPool.Utf8Text(Field.DescriptorIndex))) {
            Removed += 1;
            continue;
        }
        try KeptFields.append(AllocatorHandle, Field);
    }
    ClassFileEntry.Fields = KeptFields;

    var KeptMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    for (ClassFileEntry.Methods.items) |Member| {
        if (Dead.Contains(AllocatorHandle, Owner, ClassFileEntry.ConstantPool.Utf8Text(Member.NameIndex), ClassFileEntry.ConstantPool.Utf8Text(Member.DescriptorIndex))) {
            Removed += 1;
            continue;
        }
        try KeptMethods.append(AllocatorHandle, Member);
    }
    ClassFileEntry.Methods = KeptMethods;

    return Removed;
}
