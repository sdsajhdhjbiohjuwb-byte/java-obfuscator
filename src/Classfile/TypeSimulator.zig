const std = @import("std");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("StackMapTableCodec.zig");

pub const VType = StackMapTableCodec.VType;

pub const State = struct {
    Locals: []VType,
    Stack: []VType,
};

const SimulationError = error{ Unsupported, OutOfMemory, BadState };

fn MakeObjectType(Pool: *ConstantPoolBuilder.ConstantPool, Name: []const u8) !VType {
    return .{ .Object = try Pool.AddClass(Name) };
}

pub fn IsCategoryTwo(ValueType: VType) bool {
    return switch (ValueType) {
        .Long, .Double => true,
        else => false,
    };
}

const Simulator = struct {
    Allocator: std.mem.Allocator,
    ConstantPool: *ConstantPoolBuilder.ConstantPool,
    Locals: []VType,
    Stack: std.ArrayList(VType),

    fn Push(Self: *Simulator, ValueType: VType) !void {
        try Self.Stack.append(Self.Allocator, ValueType);
    }
    fn Pop(Self: *Simulator) !VType {
        if (Self.Stack.items.len == 0) return error.BadState;
        return Self.Stack.pop().?;
    }
    fn SetLocal(Self: *Simulator, Slot: usize, ValueType: VType) void {
        if (Slot >= Self.Locals.len) return;
        Self.Locals[Slot] = ValueType;
        if (IsCategoryTwo(ValueType) and Slot + 1 < Self.Locals.len) Self.Locals[Slot + 1] = .Top;
    }
    fn GetLocal(Self: *Simulator, Slot: usize) VType {
        if (Slot >= Self.Locals.len) return .Top;
        return Self.Locals[Slot];
    }
};

fn FieldTypeAt(Pool: *ConstantPoolBuilder.ConstantPool, Descriptor: []const u8, Index: *usize) !VType {
    const CurrentChar = Descriptor[Index.*];
    switch (CurrentChar) {
        'B', 'C', 'I', 'S', 'Z' => {
            Index.* += 1;
            return .Integer;
        },
        'F' => {
            Index.* += 1;
            return .Float;
        },
        'J' => {
            Index.* += 1;
            return .Long;
        },
        'D' => {
            Index.* += 1;
            return .Double;
        },
        'L' => {
            const Start = Index.*;
            while (Descriptor[Index.*] != ';') Index.* += 1;
            const Name = Descriptor[Start + 1 .. Index.*];
            Index.* += 1;
            return MakeObjectType(Pool, Name);
        },
        '[' => {
            const Start = Index.*;
            while (Descriptor[Index.*] == '[') Index.* += 1;
            if (Descriptor[Index.*] == 'L') {
                while (Descriptor[Index.*] != ';') Index.* += 1;
                Index.* += 1;
            } else Index.* += 1;
            return MakeObjectType(Pool, Descriptor[Start..Index.*]);
        },
        else => return error.Unsupported,
    }
}

fn ReturnType(Pool: *ConstantPoolBuilder.ConstantPool, Descriptor: []const u8) !?VType {
    var Index: usize = 0;
    while (Descriptor[Index] != ')') Index += 1;
    Index += 1;
    if (Descriptor[Index] == 'V') return null;
    return try FieldTypeAt(Pool, Descriptor, &Index);
}

fn PopArgs(Simulation: *Simulator, Descriptor: []const u8) !void {
    var Count: usize = 0;
    var Index: usize = 1;
    while (Descriptor[Index] != ')') {
        _ = try FieldTypeAt(Simulation.ConstantPool, Descriptor, &Index);
        Count += 1;
    }
    var ThirdIndex: usize = 0;
    while (ThirdIndex < Count) : (ThirdIndex += 1) _ = try Simulation.Pop();
}

fn ElementType(Simulation: *Simulator, ArrayType: VType) !VType {
    switch (ArrayType) {
        .Null => return MakeObjectType(Simulation.ConstantPool, "java/lang/Object"),
        .Object => |ClassIndex| {
            const Name = Simulation.ConstantPool.ClassName(ClassIndex);
            if (Name.len < 1 or Name[0] != '[') return error.Unsupported;
            const InnerDescriptor = Name[1..];
            var Index: usize = 0;
            return try FieldTypeAt(Simulation.ConstantPool, InnerDescriptor, &Index);
        },
        else => return error.Unsupported,
    }
}

fn LdcType(Simulation: *Simulator, Index: u16) !VType {
    return switch (Simulation.ConstantPool.TagOf(Index)) {
        ConstantPoolBuilder.TagInteger => .Integer,
        ConstantPoolBuilder.TagFloat => .Float,
        ConstantPoolBuilder.TagLong => .Long,
        ConstantPoolBuilder.TagDouble => .Double,
        ConstantPoolBuilder.TagString => try MakeObjectType(Simulation.ConstantPool, "java/lang/String"),
        ConstantPoolBuilder.TagClass => try MakeObjectType(Simulation.ConstantPool, "java/lang/Class"),
        ConstantPoolBuilder.TagMethodType => try MakeObjectType(Simulation.ConstantPool, "java/lang/invoke/MethodType"),
        ConstantPoolBuilder.TagMethodHandle => try MakeObjectType(Simulation.ConstantPool, "java/lang/invoke/MethodHandle"),
        else => error.Unsupported,
    };
}

fn ReferenceDescriptor(Simulation: *Simulator, ReferenceIndex: u16) []const u8 {
    const NameAndTypeIndex = Simulation.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
    return Simulation.ConstantPool.Utf8Text(Simulation.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
}

fn Apply(Simulation: *Simulator, Instruction: BytecodeInstructionModel.Instruction, ThisClass: u16) SimulationError!void {
    const Opcode = Instruction.Operation;
    switch (Opcode) {
        0x00 => {},
        0x01 => try Simulation.Push(.Null),
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x10, 0x11 => try Simulation.Push(.Integer),
        0x09, 0x0a => try Simulation.Push(.Long),
        0x0b, 0x0c, 0x0d => try Simulation.Push(.Float),
        0x0e, 0x0f => try Simulation.Push(.Double),
        0x12, 0x13 => try Simulation.Push(try LdcType(Simulation, if (Opcode == 0x12) Instruction.Raw[0] else ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0))),
        0x14 => {
            const ConstantIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            try Simulation.Push(if (Simulation.ConstantPool.TagOf(ConstantIndex) == ConstantPoolBuilder.TagLong) .Long else .Double);
        },
        0x15 => try Simulation.Push(.Integer),
        0x16 => try Simulation.Push(.Long),
        0x17 => try Simulation.Push(.Float),
        0x18 => try Simulation.Push(.Double),
        0x19 => try Simulation.Push(Simulation.GetLocal(Instruction.Raw[0])),
        0x1a, 0x1b, 0x1c, 0x1d => try Simulation.Push(.Integer),
        0x1e, 0x1f, 0x20, 0x21 => try Simulation.Push(.Long),
        0x22, 0x23, 0x24, 0x25 => try Simulation.Push(.Float),
        0x26, 0x27, 0x28, 0x29 => try Simulation.Push(.Double),
        0x2a => try Simulation.Push(.{ .Object = ThisClass }),
        0x2b => try Simulation.Push(Simulation.GetLocal(1)),
        0x2c => try Simulation.Push(Simulation.GetLocal(2)),
        0x2d => try Simulation.Push(Simulation.GetLocal(3)),
        0x2e, 0x30, 0x33, 0x34, 0x35 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            try Simulation.Push(if (Opcode == 0x2e) .Integer else if (Opcode == 0x30) .Float else .Integer);
        },
        0x2f => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            try Simulation.Push(.Long);
        },
        0x31 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            try Simulation.Push(.Double);
        },
        0x32 => {
            _ = try Simulation.Pop();
            const ArrayReference = try Simulation.Pop();
            try Simulation.Push(try ElementType(Simulation, ArrayReference));
        },
        0x36 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Instruction.Raw[0], .Integer);
        },
        0x37 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Instruction.Raw[0], .Long);
        },
        0x38 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Instruction.Raw[0], .Float);
        },
        0x39 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Instruction.Raw[0], .Double);
        },
        0x3a => {
            const Value = try Simulation.Pop();
            Simulation.SetLocal(Instruction.Raw[0], Value);
        },
        0x3b, 0x3c, 0x3d, 0x3e => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Opcode - 0x3b, .Integer);
        },
        0x3f, 0x40, 0x41, 0x42 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Opcode - 0x3f, .Long);
        },
        0x43, 0x44, 0x45, 0x46 => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Opcode - 0x43, .Float);
        },
        0x47, 0x48, 0x49, 0x4a => {
            _ = try Simulation.Pop();
            Simulation.SetLocal(Opcode - 0x47, .Double);
        },
        0x4b, 0x4c, 0x4d, 0x4e => {
            const Value = try Simulation.Pop();
            Simulation.SetLocal(Opcode - 0x4b, Value);
        },
        0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
        },
        0x57 => {
            _ = try Simulation.Pop();
        },
        0x58 => {
            const Value = try Simulation.Pop();
            if (!IsCategoryTwo(Value)) _ = try Simulation.Pop();
        },
        0x59 => {
            const Value = try Simulation.Pop();
            try Simulation.Push(Value);
            try Simulation.Push(Value);
        },
        0x5a => {
            const FirstValue = try Simulation.Pop();
            const SecondValue = try Simulation.Pop();
            try Simulation.Push(FirstValue);
            try Simulation.Push(SecondValue);
            try Simulation.Push(FirstValue);
        },
        0x5b => {
            const FirstValue = try Simulation.Pop();
            const SecondValue = try Simulation.Pop();
            if (IsCategoryTwo(SecondValue)) return error.Unsupported;
            const ThirdValue = try Simulation.Pop();
            try Simulation.Push(FirstValue);
            try Simulation.Push(ThirdValue);
            try Simulation.Push(SecondValue);
            try Simulation.Push(FirstValue);
        },
        0x5c => {
            const FirstValue = try Simulation.Pop();
            if (IsCategoryTwo(FirstValue)) {
                try Simulation.Push(FirstValue);
                try Simulation.Push(FirstValue);
            } else {
                const SecondValue = try Simulation.Pop();
                try Simulation.Push(SecondValue);
                try Simulation.Push(FirstValue);
                try Simulation.Push(SecondValue);
                try Simulation.Push(FirstValue);
            }
        },
        0x5d, 0x5e => return error.Unsupported,
        0x5f => {
            const FirstValue = try Simulation.Pop();
            const SecondValue = try Simulation.Pop();
            try Simulation.Push(FirstValue);
            try Simulation.Push(SecondValue);
        },
        0x60...0x73 => {
            _ = try Simulation.Pop();
        },
        0x74...0x77 => {},
        0x78...0x83 => {
            _ = try Simulation.Pop();
        },
        0x84 => {},
        0x85 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Long);
        },
        0x86 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Float);
        },
        0x87 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Double);
        },
        0x88 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x89 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Float);
        },
        0x8a => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Double);
        },
        0x8b => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x8c => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Long);
        },
        0x8d => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Double);
        },
        0x8e => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x8f => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Long);
        },
        0x90 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Float);
        },
        0x91, 0x92, 0x93 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x94 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x95, 0x96, 0x97, 0x98 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e => {
            _ = try Simulation.Pop();
        },
        0x9f, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
        },
        0xa5, 0xa6 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
        },
        0xa7, 0xc8 => {},
        0xaa, 0xab => {
            _ = try Simulation.Pop();
        },
        0xac, 0xad, 0xae, 0xaf, 0xb0 => {
            _ = try Simulation.Pop();
        },
        0xb1 => {},
        0xbf => {
            _ = try Simulation.Pop();
        },
        0xb2 => try Simulation.Push(try FieldTypeOf(Simulation, Instruction.Raw)),
        0xb3 => {
            _ = try Simulation.Pop();
        },
        0xb4 => {
            _ = try Simulation.Pop();
            try Simulation.Push(try FieldTypeOf(Simulation, Instruction.Raw));
        },
        0xb5 => {
            _ = try Simulation.Pop();
            _ = try Simulation.Pop();
        },
        0xb6, 0xb7, 0xb8, 0xb9 => {
            const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            const Descriptor = ReferenceDescriptor(Simulation, ReferenceIndex);
            try PopArgs(Simulation, Descriptor);
            if (Opcode != 0xb8) _ = try Simulation.Pop();
            if (try ReturnType(Simulation.ConstantPool, Descriptor)) |ReturnedType| try Simulation.Push(ReturnedType);
        },
        0xba => {
            const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            const NameAndTypeIndex = Simulation.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
            const Descriptor = Simulation.ConstantPool.Utf8Text(Simulation.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
            try PopArgs(Simulation, Descriptor);
            if (try ReturnType(Simulation.ConstantPool, Descriptor)) |ReturnedType| try Simulation.Push(ReturnedType);
        },
        0xbb => {
            try Simulation.Push(.{ .Uninitialized = Instruction.Identifier });
        },
        0xbc => {
            _ = try Simulation.Pop();
            const ArrayTypeCode: u8 = Instruction.Raw[0];
            const TypeName = switch (ArrayTypeCode) {
                4 => "[Z",
                5 => "[C",
                6 => "[F",
                7 => "[D",
                8 => "[B",
                9 => "[S",
                10 => "[I",
                11 => "[J",
                else => return error.Unsupported,
            };
            try Simulation.Push(try MakeObjectType(Simulation.ConstantPool, TypeName));
        },
        0xbd => {
            _ = try Simulation.Pop();
            const ClassIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            const ElementName = Simulation.ConstantPool.ClassName(ClassIndex);
            const ArrayDescriptor = try std.fmt.allocPrint(Simulation.Allocator, "[L{s};", .{ElementName});
            const ResolvedArrayDescriptor = if (ElementName.len > 0 and ElementName[0] == '[') try std.fmt.allocPrint(Simulation.Allocator, "[{s}", .{ElementName}) else ArrayDescriptor;
            try Simulation.Push(try MakeObjectType(Simulation.ConstantPool, ResolvedArrayDescriptor));
        },
        0xbe => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0xc0 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.{ .Object = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0) });
        },
        0xc1 => {
            _ = try Simulation.Pop();
            try Simulation.Push(.Integer);
        },
        0xc2, 0xc3 => {
            _ = try Simulation.Pop();
        },
        0xc5 => {
            const Dimensions = Instruction.Raw[2];
            var ThirdIndex: usize = 0;
            while (ThirdIndex < Dimensions) : (ThirdIndex += 1) _ = try Simulation.Pop();
            try Simulation.Push(.{ .Object = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0) });
        },
        0xc6, 0xc7 => {
            _ = try Simulation.Pop();
        },
        0xc4 => return error.Unsupported,
        else => return error.Unsupported,
    }
}

fn FieldTypeOf(Simulation: *Simulator, RawOperands: []const u8) !VType {
    const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(RawOperands, 0);
    const Descriptor = ReferenceDescriptor(Simulation, ReferenceIndex);
    var Index: usize = 0;
    return try FieldTypeAt(Simulation.ConstantPool, Descriptor, &Index);
}

fn FrameToSlots(AllocatorHandle: std.mem.Allocator, Frame: StackMapTableCodec.Frame, MaxLocals: usize) ![]VType {
    const Slots = try AllocatorHandle.alloc(VType, MaxLocals);
    @memset(Slots, .Top);
    var SlotIndex: usize = 0;
    for (Frame.Locals) |ValueType| {
        if (SlotIndex >= MaxLocals) break;
        Slots[SlotIndex] = ValueType;
        if (IsCategoryTwo(ValueType)) {
            SlotIndex += 2;
        } else SlotIndex += 1;
    }
    return Slots;
}

pub fn Simulate(
    AllocatorHandle: std.mem.Allocator,
    Pool: *ConstantPoolBuilder.ConstantPool,
    Instructions: []const BytecodeInstructionModel.Instruction,
    Frames: []const StackMapTableCodec.Frame,
    InitialSlots: []const VType,
    ThisClass: u16,
) ![]State {
    var FrameByLabel = std.AutoHashMap(u32, usize).init(AllocatorHandle);
    defer FrameByLabel.deinit();
    for (Frames, 0..) |Frame, Index| try FrameByLabel.put(Frame.Label, Index);

    const MaxLocals = InitialSlots.len;
    var Simulation = Simulator{
        .Allocator = AllocatorHandle,
        .ConstantPool = Pool,
        .Locals = try AllocatorHandle.dupe(VType, InitialSlots),
        .Stack = .empty,
    };

    const States = try AllocatorHandle.alloc(State, Instructions.len);
    for (Instructions, 0..) |Instruction, Index| {
        if (FrameByLabel.get(Instruction.Identifier)) |FrameIndex| {
            Simulation.Locals = try FrameToSlots(AllocatorHandle, Frames[FrameIndex], MaxLocals);
            Simulation.Stack = .empty;
            try Simulation.Stack.appendSlice(AllocatorHandle, Frames[FrameIndex].Stack);
        }
        States[Index] = .{
            .Locals = try AllocatorHandle.dupe(VType, Simulation.Locals),
            .Stack = try AllocatorHandle.dupe(VType, Simulation.Stack.items),
        };
        try Apply(&Simulation, Instruction, ThisClass);
    }
    return States;
}
