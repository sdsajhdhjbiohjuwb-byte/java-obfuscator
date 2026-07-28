const std = @import("std");
const ClassFileModel = @import("ClassFileModel.zig");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");

const ReadUnsignedShort = ConstantPoolBuilder.ReadUnsignedShort;
const ReadUnsignedInt = ConstantPoolBuilder.ReadUnsignedInt;
const WriteUnsignedShort = ConstantPoolBuilder.WriteUnsignedShort;
const WriteUnsignedInt = ConstantPoolBuilder.WriteUnsignedInt;

pub const EndLabel: u32 = 0xFFFFFFFF;

pub const Kind = enum { Fixed, Branch, BranchWide, TableSwitch, LookupSwitch };

pub const Pair = struct { Key: i32, Target: u32 };

pub const Instruction = struct {
    Identifier: u32,
    Operation: u8,
    Kind: Kind,
    Raw: []u8 = &.{},
    Target: u32 = 0,
    SwitchDefault: u32 = 0,
    SwitchLow: i32 = 0,
    SwitchHigh: i32 = 0,
    SwitchTargets: []u32 = &.{},
    SwitchPairs: []Pair = &.{},
    Offset: u32 = 0,
};

pub const ExceptionEntry = struct {
    Start: u32,
    End: u32,
    Handler: u32,
    CatchType: u16,
};

pub const CodeAttribute = struct {
    MaxStack: u16,
    MaxLocals: u16,
    Instructions: std.ArrayList(Instruction),
    Exceptions: std.ArrayList(ExceptionEntry),
    Attributes: std.ArrayList(ClassFileModel.Attribute),
    NextIdentifier: u32,

    pub fn NewIdentifier(Self: *CodeAttribute) u32 {
        const Value = Self.NextIdentifier;
        Self.NextIdentifier += 1;
        return Value;
    }
};

pub fn MakeFixedInstruction(Code: *CodeAttribute, Opcode: u8, RawOperand: []u8) Instruction {
    return .{ .Identifier = Code.NewIdentifier(), .Operation = Opcode, .Kind = .Fixed, .Raw = RawOperand };
}

pub fn PushInteger(AllocatorHandle: std.mem.Allocator, Instructions: *std.ArrayList(Instruction), Code: *CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, Value: i32) !void {
    if (Value >= -1 and Value <= 5) {
        try Instructions.append(AllocatorHandle, MakeFixedInstruction(Code, @intCast(0x03 + Value), &.{}));
    } else if (Value >= -128 and Value <= 127) {
        const RawOperand = try AllocatorHandle.alloc(u8, 1);
        RawOperand[0] = @bitCast(@as(i8, @intCast(Value)));
        try Instructions.append(AllocatorHandle, MakeFixedInstruction(Code, 0x10, RawOperand));
    } else if (Value >= -32768 and Value <= 32767) {
        const RawOperand = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(i16, RawOperand[0..2], @intCast(Value), .big);
        try Instructions.append(AllocatorHandle, MakeFixedInstruction(Code, 0x11, RawOperand));
    } else {
        const IntegerIndex = try Pool.AddInteger(Value);
        const RawOperand = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(u16, RawOperand[0..2], IntegerIndex, .big);
        try Instructions.append(AllocatorHandle, MakeFixedInstruction(Code, 0x13, RawOperand));
    }
}

pub fn Classify(Opcode: u8) Kind {
    return switch (Opcode) {
        0x99...0xa8, 0xc6, 0xc7 => .Branch,
        0xc8, 0xc9 => .BranchWide,
        0xaa => .TableSwitch,
        0xab => .LookupSwitch,
        else => .Fixed,
    };
}

fn FixedOperandLength(Opcode: u8, ByteBuffer: []const u8, Position: usize) usize {
    return switch (Opcode) {
        0x10, 0x12, 0x15, 0x16, 0x17, 0x18, 0x19, 0x36, 0x37, 0x38, 0x39, 0x3a, 0xa9, 0xbc => 1,
        0x11, 0x13, 0x14, 0x84, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xbb, 0xbd, 0xc0, 0xc1 => 2,
        0xc5 => 3,
        0xb9, 0xba => 4,
        0xc4 => if (ByteBuffer[Position + 1] == 0x84) @as(usize, 5) else @as(usize, 3),
        else => 0,
    };
}

const DecodeResult = struct {
    Instructions: std.ArrayList(Instruction),
    OffsetToIdentifier: std.AutoHashMap(u32, u32),
    NextIdentifier: u32,
};

fn Decode(AllocatorHandle: std.mem.Allocator, CodeBytes: []const u8) !DecodeResult {
    var Instructions: std.ArrayList(Instruction) = .empty;
    var OffsetToIdentifier = std.AutoHashMap(u32, u32).init(AllocatorHandle);
    var InstructionIdentifier: u32 = 0;
    var Position: usize = 0;
    while (Position < CodeBytes.len) {
        const Opcode = CodeBytes[Position];
        const BaseOffset: u32 = @intCast(Position);
        try OffsetToIdentifier.put(BaseOffset, InstructionIdentifier);
        const InstructionKind = Classify(Opcode);
        switch (InstructionKind) {
            .Fixed => {
                const OperandLength = FixedOperandLength(Opcode, CodeBytes, Position);
                const RawOperands = try AllocatorHandle.dupe(u8, CodeBytes[Position + 1 .. Position + 1 + OperandLength]);
                try Instructions.append(AllocatorHandle, .{ .Identifier = InstructionIdentifier, .Operation = Opcode, .Kind = .Fixed, .Raw = RawOperands, .Offset = BaseOffset });
                Position += 1 + OperandLength;
            },
            .Branch => {
                const RelativeOffset: i16 = @bitCast(ReadUnsignedShort(CodeBytes, Position + 1));
                const TargetOffset: u32 = @intCast(@as(i64, BaseOffset) + RelativeOffset);
                try Instructions.append(AllocatorHandle, .{ .Identifier = InstructionIdentifier, .Operation = Opcode, .Kind = .Branch, .Target = TargetOffset, .Offset = BaseOffset });
                Position += 3;
            },
            .BranchWide => {
                const RelativeOffset: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Position + 1));
                const TargetOffset: u32 = @intCast(@as(i64, BaseOffset) + RelativeOffset);
                try Instructions.append(AllocatorHandle, .{ .Identifier = InstructionIdentifier, .Operation = Opcode, .Kind = .BranchWide, .Target = TargetOffset, .Offset = BaseOffset });
                Position += 5;
            },
            .TableSwitch => {
                var Cursor = Position + 1;
                Cursor += (4 - (Cursor % 4)) % 4;
                const DefaultOffset: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor));
                const LowValue: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor + 4));
                const HighValue: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor + 8));
                Cursor += 12;
                const Count: usize = @intCast(HighValue - LowValue + 1);
                const Targets = try AllocatorHandle.alloc(u32, Count);
                var InnerIndex: usize = 0;
                while (InnerIndex < Count) : (InnerIndex += 1) {
                    const BranchOffset: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor));
                    Targets[InnerIndex] = @intCast(@as(i64, BaseOffset) + BranchOffset);
                    Cursor += 4;
                }
                try Instructions.append(AllocatorHandle, .{ .Identifier = InstructionIdentifier, .Operation = Opcode, .Kind = .TableSwitch, .SwitchDefault = @intCast(@as(i64, BaseOffset) + DefaultOffset), .SwitchLow = LowValue, .SwitchHigh = HighValue, .SwitchTargets = Targets, .Offset = BaseOffset });
                Position = Cursor;
            },
            .LookupSwitch => {
                var Cursor = Position + 1;
                Cursor += (4 - (Cursor % 4)) % 4;
                const DefaultOffset: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor));
                const PairCount: usize = @intCast(ReadUnsignedInt(CodeBytes, Cursor + 4));
                Cursor += 8;
                const Pairs = try AllocatorHandle.alloc(Pair, PairCount);
                var InnerIndex: usize = 0;
                while (InnerIndex < PairCount) : (InnerIndex += 1) {
                    const KeyValue: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor));
                    const BranchOffset: i32 = @bitCast(ReadUnsignedInt(CodeBytes, Cursor + 4));
                    Pairs[InnerIndex] = .{ .Key = KeyValue, .Target = @intCast(@as(i64, BaseOffset) + BranchOffset) };
                    Cursor += 8;
                }
                try Instructions.append(AllocatorHandle, .{ .Identifier = InstructionIdentifier, .Operation = Opcode, .Kind = .LookupSwitch, .SwitchDefault = @intCast(@as(i64, BaseOffset) + DefaultOffset), .SwitchPairs = Pairs, .Offset = BaseOffset });
                Position = Cursor;
            },
        }
        InstructionIdentifier += 1;
    }
    return .{ .Instructions = Instructions, .OffsetToIdentifier = OffsetToIdentifier, .NextIdentifier = InstructionIdentifier };
}

fn MapByteToIdentifier(OffsetToIdentifierMap: *std.AutoHashMap(u32, u32), ByteOffset: u32, CodeLength: u32) u32 {
    if (ByteOffset == CodeLength) return EndLabel;
    return OffsetToIdentifierMap.get(ByteOffset).?;
}

fn ResolveTargets(Instructions: []Instruction, OffsetToIdentifierMap: *std.AutoHashMap(u32, u32), CodeLength: u32) void {
    for (Instructions) |*InstructionItem| {
        switch (InstructionItem.Kind) {
            .Branch, .BranchWide => InstructionItem.Target = MapByteToIdentifier(OffsetToIdentifierMap, InstructionItem.Target, CodeLength),
            .TableSwitch => {
                InstructionItem.SwitchDefault = MapByteToIdentifier(OffsetToIdentifierMap, InstructionItem.SwitchDefault, CodeLength);
                for (InstructionItem.SwitchTargets) |*TargetPointer| TargetPointer.* = MapByteToIdentifier(OffsetToIdentifierMap, TargetPointer.*, CodeLength);
            },
            .LookupSwitch => {
                InstructionItem.SwitchDefault = MapByteToIdentifier(OffsetToIdentifierMap, InstructionItem.SwitchDefault, CodeLength);
                for (InstructionItem.SwitchPairs) |*PairPointer| PairPointer.Target = MapByteToIdentifier(OffsetToIdentifierMap, PairPointer.Target, CodeLength);
            },
            .Fixed => {},
        }
    }
}

pub fn ParseCode(AllocatorHandle: std.mem.Allocator, InfoBytes: []const u8) !CodeAttribute {
    const MaxStackValue = ReadUnsignedShort(InfoBytes, 0);
    const MaxLocalsValue = ReadUnsignedShort(InfoBytes, 2);
    const CodeLength = ReadUnsignedInt(InfoBytes, 4);
    const CodeBytes = InfoBytes[8 .. 8 + CodeLength];
    var DecodedResult = try Decode(AllocatorHandle, CodeBytes);
    ResolveTargets(DecodedResult.Instructions.items, &DecodedResult.OffsetToIdentifier, CodeLength);

    var Offset: usize = 8 + CodeLength;
    const ExceptionCount = ReadUnsignedShort(InfoBytes, Offset);
    Offset += 2;
    var Exceptions: std.ArrayList(ExceptionEntry) = .empty;
    var Index: usize = 0;
    while (Index < ExceptionCount) : (Index += 1) {
        try Exceptions.append(AllocatorHandle, .{
            .Start = MapByteToIdentifier(&DecodedResult.OffsetToIdentifier, ReadUnsignedShort(InfoBytes, Offset), CodeLength),
            .End = MapByteToIdentifier(&DecodedResult.OffsetToIdentifier, ReadUnsignedShort(InfoBytes, Offset + 2), CodeLength),
            .Handler = MapByteToIdentifier(&DecodedResult.OffsetToIdentifier, ReadUnsignedShort(InfoBytes, Offset + 4), CodeLength),
            .CatchType = ReadUnsignedShort(InfoBytes, Offset + 6),
        });
        Offset += 8;
    }

    const Attributes = try ClassFileModel.ParseAttributes(AllocatorHandle, InfoBytes, &Offset);
    return .{
        .MaxStack = MaxStackValue,
        .MaxLocals = MaxLocalsValue,
        .Instructions = DecodedResult.Instructions,
        .Exceptions = Exceptions,
        .Attributes = Attributes,
        .NextIdentifier = DecodedResult.NextIdentifier,
    };
}

fn InstructionSize(InstructionItem: Instruction) u32 {
    return switch (InstructionItem.Kind) {
        .Fixed => 1 + @as(u32, @intCast(InstructionItem.Raw.len)),
        .Branch => 3,
        .BranchWide => 5,
        .TableSwitch => Block: {
            const Padding = (4 - ((InstructionItem.Offset + 1) % 4)) % 4;
            const EntryCount: u32 = @intCast(InstructionItem.SwitchHigh - InstructionItem.SwitchLow + 1);
            break :Block 1 + Padding + 12 + EntryCount * 4;
        },
        .LookupSwitch => Block: {
            const Padding = (4 - ((InstructionItem.Offset + 1) % 4)) % 4;
            const EntryCount: u32 = @intCast(InstructionItem.SwitchPairs.len);
            break :Block 1 + Padding + 8 + EntryCount * 8;
        },
    };
}

pub fn AssignOffsets(Instructions: []Instruction) u32 {
    var Iteration: usize = 0;
    while (Iteration < 16) : (Iteration += 1) {
        var Offset: u32 = 0;
        var Changed = false;
        for (Instructions) |*InstructionItem| {
            if (InstructionItem.Offset != Offset) {
                InstructionItem.Offset = Offset;
                Changed = true;
            }
            Offset += InstructionSize(InstructionItem.*);
        }
        if (!Changed) return Offset;
    }
    var TotalSize: u32 = 0;
    for (Instructions) |*InstructionItem| {
        InstructionItem.Offset = TotalSize;
        TotalSize += InstructionSize(InstructionItem.*);
    }
    return TotalSize;
}

fn InvertBranch(Opcode: u8) ?u8 {
    return switch (Opcode) {
        0x99 => 0x9a,
        0x9a => 0x99,
        0x9b => 0x9c,
        0x9c => 0x9b,
        0x9d => 0x9e,
        0x9e => 0x9d,
        0x9f => 0xa0,
        0xa0 => 0x9f,
        0xa1 => 0xa2,
        0xa2 => 0xa1,
        0xa3 => 0xa4,
        0xa4 => 0xa3,
        0xa5 => 0xa6,
        0xa6 => 0xa5,
        0xc6 => 0xc7,
        0xc7 => 0xc6,
        else => null,
    };
}

pub fn PrepareLayout(AllocatorHandle: std.mem.Allocator, InstructionList: *std.ArrayList(Instruction)) !void {
    var FreshIdentifier: u32 = 0;
    for (InstructionList.items) |InstructionItem| {
        if (InstructionItem.Identifier + 1 > FreshIdentifier) FreshIdentifier = InstructionItem.Identifier + 1;
    }
    const MaxIterations = InstructionList.items.len * 2 + 16;
    var Iteration: usize = 0;
    while (Iteration < MaxIterations) : (Iteration += 1) {
        _ = AssignOffsets(InstructionList.items);
        var IdentifierToOffset = try BuildIdentifierToOffset(AllocatorHandle, InstructionList.items);
        defer IdentifierToOffset.deinit();
        var TotalSize: u32 = 0;
        for (InstructionList.items) |InstructionItem| TotalSize += InstructionSize(InstructionItem);

        var Changed = false;
        for (InstructionList.items) |*InstructionItem| {
            if (InstructionItem.Kind == .Branch and (InstructionItem.Operation == 0xA7 or InstructionItem.Operation == 0xA8)) {
                const RelativeOffset: i64 = @as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.Target, TotalSize)) - @as(i64, InstructionItem.Offset);
                if (RelativeOffset < -32768 or RelativeOffset > 32767) {
                    InstructionItem.Operation = if (InstructionItem.Operation == 0xA7) @as(u8, 0xC8) else @as(u8, 0xC9);
                    InstructionItem.Kind = .BranchWide;
                    Changed = true;
                }
            }
        }
        if (Changed) continue;

        var WidenAtIndex: ?usize = null;
        for (InstructionList.items, 0..) |InstructionItem, Index| {
            if (InstructionItem.Kind != .Branch or InvertBranch(InstructionItem.Operation) == null) continue;
            const RelativeOffset: i64 = @as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.Target, TotalSize)) - @as(i64, InstructionItem.Offset);
            if (RelativeOffset < -32768 or RelativeOffset > 32767) {
                WidenAtIndex = Index;
                break;
            }
        }
        const WidenIndex = WidenAtIndex orelse break;

        const OriginalTarget = InstructionList.items[WidenIndex].Target;
        const SkipTarget: u32 = if (WidenIndex + 1 < InstructionList.items.len) InstructionList.items[WidenIndex + 1].Identifier else EndLabel;
        InstructionList.items[WidenIndex].Operation = InvertBranch(InstructionList.items[WidenIndex].Operation).?;
        InstructionList.items[WidenIndex].Target = SkipTarget;
        try InstructionList.insert(AllocatorHandle, WidenIndex + 1, .{ .Identifier = FreshIdentifier, .Operation = 0xC8, .Kind = .BranchWide, .Target = OriginalTarget });
        FreshIdentifier += 1;
    }
}

pub fn BuildIdentifierToOffset(AllocatorHandle: std.mem.Allocator, Instructions: []const Instruction) !std.AutoHashMap(u32, u32) {
    var IdentifierToOffsetMap = std.AutoHashMap(u32, u32).init(AllocatorHandle);
    for (Instructions) |InstructionItem| try IdentifierToOffsetMap.put(InstructionItem.Identifier, InstructionItem.Offset);
    return IdentifierToOffsetMap;
}

pub fn OffsetByIdentifier(IdentifierToOffsetMap: *std.AutoHashMap(u32, u32), InstructionIdentifier: u32, CodeLength: u32) u32 {
    if (InstructionIdentifier == EndLabel) return CodeLength;
    return IdentifierToOffsetMap.get(InstructionIdentifier).?;
}

pub fn Encode(AllocatorHandle: std.mem.Allocator, Instructions: []Instruction) ![]u8 {
    const CodeLength = AssignOffsets(Instructions);
    var IdentifierToOffset = try BuildIdentifierToOffset(AllocatorHandle, Instructions);
    defer IdentifierToOffset.deinit();
    var OutputBuffer = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, CodeLength + 16);
    const Writer = &OutputBuffer.writer;
    for (Instructions) |InstructionItem| {
        switch (InstructionItem.Kind) {
            .Fixed => {
                try Writer.writeByte(InstructionItem.Operation);
                try Writer.writeAll(InstructionItem.Raw);
            },
            .Branch => {
                const RelativeOffset: i64 = @as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.Target, CodeLength)) - @as(i64, InstructionItem.Offset);
                if (RelativeOffset < -32768 or RelativeOffset > 32767) return error.BranchOverflow;
                try Writer.writeByte(InstructionItem.Operation);
                var ScratchBytes: [2]u8 = undefined;
                std.mem.writeInt(i16, &ScratchBytes, @intCast(RelativeOffset), .big);
                try Writer.writeAll(&ScratchBytes);
            },
            .BranchWide => {
                const RelativeOffset: i64 = @as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.Target, CodeLength)) - @as(i64, InstructionItem.Offset);
                try Writer.writeByte(InstructionItem.Operation);
                var ScratchBytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &ScratchBytes, @intCast(RelativeOffset), .big);
                try Writer.writeAll(&ScratchBytes);
            },
            .TableSwitch => {
                try Writer.writeByte(InstructionItem.Operation);
                const Padding = (4 - ((InstructionItem.Offset + 1) % 4)) % 4;
                var PaddingIndex: u32 = 0;
                while (PaddingIndex < Padding) : (PaddingIndex += 1) try Writer.writeByte(0);
                try WriteUnsignedInt(Writer, @bitCast(@as(i32, @intCast(@as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.SwitchDefault, CodeLength)) - @as(i64, InstructionItem.Offset)))));
                try WriteUnsignedInt(Writer, @bitCast(InstructionItem.SwitchLow));
                try WriteUnsignedInt(Writer, @bitCast(InstructionItem.SwitchHigh));
                for (InstructionItem.SwitchTargets) |TargetIdentifier| {
                    try WriteUnsignedInt(Writer, @bitCast(@as(i32, @intCast(@as(i64, OffsetByIdentifier(&IdentifierToOffset, TargetIdentifier, CodeLength)) - @as(i64, InstructionItem.Offset)))));
                }
            },
            .LookupSwitch => {
                try Writer.writeByte(InstructionItem.Operation);
                const Padding = (4 - ((InstructionItem.Offset + 1) % 4)) % 4;
                var PaddingIndex: u32 = 0;
                while (PaddingIndex < Padding) : (PaddingIndex += 1) try Writer.writeByte(0);
                try WriteUnsignedInt(Writer, @bitCast(@as(i32, @intCast(@as(i64, OffsetByIdentifier(&IdentifierToOffset, InstructionItem.SwitchDefault, CodeLength)) - @as(i64, InstructionItem.Offset)))));
                try WriteUnsignedInt(Writer, @intCast(InstructionItem.SwitchPairs.len));
                for (InstructionItem.SwitchPairs) |PairEntry| {
                    try WriteUnsignedInt(Writer, @bitCast(PairEntry.Key));
                    try WriteUnsignedInt(Writer, @bitCast(@as(i32, @intCast(@as(i64, OffsetByIdentifier(&IdentifierToOffset, PairEntry.Target, CodeLength)) - @as(i64, InstructionItem.Offset)))));
                }
            },
        }
    }
    return OutputBuffer.written();
}

pub fn SerializeCode(AllocatorHandle: std.mem.Allocator, CodeAttributeReference: *CodeAttribute) ![]u8 {
    try PrepareLayout(AllocatorHandle, &CodeAttributeReference.Instructions);
    const CodeBytes = try Encode(AllocatorHandle, CodeAttributeReference.Instructions.items);
    const CodeLength: u32 = @intCast(CodeBytes.len);
    var IdentifierToOffset = try BuildIdentifierToOffset(AllocatorHandle, CodeAttributeReference.Instructions.items);
    defer IdentifierToOffset.deinit();
    var OutputBuffer = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, CodeBytes.len + 64);
    const Writer = &OutputBuffer.writer;
    try WriteUnsignedShort(Writer, CodeAttributeReference.MaxStack);
    try WriteUnsignedShort(Writer, CodeAttributeReference.MaxLocals);
    try WriteUnsignedInt(Writer, CodeLength);
    try Writer.writeAll(CodeBytes);
    try WriteUnsignedShort(Writer, @intCast(CodeAttributeReference.Exceptions.items.len));
    for (CodeAttributeReference.Exceptions.items) |ExceptionItem| {
        try WriteUnsignedShort(Writer, @intCast(OffsetByIdentifier(&IdentifierToOffset, ExceptionItem.Start, CodeLength)));
        try WriteUnsignedShort(Writer, @intCast(OffsetByIdentifier(&IdentifierToOffset, ExceptionItem.End, CodeLength)));
        try WriteUnsignedShort(Writer, @intCast(OffsetByIdentifier(&IdentifierToOffset, ExceptionItem.Handler, CodeLength)));
        try WriteUnsignedShort(Writer, ExceptionItem.CatchType);
    }
    try ClassFileModel.SerializeAttributes(Writer, CodeAttributeReference.Attributes.items);
    return OutputBuffer.written();
}

pub fn FindIdentifier(Instructions: []const Instruction, InstructionIdentifier: u32) ?usize {
    for (Instructions, 0..) |InstructionItem, Index| {
        if (InstructionItem.Identifier == InstructionIdentifier) return Index;
    }
    return null;
}
