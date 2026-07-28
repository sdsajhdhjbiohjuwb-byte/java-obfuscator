const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");

const Set = std.StringHashMap(void);

pub fn ClassTierPlanner(
    AllocatorHandle: std.mem.Allocator,
    Models: []const *ClassFileModel.ClassFile,
    ModuleNames: *const Set,
    Roots: *const Set,
) !Set {
    var Uses = std.StringHashMap(Set).init(AllocatorHandle);
    for (Models) |Model| {
        try Uses.put(Model.ThisName(), try UsesAsType(AllocatorHandle, Model, ModuleNames));
    }

    var TierZero = Set.init(AllocatorHandle);
    var Queue: std.ArrayList([]const u8) = .empty;

    var RootIterator = Roots.keyIterator();
    while (RootIterator.next()) |Key| {
        if ((try TierZero.getOrPut(Key.*)).found_existing == false) try Queue.append(AllocatorHandle, Key.*);
    }
    var NameIterator = ModuleNames.keyIterator();
    while (NameIterator.next()) |Key| {
        if (std.mem.indexOfScalar(u8, Key.*, '$') != null) {
            if ((try TierZero.getOrPut(Key.*)).found_existing == false) try Queue.append(AllocatorHandle, Key.*);
        }
    }

    while (Queue.items.len > 0) {
        const Current = Queue.items[Queue.items.len - 1];
        Queue.items.len -= 1;
        if (Uses.getPtr(Current)) |UseSet| {
            var UseIterator = UseSet.keyIterator();
            while (UseIterator.next()) |UsedName| {
                if ((try TierZero.getOrPut(UsedName.*)).found_existing == false) try Queue.append(AllocatorHandle, UsedName.*);
            }
        }
    }

    var TierOne = Set.init(AllocatorHandle);
    var ModuleIterator = ModuleNames.keyIterator();
    while (ModuleIterator.next()) |Key| {
        if (!TierZero.contains(Key.*)) try TierOne.put(Key.*, {});
    }
    return TierOne;
}

fn UsesAsType(AllocatorHandle: std.mem.Allocator, ClassFileEntry: *ClassFileModel.ClassFile, ModuleNames: *const Set) !Set {
    var TypeSet = Set.init(AllocatorHandle);
    if (ClassFileEntry.SuperClass != 0) try AddClassReference(&TypeSet, ClassFileEntry.ConstantPool.ClassName(ClassFileEntry.SuperClass), ModuleNames);
    for (ClassFileEntry.Interfaces.items) |InterfaceIndex| try AddClassReference(&TypeSet, ClassFileEntry.ConstantPool.ClassName(InterfaceIndex), ModuleNames);

    for (ClassFileEntry.Fields.items) |Field| {
        try AddDescriptorTypes(&TypeSet, ClassFileEntry.ConstantPool.Utf8Text(Field.DescriptorIndex), ModuleNames);
        try ScanSignature(&TypeSet, ClassFileEntry, Field.Attributes.items, ModuleNames);
    }
    for (ClassFileEntry.Methods.items) |Method| {
        try AddDescriptorTypes(&TypeSet, ClassFileEntry.ConstantPool.Utf8Text(Method.DescriptorIndex), ModuleNames);
        try ScanSignature(&TypeSet, ClassFileEntry, Method.Attributes.items, ModuleNames);
        if (ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFileEntry.ConstantPool, "Code")) |CodeAttributeIndex| {
            const Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
            try ScanCode(&TypeSet, ClassFileEntry, &Code, ModuleNames);
        }
    }
    try ScanSignature(&TypeSet, ClassFileEntry, ClassFileEntry.Attributes.items, ModuleNames);
    try ScanNesting(&TypeSet, ClassFileEntry, ModuleNames);
    return TypeSet;
}

fn ScanSignature(TypeSet: *Set, ClassFileEntry: *ClassFileModel.ClassFile, Attributes: []const ClassFileModel.Attribute, ModuleNames: *const Set) !void {
    for (Attributes) |AttributeEntry| {
        if (std.mem.eql(u8, ClassFileEntry.ConstantPool.Utf8Text(AttributeEntry.NameIndex), "Signature") and AttributeEntry.Info.len >= 2) {
            try AddDescriptorTypes(TypeSet, ClassFileEntry.ConstantPool.Utf8Text(ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 0)), ModuleNames);
        }
    }
}

fn ScanNesting(TypeSet: *Set, ClassFileEntry: *ClassFileModel.ClassFile, ModuleNames: *const Set) !void {
    for (ClassFileEntry.Attributes.items) |AttributeEntry| {
        const Name = ClassFileEntry.ConstantPool.Utf8Text(AttributeEntry.NameIndex);
        if (std.mem.eql(u8, Name, "NestHost") and AttributeEntry.Info.len >= 2) {
            try AddClassIndex(TypeSet, ClassFileEntry, ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 0), ModuleNames);
        } else if (std.mem.eql(u8, Name, "NestMembers") and AttributeEntry.Info.len >= 2) {
            const Count = ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 0);
            var Index: usize = 0;
            while (Index < Count and 2 + Index * 2 + 1 < AttributeEntry.Info.len) : (Index += 1) {
                try AddClassIndex(TypeSet, ClassFileEntry, ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 2 + Index * 2), ModuleNames);
            }
        } else if (std.mem.eql(u8, Name, "InnerClasses") and AttributeEntry.Info.len >= 2) {
            const Count = ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 0);
            var Index: usize = 0;
            while (Index < Count and 2 + Index * 8 + 1 < AttributeEntry.Info.len) : (Index += 1) {
                try AddClassIndex(TypeSet, ClassFileEntry, ConstantPoolBuilder.ReadUnsignedShort(AttributeEntry.Info, 2 + Index * 8), ModuleNames);
            }
        }
    }
}

fn ScanCode(TypeSet: *Set, ClassFileEntry: *ClassFileModel.ClassFile, Code: *const BytecodeInstructionModel.CodeAttribute, ModuleNames: *const Set) !void {
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Kind != .Fixed) continue;
        switch (Instruction.Operation) {
            0xbb, 0xc0, 0xc1, 0xbd, 0xc5 => try AddClassIndex(TypeSet, ClassFileEntry, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), ModuleNames),
            0x12 => {
                const Index: u16 = Instruction.Raw[0];
                if (ClassFileEntry.ConstantPool.TagOf(Index) == ConstantPoolBuilder.TagClass) try AddClassIndex(TypeSet, ClassFileEntry, Index, ModuleNames);
            },
            0x13 => {
                const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
                if (ClassFileEntry.ConstantPool.TagOf(Index) == ConstantPoolBuilder.TagClass) try AddClassIndex(TypeSet, ClassFileEntry, Index, ModuleNames);
            },
            0xb6, 0xb7, 0xb8, 0xb9, 0xb4, 0xb5, 0xb2, 0xb3 => {
                const OwnerClassIndex = ClassFileEntry.ConstantPool.RefClassIndex(ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0));
                try AddClassIndex(TypeSet, ClassFileEntry, OwnerClassIndex, ModuleNames);
            },
            else => {},
        }
    }
    for (Code.Exceptions.items) |ExceptionEntry| {
        if (ExceptionEntry.CatchType != 0) try AddClassIndex(TypeSet, ClassFileEntry, ExceptionEntry.CatchType, ModuleNames);
    }
}

fn AddClassIndex(TypeSet: *Set, ClassFileEntry: *ClassFileModel.ClassFile, ClassIndex: u16, ModuleNames: *const Set) !void {
    if (ClassIndex == 0 or ClassFileEntry.ConstantPool.TagOf(ClassIndex) != ConstantPoolBuilder.TagClass) return;
    try AddClassReference(TypeSet, ClassFileEntry.ConstantPool.ClassName(ClassIndex), ModuleNames);
}

fn AddClassReference(TypeSet: *Set, Name: []const u8, ModuleNames: *const Set) !void {
    if (Name.len == 0) return;
    if (Name[0] == '[') {
        try AddDescriptorTypes(TypeSet, Name, ModuleNames);
        return;
    }
    if (ModuleNames.contains(Name)) try TypeSet.put(Name, {});
}

fn AddDescriptorTypes(TypeSet: *Set, Descriptor: []const u8, ModuleNames: *const Set) !void {
    var Index: usize = 0;
    while (Index < Descriptor.len) {
        if (Descriptor[Index] == 'L') {
            var InnerIndex = Index + 1;
            while (InnerIndex < Descriptor.len and Descriptor[InnerIndex] != ';') InnerIndex += 1;
            const Name = Descriptor[Index + 1 .. InnerIndex];
            if (ModuleNames.contains(Name)) try TypeSet.put(Name, {});
            Index = InnerIndex + 1;
        } else Index += 1;
    }
}
