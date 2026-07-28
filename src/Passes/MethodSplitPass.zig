const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const Assembler = @import("../Classfile/Assembler.zig");

const PrimitiveType = enum { Integer, Long, Float, Double, Reference };

fn Width(Primitive: PrimitiveType) u16 {
    return switch (Primitive) {
        .Long, .Double => 2,
        else => 1,
    };
}

fn LoadOpcode(Primitive: PrimitiveType) u8 {
    return switch (Primitive) {
        .Integer => 0x15,
        .Long => 0x16,
        .Float => 0x17,
        .Double => 0x18,
        .Reference => 0x19,
    };
}

fn ParseParameters(AllocatorHandle: std.mem.Allocator, Descriptor: []const u8) ![]PrimitiveType {
    var ParameterList: std.ArrayList(PrimitiveType) = .empty;
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        switch (Descriptor[Index]) {
            'B', 'C', 'I', 'S', 'Z' => {
                try ParameterList.append(AllocatorHandle, .Integer);
                Index += 1;
            },
            'J' => {
                try ParameterList.append(AllocatorHandle, .Long);
                Index += 1;
            },
            'F' => {
                try ParameterList.append(AllocatorHandle, .Float);
                Index += 1;
            },
            'D' => {
                try ParameterList.append(AllocatorHandle, .Double);
                Index += 1;
            },
            'L' => {
                while (Index < Descriptor.len and Descriptor[Index] != ';') Index += 1;
                Index += 1;
                try ParameterList.append(AllocatorHandle, .Reference);
            },
            '[' => {
                while (Index < Descriptor.len and Descriptor[Index] == '[') Index += 1;
                if (Index < Descriptor.len and Descriptor[Index] == 'L') while (Index < Descriptor.len and Descriptor[Index] != ';') {
                    Index += 1;
                };
                Index += 1;
                try ParameterList.append(AllocatorHandle, .Reference);
            },
            else => return error.BadDescriptor,
        }
    }
    return ParameterList.toOwnedSlice(AllocatorHandle);
}

fn ReturnOpcode(Descriptor: []const u8) u8 {
    const ReturnTypePosition = std.mem.lastIndexOfScalar(u8, Descriptor, ')').? + 1;
    return switch (Descriptor[ReturnTypePosition]) {
        'V' => 0xb1,
        'J' => 0xad,
        'F' => 0xae,
        'D' => 0xaf,
        'L', '[' => 0xb0,
        else => 0xac,
    };
}

fn NameInUse(ClassFile: *const ClassFileModel.ClassFile, CandidateName: []const u8) bool {
    for (ClassFile.Methods.items) |Member| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Member.NameIndex), CandidateName)) return true;
    }
    return false;
}

pub fn MethodSplitPass(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, RandomGenerator: *std.Random.DefaultPrng) !usize {
    const ThisClassInternalName = ClassFile.ConstantPool.ClassName(ClassFile.ThisClass);
    const CodeUtf8Index = try ClassFile.ConstantPool.AddUtf8("Code");
    var ImplementationMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    var TotalSplitCount: usize = 0;
    var Counter: u32 = 0;
    const OriginalMethodCount = ClassFile.Methods.items.len;
    var MethodIndex: usize = 0;
    while (MethodIndex < OriginalMethodCount) : (MethodIndex += 1) {
        const Member = &ClassFile.Methods.items[MethodIndex];
        if ((Member.AccessFlags & AccessFlags.AccessStatic) == 0) continue;
        if ((Member.AccessFlags & (AccessFlags.AccessSynchronized | AccessFlags.AccessNative | AccessFlags.AccessAbstract)) != 0) continue;
        const MethodName = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
        if (std.mem.eql(u8, MethodName, "<clinit>") or std.mem.eql(u8, MethodName, "<init>")) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        if (RandomGenerator.random().intRangeAtMost(u8, 0, 99) >= 55) continue;
        const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const Parameters = ParseParameters(AllocatorHandle, Descriptor) catch continue;
        var SlotCount: u16 = 0;
        for (Parameters) |Parameter| SlotCount += Width(Parameter);
        if (SlotCount > 255) continue;

        var ImplementationName: []const u8 = undefined;
        while (true) {
            ImplementationName = try std.fmt.allocPrint(AllocatorHandle, "L{d}", .{900000 + Counter});
            Counter += 1;
            if (!NameInUse(ClassFile, ImplementationName)) break;
        }
        const ImplementationNameIndex = try ClassFile.ConstantPool.AddUtf8(ImplementationName);
        const ImplementationMethodReference = try ClassFile.ConstantPool.AddMethodref(ThisClassInternalName, ImplementationName, Descriptor);

        var StubAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFile.ConstantPool);
        var CurrentSlot: u16 = 0;
        for (Parameters) |Parameter| {
            try StubAssembler.Operation1(LoadOpcode(Parameter), @intCast(CurrentSlot));
            CurrentSlot += Width(Parameter);
        }
        try StubAssembler.Invoke(0xb8, ImplementationMethodReference);
        try StubAssembler.Operation0(ReturnOpcode(Descriptor));
        const StubCodeAttribute = try Assembler.BuildMethod(AllocatorHandle, &ClassFile.ConstantPool, try StubAssembler.Finish(), &.{}, Descriptor, true, CodeUtf8Index);

        const OriginalCodeAttribute = Member.Attributes.items[CodeAttributeIndex];
        var ImplementationAttributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
        try ImplementationAttributes.append(AllocatorHandle, OriginalCodeAttribute);
        try ImplementationMethods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic | AccessFlags.AccessPrivate, .NameIndex = ImplementationNameIndex, .DescriptorIndex = Member.DescriptorIndex, .Attributes = ImplementationAttributes });

        Member.Attributes.items[CodeAttributeIndex] = StubCodeAttribute;
        TotalSplitCount += 1;
    }
    for (ImplementationMethods.items) |ImplementationMethod| try ClassFile.Methods.append(AllocatorHandle, ImplementationMethod);
    return TotalSplitCount;
}
