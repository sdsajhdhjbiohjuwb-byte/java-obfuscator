const std = @import("std");
const BytecodeInstructionModel = @import("BytecodeInstructionModel.zig");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");

pub const Maximums = struct { MaxStack: u16, MaxLocals: u16 };

pub fn Compute(
    AllocatorHandle: std.mem.Allocator,
    Pool: *const ConstantPoolBuilder.ConstantPool,
    Code: *const BytecodeInstructionModel.CodeAttribute,
    Descriptor: []const u8,
    IsStatic: bool,
) !Maximums {
    const Instructions = Code.Instructions.items;
    const InstructionCount = Instructions.len;

    var LocalCount: u32 = ParameterLocals(Descriptor, IsStatic);
    for (Instructions) |Instruction| {
        const Extent = LocalExtent(Instruction);
        if (Extent > LocalCount) LocalCount = Extent;
    }

    if (InstructionCount == 0) return .{ .MaxStack = 0, .MaxLocals = @intCast(@min(LocalCount, 65535)) };

    var IdentifierIndexMap = std.AutoHashMap(u32, usize).init(AllocatorHandle);
    defer IdentifierIndexMap.deinit();
    for (Instructions, 0..) |Instruction, Index| try IdentifierIndexMap.put(Instruction.Identifier, Index);

    const Heights = try AllocatorHandle.alloc(i32, InstructionCount);
    @memset(Heights, -1);
    var WorkStack: std.ArrayList(usize) = .empty;

    Heights[0] = 0;
    try WorkStack.append(AllocatorHandle, 0);
    for (Code.Exceptions.items) |ExceptionEntry| {
        if (IdentifierIndexMap.get(ExceptionEntry.Handler)) |HandlerIndex| {
            if (Heights[HandlerIndex] == -1) {
                Heights[HandlerIndex] = 1;
                try WorkStack.append(AllocatorHandle, HandlerIndex);
            }
        }
    }

    while (WorkStack.items.len > 0) {
        const InstructionIndex = WorkStack.items[WorkStack.items.len - 1];
        WorkStack.items.len -= 1;
        const Instruction = Instructions[InstructionIndex];
        const HeightOut = Heights[InstructionIndex] + Delta(Pool, Instruction);

        switch (Instruction.Kind) {
            .Fixed => {
                if (!NoFallThrough(Instruction.Operation) and InstructionIndex + 1 < InstructionCount) {
                    try AddSuccessor(AllocatorHandle, Heights, &WorkStack, InstructionIndex + 1, HeightOut);
                }
            },
            .Branch, .BranchWide => {
                try AddSuccessorByIdentifier(AllocatorHandle, Heights, &WorkStack, &IdentifierIndexMap, Instruction.Target, HeightOut);
                if (Instruction.Operation != 0xA7 and Instruction.Operation != 0xC8 and InstructionIndex + 1 < InstructionCount) {
                    try AddSuccessor(AllocatorHandle, Heights, &WorkStack, InstructionIndex + 1, HeightOut);
                }
            },
            .TableSwitch => {
                try AddSuccessorByIdentifier(AllocatorHandle, Heights, &WorkStack, &IdentifierIndexMap, Instruction.SwitchDefault, HeightOut);
                for (Instruction.SwitchTargets) |TargetIdentifier| try AddSuccessorByIdentifier(AllocatorHandle, Heights, &WorkStack, &IdentifierIndexMap, TargetIdentifier, HeightOut);
            },
            .LookupSwitch => {
                try AddSuccessorByIdentifier(AllocatorHandle, Heights, &WorkStack, &IdentifierIndexMap, Instruction.SwitchDefault, HeightOut);
                for (Instruction.SwitchPairs) |Pair| try AddSuccessorByIdentifier(AllocatorHandle, Heights, &WorkStack, &IdentifierIndexMap, Pair.Target, HeightOut);
            },
        }
    }

    var Peak: i32 = 0;
    for (Instructions, 0..) |Instruction, InstructionIndex| {
        if (Heights[InstructionIndex] < 0) continue;
        const Before = Heights[InstructionIndex];
        const After = Before + Delta(Pool, Instruction);
        const Maximum = @max(Before, After);
        if (Maximum > Peak) Peak = Maximum;
    }

    return .{
        .MaxStack = @intCast(@max(@as(i32, 0), Peak)),
        .MaxLocals = @intCast(@min(LocalCount, 65535)),
    };
}

fn AddSuccessor(AllocatorHandle: std.mem.Allocator, Heights: []i32, WorkStack: *std.ArrayList(usize), SuccessorIndex: usize, Height: i32) !void {
    if (Heights[SuccessorIndex] == -1) {
        Heights[SuccessorIndex] = Height;
        try WorkStack.append(AllocatorHandle, SuccessorIndex);
    }
}

fn AddSuccessorByIdentifier(AllocatorHandle: std.mem.Allocator, Heights: []i32, WorkStack: *std.ArrayList(usize), IdentifierIndexMap: *std.AutoHashMap(u32, usize), TargetIdentifier: u32, Height: i32) !void {
    if (IdentifierIndexMap.get(TargetIdentifier)) |SuccessorIndex| try AddSuccessor(AllocatorHandle, Heights, WorkStack, SuccessorIndex, Height);
}

fn NoFallThrough(Opcode: u8) bool {
    return switch (Opcode) {
        0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1 => true,
        0xBF => true,
        0xA9 => true,
        else => false,
    };
}

fn Delta(Pool: *const ConstantPoolBuilder.ConstantPool, Instruction: BytecodeInstructionModel.Instruction) i32 {
    return switch (Instruction.Operation) {
        0x12, 0x13 => 1,
        0x14 => 2,
        0xb2 => @intCast(FieldSlots(Pool, Instruction.Raw)),
        0xb3 => -@as(i32, @intCast(FieldSlots(Pool, Instruction.Raw))),
        0xb4 => @as(i32, @intCast(FieldSlots(Pool, Instruction.Raw))) - 1,
        0xb5 => -1 - @as(i32, @intCast(FieldSlots(Pool, Instruction.Raw))),
        0xb6, 0xb7, 0xb9 => Block: {
            const Descriptor = MethodDescriptor(Pool, Instruction.Raw);
            break :Block @as(i32, @intCast(ReturnSlots(Descriptor))) - @as(i32, @intCast(ParameterSlots(Descriptor))) - 1;
        },
        0xb8, 0xba => Block: {
            const Descriptor = MethodDescriptor(Pool, Instruction.Raw);
            break :Block @as(i32, @intCast(ReturnSlots(Descriptor))) - @as(i32, @intCast(ParameterSlots(Descriptor)));
        },
        0xc5 => 1 - @as(i32, Instruction.Raw[2]),
        0xc4 => StaticDelta(Instruction.Raw[0]),
        else => StaticDelta(Instruction.Operation),
    };
}

fn MethodDescriptor(Pool: *const ConstantPoolBuilder.ConstantPool, Raw: []const u8) []const u8 {
    const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Raw, 0);
    const NameAndTypeIndex = Pool.RefNameAndTypeIndex(ReferenceIndex);
    return Pool.Utf8Text(Pool.NameAndTypeDesc(NameAndTypeIndex));
}

fn FieldSlots(Pool: *const ConstantPoolBuilder.ConstantPool, Raw: []const u8) usize {
    const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Raw, 0);
    const NameAndTypeIndex = Pool.RefNameAndTypeIndex(ReferenceIndex);
    return TypeSlots(Pool.Utf8Text(Pool.NameAndTypeDesc(NameAndTypeIndex)));
}

fn StaticDelta(Opcode: u8) i32 {
    return switch (Opcode) {
        0x00 => 0,
        0x01 => 1,
        0x02...0x08 => 1,
        0x09, 0x0a => 2,
        0x0b...0x0d => 1,
        0x0e, 0x0f => 2,
        0x10, 0x11 => 1,
        0x15 => 1,
        0x16 => 2,
        0x17 => 1,
        0x18 => 2,
        0x19 => 1,
        0x1a...0x1d => 1,
        0x1e...0x21 => 2,
        0x22...0x25 => 1,
        0x26...0x29 => 2,
        0x2a...0x2d => 1,
        0x2e => -1,
        0x2f => 0,
        0x30 => -1,
        0x31 => 0,
        0x32 => -1,
        0x33...0x35 => -1,
        0x36 => -1,
        0x37 => -2,
        0x38 => -1,
        0x39 => -2,
        0x3a => -1,
        0x3b...0x3e => -1,
        0x3f...0x42 => -2,
        0x43...0x46 => -1,
        0x47...0x4a => -2,
        0x4b...0x4e => -1,
        0x4f => -3,
        0x50 => -4,
        0x51 => -3,
        0x52 => -4,
        0x53...0x56 => -3,
        0x57 => -1,
        0x58 => -2,
        0x59 => 1,
        0x5a => 1,
        0x5b => 1,
        0x5c => 2,
        0x5d => 2,
        0x5e => 2,
        0x5f => 0,
        0x60 => -1,
        0x61 => -2,
        0x62 => -1,
        0x63 => -2,
        0x64 => -1,
        0x65 => -2,
        0x66 => -1,
        0x67 => -2,
        0x68 => -1,
        0x69 => -2,
        0x6a => -1,
        0x6b => -2,
        0x6c => -1,
        0x6d => -2,
        0x6e => -1,
        0x6f => -2,
        0x70 => -1,
        0x71 => -2,
        0x72 => -1,
        0x73 => -2,
        0x74...0x77 => 0,
        0x78...0x7d => -1,
        0x7e => -1,
        0x7f => -2,
        0x80 => -1,
        0x81 => -2,
        0x82 => -1,
        0x83 => -2,
        0x84 => 0,
        0x85 => 1,
        0x86 => 0,
        0x87 => 1,
        0x88 => -1,
        0x89 => -1,
        0x8a => 0,
        0x8b => 0,
        0x8c => 1,
        0x8d => 1,
        0x8e => -1,
        0x8f => 0,
        0x90 => -1,
        0x91...0x93 => 0,
        0x94 => -3,
        0x95, 0x96 => -1,
        0x97, 0x98 => -3,
        0x99...0x9e => -1,
        0x9f...0xa4 => -2,
        0xa5, 0xa6 => -2,
        0xa7 => 0,
        0xa8 => 1,
        0xa9 => 0,
        0xaa, 0xab => -1,
        0xac => -1,
        0xad => -2,
        0xae => -1,
        0xaf => -2,
        0xb0 => -1,
        0xb1 => 0,
        0xbb => 1,
        0xbc => 0,
        0xbd => 0,
        0xbe => 0,
        0xbf => -1,
        0xc0 => 0,
        0xc1 => 0,
        0xc2 => -1,
        0xc3 => -1,
        0xc6, 0xc7 => -1,
        0xc8 => 0,
        0xc9 => 1,
        else => 0,
    };
}

fn LocalExtent(Instruction: BytecodeInstructionModel.Instruction) u32 {
    const Opcode = Instruction.Operation;
    return switch (Opcode) {
        0x15, 0x17, 0x19 => @as(u32, Instruction.Raw[0]) + 1,
        0x16, 0x18 => @as(u32, Instruction.Raw[0]) + 2,
        0x36, 0x38, 0x3a => @as(u32, Instruction.Raw[0]) + 1,
        0x37, 0x39 => @as(u32, Instruction.Raw[0]) + 2,
        0x1a...0x1d => @as(u32, Opcode - 0x1a) + 1,
        0x1e...0x21 => @as(u32, Opcode - 0x1e) + 2,
        0x22...0x25 => @as(u32, Opcode - 0x22) + 1,
        0x26...0x29 => @as(u32, Opcode - 0x26) + 2,
        0x2a...0x2d => @as(u32, Opcode - 0x2a) + 1,
        0x3b...0x3e => @as(u32, Opcode - 0x3b) + 1,
        0x3f...0x42 => @as(u32, Opcode - 0x3f) + 2,
        0x43...0x46 => @as(u32, Opcode - 0x43) + 1,
        0x47...0x4a => @as(u32, Opcode - 0x47) + 2,
        0x4b...0x4e => @as(u32, Opcode - 0x4b) + 1,
        0x84 => @as(u32, Instruction.Raw[0]) + 1,
        0xa9 => @as(u32, Instruction.Raw[0]) + 1,
        0xc4 => Block: {
            const WideOpcode = Instruction.Raw[0];
            const WideIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 1);
            const Width: u32 = switch (WideOpcode) {
                0x16, 0x18, 0x37, 0x39 => 2,
                else => 1,
            };
            break :Block @as(u32, WideIndex) + Width;
        },
        else => 0,
    };
}

fn ParameterLocals(Descriptor: []const u8, IsStatic: bool) u32 {
    return ParameterSlots(Descriptor) + @as(u32, if (IsStatic) 0 else 1);
}

fn ParameterSlots(Descriptor: []const u8) u32 {
    var Index: usize = 0;
    while (Index < Descriptor.len and Descriptor[Index] != '(') Index += 1;
    if (Index >= Descriptor.len) return 0;
    Index += 1;
    var Slots: u32 = 0;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        Slots += OneTypeSlots(Descriptor, &Index);
    }
    return Slots;
}

fn ReturnSlots(Descriptor: []const u8) u32 {
    var Index: usize = 0;
    while (Index < Descriptor.len and Descriptor[Index] != ')') Index += 1;
    if (Index >= Descriptor.len) return 0;
    Index += 1;
    if (Index >= Descriptor.len or Descriptor[Index] == 'V') return 0;
    return OneTypeSlots(Descriptor, &Index);
}

fn TypeSlots(Descriptor: []const u8) usize {
    var Index: usize = 0;
    return OneTypeSlots(Descriptor, &Index);
}

fn OneTypeSlots(Descriptor: []const u8, Index: *usize) u32 {
    var IsArray = false;
    while (Index.* < Descriptor.len and Descriptor[Index.*] == '[') {
        IsArray = true;
        Index.* += 1;
    }
    if (Index.* >= Descriptor.len) return 1;
    const TypeChar = Descriptor[Index.*];
    switch (TypeChar) {
        'L' => {
            while (Index.* < Descriptor.len and Descriptor[Index.*] != ';') Index.* += 1;
            if (Index.* < Descriptor.len) Index.* += 1;
            return 1;
        },
        'J', 'D' => {
            Index.* += 1;
            return if (IsArray) 1 else 2;
        },
        else => {
            Index.* += 1;
            return 1;
        },
    }
}

test "descriptor slot parsing" {
    try std.testing.expectEqual(@as(u32, 0), ParameterSlots("()V"));
    try std.testing.expectEqual(@as(u32, 1), ParameterSlots("(I)V"));
    try std.testing.expectEqual(@as(u32, 2), ParameterSlots("(J)V"));
    try std.testing.expectEqual(@as(u32, 1), ParameterSlots("([J)V"));
    try std.testing.expectEqual(@as(u32, 3), ParameterSlots("(ILjava/lang/String;I)V"));
    try std.testing.expectEqual(@as(u32, 4), ParameterSlots("(JD)V"));
    try std.testing.expectEqual(@as(u32, 0), ReturnSlots("()V"));
    try std.testing.expectEqual(@as(u32, 1), ReturnSlots("()Ljava/lang/Object;"));
    try std.testing.expectEqual(@as(u32, 2), ReturnSlots("()D"));
    try std.testing.expectEqual(@as(u32, 1), ReturnSlots("()[D"));
}

test "static deltas sample" {
    try std.testing.expectEqual(@as(i32, 1), StaticDelta(0x59));
    try std.testing.expectEqual(@as(i32, -2), StaticDelta(0xa4));
    try std.testing.expectEqual(@as(i32, -3), StaticDelta(0x94));
    try std.testing.expectEqual(@as(i32, -1), StaticDelta(0xbf));
    try std.testing.expectEqual(@as(i32, 1), StaticDelta(0xbb));
}
