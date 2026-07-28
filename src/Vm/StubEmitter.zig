const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const MaxStackLocalsComputer = @import("../Classfile/MaxStackLocalsComputer.zig");

fn PushInteger(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, Instructions: *std.ArrayList(BytecodeInstructionModel.Instruction), NextInstructionIdentifier: *u32, Value: i32) !void {
    if (Value >= -1 and Value <= 5) {
        try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, @intCast(0x03 + Value), &.{});
    } else if (Value >= -128 and Value <= 127) {
        try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x10, try MakeOneByteOperand(AllocatorHandle, @bitCast(@as(i8, @intCast(Value)))));
    } else if (Value >= -32768 and Value <= 32767) {
        const Operand = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(i16, Operand[0..2], @intCast(Value), .big);
        try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x11, Operand);
    } else {
        try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x13, try MakeTwoByteOperand(AllocatorHandle, try Pool.AddInteger(Value)));
    }
}

fn Emit(AllocatorHandle: std.mem.Allocator, Instructions: *std.ArrayList(BytecodeInstructionModel.Instruction), NextInstructionIdentifier: *u32, Opcode: u8, RawOperand: []u8) !void {
    try Instructions.append(AllocatorHandle, .{ .Identifier = NextInstructionIdentifier.*, .Operation = Opcode, .Kind = .Fixed, .Raw = RawOperand });
    NextInstructionIdentifier.* += 1;
}
fn MakeOneByteOperand(AllocatorHandle: std.mem.Allocator, Value: u8) ![]u8 {
    const Operand = try AllocatorHandle.alloc(u8, 1);
    Operand[0] = Value;
    return Operand;
}
fn MakeTwoByteOperand(AllocatorHandle: std.mem.Allocator, Value: u16) ![]u8 {
    const Operand = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, Operand[0..2], Value, .big);
    return Operand;
}

fn FieldTypeLength(Descriptor: []const u8, Index: usize) usize {
    return switch (Descriptor[Index]) {
        'L' => Block: {
            var Cursor = Index + 1;
            while (Cursor < Descriptor.len and Descriptor[Cursor] != ';') : (Cursor += 1) {}
            break :Block Cursor - Index + 1;
        },
        '[' => Block: {
            var Cursor = Index;
            while (Cursor < Descriptor.len and Descriptor[Cursor] == '[') : (Cursor += 1) {}
            break :Block Cursor - Index + FieldTypeLength(Descriptor, Cursor);
        },
        else => 1,
    };
}

fn SlotWidth(TypeChar: u8) u16 {
    return if (TypeChar == 'J' or TypeChar == 'D') 2 else 1;
}

fn EmitEncodedInteger(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, Instructions: *std.ArrayList(BytecodeInstructionModel.Instruction), NextInstructionIdentifier: *u32, Value: i32, Mask: i32) !void {
    const Selector: u2 = @truncate(@as(u32, @bitCast(Mask)) >> 29);
    switch (Selector) {
        0 => {
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask);
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask ^ Value);
            try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x82, &.{});
        },
        1 => {
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask);
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Value -% Mask);
            try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x60, &.{});
        },
        2 => {
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Value +% Mask);
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask);
            try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x64, &.{});
        },
        3 => {
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask ^ Value);
            try PushInteger(AllocatorHandle, Pool, Instructions, NextInstructionIdentifier, Mask);
            try Emit(AllocatorHandle, Instructions, NextInstructionIdentifier, 0x82, &.{});
        },
    }
}

pub fn EmitStub(
    AllocatorHandle: std.mem.Allocator,
    Pool: *ConstantPoolBuilder.ConstantPool,
    CodeAttributeNameIndex: u16,
    MethodIdentifier: u32,
    DispatchMethodReference: u16,
    Descriptor: []const u8,
    IsStatic: bool,
    Mask: i32,
) !ClassFileModel.Attribute {
    var Instructions: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty;
    var NextInstructionIdentifier: u32 = 0;

    const ObjectClassIndex = try Pool.AddClass("java/lang/Object");
    const IntegerClassIndex = try Pool.AddClass("java/lang/Integer");
    const IntegerValueOf = try Pool.AddMethodref("java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;");
    const IntegerIntValue = try Pool.AddMethodref("java/lang/Integer", "intValue", "()I");
    const LongClassIndex = try Pool.AddClass("java/lang/Long");
    const LongValueOf = try Pool.AddMethodref("java/lang/Long", "valueOf", "(J)Ljava/lang/Long;");
    const LongLongValue = try Pool.AddMethodref("java/lang/Long", "longValue", "()J");
    const FloatClassIndex = try Pool.AddClass("java/lang/Float");
    const FloatValueOf = try Pool.AddMethodref("java/lang/Float", "valueOf", "(F)Ljava/lang/Float;");
    const FloatFloatValue = try Pool.AddMethodref("java/lang/Float", "floatValue", "()F");
    const DoubleClassIndex = try Pool.AddClass("java/lang/Double");
    const DoubleValueOf = try Pool.AddMethodref("java/lang/Double", "valueOf", "(D)Ljava/lang/Double;");
    const DoubleDoubleValue = try Pool.AddMethodref("java/lang/Double", "doubleValue", "()D");

    var TotalSlots: u16 = 0;
    {
        var Index: usize = 1;
        while (Index < Descriptor.len and Descriptor[Index] != ')') {
            TotalSlots += SlotWidth(Descriptor[Index]);
            Index += FieldTypeLength(Descriptor, Index);
        }
    }

    const ReceiverSlots: u16 = if (IsStatic) 0 else 1;
    try EmitEncodedInteger(AllocatorHandle, Pool, &Instructions, &NextInstructionIdentifier, @intCast(MethodIdentifier), Mask);
    try PushInteger(AllocatorHandle, Pool, &Instructions, &NextInstructionIdentifier, @intCast(TotalSlots + ReceiverSlots));
    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xbd, try MakeTwoByteOperand(AllocatorHandle, ObjectClassIndex));

    if (!IsStatic) {
        try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x59, &.{});
        try PushInteger(AllocatorHandle, Pool, &Instructions, &NextInstructionIdentifier, 0);
        try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x2a, &.{});
        try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x53, &.{});
    }

    {
        var Index: usize = 1;
        var Slot: u16 = ReceiverSlots;
        while (Index < Descriptor.len and Descriptor[Index] != ')') {
            const TypeChar = Descriptor[Index];
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x59, &.{});
            try PushInteger(AllocatorHandle, Pool, &Instructions, &NextInstructionIdentifier, @intCast(Slot));
            switch (TypeChar) {
                'J' => {
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x16, try MakeOneByteOperand(AllocatorHandle, @intCast(Slot)));
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb8, try MakeTwoByteOperand(AllocatorHandle, LongValueOf));
                },
                'F' => {
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x17, try MakeOneByteOperand(AllocatorHandle, @intCast(Slot)));
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb8, try MakeTwoByteOperand(AllocatorHandle, FloatValueOf));
                },
                'D' => {
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x18, try MakeOneByteOperand(AllocatorHandle, @intCast(Slot)));
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb8, try MakeTwoByteOperand(AllocatorHandle, DoubleValueOf));
                },
                'L', '[' => {
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x19, try MakeOneByteOperand(AllocatorHandle, @intCast(Slot)));
                },
                else => {
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x15, try MakeOneByteOperand(AllocatorHandle, @intCast(Slot)));
                    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb8, try MakeTwoByteOperand(AllocatorHandle, IntegerValueOf));
                },
            }
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x53, &.{});
            Slot += SlotWidth(TypeChar);
            Index += FieldTypeLength(Descriptor, Index);
        }
    }

    try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb8, try MakeTwoByteOperand(AllocatorHandle, DispatchMethodReference));

    var ReturnIndex: usize = 0;
    {
        var Index: usize = 0;
        while (Index < Descriptor.len) : (Index += 1) {
            if (Descriptor[Index] == ')') {
                ReturnIndex = Index + 1;
                break;
            }
        }
    }
    switch (Descriptor[ReturnIndex]) {
        'V' => {
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0x57, &.{});
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb1, &.{});
        },
        'J' => {
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xc0, try MakeTwoByteOperand(AllocatorHandle, LongClassIndex));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb6, try MakeTwoByteOperand(AllocatorHandle, LongLongValue));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xad, &.{});
        },
        'F' => {
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xc0, try MakeTwoByteOperand(AllocatorHandle, FloatClassIndex));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb6, try MakeTwoByteOperand(AllocatorHandle, FloatFloatValue));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xae, &.{});
        },
        'D' => {
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xc0, try MakeTwoByteOperand(AllocatorHandle, DoubleClassIndex));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb6, try MakeTwoByteOperand(AllocatorHandle, DoubleDoubleValue));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xaf, &.{});
        },
        'L', '[' => {
            const ReturnClassName = if (Descriptor[ReturnIndex] == 'L')
                Descriptor[ReturnIndex + 1 .. Descriptor.len - 1]
            else
                Descriptor[ReturnIndex..Descriptor.len];
            const ReturnClassIndex = try Pool.AddClass(ReturnClassName);
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xc0, try MakeTwoByteOperand(AllocatorHandle, ReturnClassIndex));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb0, &.{});
        },
        else => {
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xc0, try MakeTwoByteOperand(AllocatorHandle, IntegerClassIndex));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xb6, try MakeTwoByteOperand(AllocatorHandle, IntegerIntValue));
            try Emit(AllocatorHandle, &Instructions, &NextInstructionIdentifier, 0xac, &.{});
        },
    }

    var CodeAttribute = BytecodeInstructionModel.CodeAttribute{ .MaxStack = 0, .MaxLocals = 0, .Instructions = Instructions, .Exceptions = .empty, .Attributes = .empty, .NextIdentifier = NextInstructionIdentifier };
    const Maxima = try MaxStackLocalsComputer.Compute(AllocatorHandle, Pool, &CodeAttribute, Descriptor, IsStatic);
    CodeAttribute.MaxStack = Maxima.MaxStack;
    CodeAttribute.MaxLocals = Maxima.MaxLocals;
    return .{ .NameIndex = CodeAttributeNameIndex, .Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &CodeAttribute) };
}
