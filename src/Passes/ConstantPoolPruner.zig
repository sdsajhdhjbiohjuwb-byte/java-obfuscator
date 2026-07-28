const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");

const OrphanNames = [_][]const u8{
    "SourceFile",
    "SourceDebugExtension",
    "Signature",
    "Deprecated",
    "Synthetic",
    "MethodParameters",
    "LineNumberTable",
    "LocalVariableTable",
    "LocalVariableTypeTable",
    "RuntimeVisibleTypeAnnotations",
    "RuntimeInvisibleTypeAnnotations",
};

const ComplexNames = [_][]const u8{
    "RuntimeVisibleAnnotations",
    "RuntimeInvisibleAnnotations",
    "RuntimeVisibleParameterAnnotations",
    "RuntimeInvisibleParameterAnnotations",
    "AnnotationDefault",
    "Record",
    "Module",
    "ModulePackages",
    "ModuleMainClass",
};

fn InList(TargetName: []const u8, NameList: []const []const u8) bool {
    for (NameList) |Candidate| {
        if (std.mem.eql(u8, TargetName, Candidate)) return true;
    }
    return false;
}

fn Mark(MarkFlags: []bool, Index: u16) void {
    if (Index != 0 and Index < MarkFlags.len) MarkFlags[Index] = true;
}

fn IsSimple(ClassFile: *ClassFileModel.ClassFile) bool {
    for (ClassFile.Attributes.items) |Attribute| {
        if (InList(ClassFile.ConstantPool.Utf8Text(Attribute.NameIndex), &ComplexNames)) return false;
    }
    for (ClassFile.Fields.items) |Field| {
        for (Field.Attributes.items) |Attribute| {
            if (InList(ClassFile.ConstantPool.Utf8Text(Attribute.NameIndex), &ComplexNames)) return false;
        }
    }
    for (ClassFile.Methods.items) |Method| {
        for (Method.Attributes.items) |Attribute| {
            if (InList(ClassFile.ConstantPool.Utf8Text(Attribute.NameIndex), &ComplexNames)) return false;
        }
    }
    return true;
}

fn MarkLiveNameAndType(ClassFile: *ClassFileModel.ClassFile, LiveFlags: []bool, Index: u16) void {
    if (Index == 0 or Index >= LiveFlags.len) return;
    const Entry = ClassFile.ConstantPool.Entries.items[Index];
    switch (Entry.Tag) {
        ConstantPoolBuilder.TagMethodref, ConstantPoolBuilder.TagFieldref, ConstantPoolBuilder.TagInterfaceMethodref, ConstantPoolBuilder.TagInvokeDynamic, ConstantPoolBuilder.TagDynamic => {
            if (Entry.Payload.len >= 4) Mark(LiveFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 2));
        },
        ConstantPoolBuilder.TagMethodHandle => {
            if (Entry.Payload.len >= 3) MarkLiveNameAndType(ClassFile, LiveFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 1));
        },
        else => {},
    }
}

fn MarkLiveString(ClassFile: *ClassFileModel.ClassFile, LiveFlags: []bool, Index: u16) void {
    if (Index != 0 and Index < LiveFlags.len and ClassFile.ConstantPool.TagOf(Index) == ConstantPoolBuilder.TagString) LiveFlags[Index] = true;
}

fn MarkReferenced(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, ReferencedFlags: []bool, LiveStrings: ?[]const bool) !void {
    var Index: u16 = 1;
    const PoolCount = ClassFile.ConstantPool.Count();
    while (Index < PoolCount) : (Index += 1) {
        const Entry = ClassFile.ConstantPool.Entries.items[Index];
        switch (Entry.Tag) {
            ConstantPoolBuilder.TagClass, ConstantPoolBuilder.TagMethodType, ConstantPoolBuilder.TagModule, ConstantPoolBuilder.TagPackage => {
                if (Entry.Payload.len >= 2) Mark(ReferencedFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 0));
            },
            ConstantPoolBuilder.TagString => {
                const StringIsLive = if (LiveStrings) |Flags| (Index < Flags.len and Flags[Index]) else true;
                if (StringIsLive and Entry.Payload.len >= 2) Mark(ReferencedFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 0));
            },
            ConstantPoolBuilder.TagNameAndType => {
                if (Entry.Payload.len >= 4) {
                    Mark(ReferencedFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 0));
                    Mark(ReferencedFlags, ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 2));
                }
            },
            else => {},
        }
    }
    for (ClassFile.Fields.items) |Field| {
        Mark(ReferencedFlags, Field.NameIndex);
        Mark(ReferencedFlags, Field.DescriptorIndex);
        for (Field.Attributes.items) |Attribute| Mark(ReferencedFlags, Attribute.NameIndex);
    }
    for (ClassFile.Methods.items) |Method| {
        Mark(ReferencedFlags, Method.NameIndex);
        Mark(ReferencedFlags, Method.DescriptorIndex);
        for (Method.Attributes.items) |Attribute| {
            Mark(ReferencedFlags, Attribute.NameIndex);
            if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Attribute.NameIndex), "Code")) {
                const ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Attribute.Info);
                for (ParsedCode.Attributes.items) |CodeChildAttribute| Mark(ReferencedFlags, CodeChildAttribute.NameIndex);
            }
        }
    }
    for (ClassFile.Attributes.items) |Attribute| Mark(ReferencedFlags, Attribute.NameIndex);

    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "InnerClasses")) |InnerClassesIndex| {
        const Info = ClassFile.Attributes.items[InnerClassesIndex].Info;
        const EntryCount = ConstantPoolBuilder.ReadUnsignedShort(Info, 0);
        var Offset: usize = 2;
        var ThirdIndex: usize = 0;
        while (ThirdIndex < EntryCount and Offset + 8 <= Info.len) : (ThirdIndex += 1) {
            Mark(ReferencedFlags, ConstantPoolBuilder.ReadUnsignedShort(Info, Offset + 4));
            Offset += 8;
        }
    }
}

pub fn ConstantPoolPruner(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile) !void {
    const InitialPoolCount = ClassFile.ConstantPool.Count();
    if (InitialPoolCount == 0) return;

    if (!IsSimple(ClassFile)) {
        const ReferencedFlags = try AllocatorHandle.alloc(bool, InitialPoolCount);
        @memset(ReferencedFlags, false);
        try MarkReferenced(AllocatorHandle, ClassFile, ReferencedFlags, null);
        var Index: u16 = 1;
        while (Index < InitialPoolCount) : (Index += 1) {
            if (ClassFile.ConstantPool.Entries.items[Index].Tag != ConstantPoolBuilder.TagUtf8) continue;
            if (ReferencedFlags[Index]) continue;
            if (InList(ClassFile.ConstantPool.Utf8Text(Index), &OrphanNames)) try ClassFile.ConstantPool.SetUtf8Content(Index, &.{});
        }
        return;
    }

    const LiveNameAndTypeFlags = try AllocatorHandle.alloc(bool, InitialPoolCount);
    @memset(LiveNameAndTypeFlags, false);
    const LiveStringFlags = try AllocatorHandle.alloc(bool, InitialPoolCount);
    @memset(LiveStringFlags, false);
    for (ClassFile.Fields.items) |Field| {
        for (Field.Attributes.items) |Attribute| {
            if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Attribute.NameIndex), "ConstantValue") and Attribute.Info.len >= 2) {
                MarkLiveString(ClassFile, LiveStringFlags, ConstantPoolBuilder.ReadUnsignedShort(Attribute.Info, 0));
            }
        }
    }
    for (ClassFile.Methods.items) |Method| {
        if (ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code")) |CodeIndex| {
            const ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeIndex].Info);
            for (ParsedCode.Instructions.items) |Instruction| {
                if (Instruction.Kind != .Fixed or Instruction.Raw.len < 2) continue;
                switch (Instruction.Operation) {
                    0x12 => {
                        MarkLiveNameAndType(ClassFile, LiveNameAndTypeFlags, Instruction.Raw[0]);
                        MarkLiveString(ClassFile, LiveStringFlags, Instruction.Raw[0]);
                    },
                    0x13 => {
                        const LdcWideIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
                        MarkLiveNameAndType(ClassFile, LiveNameAndTypeFlags, LdcWideIndex);
                        MarkLiveString(ClassFile, LiveStringFlags, LdcWideIndex);
                    },
                    0x14, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba => MarkLiveNameAndType(ClassFile, LiveNameAndTypeFlags, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0)),
                    else => {},
                }
            }
        }
    }
    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods")) |BootstrapMethodsIndex| {
        const Info = ClassFile.Attributes.items[BootstrapMethodsIndex].Info;
        const EntryCount = ConstantPoolBuilder.ReadUnsignedShort(Info, 0);
        var Offset: usize = 2;
        var ThirdIndex: usize = 0;
        while (ThirdIndex < EntryCount and Offset + 4 <= Info.len) : (ThirdIndex += 1) {
            MarkLiveNameAndType(ClassFile, LiveNameAndTypeFlags, ConstantPoolBuilder.ReadUnsignedShort(Info, Offset));
            Offset += 2;
            const ArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(Info, Offset);
            Offset += 2;
            var ArgumentIndex: usize = 0;
            while (ArgumentIndex < ArgumentCount and Offset + 2 <= Info.len) : (ArgumentIndex += 1) {
                const ArgumentConstant = ConstantPoolBuilder.ReadUnsignedShort(Info, Offset);
                MarkLiveNameAndType(ClassFile, LiveNameAndTypeFlags, ArgumentConstant);
                MarkLiveString(ClassFile, LiveStringFlags, ArgumentConstant);
                Offset += 2;
            }
        }
    }
    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "EnclosingMethod")) |EnclosingMethodIndex| {
        const Info = ClassFile.Attributes.items[EnclosingMethodIndex].Info;
        if (Info.len >= 4) Mark(LiveNameAndTypeFlags, ConstantPoolBuilder.ReadUnsignedShort(Info, 2));
    }

    const DummyName = try ClassFile.ConstantPool.AddUtf8("a");
    const DummyMethod = try ClassFile.ConstantPool.AddUtf8("()V");
    const DummyField = try ClassFile.ConstantPool.AddUtf8("I");

    var Index: u16 = 1;
    while (Index < InitialPoolCount) : (Index += 1) {
        const Entry = ClassFile.ConstantPool.Entries.items[Index];
        if (Entry.Tag != ConstantPoolBuilder.TagNameAndType or LiveNameAndTypeFlags[Index] or Entry.Payload.len < 4) continue;
        const Descriptor = ClassFile.ConstantPool.Utf8Text(ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 2));
        const IsMethod = Descriptor.len > 0 and Descriptor[0] == '(';
        std.mem.writeInt(u16, Entry.Payload[0..2], DummyName, .big);
        std.mem.writeInt(u16, Entry.Payload[2..4], if (IsMethod) DummyMethod else DummyField, .big);
    }

    const PoolCount = ClassFile.ConstantPool.Count();
    const ReferencedFlags = try AllocatorHandle.alloc(bool, PoolCount);
    @memset(ReferencedFlags, false);
    try MarkReferenced(AllocatorHandle, ClassFile, ReferencedFlags, LiveStringFlags);

    Index = 1;
    while (Index < PoolCount) : (Index += 1) {
        if (ClassFile.ConstantPool.Entries.items[Index].Tag != ConstantPoolBuilder.TagUtf8) continue;
        if (ReferencedFlags[Index]) continue;
        try ClassFile.ConstantPool.SetUtf8Content(Index, &.{});
    }
}
