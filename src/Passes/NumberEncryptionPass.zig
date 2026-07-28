const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const RuntimeConfig = @import("../Pipeline/RuntimeConfig.zig");

const InstructionList = std.ArrayList(BytecodeInstructionModel.Instruction);

fn ModularInverse32(Value: u32) u32 {
    var Inverse: u32 = Value;
    var Iteration: usize = 0;
    while (Iteration < 5) : (Iteration += 1) Inverse = Inverse *% (2 -% Value *% Inverse);
    return Inverse;
}

fn ModularInverse64(Value: u64) u64 {
    var Inverse: u64 = Value;
    var Iteration: usize = 0;
    while (Iteration < 6) : (Iteration += 1) Inverse = Inverse *% (2 -% Value *% Inverse);
    return Inverse;
}

fn PushLong(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, Value: i64) !void {
    if (Value == 0) {
        try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x09, &.{}));
    } else if (Value == 1) {
        try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x0a, &.{}));
    } else {
        const PoolIndex = try Pool.AddLong(Value);
        const RawOperand = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(u16, RawOperand[0..2], PoolIndex, .big);
        try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x14, RawOperand));
    }
}

fn EncodeInteger(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, PseudoRandom: *std.Random.DefaultPrng, Value: i32, Depth: u8) !void {
    const OperationSelector = PseudoRandom.random().intRangeAtMost(u8, 0, 3);
    var FirstOperand: i32 = @bitCast(PseudoRandom.random().int(u32));
    var SecondOperand: i32 = undefined;
    var Opcode: u8 = undefined;
    switch (OperationSelector) {
        0 => {
            SecondOperand = Value ^ FirstOperand;
            Opcode = 0x82;
        },
        1 => {
            SecondOperand = Value -% FirstOperand;
            Opcode = 0x60;
        },
        2 => {
            SecondOperand = FirstOperand -% Value;
            Opcode = 0x64;
        },
        else => {
            FirstOperand = @bitCast(PseudoRandom.random().int(u32) | 1);
            SecondOperand = Value *% @as(i32, @bitCast(ModularInverse32(@bitCast(FirstOperand))));
            Opcode = 0x68;
        },
    }
    if (Depth == 0) {
        try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, FirstOperand);
        try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, SecondOperand);
    } else {
        try EncodeInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, PseudoRandom, FirstOperand, Depth - 1);
        try EncodeInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, PseudoRandom, SecondOperand, Depth - 1);
    }
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, Opcode, &.{}));
}

fn EncodeLong(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, PseudoRandom: *std.Random.DefaultPrng, Value: i64, Depth: u8) !void {
    const OperationSelector = PseudoRandom.random().intRangeAtMost(u8, 0, 3);
    var FirstOperand: i64 = @bitCast(PseudoRandom.random().int(u64));
    var SecondOperand: i64 = undefined;
    var Opcode: u8 = undefined;
    switch (OperationSelector) {
        0 => {
            SecondOperand = Value ^ FirstOperand;
            Opcode = 0x83;
        },
        1 => {
            SecondOperand = Value -% FirstOperand;
            Opcode = 0x61;
        },
        2 => {
            SecondOperand = FirstOperand -% Value;
            Opcode = 0x65;
        },
        else => {
            FirstOperand = @bitCast(PseudoRandom.random().int(u64) | 1);
            SecondOperand = Value *% @as(i64, @bitCast(ModularInverse64(@bitCast(FirstOperand))));
            Opcode = 0x69;
        },
    }
    if (Depth == 0) {
        try PushLong(AllocatorHandle, Instructions, CodeAttribute, Pool, FirstOperand);
        try PushLong(AllocatorHandle, Instructions, CodeAttribute, Pool, SecondOperand);
    } else {
        try EncodeLong(AllocatorHandle, Instructions, CodeAttribute, Pool, PseudoRandom, FirstOperand, Depth - 1);
        try EncodeLong(AllocatorHandle, Instructions, CodeAttribute, Pool, PseudoRandom, SecondOperand, Depth - 1);
    }
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, Opcode, &.{}));
}

fn PoolInteger(Pool: *const ConstantPoolBuilder.ConstantPool, PoolIndex: u16) i32 {
    return std.mem.readInt(i32, Pool.GetEntry(PoolIndex).Payload[0..4], .big);
}

fn PoolLong(Pool: *const ConstantPoolBuilder.ConstantPool, PoolIndex: u16) i64 {
    return std.mem.readInt(i64, Pool.GetEntry(PoolIndex).Payload[0..8], .big);
}

fn ConstantIntegerValue(ClassFile: *ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?i32 {
    return switch (Instruction.Operation) {
        0x02...0x08 => @as(i32, Instruction.Operation) - 0x03,
        0x10 => @as(i32, @as(i8, @bitCast(Instruction.Raw[0]))),
        0x11 => @as(i32, std.mem.readInt(i16, Instruction.Raw[0..2], .big)),
        0x12 => Block: {
            const PoolIndex: u16 = Instruction.Raw[0];
            break :Block if (ClassFile.ConstantPool.TagOf(PoolIndex) == ConstantPoolBuilder.TagInteger) PoolInteger(&ClassFile.ConstantPool, PoolIndex) else null;
        },
        0x13 => Block: {
            const PoolIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            break :Block if (ClassFile.ConstantPool.TagOf(PoolIndex) == ConstantPoolBuilder.TagInteger) PoolInteger(&ClassFile.ConstantPool, PoolIndex) else null;
        },
        else => null,
    };
}

fn ConstantLongValue(ClassFile: *ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?i64 {
    return switch (Instruction.Operation) {
        0x09 => 0,
        0x0a => 1,
        0x14 => Block: {
            const PoolIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            break :Block if (ClassFile.ConstantPool.TagOf(PoolIndex) == ConstantPoolBuilder.TagLong) PoolLong(&ClassFile.ConstantPool, PoolIndex) else null;
        },
        else => null,
    };
}

fn Phi(Value: i32, OddMultiplier: i32, ConstantAddend: i32) i32 {
    return (Value *% OddMultiplier) ^ ConstantAddend;
}

fn TransformMethod(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, Member: *ClassFileModel.MemberInfo, CodeInfo: []const u8, PseudoRandom: *std.Random.DefaultPrng) !?[]u8 {
    var CodeAttribute = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfo);
    if (CodeAttribute.Instructions.items.len > RuntimeConfig.Active.Passes.NumberEncryption.MaxInstructionsGuard) return null;
    const MethodName = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);

    var Frames: []StackMapTableCodec.Frame = &.{};
    const StackMapIndex = ClassFileModel.FindAttribute(CodeAttribute.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
    if (StackMapIndex) |AttributeIndex| {
        const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
        const IsClinit = std.mem.eql(u8, MethodName, "<clinit>");
        const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, IsClinit);
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, CodeAttribute.Attributes.items[AttributeIndex].Info, CodeAttribute.Instructions.items, InitialLocals);
    }

    var OutputList: InstructionList = .empty;
    var Changed = false;
    var Budget: usize = RuntimeConfig.Active.Passes.NumberEncryption.MaxPerMethod;

    for (CodeAttribute.Instructions.items) |Instruction| {
        if (Budget > 0) {
            if (ConstantIntegerValue(ClassFile, Instruction)) |Value| {
                const StartIndex = OutputList.items.len;
                try EncodeInteger(AllocatorHandle, &OutputList, &CodeAttribute, &ClassFile.ConstantPool, PseudoRandom, Value, PseudoRandom.random().intRangeAtMost(u8, 1, RuntimeConfig.Active.Passes.NumberEncryption.MaxDepth));
                OutputList.items[StartIndex].Identifier = Instruction.Identifier;
                Changed = true;
                Budget -= 1;
                continue;
            }
            if (ConstantLongValue(ClassFile, Instruction)) |Value| {
                const StartIndex = OutputList.items.len;
                try EncodeLong(AllocatorHandle, &OutputList, &CodeAttribute, &ClassFile.ConstantPool, PseudoRandom, Value, PseudoRandom.random().intRangeAtMost(u8, 1, RuntimeConfig.Active.Passes.NumberEncryption.MaxDepth));
                OutputList.items[StartIndex].Identifier = Instruction.Identifier;
                Changed = true;
                Budget -= 1;
                continue;
            }
        }
        if (RuntimeConfig.Active.Passes.NumberEncryption.EncryptSwitchKeys and (Instruction.Kind == .TableSwitch or Instruction.Kind == .LookupSwitch)) {
            const OddMultiplier: i32 = @bitCast(PseudoRandom.random().int(u32) | 1);
            const ConstantAddend: i32 = @bitCast(PseudoRandom.random().int(u32));
            const StartIndex = OutputList.items.len;
            try BytecodeInstructionModel.PushInteger(AllocatorHandle, &OutputList, &CodeAttribute, &ClassFile.ConstantPool, OddMultiplier);
            try OutputList.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&CodeAttribute, 0x68, &.{}));
            try BytecodeInstructionModel.PushInteger(AllocatorHandle, &OutputList, &CodeAttribute, &ClassFile.ConstantPool, ConstantAddend);
            try OutputList.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&CodeAttribute, 0x82, &.{}));
            var NewPairs: std.ArrayList(BytecodeInstructionModel.Pair) = .empty;
            if (Instruction.Kind == .TableSwitch) {
                var KeyValue: i64 = Instruction.SwitchLow;
                var TargetIndex: usize = 0;
                while (KeyValue <= Instruction.SwitchHigh) : (KeyValue += 1) {
                    try NewPairs.append(AllocatorHandle, .{ .Key = Phi(@intCast(KeyValue), OddMultiplier, ConstantAddend), .Target = Instruction.SwitchTargets[TargetIndex] });
                    TargetIndex += 1;
                }
            } else {
                for (Instruction.SwitchPairs) |Pair| try NewPairs.append(AllocatorHandle, .{ .Key = Phi(Pair.Key, OddMultiplier, ConstantAddend), .Target = Pair.Target });
            }
            const Pairs = try NewPairs.toOwnedSlice(AllocatorHandle);
            std.mem.sort(BytecodeInstructionModel.Pair, Pairs, {}, struct {
                fn Less(_: void, LeftPair: BytecodeInstructionModel.Pair, RightPair: BytecodeInstructionModel.Pair) bool {
                    return LeftPair.Key < RightPair.Key;
                }
            }.Less);
            try OutputList.append(AllocatorHandle, .{ .Identifier = CodeAttribute.NewIdentifier(), .Operation = 0xab, .Kind = .LookupSwitch, .SwitchDefault = Instruction.SwitchDefault, .SwitchPairs = Pairs });
            OutputList.items[StartIndex].Identifier = Instruction.Identifier;
            Changed = true;
            continue;
        }
        try OutputList.append(AllocatorHandle, Instruction);
    }

    if (!Changed) return null;
    CodeAttribute.Instructions = OutputList;
    CodeAttribute.MaxStack = @intCast(@min(@as(u32, 65535), @as(u32, CodeAttribute.MaxStack) + 32));
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &CodeAttribute.Instructions);
    if (StackMapIndex) |AttributeIndex| CodeAttribute.Attributes.items[AttributeIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, CodeAttribute.Instructions.items);
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &CodeAttribute);
}

pub fn NumberEncryptionPass(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, PseudoRandom: *std.Random.DefaultPrng) !usize {
    var Count: usize = 0;
    for (ClassFile.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        const CodeInfo = Member.Attributes.items[CodeAttributeIndex].Info;
        if (TransformMethod(AllocatorHandle, ClassFile, Member, CodeInfo, PseudoRandom) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
            Count += 1;
        }
    }
    return Count;
}
