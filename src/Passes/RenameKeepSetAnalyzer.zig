const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const MemberKey = @import("MemberKey.zig");

const ClearVisibility: u16 = ~@as(u16, AccessFlags.AccessPrivate | AccessFlags.AccessProtected);

pub fn CollectStringConstants(AllocatorHandle: std.mem.Allocator, Classes: []const *ClassFileModel.ClassFile) !std.StringHashMap(void) {
    var StringConstantSet = std.StringHashMap(void).init(AllocatorHandle);
    for (Classes) |ClassFile| {
        var Index: u16 = 1;
        while (Index < ClassFile.ConstantPool.Count()) : (Index += 1) {
            if (ClassFile.ConstantPool.Entries.items[Index].Tag != ConstantPoolBuilder.TagString) continue;
            try StringConstantSet.put(ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.RefIndex(Index)), {});
        }
    }
    return StringConstantSet;
}

pub fn IsEnumClass(ClassFile: *const ClassFileModel.ClassFile) bool {
    if ((ClassFile.AccessFlags & AccessFlags.AccessEnum) != 0) return true;
    if (ClassFile.SuperClass == 0) return false;
    return std.mem.eql(u8, ClassFile.ConstantPool.ClassName(ClassFile.SuperClass), "java/lang/Enum");
}

const SerializationMethodNames = [_][]const u8{ "readObject", "writeObject", "readResolve", "writeReplace", "readObjectNoData", "validateObject" };

pub fn IsSerializationCallback(Name: []const u8) bool {
    for (SerializationMethodNames) |SerializationMethodName| {
        if (std.mem.eql(u8, Name, SerializationMethodName)) return true;
    }
    return false;
}

pub fn CollectMethodHandleTargets(AllocatorHandle: std.mem.Allocator, Classes: []const *ClassFileModel.ClassFile) !std.StringHashMap(void) {
    var MethodHandleTargetSet = std.StringHashMap(void).init(AllocatorHandle);
    for (Classes) |ClassFile| {
        var Index: u16 = 1;
        const PoolCount = ClassFile.ConstantPool.Count();
        while (Index < PoolCount) : (Index += 1) {
            const Entry = ClassFile.ConstantPool.Entries.items[Index];
            if (Entry.Tag != ConstantPoolBuilder.TagMethodHandle or Entry.Payload.len < 3) continue;
            const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 1);
            if (ReferenceIndex == 0 or ReferenceIndex >= PoolCount) continue;
            const ReferenceEntry = ClassFile.ConstantPool.Entries.items[ReferenceIndex];
            if (ReferenceEntry.Tag != ConstantPoolBuilder.TagMethodref and ReferenceEntry.Tag != ConstantPoolBuilder.TagFieldref and ReferenceEntry.Tag != ConstantPoolBuilder.TagInterfaceMethodref) continue;
            const NameAndTypeIndex = ClassFile.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
            const Name = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(NameAndTypeIndex));
            const Descriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
            try MethodHandleTargetSet.put(try MemberKey.Signature(AllocatorHandle, Name, Descriptor), {});
        }
    }
    return MethodHandleTargetSet;
}

pub fn RenamableMember(
    ClassFile: *const ClassFileModel.ClassFile,
    Member: ClassFileModel.MemberInfo,
    IsEnum: bool,
) bool {
    const Name = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
    if (std.mem.eql(u8, Name, "<init>") or std.mem.eql(u8, Name, "<clinit>")) return false;
    if (std.mem.eql(u8, Name, "serialVersionUID")) return false;
    if ((Member.AccessFlags & AccessFlags.AccessNative) != 0) return false;
    if ((Member.AccessFlags & AccessFlags.AccessBridge) != 0) return false;
    if (IsEnum and (std.mem.eql(u8, Name, "values") or std.mem.eql(u8, Name, "valueOf") or std.mem.eql(u8, Name, "$VALUES"))) return false;
    const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
    if (std.mem.eql(u8, Name, "main") and (Member.AccessFlags & AccessFlags.AccessStatic) != 0 and std.mem.eql(u8, Descriptor, "([Ljava/lang/String;)V")) return false;
    if (IsSerializationCallback(Name)) return false;
    const IsInstanceMethod = Descriptor.len > 0 and Descriptor[0] == '(' and (Member.AccessFlags & AccessFlags.AccessStatic) == 0;
    if (IsInstanceMethod and (Member.AccessFlags & AccessFlags.AccessPrivate) == 0) return false;
    return true;
}

pub fn PromoteAccess(ClassFile: *ClassFileModel.ClassFile) void {
    ClassFile.AccessFlags = (ClassFile.AccessFlags & ClearVisibility) | AccessFlags.AccessPublic;
    for (ClassFile.Fields.items) |*Field| Field.AccessFlags = (Field.AccessFlags & ClearVisibility) | AccessFlags.AccessPublic;
    for (ClassFile.Methods.items) |*Member| {
        if (IsSerializationCallback(ClassFile.ConstantPool.Utf8Text(Member.NameIndex))) continue;
        Member.AccessFlags = (Member.AccessFlags & ClearVisibility) | AccessFlags.AccessPublic;
    }
}
