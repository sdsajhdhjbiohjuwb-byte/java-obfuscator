const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const Assembler = @import("../Classfile/Assembler.zig");

const List = std.ArrayList(BytecodeInstructionModel.Instruction);

const ParameterKind = enum { Integer, Long, Float, Double, Reference };

fn Width(Kind: ParameterKind) u16 {
    return switch (Kind) {
        .Long, .Double => 2,
        else => 1,
    };
}

fn LoadOpcode(Kind: ParameterKind) u8 {
    return switch (Kind) {
        .Integer => 0x15,
        .Long => 0x16,
        .Float => 0x17,
        .Double => 0x18,
        .Reference => 0x19,
    };
}

fn ParseParameters(AllocatorHandle: std.mem.Allocator, Descriptor: []const u8) ![]ParameterKind {
    var ParameterList: std.ArrayList(ParameterKind) = .empty;
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

fn IsStoreOrAllocate(Opcode: u8) bool {
    if (Opcode >= 0x36 and Opcode <= 0x56) return true;
    if (Opcode == 0x84) return true;
    if (Opcode == 0xbb or Opcode == 0xbc or Opcode == 0xbd or Opcode == 0xc5) return true;
    return false;
}

fn IsInitializerCall(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) bool {
    if (Instruction.Operation != 0xb7 or Instruction.Raw.len < 2) return false;
    const ReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
    if (Pool.TagOf(ReferenceIndex) != ConstantPoolBuilder.TagMethodref) return false;
    const NameIndex = Pool.NameAndTypeName(Pool.RefNameAndTypeIndex(ReferenceIndex));
    return std.mem.eql(u8, Pool.Utf8Text(NameIndex), "<init>");
}

fn NameInUse(ClassFile: *const ClassFileModel.ClassFile, CandidateName: []const u8) bool {
    for (ClassFile.Methods.items) |Member| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Member.NameIndex), CandidateName)) return true;
    }
    return false;
}

fn TwoByteOperand(AllocatorHandle: std.mem.Allocator, Value: u16) ![]u8 {
    const Bytes = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, Bytes[0..2], Value, .big);
    return Bytes;
}

pub fn SplitConstructors(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile) !usize {
    const ThisClassInternalName = ClassFile.ConstantPool.ClassName(ClassFile.ThisClass);
    const CodeUtf8Index = try ClassFile.ConstantPool.AddUtf8("Code");
    var TailMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    var Counter: u32 = 0;
    var SplitCount: usize = 0;
    const OriginalMethodCount = ClassFile.Methods.items.len;
    var MethodIndex: usize = 0;
    while (MethodIndex < OriginalMethodCount) : (MethodIndex += 1) {
        const Member = &ClassFile.Methods.items[MethodIndex];
        if ((Member.AccessFlags & (AccessFlags.AccessNative | AccessFlags.AccessAbstract)) != 0) continue;
        if (!std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Member.NameIndex), "<init>")) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        var Code = BytecodeInstructionModel.ParseCode(AllocatorHandle, Member.Attributes.items[CodeAttributeIndex].Info) catch continue;
        if (Code.Exceptions.items.len != 0) continue;

        var StraightLine = true;
        for (Code.Instructions.items) |Instruction| {
            if (Instruction.Kind != .Fixed) {
                StraightLine = false;
                break;
            }
        }
        if (!StraightLine) continue;

        var SuperIndex: ?usize = null;
        for (Code.Instructions.items, 0..) |Instruction, Index| {
            if (IsInitializerCall(&ClassFile.ConstantPool, Instruction)) {
                SuperIndex = Index;
                break;
            }
            if (IsStoreOrAllocate(Instruction.Operation)) break;
        }
        const SuperCallIndex = SuperIndex orelse continue;
        if (SuperCallIndex + 3 > Code.Instructions.items.len) continue;

        const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const Parameters = ParseParameters(AllocatorHandle, Descriptor) catch continue;
        var SlotCount: u16 = 1;
        for (Parameters) |Parameter| SlotCount += Width(Parameter);
        if (SlotCount > 255) continue;

        var TailName: []const u8 = undefined;
        while (true) {
            TailName = try std.fmt.allocPrint(AllocatorHandle, "L{d}", .{910000 + Counter});
            Counter += 1;
            if (!NameInUse(ClassFile, TailName)) break;
        }
        const TailNameIndex = try ClassFile.ConstantPool.AddUtf8(TailName);
        const TailReference = try ClassFile.ConstantPool.AddMethodref(ThisClassInternalName, TailName, Descriptor);

        var TailInstructions: List = .empty;
        try TailInstructions.appendSlice(AllocatorHandle, Code.Instructions.items[SuperCallIndex + 1 ..]);
        const TailCode = Assembler.BuildMethod(AllocatorHandle, &ClassFile.ConstantPool, TailInstructions.items, &.{}, Descriptor, false, CodeUtf8Index) catch continue;
        var TailAttributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
        try TailAttributes.append(AllocatorHandle, TailCode);
        try TailMethods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessSynthetic | AccessFlags.AccessPrivate, .NameIndex = TailNameIndex, .DescriptorIndex = Member.DescriptorIndex, .Attributes = TailAttributes });

        var PrologueInstructions: List = .empty;
        try PrologueInstructions.appendSlice(AllocatorHandle, Code.Instructions.items[0 .. SuperCallIndex + 1]);
        try PrologueInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&Code, 0x2a, &.{}));
        var CurrentSlot: u16 = 1;
        for (Parameters) |Parameter| {
            const SlotByte = try AllocatorHandle.alloc(u8, 1);
            SlotByte[0] = @intCast(CurrentSlot);
            try PrologueInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&Code, LoadOpcode(Parameter), SlotByte));
            CurrentSlot += Width(Parameter);
        }
        try PrologueInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&Code, 0xb7, try TwoByteOperand(AllocatorHandle, TailReference)));
        try PrologueInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&Code, 0xb1, &.{}));
        const PrologueCode = Assembler.BuildMethod(AllocatorHandle, &ClassFile.ConstantPool, PrologueInstructions.items, &.{}, Descriptor, false, CodeUtf8Index) catch continue;

        Member.Attributes.items[CodeAttributeIndex] = PrologueCode;
        SplitCount += 1;
    }
    try ClassFile.Methods.appendSlice(AllocatorHandle, TailMethods.items);
    return SplitCount;
}
