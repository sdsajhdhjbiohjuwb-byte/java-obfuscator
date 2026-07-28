const std = @import("std");
const RuntimeConfig = @import("../Pipeline/RuntimeConfig.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const InstructionSetArchitecture = @import("InstructionSetArchitecture.zig");
const DescriptorUtil = @import("../Classfile/DescriptorUtil.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const TypeSimulator = @import("../Classfile/TypeSimulator.zig");

pub const Program = struct {
    Bytes: []u8,
    NumberOfLocals: u16,
    MaxStack: u16,
    OpcodeOffsets: []const u32,
    LocalOperandOffsets: []const u32,
    StackOperandOffsets: []const u32,
};

const VirtualMachineInstruction = struct {
    Operation: u8,
    Immediate: i32 = 0,
    LongImmediate: i64 = 0,
    Index: u8 = 0,
    Condition: u8 = 0,
    TargetJumpIdentifier: u32 = 0,
    Symbol: []const u8 = "",
    SwitchLow: i32 = 0,
    SwitchHigh: i32 = 0,
    SwitchKeys: []const i32 = &.{},
    SwitchTargetIdentifiers: []const u32 = &.{},
    MoveDestination: i8 = 0,
    MoveSource: i8 = 0,
    MoveDepthDelta: i8 = 0,

    fn Size(SelfInstruction: VirtualMachineInstruction) usize {
        return 1 + 2 * StackSlotCount(SelfInstruction) + switch (SelfInstruction.Operation) {
            InstructionSetArchitecture.VirtualTableSwitch => 12 + 4 * SelfInstruction.SwitchTargetIdentifiers.len,
            InstructionSetArchitecture.VirtualLookupSwitch => 8 + 8 * SelfInstruction.SwitchTargetIdentifiers.len,
            InstructionSetArchitecture.VirtualPush, InstructionSetArchitecture.VirtualGoto, InstructionSetArchitecture.VirtualPushFloat => 4,
            InstructionSetArchitecture.VirtualPushLong, InstructionSetArchitecture.VirtualPushDouble => 8,
            InstructionSetArchitecture.VirtualLoad, InstructionSetArchitecture.VirtualStore, InstructionSetArchitecture.VirtualConvert, InstructionSetArchitecture.VirtualCompareWide, InstructionSetArchitecture.VirtualNewArray, InstructionSetArchitecture.VirtualArrayLoad, InstructionSetArchitecture.VirtualArrayStore => 1,
            InstructionSetArchitecture.VirtualIf, InstructionSetArchitecture.VirtualIfCompare, InstructionSetArchitecture.VirtualIncrement, InstructionSetArchitecture.VirtualIfNull, InstructionSetArchitecture.VirtualIfAcmp => 5,
            InstructionSetArchitecture.VirtualCall => 4 + SelfInstruction.Symbol.len,
            InstructionSetArchitecture.VirtualGetStatic, InstructionSetArchitecture.VirtualPutStatic, InstructionSetArchitecture.VirtualPushString, InstructionSetArchitecture.VirtualNew, InstructionSetArchitecture.VirtualInit, InstructionSetArchitecture.VirtualGetField, InstructionSetArchitecture.VirtualPutField, InstructionSetArchitecture.VirtualCheckCast, InstructionSetArchitecture.VirtualInstanceOf, InstructionSetArchitecture.VirtualANewArray, InstructionSetArchitecture.VirtualLoadClass => 2 + SelfInstruction.Symbol.len,
            InstructionSetArchitecture.VirtualMultiANewArray => 3 + SelfInstruction.Symbol.len,
            else => 0,
        };
    }
};

fn StackSlotCount(Instruction: VirtualMachineInstruction) usize {
    return switch (Instruction.Operation) {
        InstructionSetArchitecture.VirtualGoto,
        InstructionSetArchitecture.VirtualPop,
        InstructionSetArchitecture.VirtualIncrement,
        => 0,
        InstructionSetArchitecture.VirtualAdd,
        InstructionSetArchitecture.VirtualSubtract,
        InstructionSetArchitecture.VirtualMultiply,
        InstructionSetArchitecture.VirtualDivide,
        InstructionSetArchitecture.VirtualRemainder,
        InstructionSetArchitecture.VirtualAnd,
        InstructionSetArchitecture.VirtualOr,
        InstructionSetArchitecture.VirtualXor,
        InstructionSetArchitecture.VirtualShiftLeft,
        InstructionSetArchitecture.VirtualShiftRight,
        InstructionSetArchitecture.VirtualUnsignedShiftRight,
        InstructionSetArchitecture.VirtualIfCompare,
        InstructionSetArchitecture.VirtualDuplicate,
        InstructionSetArchitecture.VirtualSwap,
        InstructionSetArchitecture.VirtualCompareWide,
        InstructionSetArchitecture.VirtualIfAcmp,
        InstructionSetArchitecture.VirtualPutField,
        InstructionSetArchitecture.VirtualArrayLoad,
        InstructionSetArchitecture.VirtualMove,
        => 2,
        InstructionSetArchitecture.VirtualArrayStore => 3,
        InstructionSetArchitecture.VirtualCall => Block: {
            const ColonIndex = std.mem.indexOfScalar(u8, Instruction.Symbol, ':') orelse break :Block 0;
            const ArgumentCount = DescriptorUtil.ParameterCount(Instruction.Symbol[ColonIndex + 1 ..]);
            const Receiver: usize = if (Instruction.Index != 3) 1 else 0;
            const HasReturn: usize = if (Instruction.Condition != 0) 1 else 0;
            break :Block ArgumentCount + Receiver + HasReturn;
        },
        InstructionSetArchitecture.VirtualInit => Block: {
            const ColonIndex = std.mem.indexOfScalar(u8, Instruction.Symbol, ':') orelse break :Block 1;
            break :Block DescriptorUtil.ParameterCount(Instruction.Symbol[ColonIndex + 1 ..]) + 1;
        },
        InstructionSetArchitecture.VirtualMultiANewArray => @as(usize, Instruction.Index) + 1,
        else => 1,
    };
}

fn IsCoreOperation(Operation: u8) bool {
    return switch (Operation) {
        else => Operation >= 1 and Operation <= 55,
    };
}

fn CoreStackEffect(Instruction: VirtualMachineInstruction) i32 {
    return switch (Instruction.Operation) {
        InstructionSetArchitecture.VirtualPush,
        InstructionSetArchitecture.VirtualLoad,
        InstructionSetArchitecture.VirtualDuplicate,
        InstructionSetArchitecture.VirtualPushLong,
        InstructionSetArchitecture.VirtualPushFloat,
        InstructionSetArchitecture.VirtualPushDouble,
        InstructionSetArchitecture.VirtualGetStatic,
        InstructionSetArchitecture.VirtualPushString,
        InstructionSetArchitecture.VirtualAConstNull,
        InstructionSetArchitecture.VirtualLoadClass,
        InstructionSetArchitecture.VirtualNew,
        => 1,
        InstructionSetArchitecture.VirtualStore,
        InstructionSetArchitecture.VirtualPop,
        InstructionSetArchitecture.VirtualIf,
        InstructionSetArchitecture.VirtualReturn,
        InstructionSetArchitecture.VirtualAdd,
        InstructionSetArchitecture.VirtualSubtract,
        InstructionSetArchitecture.VirtualMultiply,
        InstructionSetArchitecture.VirtualDivide,
        InstructionSetArchitecture.VirtualRemainder,
        InstructionSetArchitecture.VirtualAnd,
        InstructionSetArchitecture.VirtualOr,
        InstructionSetArchitecture.VirtualXor,
        InstructionSetArchitecture.VirtualShiftLeft,
        InstructionSetArchitecture.VirtualShiftRight,
        InstructionSetArchitecture.VirtualUnsignedShiftRight,
        InstructionSetArchitecture.VirtualCompareWide,
        InstructionSetArchitecture.VirtualPutStatic,
        InstructionSetArchitecture.VirtualIfNull,
        InstructionSetArchitecture.VirtualArrayLoad,
        InstructionSetArchitecture.VirtualTableSwitch,
        InstructionSetArchitecture.VirtualLookupSwitch,
        InstructionSetArchitecture.VirtualMonitorEnter,
        InstructionSetArchitecture.VirtualMonitorExit,
        InstructionSetArchitecture.VirtualAThrow,
        => -1,
        InstructionSetArchitecture.VirtualIfCompare,
        InstructionSetArchitecture.VirtualIfAcmp,
        InstructionSetArchitecture.VirtualPutField,
        => -2,
        InstructionSetArchitecture.VirtualArrayStore => -3,
        InstructionSetArchitecture.VirtualMultiANewArray => 1 - @as(i32, Instruction.Index),
        InstructionSetArchitecture.VirtualMove => Instruction.MoveDepthDelta,
        InstructionSetArchitecture.VirtualCall => Block: {
            const ColonIndex = std.mem.indexOfScalar(u8, Instruction.Symbol, ':') orelse break :Block 0;
            const ArgumentCount: i32 = @intCast(DescriptorUtil.ParameterCount(Instruction.Symbol[ColonIndex + 1 ..]));
            const Receiver: i32 = if (Instruction.Index != 3) 1 else 0;
            const HasReturn: i32 = if (Instruction.Condition != 0) 1 else 0;
            break :Block HasReturn - ArgumentCount - Receiver;
        },
        InstructionSetArchitecture.VirtualInit => InitBlock: {
            const ColonIndex = std.mem.indexOfScalar(u8, Instruction.Symbol, ':') orelse break :InitBlock 0;
            const ArgumentCount: i32 = @intCast(DescriptorUtil.ParameterCount(Instruction.Symbol[ColonIndex + 1 ..]));
            break :InitBlock -(ArgumentCount + 1);
        },
        else => 0,
    };
}

fn ResolveMethodReference(Pool: *const ConstantPoolBuilder.ConstantPool, MethodReferenceIndex: u16) ?struct { Owner: []const u8, Name: []const u8, Descriptor: []const u8 } {
    const MethodReferencePayload = Pool.GetEntry(MethodReferenceIndex).Payload;
    const ClassIndex = ConstantPoolBuilder.ReadUnsignedShort(MethodReferencePayload, 0);
    const NameAndTypeIndex = ConstantPoolBuilder.ReadUnsignedShort(MethodReferencePayload, 2);
    const ClassNameIndex = ConstantPoolBuilder.ReadUnsignedShort(Pool.GetEntry(ClassIndex).Payload, 0);
    const NameAndTypePayload = Pool.GetEntry(NameAndTypeIndex).Payload;
    return .{
        .Owner = Pool.Utf8Text(ClassNameIndex),
        .Name = Pool.Utf8Text(ConstantPoolBuilder.ReadUnsignedShort(NameAndTypePayload, 0)),
        .Descriptor = Pool.Utf8Text(ConstantPoolBuilder.ReadUnsignedShort(NameAndTypePayload, 2)),
    };
}

fn BuildSymbol(AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8) ![]const u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    for (Owner) |Character| try ScratchBuffer.append(AllocatorHandle, if (Character == '/') '.' else Character);
    try ScratchBuffer.append(AllocatorHandle, '.');
    try ScratchBuffer.appendSlice(AllocatorHandle, Name);
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

fn BuildClassSymbol(AllocatorHandle: std.mem.Allocator, Name: []const u8) ![]const u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    for (Name) |Character| try ScratchBuffer.append(AllocatorHandle, if (Character == '/') '.' else Character);
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

fn RemapDescriptor(AllocatorHandle: std.mem.Allocator, Descriptor: []const u8, MappingRegistry: *const Mapping) ![]const u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    var Index: usize = 0;
    while (Index < Descriptor.len) {
        if (Descriptor[Index] == 'L') {
            var End = Index + 1;
            while (End < Descriptor.len and Descriptor[End] != ';') : (End += 1) {}
            const Inner = Descriptor[Index + 1 .. End];
            const Remapped = MappingRegistry.RemapInternal(Inner) orelse Inner;
            try ScratchBuffer.append(AllocatorHandle, 'L');
            try ScratchBuffer.appendSlice(AllocatorHandle, Remapped);
            try ScratchBuffer.append(AllocatorHandle, ';');
            Index = if (End < Descriptor.len) End + 1 else End;
        } else {
            try ScratchBuffer.append(AllocatorHandle, Descriptor[Index]);
            Index += 1;
        }
    }
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

fn BuildInvokeSymbol(AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8, Descriptor: []const u8, MappingRegistry: *const Mapping) ![]const u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    for (Owner) |Character| try ScratchBuffer.append(AllocatorHandle, if (Character == '/') '.' else Character);
    try ScratchBuffer.append(AllocatorHandle, '.');
    try ScratchBuffer.appendSlice(AllocatorHandle, Name);
    try ScratchBuffer.append(AllocatorHandle, ':');
    const RemappedDescriptor = try RemapDescriptor(AllocatorHandle, Descriptor, MappingRegistry);
    try ScratchBuffer.appendSlice(AllocatorHandle, RemappedDescriptor);
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

fn BuildInitSymbol(AllocatorHandle: std.mem.Allocator, Owner: []const u8, Descriptor: []const u8, MappingRegistry: *const Mapping) ![]const u8 {
    var ScratchBuffer: std.ArrayList(u8) = .empty;
    for (Owner) |Character| try ScratchBuffer.append(AllocatorHandle, if (Character == '/') '.' else Character);
    try ScratchBuffer.append(AllocatorHandle, ':');
    const RemappedDescriptor = try RemapDescriptor(AllocatorHandle, Descriptor, MappingRegistry);
    try ScratchBuffer.appendSlice(AllocatorHandle, RemappedDescriptor);
    return ScratchBuffer.toOwnedSlice(AllocatorHandle);
}

fn ClassNameOf(Pool: *const ConstantPoolBuilder.ConstantPool, ClassConstantIndex: u16) []const u8 {
    const NameIndex = ConstantPoolBuilder.ReadUnsignedShort(Pool.GetEntry(ClassConstantIndex).Payload, 0);
    return Pool.Utf8Text(NameIndex);
}

fn MultiComponentSymbol(AllocatorHandle: std.mem.Allocator, ArrayDescriptor: []const u8, Dimensions: u8, MappingRegistry: *const Mapping) ![]const u8 {
    var Start: usize = 0;
    var Remaining: u8 = Dimensions;
    while (Remaining > 0 and Start < ArrayDescriptor.len and ArrayDescriptor[Start] == '[') : (Start += 1) Remaining -= 1;
    const Component = ArrayDescriptor[Start..];
    const Remapped = try RemapDescriptor(AllocatorHandle, Component, MappingRegistry);
    return BuildClassSymbol(AllocatorHandle, Remapped);
}

fn ReturnPushes(Descriptor: []const u8) bool {
    var Index: usize = 0;
    while (Index < Descriptor.len and Descriptor[Index] != ')') : (Index += 1) {}
    if (Index + 1 >= Descriptor.len) return false;
    return Descriptor[Index + 1] != 'V';
}

fn StringConstant(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?[]const u8 {
    const Index: u16 = switch (Instruction.Operation) {
        0x12 => Instruction.Raw[0],
        0x13 => ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0),
        else => return null,
    };
    if (Pool.TagOf(Index) != ConstantPoolBuilder.TagString) return null;
    const Utf8Index = ConstantPoolBuilder.ReadUnsignedShort(Pool.GetEntry(Index).Payload, 0);
    return Pool.Utf8Text(Utf8Index);
}

fn ClassConstant(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?[]const u8 {
    const Index: u16 = switch (Instruction.Operation) {
        0x12 => Instruction.Raw[0],
        0x13 => ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0),
        else => return null,
    };
    if (Pool.TagOf(Index) != ConstantPoolBuilder.TagClass) return null;
    const Name = ClassNameOf(Pool, Index);
    if (Name.len > 0 and Name[0] == '[') return null;
    return Name;
}

fn IntegerConstant(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?i32 {
    return switch (Instruction.Operation) {
        0x02 => -1,
        0x03...0x08 => @as(i32, Instruction.Operation) - 0x03,
        0x10 => @as(i32, @as(i8, @bitCast(Instruction.Raw[0]))),
        0x11 => @as(i32, std.mem.readInt(i16, Instruction.Raw[0..2], .big)),
        0x12 => Block: {
            const Index: u16 = Instruction.Raw[0];
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagInteger) break :Block null;
            break :Block @bitCast(ConstantPoolBuilder.ReadUnsignedInt(Pool.GetEntry(Index).Payload, 0));
        },
        0x13 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagInteger) break :Block null;
            break :Block @bitCast(ConstantPoolBuilder.ReadUnsignedInt(Pool.GetEntry(Index).Payload, 0));
        },
        else => null,
    };
}

fn LongConstant(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?i64 {
    return switch (Instruction.Operation) {
        0x09 => 0,
        0x0a => 1,
        0x14 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagLong) break :Block null;
            break :Block @bitCast(std.mem.readInt(u64, Pool.GetEntry(Index).Payload[0..8], .big));
        },
        else => null,
    };
}

fn FloatConstantBits(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?i32 {
    return switch (Instruction.Operation) {
        0x0b => @as(i32, @bitCast(@as(f32, 0.0))),
        0x0c => @as(i32, @bitCast(@as(f32, 1.0))),
        0x0d => @as(i32, @bitCast(@as(f32, 2.0))),
        0x12 => Block: {
            const Index: u16 = Instruction.Raw[0];
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagFloat) break :Block null;
            break :Block @bitCast(ConstantPoolBuilder.ReadUnsignedInt(Pool.GetEntry(Index).Payload, 0));
        },
        0x13 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagFloat) break :Block null;
            break :Block @bitCast(ConstantPoolBuilder.ReadUnsignedInt(Pool.GetEntry(Index).Payload, 0));
        },
        else => null,
    };
}

fn DoubleConstantBits(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) ?i64 {
    return switch (Instruction.Operation) {
        0x0e => @as(i64, @bitCast(@as(f64, 0.0))),
        0x0f => @as(i64, @bitCast(@as(f64, 1.0))),
        0x14 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (Pool.TagOf(Index) != ConstantPoolBuilder.TagDouble) break :Block null;
            break :Block @bitCast(std.mem.readInt(u64, Pool.GetEntry(Index).Payload[0..8], .big));
        },
        else => null,
    };
}

fn ModularInverse32(Value: u32) u32 {
    var Inverse: u32 = Value;
    var Iteration: usize = 0;
    while (Iteration < 5) : (Iteration += 1) Inverse = Inverse *% (2 -% Value *% Inverse);
    return Inverse;
}

fn EmitConstant(Output: *std.ArrayList(VirtualMachineInstruction), AllocatorHandle: std.mem.Allocator, Value: i32, Random: std.Random, Depth: u8) !void {
    if (!RuntimeConfig.Active.Passes.Virtualizer.MbaEnabled or Depth == 0 or Random.uintLessThan(u8, 100) >= RuntimeConfig.Active.Passes.Virtualizer.MbaSplitPercent) {
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPush, .Immediate = Value });
        return;
    }
    switch (Random.uintLessThan(u8, 4)) {
        0 => {
            const Mask: i32 = @bitCast(Random.int(u32));
            try EmitConstant(Output, AllocatorHandle, Value ^ Mask, Random, Depth - 1);
            try EmitConstant(Output, AllocatorHandle, Mask, Random, Depth - 1);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualXor });
        },
        1 => {
            const Mask: i32 = @bitCast(Random.int(u32));
            try EmitConstant(Output, AllocatorHandle, Value -% Mask, Random, Depth - 1);
            try EmitConstant(Output, AllocatorHandle, Mask, Random, Depth - 1);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAdd });
        },
        2 => {
            const Mask: i32 = @bitCast(Random.int(u32));
            try EmitConstant(Output, AllocatorHandle, Value +% Mask, Random, Depth - 1);
            try EmitConstant(Output, AllocatorHandle, Mask, Random, Depth - 1);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualSubtract });
        },
        else => {
            const OddMultiplier: u32 = Random.int(u32) | 1;
            const Inverse = ModularInverse32(OddMultiplier);
            try EmitConstant(Output, AllocatorHandle, Value *% @as(i32, @bitCast(Inverse)), Random, Depth - 1);
            try EmitConstant(Output, AllocatorHandle, @as(i32, @bitCast(OddMultiplier)), Random, Depth - 1);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMultiply });
        },
    }
}

fn EmitMove(Output: *std.ArrayList(VirtualMachineInstruction), AllocatorHandle: std.mem.Allocator, Destination: i8, Source: i8, DepthDelta: i8) !void {
    try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMove, .MoveDestination = Destination, .MoveSource = Source, .MoveDepthDelta = DepthDelta });
}

fn EmitDupInsert(Output: *std.ArrayList(VirtualMachineInstruction), AllocatorHandle: std.mem.Allocator, DuplicateSlots: i8, SkipSlots: i8) !void {
    var Position: i8 = 0;
    while (Position < DuplicateSlots) : (Position += 1) {
        const DepthDelta: i8 = if (SkipSlots == 0 and Position == DuplicateSlots - 1) DuplicateSlots else 0;
        try EmitMove(Output, AllocatorHandle, Position, Position - DuplicateSlots, DepthDelta);
    }
    if (SkipSlots == 0) return;
    var Skip: i8 = SkipSlots;
    while (Skip > 0) {
        Skip -= 1;
        try EmitMove(Output, AllocatorHandle, Skip - SkipSlots, Skip - DuplicateSlots - SkipSlots, 0);
    }
    Position = 0;
    while (Position < DuplicateSlots) : (Position += 1) {
        const DepthDelta: i8 = if (Position == DuplicateSlots - 1) DuplicateSlots else 0;
        try EmitMove(Output, AllocatorHandle, Position - DuplicateSlots - SkipSlots, Position, DepthDelta);
    }
}

fn MethodHasStackJuggle(Code: *const BytecodeInstructionModel.CodeAttribute) bool {
    for (Code.Instructions.items) |Instruction| {
        switch (Instruction.Operation) {
            0x58, 0x5b, 0x5c => return true,
            else => {},
        }
    }
    return false;
}

fn ComputeStackStates(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, Code: *const BytecodeInstructionModel.CodeAttribute, Descriptor: []const u8, IsStatic: bool, ThisClass: u16) ![]TypeSimulator.State {
    const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, Pool, Descriptor, IsStatic, ThisClass, false);
    var Frames: []StackMapTableCodec.Frame = &.{};
    if (ClassFileModel.FindAttribute(Code.Attributes.items, Pool, "StackMapTable")) |AttributeIndex| {
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[AttributeIndex].Info, Code.Instructions.items, InitialLocals);
    }
    return TypeSimulator.Simulate(AllocatorHandle, Pool, Code.Instructions.items, Frames, InitialLocals, ThisClass);
}

fn DescriptorMentionsWide(Descriptor: []const u8) bool {
    for (Descriptor) |Char| {
        if (Char == 'J' or Char == 'D') return true;
    }
    return false;
}

fn MethodUsesCategoryTwo(Pool: *const ConstantPoolBuilder.ConstantPool, Code: *const BytecodeInstructionModel.CodeAttribute) bool {
    for (Code.Instructions.items) |Instruction| {
        switch (Instruction.Operation) {
            0x09,
            0x0a,
            0x0e,
            0x0f,
            0x14,
            0x16,
            0x18,
            0x1e...0x21,
            0x26...0x29,
            0x37,
            0x39,
            0x3f...0x42,
            0x47...0x4a,
            0x2f,
            0x31,
            0x50,
            0x52,
            0x61,
            0x63,
            0x65,
            0x67,
            0x69,
            0x6b,
            0x6d,
            0x6f,
            0x71,
            0x73,
            0x75,
            0x77,
            0x79,
            0x7b,
            0x7d,
            0x7f,
            0x81,
            0x83,
            0x85,
            0x87,
            0x88,
            0x89,
            0x8a,
            0x8c,
            0x8d,
            0x8e,
            0x8f,
            0x90,
            0x94,
            0x97,
            0x98,
            0xad,
            0xaf,
            => return true,
            0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9 => {
                const ReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
                if (ResolveMethodReference(Pool, ReferenceIndex)) |Info| {
                    if (DescriptorMentionsWide(Info.Descriptor)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn Translate(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction, Output: *std.ArrayList(VirtualMachineInstruction), AllocatorHandle: std.mem.Allocator, MappingRegistry: *const Mapping, Random: std.Random, CurrentClass: []const u8, UsesCategoryTwo: bool, StackBefore: []const TypeSimulator.VType) !bool {
    const Opcode = Instruction.Operation;
    if (IntegerConstant(Pool, Instruction)) |Value| {
        try EmitConstant(Output, AllocatorHandle, Value, Random, RuntimeConfig.Active.Passes.Virtualizer.MbaMaxDepth);
        return true;
    }
    if (LongConstant(Pool, Instruction)) |LongValue| {
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPushLong, .LongImmediate = LongValue });
        return true;
    }
    if (FloatConstantBits(Pool, Instruction)) |FloatBits| {
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPushFloat, .Immediate = FloatBits });
        return true;
    }
    if (DoubleConstantBits(Pool, Instruction)) |DoubleBits| {
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPushDouble, .LongImmediate = DoubleBits });
        return true;
    }
    if (StringConstant(Pool, Instruction)) |StringValue| {
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPushString, .Symbol = StringValue });
        return true;
    }
    if (ClassConstant(Pool, Instruction)) |ClassName| {
        const FinalName = MappingRegistry.RemapInternal(ClassName) orelse ClassName;
        const Symbol = try BuildClassSymbol(AllocatorHandle, FinalName);
        try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoadClass, .Symbol = Symbol });
        return true;
    }
    switch (Opcode) {
        0x00 => {},
        0x15 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = Instruction.Raw[0] }),
        0x1a...0x1d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = @intCast(Opcode - 0x1a) }),
        0x36 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = Instruction.Raw[0] }),
        0x3b...0x3e => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = @intCast(Opcode - 0x3b) }),
        0x60 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAdd }),
        0x64 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualSubtract }),
        0x68 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMultiply }),
        0x6c => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualDivide }),
        0x70 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualRemainder }),
        0x74 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualNegate }),
        0x78 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualShiftLeft }),
        0x7a => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualShiftRight }),
        0x7c => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualUnsignedShiftRight }),
        0x7e => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAnd }),
        0x80 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualOr }),
        0x82 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualXor }),
        0x57 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPop }),
        0x59 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualDuplicate }),
        0x5f => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualSwap }),
        0x5a => {
            try EmitMove(Output, AllocatorHandle, 0, -1, 0);
            try EmitMove(Output, AllocatorHandle, -1, -2, 0);
            try EmitMove(Output, AllocatorHandle, -2, 0, 1);
        },
        0x58 => {
            if (UsesCategoryTwo) {
                if (StackBefore.len == 0) return false;
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPop });
                if (!TypeSimulator.IsCategoryTwo(StackBefore[StackBefore.len - 1])) {
                    if (StackBefore.len < 2) return false;
                    try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPop });
                }
            } else {
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPop });
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPop });
            }
        },
        0x5c => {
            const DuplicateSlots: i8 = if (UsesCategoryTwo) Block: {
                if (StackBefore.len == 0) return false;
                break :Block if (TypeSimulator.IsCategoryTwo(StackBefore[StackBefore.len - 1])) 1 else 2;
            } else 2;
            try EmitDupInsert(Output, AllocatorHandle, DuplicateSlots, 0);
        },
        0x5b => {
            const SkipSlots: i8 = if (UsesCategoryTwo) Block: {
                if (StackBefore.len < 2) return false;
                break :Block if (TypeSimulator.IsCategoryTwo(StackBefore[StackBefore.len - 2])) 1 else 2;
            } else 2;
            try EmitDupInsert(Output, AllocatorHandle, 1, SkipSlots);
        },
        0x5d, 0x5e => return false,
        0x84 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIncrement, .Index = Instruction.Raw[0], .Immediate = @as(i32, @as(i8, @bitCast(Instruction.Raw[1]))) }),
        0xa7, 0xc8 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualGoto, .TargetJumpIdentifier = Instruction.Target }),
        0x99 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionEqual, .TargetJumpIdentifier = Instruction.Target }),
        0x9a => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionNotEqual, .TargetJumpIdentifier = Instruction.Target }),
        0x9b => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionLessThan, .TargetJumpIdentifier = Instruction.Target }),
        0x9c => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionGreaterEqual, .TargetJumpIdentifier = Instruction.Target }),
        0x9d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionGreaterThan, .TargetJumpIdentifier = Instruction.Target }),
        0x9e => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIf, .Condition = InstructionSetArchitecture.ConditionLessEqual, .TargetJumpIdentifier = Instruction.Target }),
        0x9f => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionEqual, .TargetJumpIdentifier = Instruction.Target }),
        0xa0 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionNotEqual, .TargetJumpIdentifier = Instruction.Target }),
        0xa1 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionLessThan, .TargetJumpIdentifier = Instruction.Target }),
        0xa2 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionGreaterEqual, .TargetJumpIdentifier = Instruction.Target }),
        0xa3 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionGreaterThan, .TargetJumpIdentifier = Instruction.Target }),
        0xa4 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfCompare, .Condition = InstructionSetArchitecture.ConditionLessEqual, .TargetJumpIdentifier = Instruction.Target }),
        0xac => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualReturn }),
        0xbf => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAThrow }),
        0xb1 => {
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualPush, .Immediate = 0 });
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualReturn });
        },
        0xb6, 0xb8, 0xb9 => {
            const MethodReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const MethodInfo = ResolveMethodReference(Pool, MethodReferenceIndex) orelse return false;
            const FinalOwner = MappingRegistry.RemapInternal(MethodInfo.Owner) orelse MethodInfo.Owner;
            const Symbol = try BuildInvokeSymbol(AllocatorHandle, FinalOwner, MethodInfo.Name, MethodInfo.Descriptor, MappingRegistry);
            const Kind: u8 = switch (Opcode) {
                0xb6 => 0,
                0xb9 => 2,
                else => 3,
            };
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCall, .Symbol = Symbol, .Index = Kind, .Condition = if (ReturnPushes(MethodInfo.Descriptor)) @as(u8, 1) else 0 });
        },
        0xb7 => {
            const MethodReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const MethodInfo = ResolveMethodReference(Pool, MethodReferenceIndex) orelse return false;
            const FinalOwner = MappingRegistry.RemapInternal(MethodInfo.Owner) orelse MethodInfo.Owner;
            if (std.mem.eql(u8, MethodInfo.Name, "<init>")) {
                const Symbol = try BuildInitSymbol(AllocatorHandle, FinalOwner, MethodInfo.Descriptor, MappingRegistry);
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualInit, .Symbol = Symbol });
            } else if (std.mem.eql(u8, MethodInfo.Owner, CurrentClass)) {
                const Symbol = try BuildInvokeSymbol(AllocatorHandle, FinalOwner, MethodInfo.Name, MethodInfo.Descriptor, MappingRegistry);
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCall, .Symbol = Symbol, .Index = 1, .Condition = if (ReturnPushes(MethodInfo.Descriptor)) @as(u8, 1) else 0 });
            } else {
                const Symbol = try BuildInvokeSymbol(AllocatorHandle, FinalOwner, MethodInfo.Name, MethodInfo.Descriptor, MappingRegistry);
                try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCall, .Symbol = Symbol, .Index = 5, .Condition = if (ReturnPushes(MethodInfo.Descriptor)) @as(u8, 1) else 0 });
            }
        },
        0xb2, 0xb3 => {
            const FieldReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const FieldInfo = ResolveMethodReference(Pool, FieldReferenceIndex) orelse return false;
            const FinalOwner = MappingRegistry.RemapInternal(FieldInfo.Owner) orelse FieldInfo.Owner;
            const Symbol = try BuildSymbol(AllocatorHandle, FinalOwner, FieldInfo.Name);
            try Output.append(AllocatorHandle, .{ .Operation = if (Opcode == 0xb2) InstructionSetArchitecture.VirtualGetStatic else InstructionSetArchitecture.VirtualPutStatic, .Symbol = Symbol });
        },
        0xb4, 0xb5 => {
            const FieldReferenceIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const FieldInfo = ResolveMethodReference(Pool, FieldReferenceIndex) orelse return false;
            const FinalOwner = MappingRegistry.RemapInternal(FieldInfo.Owner) orelse FieldInfo.Owner;
            const Symbol = try BuildSymbol(AllocatorHandle, FinalOwner, FieldInfo.Name);
            try Output.append(AllocatorHandle, .{ .Operation = if (Opcode == 0xb4) InstructionSetArchitecture.VirtualGetField else InstructionSetArchitecture.VirtualPutField, .Symbol = Symbol });
        },
        0x01 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAConstNull }),
        0x19 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = Instruction.Raw[0] }),
        0x2a...0x2d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = @intCast(Opcode - 0x2a) }),
        0x3a => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = Instruction.Raw[0] }),
        0x4b...0x4e => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = @intCast(Opcode - 0x4b) }),
        0xb0 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualReturn }),
        0xc6 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfNull, .Condition = 0, .TargetJumpIdentifier = Instruction.Target }),
        0xc7 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfNull, .Condition = 1, .TargetJumpIdentifier = Instruction.Target }),
        0xa5 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfAcmp, .Condition = 0, .TargetJumpIdentifier = Instruction.Target }),
        0xa6 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualIfAcmp, .Condition = 1, .TargetJumpIdentifier = Instruction.Target }),
        0xbb => {
            const ClassIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const ClassName = ClassNameOf(Pool, ClassIndex);
            const FinalName = MappingRegistry.RemapInternal(ClassName) orelse ClassName;
            const Symbol = try BuildClassSymbol(AllocatorHandle, FinalName);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualNew, .Symbol = Symbol });
        },
        0xc0, 0xc1 => {
            const ClassIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const ClassName = ClassNameOf(Pool, ClassIndex);
            const FinalName = MappingRegistry.RemapInternal(ClassName) orelse ClassName;
            const Symbol = try BuildClassSymbol(AllocatorHandle, FinalName);
            try Output.append(AllocatorHandle, .{ .Operation = if (Opcode == 0xc0) InstructionSetArchitecture.VirtualCheckCast else InstructionSetArchitecture.VirtualInstanceOf, .Symbol = Symbol });
        },
        0xbc => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualNewArray, .Index = Instruction.Raw[0] }),
        0xbd => {
            const ClassIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const ClassName = ClassNameOf(Pool, ClassIndex);
            const FinalName = MappingRegistry.RemapInternal(ClassName) orelse ClassName;
            const Symbol = try BuildClassSymbol(AllocatorHandle, FinalName);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualANewArray, .Symbol = Symbol });
        },
        0xbe => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualArrayLength }),
        0xc5 => {
            const ClassIndex = (@as(u16, Instruction.Raw[0]) << 8) | @as(u16, Instruction.Raw[1]);
            const Dimensions = Instruction.Raw[2];
            const Symbol = try MultiComponentSymbol(AllocatorHandle, ClassNameOf(Pool, ClassIndex), Dimensions, MappingRegistry);
            try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMultiANewArray, .Symbol = Symbol, .Index = Dimensions });
        },
        0x2e...0x35 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualArrayLoad, .Index = @intCast(Opcode - 0x2e) }),
        0x4f...0x56 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualArrayStore, .Index = @intCast(Opcode - 0x4f) }),
        0xaa => try Output.append(AllocatorHandle, .{
            .Operation = InstructionSetArchitecture.VirtualTableSwitch,
            .TargetJumpIdentifier = Instruction.SwitchDefault,
            .SwitchLow = Instruction.SwitchLow,
            .SwitchHigh = Instruction.SwitchHigh,
            .SwitchTargetIdentifiers = Instruction.SwitchTargets,
        }),
        0xab => {
            const Keys = try AllocatorHandle.alloc(i32, Instruction.SwitchPairs.len);
            const Targets = try AllocatorHandle.alloc(u32, Instruction.SwitchPairs.len);
            for (Instruction.SwitchPairs, 0..) |PairEntry, PairIndex| {
                Keys[PairIndex] = PairEntry.Key;
                Targets[PairIndex] = PairEntry.Target;
            }
            try Output.append(AllocatorHandle, .{
                .Operation = InstructionSetArchitecture.VirtualLookupSwitch,
                .TargetJumpIdentifier = Instruction.SwitchDefault,
                .SwitchKeys = Keys,
                .SwitchTargetIdentifiers = Targets,
            });
        },
        0x16 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = Instruction.Raw[0] }),
        0x1e...0x21 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = @intCast(Opcode - 0x1e) }),
        0x37 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = Instruction.Raw[0] }),
        0x3f...0x42 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = @intCast(Opcode - 0x3f) }),
        0x61 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAdd }),
        0x65 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualSubtract }),
        0x69 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMultiply }),
        0x6d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualDivide }),
        0x71 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualRemainder }),
        0x75 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualNegate }),
        0x79 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualShiftLeft }),
        0x7b => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualShiftRight }),
        0x7d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualUnsignedShiftRight }),
        0x7f => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAnd }),
        0x81 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualOr }),
        0x83 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualXor }),
        0x94 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCompareWide, .Condition = 0 }),
        0x17 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = Instruction.Raw[0] }),
        0x22...0x25 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = @intCast(Opcode - 0x22) }),
        0x38 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = Instruction.Raw[0] }),
        0x43...0x46 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = @intCast(Opcode - 0x43) }),
        0x18 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = Instruction.Raw[0] }),
        0x26...0x29 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualLoad, .Index = @intCast(Opcode - 0x26) }),
        0x39 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = Instruction.Raw[0] }),
        0x47...0x4a => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualStore, .Index = @intCast(Opcode - 0x47) }),
        0x62, 0x63 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualAdd }),
        0x66, 0x67 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualSubtract }),
        0x6a, 0x6b => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMultiply }),
        0x6e, 0x6f => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualDivide }),
        0x72, 0x73 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualRemainder }),
        0x76, 0x77 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualNegate }),
        0x95 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCompareWide, .Condition = 1 }),
        0x96 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCompareWide, .Condition = 2 }),
        0x97 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCompareWide, .Condition = 3 }),
        0x98 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualCompareWide, .Condition = 4 }),
        0x85 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 1 }),
        0x86 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 2 }),
        0x87 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 3 }),
        0x88 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 0 }),
        0x89 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 2 }),
        0x8a => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 3 }),
        0x8b => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 0 }),
        0x8c => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 1 }),
        0x8d => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 3 }),
        0x8e => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 0 }),
        0x8f => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 1 }),
        0x90 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 2 }),
        0x91 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 4 }),
        0x92 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 5 }),
        0x93 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualConvert, .Condition = 6 }),
        0xad, 0xae, 0xaf => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualReturn }),
        0xc2 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMonitorEnter }),
        0xc3 => try Output.append(AllocatorHandle, .{ .Operation = InstructionSetArchitecture.VirtualMonitorExit }),
        else => return false,
    }
    return true;
}

pub fn MethodVirtualizer(
    AllocatorHandle: std.mem.Allocator,
    Pool: *ConstantPoolBuilder.ConstantPool,
    Code: *const BytecodeInstructionModel.CodeAttribute,
    Descriptor: []const u8,
    Permutation: [64]u8,
    MappingRegistry: *const Mapping,
    Random: std.Random,
    CurrentClass: []const u8,
    ThisClass: u16,
    IsStatic: bool,
) !?Program {
    if (!DescriptorUtil.DescriptorIsSupported(Descriptor)) return null;

    var VirtualInstructions: std.ArrayList(VirtualMachineInstruction) = .empty;
    var LabelMap = std.AutoHashMap(u32, usize).init(AllocatorHandle);
    defer LabelMap.deinit();

    const UsesCategoryTwo = MethodUsesCategoryTwo(Pool, Code);
    var StackStates: []const TypeSimulator.State = &.{};
    if (UsesCategoryTwo and MethodHasStackJuggle(Code)) {
        StackStates = ComputeStackStates(AllocatorHandle, Pool, Code, Descriptor, IsStatic, ThisClass) catch return null;
        if (StackStates.len != Code.Instructions.items.len) return null;
    }
    for (Code.Instructions.items, 0..) |Instruction, InstructionIndex| {
        try LabelMap.put(Instruction.Identifier, VirtualInstructions.items.len);
        const StackBefore: []const TypeSimulator.VType = if (InstructionIndex < StackStates.len) StackStates[InstructionIndex].Stack else &.{};
        const TranslateOk = try Translate(Pool, Instruction, &VirtualInstructions, AllocatorHandle, MappingRegistry, Random, CurrentClass, UsesCategoryTwo, StackBefore);
        if (!TranslateOk) return null;
    }

    for (VirtualInstructions.items) |VirtualInstruction| {
        if (!IsCoreOperation(VirtualInstruction.Operation)) return null;
    }

    for (VirtualInstructions.items) |VirtualInstruction| {
        switch (VirtualInstruction.Operation) {
            InstructionSetArchitecture.VirtualGoto, InstructionSetArchitecture.VirtualIf, InstructionSetArchitecture.VirtualIfCompare, InstructionSetArchitecture.VirtualIfNull, InstructionSetArchitecture.VirtualIfAcmp => {
                if (LabelMap.get(VirtualInstruction.TargetJumpIdentifier) == null) return null;
            },
            InstructionSetArchitecture.VirtualTableSwitch, InstructionSetArchitecture.VirtualLookupSwitch => {
                if (LabelMap.get(VirtualInstruction.TargetJumpIdentifier) == null) return null;
                for (VirtualInstruction.SwitchTargetIdentifiers) |TargetIdentifier| {
                    if (LabelMap.get(TargetIdentifier) == null) return null;
                }
            },
            else => {},
        }
    }

    const DepthBefore = try AllocatorHandle.alloc(u16, VirtualInstructions.items.len);
    {
        const DepthUnknown: i32 = -1;
        const DepthWork = try AllocatorHandle.alloc(i32, VirtualInstructions.items.len);
        for (DepthWork) |*Slot| Slot.* = DepthUnknown;
        const DepthItem = struct { Index: usize, Depth: i32 };
        var WorkList: std.ArrayList(DepthItem) = .empty;
        if (VirtualInstructions.items.len > 0) try WorkList.append(AllocatorHandle, .{ .Index = 0, .Depth = 0 });
        for (Code.Exceptions.items) |ExceptionTableEntry| {
            if (LabelMap.get(ExceptionTableEntry.Handler)) |HandlerIndex| {
                try WorkList.append(AllocatorHandle, .{ .Index = HandlerIndex, .Depth = 1 });
            }
        }
        var WorkIndex: usize = 0;
        while (WorkIndex < WorkList.items.len) : (WorkIndex += 1) {
            const Item = WorkList.items[WorkIndex];
            if (Item.Index >= VirtualInstructions.items.len) continue;
            if (DepthWork[Item.Index] != DepthUnknown) continue;
            DepthWork[Item.Index] = Item.Depth;
            const Instruction = VirtualInstructions.items[Item.Index];
            const After = Item.Depth + CoreStackEffect(Instruction);
            if (After < 0) return null;
            switch (Instruction.Operation) {
                InstructionSetArchitecture.VirtualGoto => {
                    try WorkList.append(AllocatorHandle, .{ .Index = LabelMap.get(Instruction.TargetJumpIdentifier) orelse return null, .Depth = After });
                },
                InstructionSetArchitecture.VirtualReturn, InstructionSetArchitecture.VirtualAThrow => {},
                InstructionSetArchitecture.VirtualIf, InstructionSetArchitecture.VirtualIfCompare => {
                    try WorkList.append(AllocatorHandle, .{ .Index = Item.Index + 1, .Depth = After });
                    try WorkList.append(AllocatorHandle, .{ .Index = LabelMap.get(Instruction.TargetJumpIdentifier) orelse return null, .Depth = After });
                },
                else => try WorkList.append(AllocatorHandle, .{ .Index = Item.Index + 1, .Depth = After }),
            }
        }
        for (DepthWork, 0..) |Value, Index| {
            if (Value == DepthUnknown or Value > 65535) return null;
            DepthBefore[Index] = @intCast(Value);
        }
    }

    const VirtualProgramCounters = try AllocatorHandle.alloc(u32, VirtualInstructions.items.len + 1);
    var Offset: u32 = 0;
    for (VirtualInstructions.items, 0..) |VirtualInstruction, Index| {
        VirtualProgramCounters[Index] = Offset;
        Offset += @intCast(VirtualInstruction.Size());
    }
    VirtualProgramCounters[VirtualInstructions.items.len] = Offset;
    const Total = Offset;

    const JumpIdentifierToOffset = struct {
        fn Get(LabelToOffsetMap: *std.AutoHashMap(u32, usize), OffsetTable: []const u32, JumpIdentifier: u32, Base: u32) u32 {
            return Base + OffsetTable[LabelToOffsetMap.get(JumpIdentifier) orelse OffsetTable.len - 1];
        }
    }.Get;

    const HandlerEntry = struct { StartOffset: u32, EndOffset: u32, HandlerOffset: u32, CatchSymbol: []const u8 };
    var HandlerEntries: std.ArrayList(HandlerEntry) = .empty;
    for (Code.Exceptions.items) |ExceptionTableEntry| {
        try HandlerEntries.append(AllocatorHandle, .{
            .StartOffset = JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, ExceptionTableEntry.Start, 0),
            .EndOffset = JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, ExceptionTableEntry.End, 0),
            .HandlerOffset = JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, ExceptionTableEntry.Handler, 0),
            .CatchSymbol = if (ExceptionTableEntry.CatchType == 0) "" else Block: {
                const CatchName = ClassNameOf(Pool, ExceptionTableEntry.CatchType);
                const FinalName = MappingRegistry.RemapInternal(CatchName) orelse CatchName;
                break :Block try BuildClassSymbol(AllocatorHandle, FinalName);
            },
        });
    }
    var TableSize: u32 = 2;
    for (HandlerEntries.items) |Entry| TableSize += @intCast(14 + Entry.CatchSymbol.len);

    var Output: std.ArrayList(u8) = .empty;
    var OpcodeOffsets: std.ArrayList(u32) = .empty;
    var StackOperandOffsets: std.ArrayList(u32) = .empty;
    var LocalOperandOffsets: std.ArrayList(u32) = .empty;
    const Emit = struct {
        fn Slot(Alloc: std.mem.Allocator, Out: *std.ArrayList(u8), Offs: *std.ArrayList(u32), Base: u32, LogicalSlot: i64) !void {
            const Value: u16 = @intCast(LogicalSlot);
            try Offs.append(Alloc, Base + @as(u32, @intCast(Out.items.len)));
            try Out.append(Alloc, @intCast((Value >> 8) & 0xff));
            try Out.append(Alloc, @intCast(Value & 0xff));
        }
        fn Local(Alloc: std.mem.Allocator, Out: *std.ArrayList(u8), Offs: *std.ArrayList(u32), Base: u32, IndexByte: u8) !void {
            try Offs.append(Alloc, Base + @as(u32, @intCast(Out.items.len)));
            try Out.append(Alloc, IndexByte);
        }
    };
    for (VirtualInstructions.items, 0..) |VirtualInstruction, EmitIndex| {
        const Depth: i64 = DepthBefore[EmitIndex];
        try OpcodeOffsets.append(AllocatorHandle, TableSize + @as(u32, @intCast(Output.items.len)));
        try Output.append(AllocatorHandle, Permutation[VirtualInstruction.Operation]);
        switch (VirtualInstruction.Operation) {
            InstructionSetArchitecture.VirtualPush, InstructionSetArchitecture.VirtualPushFloat => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth);
                try Write32(AllocatorHandle, &Output, @bitCast(VirtualInstruction.Immediate));
            },
            InstructionSetArchitecture.VirtualPushLong, InstructionSetArchitecture.VirtualPushDouble => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth);
                try Write64(AllocatorHandle, &Output, @bitCast(VirtualInstruction.LongImmediate));
            },
            InstructionSetArchitecture.VirtualPushString, InstructionSetArchitecture.VirtualGetStatic, InstructionSetArchitecture.VirtualNew, InstructionSetArchitecture.VirtualLoadClass => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth);
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
            },
            InstructionSetArchitecture.VirtualAConstNull => try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth),
            InstructionSetArchitecture.VirtualLoad => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth);
                try Emit.Local(AllocatorHandle, &Output, &LocalOperandOffsets, TableSize, VirtualInstruction.Index);
            },
            InstructionSetArchitecture.VirtualStore => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Local(AllocatorHandle, &Output, &LocalOperandOffsets, TableSize, VirtualInstruction.Index);
            },
            InstructionSetArchitecture.VirtualIncrement => {
                try Emit.Local(AllocatorHandle, &Output, &LocalOperandOffsets, TableSize, VirtualInstruction.Index);
                try Write32(AllocatorHandle, &Output, @bitCast(VirtualInstruction.Immediate));
            },
            InstructionSetArchitecture.VirtualAdd, InstructionSetArchitecture.VirtualSubtract, InstructionSetArchitecture.VirtualMultiply, InstructionSetArchitecture.VirtualDivide, InstructionSetArchitecture.VirtualRemainder, InstructionSetArchitecture.VirtualAnd, InstructionSetArchitecture.VirtualOr, InstructionSetArchitecture.VirtualXor, InstructionSetArchitecture.VirtualShiftLeft, InstructionSetArchitecture.VirtualShiftRight, InstructionSetArchitecture.VirtualUnsignedShiftRight => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
            },
            InstructionSetArchitecture.VirtualNegate => try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1),
            InstructionSetArchitecture.VirtualConvert => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Output.append(AllocatorHandle, VirtualInstruction.Condition);
            },
            InstructionSetArchitecture.VirtualCompareWide => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
                try Output.append(AllocatorHandle, VirtualInstruction.Condition);
            },
            InstructionSetArchitecture.VirtualDuplicate => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth);
            },
            InstructionSetArchitecture.VirtualSwap => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
            },
            InstructionSetArchitecture.VirtualMove => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth + @as(i64, VirtualInstruction.MoveDestination));
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth + @as(i64, VirtualInstruction.MoveSource));
            },
            InstructionSetArchitecture.VirtualReturn, InstructionSetArchitecture.VirtualAThrow, InstructionSetArchitecture.VirtualMonitorEnter, InstructionSetArchitecture.VirtualMonitorExit => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
            },
            InstructionSetArchitecture.VirtualPop => {},
            InstructionSetArchitecture.VirtualGoto => try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, VirtualInstruction.TargetJumpIdentifier, TableSize)),
            InstructionSetArchitecture.VirtualIf, InstructionSetArchitecture.VirtualIfNull => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Output.append(AllocatorHandle, VirtualInstruction.Condition);
                try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, VirtualInstruction.TargetJumpIdentifier, TableSize));
            },
            InstructionSetArchitecture.VirtualIfCompare, InstructionSetArchitecture.VirtualIfAcmp => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
                try Output.append(AllocatorHandle, VirtualInstruction.Condition);
                try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, VirtualInstruction.TargetJumpIdentifier, TableSize));
            },
            InstructionSetArchitecture.VirtualTableSwitch => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, VirtualInstruction.TargetJumpIdentifier, TableSize));
                try Write32(AllocatorHandle, &Output, @bitCast(VirtualInstruction.SwitchLow));
                try Write32(AllocatorHandle, &Output, @bitCast(VirtualInstruction.SwitchHigh));
                for (VirtualInstruction.SwitchTargetIdentifiers) |TargetIdentifier| {
                    try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, TargetIdentifier, TableSize));
                }
            },
            InstructionSetArchitecture.VirtualLookupSwitch => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, VirtualInstruction.TargetJumpIdentifier, TableSize));
                try Write32(AllocatorHandle, &Output, @intCast(VirtualInstruction.SwitchTargetIdentifiers.len));
                for (VirtualInstruction.SwitchKeys, VirtualInstruction.SwitchTargetIdentifiers) |KeyValue, TargetIdentifier| {
                    try Write32(AllocatorHandle, &Output, @bitCast(KeyValue));
                    try Write32(AllocatorHandle, &Output, JumpIdentifierToOffset(&LabelMap, VirtualProgramCounters, TargetIdentifier, TableSize));
                }
            },
            InstructionSetArchitecture.VirtualPutStatic, InstructionSetArchitecture.VirtualGetField, InstructionSetArchitecture.VirtualCheckCast, InstructionSetArchitecture.VirtualInstanceOf, InstructionSetArchitecture.VirtualANewArray => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
            },
            InstructionSetArchitecture.VirtualPutField => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
            },
            InstructionSetArchitecture.VirtualNewArray => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Output.append(AllocatorHandle, VirtualInstruction.Index);
            },
            InstructionSetArchitecture.VirtualArrayLength => try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1),
            InstructionSetArchitecture.VirtualArrayLoad => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
                try Output.append(AllocatorHandle, VirtualInstruction.Index);
            },
            InstructionSetArchitecture.VirtualArrayStore => {
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 2);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 3);
                try Output.append(AllocatorHandle, VirtualInstruction.Index);
            },
            InstructionSetArchitecture.VirtualCall => {
                try Output.append(AllocatorHandle, VirtualInstruction.Index);
                try Output.append(AllocatorHandle, VirtualInstruction.Condition);
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
                const ColonIndex = std.mem.indexOfScalar(u8, VirtualInstruction.Symbol, ':') orelse return null;
                const ArgumentCount: i64 = @intCast(DescriptorUtil.ParameterCount(VirtualInstruction.Symbol[ColonIndex + 1 ..]));
                var ArgumentIndex: i64 = 0;
                while (ArgumentIndex < ArgumentCount) : (ArgumentIndex += 1) try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1 - ArgumentIndex);
                const Receiver: i64 = if (VirtualInstruction.Index != 3) 1 else 0;
                if (Receiver != 0) try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1 - ArgumentCount);
                if (VirtualInstruction.Condition != 0) try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - ArgumentCount - Receiver);
            },
            InstructionSetArchitecture.VirtualInit => {
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
                const ColonIndex = std.mem.indexOfScalar(u8, VirtualInstruction.Symbol, ':') orelse return null;
                const ArgumentCount: i64 = @intCast(DescriptorUtil.ParameterCount(VirtualInstruction.Symbol[ColonIndex + 1 ..]));
                var ArgumentIndex: i64 = 0;
                while (ArgumentIndex < ArgumentCount) : (ArgumentIndex += 1) try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1 - ArgumentIndex);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1 - ArgumentCount);
            },
            InstructionSetArchitecture.VirtualMultiANewArray => {
                try EmitSymbol(AllocatorHandle, &Output, VirtualInstruction.Symbol);
                try Output.append(AllocatorHandle, VirtualInstruction.Index);
                const Dimensions: i64 = VirtualInstruction.Index;
                var DimensionIndex: i64 = 0;
                while (DimensionIndex < Dimensions) : (DimensionIndex += 1) try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - 1 - DimensionIndex);
                try Emit.Slot(AllocatorHandle, &Output, &StackOperandOffsets, TableSize, Depth - Dimensions);
            },
            else => {},
        }
    }
    if (Output.items.len != Total) return null;

    var TableBytes: std.ArrayList(u8) = .empty;
    try TableBytes.append(AllocatorHandle, @intCast(HandlerEntries.items.len >> 8));
    try TableBytes.append(AllocatorHandle, @intCast(HandlerEntries.items.len & 0xff));
    for (HandlerEntries.items) |Entry| {
        try Write32(AllocatorHandle, &TableBytes, Entry.StartOffset + TableSize);
        try Write32(AllocatorHandle, &TableBytes, Entry.EndOffset + TableSize);
        try Write32(AllocatorHandle, &TableBytes, Entry.HandlerOffset + TableSize);
        try TableBytes.append(AllocatorHandle, @intCast(Entry.CatchSymbol.len >> 8));
        try TableBytes.append(AllocatorHandle, @intCast(Entry.CatchSymbol.len & 0xff));
        try TableBytes.appendSlice(AllocatorHandle, Entry.CatchSymbol);
    }
    try TableBytes.appendSlice(AllocatorHandle, Output.items);

    const BaseMaxStack: u16 = if (Code.MaxStack < 2) 2 else Code.MaxStack;
    const MixedBooleanArithmeticMargin: u16 = (if (RuntimeConfig.Active.Passes.Virtualizer.MbaEnabled) @as(u16, RuntimeConfig.Active.Passes.Virtualizer.MbaMaxDepth) else 0) + 1;
    return Program{
        .Bytes = TableBytes.items,
        .NumberOfLocals = Code.MaxLocals,
        .MaxStack = BaseMaxStack + MixedBooleanArithmeticMargin,
        .OpcodeOffsets = OpcodeOffsets.items,
        .LocalOperandOffsets = LocalOperandOffsets.items,
        .StackOperandOffsets = StackOperandOffsets.items,
    };
}

fn EmitSymbol(AllocatorHandle: std.mem.Allocator, Output: *std.ArrayList(u8), Symbol: []const u8) !void {
    try Output.append(AllocatorHandle, @intCast((Symbol.len >> 8) & 0xff));
    try Output.append(AllocatorHandle, @intCast(Symbol.len & 0xff));
    try Output.appendSlice(AllocatorHandle, Symbol);
}

fn Write32(AllocatorHandle: std.mem.Allocator, Output: *std.ArrayList(u8), Value: u32) !void {
    var ByteBuffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &ByteBuffer, Value, .big);
    try Output.appendSlice(AllocatorHandle, &ByteBuffer);
}

fn Write64(AllocatorHandle: std.mem.Allocator, Output: *std.ArrayList(u8), Value: u64) !void {
    var ByteBuffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &ByteBuffer, Value, .big);
    try Output.appendSlice(AllocatorHandle, &ByteBuffer);
}
