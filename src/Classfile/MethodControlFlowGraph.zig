const std = @import("std");
const BytecodeInstructionModel = @import("BytecodeInstructionModel.zig");
const RandomShuffle = @import("../RandomShuffle.zig");

pub const Block = struct { Low: usize, High: usize };

pub const OpaquePlan = struct {
    SlotX: u16,
    SlotY: u16 = 0,
    TwoVariable: bool = false,
    Variant: u8 = 0,
    Key: i32 = 1,
    FalseTarget: u32,
};

pub fn IsTerminator(Operand: u8) bool {
    return switch (Operand) {
        0xA7, 0xC8 => true,
        0xAA, 0xAB => true,
        0xAC, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1 => true,
        0xBF => true,
        0xA9 => true,
        else => false,
    };
}

pub fn BuildBlocks(AllocatorHandle: std.mem.Allocator, Instructions: []const BytecodeInstructionModel.Instruction, LeaderIdentifiers: []const u32) ![]Block {
    const Count = Instructions.len;
    var IsLeaderFlags = try AllocatorHandle.alloc(bool, Count + 1);
    @memset(IsLeaderFlags, false);
    if (Count > 0) IsLeaderFlags[0] = true;
    for (LeaderIdentifiers) |LeaderIdentifier| {
        if (BytecodeInstructionModel.FindIdentifier(Instructions, LeaderIdentifier)) |FoundIndex| IsLeaderFlags[FoundIndex] = true;
    }

    var Leaders: std.ArrayList(usize) = .empty;
    var Index: usize = 0;
    while (Index < Count) : (Index += 1) {
        if (IsLeaderFlags[Index]) try Leaders.append(AllocatorHandle, Index);
    }

    var Blocks: std.ArrayList(Block) = .empty;
    for (Leaders.items, 0..) |LowBound, BlockIndex| {
        const HighBound = if (BlockIndex + 1 < Leaders.items.len) Leaders.items[BlockIndex + 1] else Count;
        try Blocks.append(AllocatorHandle, .{ .Low = LowBound, .High = HighBound });
    }
    return Blocks.toOwnedSlice(AllocatorHandle);
}

pub fn CanFallThrough(Instructions: []const BytecodeInstructionModel.Instruction, BasicBlock: Block) bool {
    if (BasicBlock.High == 0 or BasicBlock.High > Instructions.len) return false;
    return !IsTerminator(Instructions[BasicBlock.High - 1].Operation);
}

fn AppendBranch(AllocatorHandle: std.mem.Allocator, NewInstructions: *std.ArrayList(BytecodeInstructionModel.Instruction), Code: *BytecodeInstructionModel.CodeAttribute, Opcode: u8, Target: u32) !void {
    const RawBytes = try AllocatorHandle.alloc(u8, 2);
    try NewInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = Opcode, .Kind = .Branch, .Target = Target, .Raw = RawBytes });
}

fn EmitLoad(AllocatorHandle: std.mem.Allocator, Out: *std.ArrayList(BytecodeInstructionModel.Instruction), Code: *BytecodeInstructionModel.CodeAttribute, Slot: u16) !void {
    const Raw = try AllocatorHandle.alloc(u8, 1);
    Raw[0] = @intCast(Slot);
    try Out.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, 0x15, Raw));
}

fn EmitBare(AllocatorHandle: std.mem.Allocator, Out: *std.ArrayList(BytecodeInstructionModel.Instruction), Code: *BytecodeInstructionModel.CodeAttribute, Opcode: u8) !void {
    try Out.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, Opcode, &.{}));
}

fn EmitSipush(AllocatorHandle: std.mem.Allocator, Out: *std.ArrayList(BytecodeInstructionModel.Instruction), Code: *BytecodeInstructionModel.CodeAttribute, Value: i16) !void {
    const Raw = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(i16, Raw[0..2], Value, .big);
    try Out.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, 0x11, Raw));
}

fn EmitOpaquePredicate(AllocatorHandle: std.mem.Allocator, Out: *std.ArrayList(BytecodeInstructionModel.Instruction), Code: *BytecodeInstructionModel.CodeAttribute, Plan: OpaquePlan) !void {
    const X = Plan.SlotX;
    const Y = Plan.SlotY;
    const Key: i16 = @intCast(@mod(Plan.Key, 30000) + 2);
    switch (Plan.Variant) {
        0 => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x80);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x82);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
        },
        1 => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x80);
            try EmitBare(AllocatorHandle, Out, Code, 0x60);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
        },
        2 => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x60);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
            try EmitBare(AllocatorHandle, Out, Code, 0x04);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
        },
        4 => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
            try EmitBare(AllocatorHandle, Out, Code, 0x04);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
        },
        5 => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x60);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x82);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, Y);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
            try EmitBare(AllocatorHandle, Out, Code, 0x04);
            try EmitBare(AllocatorHandle, Out, Code, 0x78);
            try EmitBare(AllocatorHandle, Out, Code, 0x64);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
        },
        else => {
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitLoad(AllocatorHandle, Out, Code, X);
            try EmitBare(AllocatorHandle, Out, Code, 0x02);
            try EmitBare(AllocatorHandle, Out, Code, 0x82);
            try EmitBare(AllocatorHandle, Out, Code, 0x7e);
            try EmitSipush(AllocatorHandle, Out, Code, Key);
            try EmitBare(AllocatorHandle, Out, Code, 0x68);
        },
    }
}

pub fn ShuffleBlocks(AllocatorHandle: std.mem.Allocator, Code: *BytecodeInstructionModel.CodeAttribute, Blocks: []const Block, PseudoRandom: *std.Random.DefaultPrng, Plans: ?[]const ?OpaquePlan) !std.ArrayList(BytecodeInstructionModel.Instruction) {
    const OriginalInstructions = Code.Instructions.items;
    var Order = try AllocatorHandle.alloc(usize, Blocks.len);
    for (0..Blocks.len) |Index| Order[Index] = Index;
    if (Blocks.len >= 2) RandomShuffle.Shuffle(usize, Order[1..], PseudoRandom.random());
    var NewInstructions: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty;
    for (Order) |BlockIndex| {
        const CurrentBlock = Blocks[BlockIndex];
        var InstructionIndex = CurrentBlock.Low;
        while (InstructionIndex < CurrentBlock.High) : (InstructionIndex += 1) try NewInstructions.append(AllocatorHandle, OriginalInstructions[InstructionIndex]);
        if (CanFallThrough(OriginalInstructions, CurrentBlock)) {
            const FallThroughIdentifier = if (CurrentBlock.High < OriginalInstructions.len) OriginalInstructions[CurrentBlock.High].Identifier else BytecodeInstructionModel.EndLabel;
            const Plan: ?OpaquePlan = if (Plans) |Provider| Provider[BlockIndex] else null;
            if (Plan) |Predicate| {
                try EmitOpaquePredicate(AllocatorHandle, &NewInstructions, Code, Predicate);
                try AppendBranch(AllocatorHandle, &NewInstructions, Code, 0x99, FallThroughIdentifier);
                try AppendBranch(AllocatorHandle, &NewInstructions, Code, 0xA7, Predicate.FalseTarget);
            } else {
                try AppendBranch(AllocatorHandle, &NewInstructions, Code, 0xA7, FallThroughIdentifier);
            }
        }
    }
    return NewInstructions;
}

test "opaque predicate formulas are invariant" {
    const Edges = [_]i32{ 0, 1, -1, 2, -2, std.math.maxInt(i32), std.math.minInt(i32), 12345, -9999, 1431655765, 1073741824 };
    var Seed: u32 = 0x12345678;
    for (Edges) |X| {
        for (Edges) |Y| {
            Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
            const Key: i32 = 2 + @as(i32, @intCast(Seed % 29998));
            try std.testing.expectEqual(@as(i32, 0), ((X | Y) -% (X ^ Y) -% (X & Y)) *% Key);
            try std.testing.expectEqual(@as(i32, 0), ((X & Y) +% (X | Y) -% X -% Y) *% Key);
            try std.testing.expectEqual(@as(i32, 0), ((X *% X +% X) *% Key) & 1);
            try std.testing.expectEqual(@as(i32, 0), (X & ~X) *% Key);
            try std.testing.expectEqual(@as(i32, 0), ((X *% X -% X) *% Key) & 1);
            try std.testing.expectEqual(@as(i32, 0), ((X +% Y) -% (X ^ Y) -% ((X & Y) *% 2)) *% Key);
        }
    }
    var Trials: usize = 0;
    while (Trials < 6000) : (Trials += 1) {
        Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
        const X: i32 = @bitCast(Seed);
        Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
        const Y: i32 = @bitCast(Seed);
        Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
        const Key: i32 = 2 + @as(i32, @intCast(Seed % 29998));
        try std.testing.expectEqual(@as(i32, 0), ((X | Y) -% (X ^ Y) -% (X & Y)) *% Key);
        try std.testing.expectEqual(@as(i32, 0), ((X & Y) +% (X | Y) -% X -% Y) *% Key);
        try std.testing.expectEqual(@as(i32, 0), ((X *% X +% X) *% Key) & 1);
        try std.testing.expectEqual(@as(i32, 0), (X & ~X) *% Key);
        try std.testing.expectEqual(@as(i32, 0), ((X *% X -% X) *% Key) & 1);
        try std.testing.expectEqual(@as(i32, 0), ((X +% Y) -% (X ^ Y) -% ((X & Y) *% 2)) *% Key);
    }
}
