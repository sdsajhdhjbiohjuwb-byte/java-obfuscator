const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const IdentifierGenerator = @import("../Passes/IdentifierGenerator.zig");

pub fn HasInvokeDynamic(Code: *const BytecodeInstructionModel.CodeAttribute) bool {
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Operation == 0xba) return true;
    }
    return false;
}

fn ReturnOpcode(Descriptor: []const u8) u8 {
    const CloseIndex = std.mem.indexOfScalar(u8, Descriptor, ')') orelse return 0xb1;
    return switch (Descriptor[CloseIndex + 1]) {
        'V' => 0xb1,
        'J' => 0xad,
        'F' => 0xae,
        'D' => 0xaf,
        'L', '[' => 0xb0,
        else => 0xac,
    };
}

fn EmitParameterLoads(AssemblerState: *Assembler.AssemblerState, Descriptor: []const u8) !void {
    var Index: usize = 1;
    var Slot: usize = 0;
    while (Descriptor[Index] != ')') {
        var LoadOpcode: u8 = 0x19;
        var Width: usize = 1;
        switch (Descriptor[Index]) {
            'B', 'C', 'I', 'S', 'Z' => {
                LoadOpcode = 0x15;
                Index += 1;
            },
            'F' => {
                LoadOpcode = 0x17;
                Index += 1;
            },
            'J' => {
                LoadOpcode = 0x16;
                Width = 2;
                Index += 1;
            },
            'D' => {
                LoadOpcode = 0x18;
                Width = 2;
                Index += 1;
            },
            'L' => {
                while (Descriptor[Index] != ';') Index += 1;
                Index += 1;
            },
            '[' => {
                while (Descriptor[Index] == '[') Index += 1;
                if (Descriptor[Index] == 'L') {
                    while (Descriptor[Index] != ';') Index += 1;
                }
                Index += 1;
            },
            else => return error.BadDescriptor,
        }
        if (Slot > 255) return error.TooManyParameters;
        try AssemblerState.Operation1(LoadOpcode, @intCast(Slot));
        Slot += Width;
    }
}

fn BuildBridge(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, Descriptor: []const u8, InvokeDynamicIndex: u16, BridgeName: []const u8, CodeUtf8Index: u16) !ClassFileModel.MemberInfo {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try EmitParameterLoads(&AssemblerState, Descriptor);
    const InvokeDynamicOperand = try AllocatorHandle.alloc(u8, 4);
    std.mem.writeInt(u16, InvokeDynamicOperand[0..2], InvokeDynamicIndex, .big);
    InvokeDynamicOperand[2] = 0;
    InvokeDynamicOperand[3] = 0;
    try AssemblerState.Raw(0xba, InvokeDynamicOperand);
    try AssemblerState.Operation0(ReturnOpcode(Descriptor));
    const CodeAttribute = try Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, Descriptor, true, CodeUtf8Index);
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, CodeAttribute);
    return .{
        .AccessFlags = AccessFlags.AccessSynthetic | AccessFlags.AccessStatic | AccessFlags.AccessPrivate,
        .NameIndex = try Pool.AddUtf8(BridgeName),
        .DescriptorIndex = try Pool.AddUtf8(Descriptor),
        .Attributes = Attributes,
    };
}

pub fn ExtractBridges(AllocatorHandle: std.mem.Allocator, ClassFileHandle: *ClassFileModel.ClassFile, Code: *BytecodeInstructionModel.CodeAttribute, Random: std.Random, CodeUtf8Index: u16) !?std.ArrayList(ClassFileModel.MemberInfo) {
    const OwnerName = ClassFileHandle.ConstantPool.ClassName(ClassFileHandle.ThisClass);
    var Bridges: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    for (Code.Instructions.items) |*Instruction| {
        if (Instruction.Operation != 0xba) continue;
        if (Instruction.Raw.len < 2) return null;
        const InvokeDynamicIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
        if (ClassFileHandle.ConstantPool.TagOf(InvokeDynamicIndex) != ConstantPoolBuilder.TagInvokeDynamic) return null;
        const Payload = ClassFileHandle.ConstantPool.Entries.items[InvokeDynamicIndex].Payload;
        const NameAndTypeIndex = ConstantPoolBuilder.ReadUnsignedShort(Payload, 2);
        const Descriptor = ClassFileHandle.ConstantPool.Utf8Text(ClassFileHandle.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
        const BridgeName = try IdentifierGenerator.RandomLetters(AllocatorHandle, Random, 16);
        const Bridge = BuildBridge(AllocatorHandle, &ClassFileHandle.ConstantPool, Descriptor, InvokeDynamicIndex, BridgeName, CodeUtf8Index) catch return null;
        const ReferenceIndex = try ClassFileHandle.ConstantPool.AddMethodref(OwnerName, BridgeName, Descriptor);
        const RewrittenOperand = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(u16, RewrittenOperand[0..2], ReferenceIndex, .big);
        Instruction.Operation = 0xb8;
        Instruction.Raw = RewrittenOperand;
        try Bridges.append(AllocatorHandle, Bridge);
    }
    return Bridges;
}
