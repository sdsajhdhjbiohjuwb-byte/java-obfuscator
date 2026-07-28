const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const RandomShuffle = @import("../RandomShuffle.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const MethodControlFlowGraph = @import("../Classfile/MethodControlFlowGraph.zig");
const TypeSimulator = @import("../Classfile/TypeSimulator.zig");

const VerificationType = StackMapTableCodec.VType;
const Instruction = BytecodeInstructionModel.Instruction;
const InstructionList = std.ArrayList(Instruction);

const ReferencePool = struct {
    SpillSlot: u16,
    StateSlot: u16,
    KeySlot: u16,
    KeyConstant: i32,
    Multiplier: i32,
    Addend: i32,
    ObjectArrayClass: u16,
    ObjectClass: u16,
    IntegerClass: u16,
    LongClass: u16,
    FloatClass: u16,
    DoubleClass: u16,
    IntegerValueOf: u16,
    LongValueOf: u16,
    FloatValueOf: u16,
    DoubleValueOf: u16,
    IntegerIntValue: u16,
    LongLongValue: u16,
    FloatFloatValue: u16,
    DoubleDoubleValue: u16,
    IdentityHashCode: u16,
};

const BasicBlock = struct {
    Low: usize,
    High: usize,
    StateValue: i32,
    EntryIdentifier: u32,
    OriginalIdentifier: u32,
    IsHandler: bool = false,
};

fn EmitSlotInstruction(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Opcode: u8, Slot: u16) !void {
    const RawOperand = try AllocatorHandle.alloc(u8, 1);
    RawOperand[0] = @intCast(Slot);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, Opcode, RawOperand));
}

fn EmitReferenceInstruction(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Opcode: u8, ReferenceIndex: u16) !void {
    const RawOperand = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, RawOperand[0..2], ReferenceIndex, .big);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, Opcode, RawOperand));
}

fn SpillSlot(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, Slot: u16, SlotVerificationType: VerificationType) !void {
    switch (SlotVerificationType) {
        .Top, .Uninitialized, .UninitializedThis, .Null => return,
        else => {},
    }
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x19, References.SpillSlot);
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, @intCast(Slot));
    switch (SlotVerificationType) {
        .Integer => {
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x15, Slot);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb8, References.IntegerValueOf);
        },
        .Long => {
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x16, Slot);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb8, References.LongValueOf);
        },
        .Float => {
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x17, Slot);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb8, References.FloatValueOf);
        },
        .Double => {
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x18, Slot);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb8, References.DoubleValueOf);
        },
        else => try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x19, Slot),
    }
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x53, &.{}));
}

fn ReloadSlot(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, Slot: u16, SlotVerificationType: VerificationType) !void {
    switch (SlotVerificationType) {
        .Top, .Uninitialized, .UninitializedThis => return,
        .Null => {
            try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x01, &.{}));
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x3a, Slot);
            return;
        },
        else => {},
    }
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x19, References.SpillSlot);
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, @intCast(Slot));
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x32, &.{}));
    switch (SlotVerificationType) {
        .Integer => {
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xc0, References.IntegerClass);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb6, References.IntegerIntValue);
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x36, Slot);
        },
        .Long => {
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xc0, References.LongClass);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb6, References.LongLongValue);
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x37, Slot);
        },
        .Float => {
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xc0, References.FloatClass);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb6, References.FloatFloatValue);
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x38, Slot);
        },
        .Double => {
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xc0, References.DoubleClass);
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xb6, References.DoubleDoubleValue);
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x39, Slot);
        },
        .Object => |ClassIndex| {
            try EmitReferenceInstruction(AllocatorHandle, Instructions, CodeAttribute, 0xc0, ClassIndex);
            try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x3a, Slot);
        },
        else => {},
    }
}

fn SpillLocals(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, Locals: []const VerificationType) !void {
    for (Locals, 0..) |SlotVerificationType, SlotIndex| try SpillSlot(AllocatorHandle, Instructions, CodeAttribute, Pool, References, @intCast(SlotIndex), SlotVerificationType);
}

fn ReloadLocals(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, Locals: []const VerificationType) !void {
    for (Locals, 0..) |SlotVerificationType, SlotIndex| try ReloadSlot(AllocatorHandle, Instructions, CodeAttribute, Pool, References, @intCast(SlotIndex), SlotVerificationType);
}

fn EmitXorShift(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, ShiftAmount: i32, ShiftOpcode: u8) !void {
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x59, &.{}));
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, ShiftAmount);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, ShiftOpcode, &.{}));
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x82, &.{}));
}

fn EmitKeyRotate(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool) !void {
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x15, References.KeySlot);
    try EmitXorShift(AllocatorHandle, Instructions, CodeAttribute, Pool, 13, 0x78);
    try EmitXorShift(AllocatorHandle, Instructions, CodeAttribute, Pool, 17, 0x7c);
    try EmitXorShift(AllocatorHandle, Instructions, CodeAttribute, Pool, 5, 0x78);
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, References.Multiplier);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x68, &.{}));
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, References.Addend);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x60, &.{}));
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x36, References.KeySlot);
}

fn EmitEncodeState(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, StateValue: i32) !void {
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, Instructions, CodeAttribute, Pool, StateValue);
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x15, References.KeySlot);
    try Instructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x82, &.{}));
    try EmitSlotInstruction(AllocatorHandle, Instructions, CodeAttribute, 0x36, References.StateSlot);
}

fn DispatchTo(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, References: ReferencePool, TargetLocals: []const VerificationType, StateValue: i32, DispatchIdentifier: u32) !void {
    try SpillLocals(AllocatorHandle, Instructions, CodeAttribute, Pool, References, TargetLocals);
    try EmitKeyRotate(AllocatorHandle, Instructions, CodeAttribute, Pool, References);
    try EmitEncodeState(AllocatorHandle, Instructions, CodeAttribute, Pool, References, StateValue);
    try Instructions.append(AllocatorHandle, .{ .Identifier = CodeAttribute.NewIdentifier(), .Operation = 0xa7, .Kind = .Branch, .Target = DispatchIdentifier });
}

fn UniformLocals(AllocatorHandle: std.mem.Allocator, MaxLocals: u16, References: ReferencePool) ![]VerificationType {
    var LocalsList: std.ArrayList(VerificationType) = .empty;
    var SlotIndex: u16 = 0;
    while (SlotIndex < MaxLocals) : (SlotIndex += 1) try LocalsList.append(AllocatorHandle, .Top);
    try LocalsList.append(AllocatorHandle, .{ .Object = References.ObjectArrayClass });
    try LocalsList.append(AllocatorHandle, .Integer);
    try LocalsList.append(AllocatorHandle, .Integer);
    return LocalsList.toOwnedSlice(AllocatorHandle);
}

fn SlotsToEntries(AllocatorHandle: std.mem.Allocator, Slots: []const VerificationType, MaxLocals: u16, References: ReferencePool) ![]VerificationType {
    var LocalsList: std.ArrayList(VerificationType) = .empty;
    var Index: usize = 0;
    while (Index < MaxLocals) {
        const SlotVerificationType = if (Index < Slots.len) Slots[Index] else .Top;
        try LocalsList.append(AllocatorHandle, SlotVerificationType);
        if (SlotVerificationType == .Long or SlotVerificationType == .Double) Index += 2 else Index += 1;
    }
    try LocalsList.append(AllocatorHandle, .{ .Object = References.ObjectArrayClass });
    try LocalsList.append(AllocatorHandle, .Integer);
    try LocalsList.append(AllocatorHandle, .Integer);
    return LocalsList.toOwnedSlice(AllocatorHandle);
}

fn HasUninitialized(Locals: []const VerificationType) bool {
    for (Locals) |SlotVerificationType| {
        if (SlotVerificationType == .Uninitialized or SlotVerificationType == .UninitializedThis) return true;
    }
    return false;
}

fn Mark(InstructionSlice: []const Instruction, LeaderFlags: []bool, TargetId: u32) void {
    if (TargetId == BytecodeInstructionModel.EndLabel) return;
    if (BytecodeInstructionModel.FindIdentifier(InstructionSlice, TargetId)) |FoundIndex| LeaderFlags[FoundIndex] = true;
}

fn BuildLeaders(AllocatorHandle: std.mem.Allocator, InstructionSlice: []const Instruction, Exceptions: []const BytecodeInstructionModel.ExceptionEntry) ![]bool {
    const InstructionCount = InstructionSlice.len;
    var LeaderFlags = try AllocatorHandle.alloc(bool, InstructionCount);
    @memset(LeaderFlags, false);
    if (InstructionCount > 0) LeaderFlags[0] = true;
    for (InstructionSlice, 0..) |CurrentInstruction, Index| {
        switch (CurrentInstruction.Kind) {
            .Branch, .BranchWide => {
                Mark(InstructionSlice, LeaderFlags, CurrentInstruction.Target);
                if (Index + 1 < InstructionCount) LeaderFlags[Index + 1] = true;
            },
            .TableSwitch => {
                Mark(InstructionSlice, LeaderFlags, CurrentInstruction.SwitchDefault);
                for (CurrentInstruction.SwitchTargets) |SwitchTarget| Mark(InstructionSlice, LeaderFlags, SwitchTarget);
                if (Index + 1 < InstructionCount) LeaderFlags[Index + 1] = true;
            },
            .LookupSwitch => {
                Mark(InstructionSlice, LeaderFlags, CurrentInstruction.SwitchDefault);
                for (CurrentInstruction.SwitchPairs) |SwitchPair| Mark(InstructionSlice, LeaderFlags, SwitchPair.Target);
                if (Index + 1 < InstructionCount) LeaderFlags[Index + 1] = true;
            },
            .Fixed => {
                if (MethodControlFlowGraph.IsTerminator(CurrentInstruction.Operation) and Index + 1 < InstructionCount) LeaderFlags[Index + 1] = true;
            },
        }
    }
    for (Exceptions) |ExceptionEntryValue| {
        Mark(InstructionSlice, LeaderFlags, ExceptionEntryValue.Start);
        Mark(InstructionSlice, LeaderFlags, ExceptionEntryValue.End);
        Mark(InstructionSlice, LeaderFlags, ExceptionEntryValue.Handler);
    }
    return LeaderFlags;
}

fn BuildReferencePool(ClassFile: *ClassFileModel.ClassFile, MaxLocals: u16) !ReferencePool {
    const Pool = &ClassFile.ConstantPool;
    return .{
        .SpillSlot = MaxLocals,
        .StateSlot = MaxLocals + 1,
        .KeySlot = MaxLocals + 2,
        .KeyConstant = 0,
        .Multiplier = 1,
        .Addend = 0,
        .ObjectArrayClass = try Pool.AddClass("[Ljava/lang/Object;"),
        .ObjectClass = try Pool.AddClass("java/lang/Object"),
        .IntegerClass = try Pool.AddClass("java/lang/Integer"),
        .LongClass = try Pool.AddClass("java/lang/Long"),
        .FloatClass = try Pool.AddClass("java/lang/Float"),
        .DoubleClass = try Pool.AddClass("java/lang/Double"),
        .IntegerValueOf = try Pool.AddMethodref("java/lang/Integer", "valueOf", "(I)Ljava/lang/Integer;"),
        .LongValueOf = try Pool.AddMethodref("java/lang/Long", "valueOf", "(J)Ljava/lang/Long;"),
        .FloatValueOf = try Pool.AddMethodref("java/lang/Float", "valueOf", "(F)Ljava/lang/Float;"),
        .DoubleValueOf = try Pool.AddMethodref("java/lang/Double", "valueOf", "(D)Ljava/lang/Double;"),
        .IntegerIntValue = try Pool.AddMethodref("java/lang/Integer", "intValue", "()I"),
        .LongLongValue = try Pool.AddMethodref("java/lang/Long", "longValue", "()J"),
        .FloatFloatValue = try Pool.AddMethodref("java/lang/Float", "floatValue", "()F"),
        .DoubleDoubleValue = try Pool.AddMethodref("java/lang/Double", "doubleValue", "()D"),
        .IdentityHashCode = try Pool.AddMethodref("java/lang/System", "identityHashCode", "(Ljava/lang/Object;)I"),
    };
}

const Trampoline = struct { TrampolineIdentifier: u32, TargetBlock: usize };

fn EnsureTrampoline(AllocatorHandle: std.mem.Allocator, TrampolineMap: *std.AutoHashMap(u32, u32), TrampolineList: *std.ArrayList(Trampoline), CodeAttribute: *BytecodeInstructionModel.CodeAttribute, BlockByOriginalId: *std.AutoHashMap(u32, usize), TargetId: u32) !u32 {
    if (TrampolineMap.get(TargetId)) |ExistingIdentifier| return ExistingIdentifier;
    const TrampolineIdentifier = CodeAttribute.NewIdentifier();
    try TrampolineMap.put(TargetId, TrampolineIdentifier);
    try TrampolineList.append(AllocatorHandle, .{ .TrampolineIdentifier = TrampolineIdentifier, .TargetBlock = BlockByOriginalId.get(TargetId).? });
    return TrampolineIdentifier;
}

fn TransformMethod(
    AllocatorHandle: std.mem.Allocator,
    ClassFile: *ClassFileModel.ClassFile,
    Member: *ClassFileModel.MemberInfo,
    CodeInfo: []const u8,
    PseudoRandom: *std.Random.DefaultPrng,
) !?[]u8 {
    var CodeAttribute = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfo);
    const MethodName = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
    if (std.mem.eql(u8, MethodName, "<init>")) return null;
    const StackMapIndex = ClassFileModel.FindAttribute(CodeAttribute.Attributes.items, &ClassFile.ConstantPool, "StackMapTable") orelse return null;

    const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
    const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
    const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, false);

    var InitialSlots: std.ArrayList(VerificationType) = .empty;
    for (InitialLocals) |LocalVerificationType| {
        try InitialSlots.append(AllocatorHandle, LocalVerificationType);
        if (LocalVerificationType == .Long or LocalVerificationType == .Double) try InitialSlots.append(AllocatorHandle, .Top);
    }
    const MaxLocals = CodeAttribute.MaxLocals;
    while (InitialSlots.items.len < MaxLocals) try InitialSlots.append(AllocatorHandle, .Top);
    if (@as(usize, MaxLocals) + 3 > 255) return null;

    const Frames = try StackMapTableCodec.Parse(AllocatorHandle, CodeAttribute.Attributes.items[StackMapIndex].Info, CodeAttribute.Instructions.items, InitialLocals);
    const States = TypeSimulator.Simulate(AllocatorHandle, &ClassFile.ConstantPool, CodeAttribute.Instructions.items, Frames, InitialSlots.items, ClassFile.ThisClass) catch return null;

    const OriginalInstructions = CodeAttribute.Instructions.items;
    const LeaderFlags = try BuildLeaders(AllocatorHandle, OriginalInstructions, CodeAttribute.Exceptions.items);

    var Blocks: std.ArrayList(BasicBlock) = .empty;
    {
        var Index: usize = 0;
        while (Index < OriginalInstructions.len) {
            if (!LeaderFlags[Index]) {
                Index += 1;
                continue;
            }
            var InnerIndex = Index + 1;
            while (InnerIndex < OriginalInstructions.len and !LeaderFlags[InnerIndex]) InnerIndex += 1;
            try Blocks.append(AllocatorHandle, .{ .Low = Index, .High = InnerIndex, .StateValue = 0, .EntryIdentifier = 0, .OriginalIdentifier = OriginalInstructions[Index].Identifier });
            Index = InnerIndex;
        }
    }
    const BlockList = Blocks.items;
    if (BlockList.len < 2) return null;

    var BlockByOriginalId = std.AutoHashMap(u32, usize).init(AllocatorHandle);
    for (BlockList, 0..) |CurrentBlock, BlockIndex| try BlockByOriginalId.put(CurrentBlock.OriginalIdentifier, BlockIndex);

    var HandlerBlockMap = std.AutoHashMap(u32, usize).init(AllocatorHandle);
    for (CodeAttribute.Exceptions.items) |ExceptionEntryValue| {
        const HandlerBlockIndex = BlockByOriginalId.get(ExceptionEntryValue.Handler) orelse return null;
        BlockList[HandlerBlockIndex].IsHandler = true;
        try HandlerBlockMap.put(ExceptionEntryValue.Handler, HandlerBlockIndex);
    }

    if (BlockList[0].IsHandler) return null;
    for (BlockList) |CurrentBlock| {
        if (HasUninitialized(States[CurrentBlock.Low].Locals)) return null;
        if (CurrentBlock.IsHandler) {
            if (States[CurrentBlock.Low].Stack.len != 1) return null;
        } else {
            if (States[CurrentBlock.Low].Stack.len != 0) return null;
        }
    }

    var References = try BuildReferencePool(ClassFile, MaxLocals);
    References.KeyConstant = @bitCast(PseudoRandom.random().int(u32));
    References.Multiplier = @bitCast(PseudoRandom.random().int(u32) | 1);
    References.Addend = @bitCast(PseudoRandom.random().int(u32));

    var UsedStates = std.AutoHashMap(i32, void).init(AllocatorHandle);
    for (BlockList) |*CurrentBlock| {
        var StateCandidate: i32 = PseudoRandom.random().intRangeAtMost(i32, 1, 30000);
        while (UsedStates.contains(StateCandidate)) StateCandidate = PseudoRandom.random().intRangeAtMost(i32, 1, 30000);
        try UsedStates.put(StateCandidate, {});
        CurrentBlock.StateValue = StateCandidate;
        CurrentBlock.EntryIdentifier = if (CurrentBlock.IsHandler) CurrentBlock.OriginalIdentifier else CodeAttribute.NewIdentifier();
    }

    const DispatchIdentifier = CodeAttribute.NewIdentifier();
    const UniformFrameLocals = try UniformLocals(AllocatorHandle, MaxLocals, References);
    var NewFrames: std.ArrayList(StackMapTableCodec.Frame) = .empty;
    var OutputInstructions: InstructionList = .empty;

    try BytecodeInstructionModel.PushInteger(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, @intCast(MaxLocals));
    try EmitReferenceInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0xbd, References.ObjectClass);
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x3a, References.SpillSlot);
    try SpillLocals(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, InitialSlots.items);
    const KeyConstant: i32 = @bitCast(PseudoRandom.random().int(u32));
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, KeyConstant);
    try BytecodeInstructionModel.PushInteger(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, KeyConstant ^ References.KeyConstant);
    try OutputInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&CodeAttribute, 0x82, &.{}));
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x36, References.KeySlot);
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x15, References.KeySlot);
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x19, References.SpillSlot);
    try EmitReferenceInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0xb8, References.IdentityHashCode);
    try OutputInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&CodeAttribute, 0x82, &.{}));
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x36, References.KeySlot);
    try EmitKeyRotate(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References);
    try EmitEncodeState(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, BlockList[0].StateValue);
    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = CodeAttribute.NewIdentifier(), .Operation = 0xa7, .Kind = .Branch, .Target = DispatchIdentifier });

    var PairsList: std.ArrayList(BytecodeInstructionModel.Pair) = .empty;
    for (BlockList) |CurrentBlock| {
        if (!CurrentBlock.IsHandler) try PairsList.append(AllocatorHandle, .{ .Key = CurrentBlock.StateValue, .Target = CurrentBlock.EntryIdentifier });
    }
    const Pairs = try PairsList.toOwnedSlice(AllocatorHandle);
    std.mem.sort(BytecodeInstructionModel.Pair, Pairs, {}, struct {
        fn Less(_: void, LeftPair: BytecodeInstructionModel.Pair, RightPair: BytecodeInstructionModel.Pair) bool {
            return LeftPair.Key < RightPair.Key;
        }
    }.Less);
    const LoadRawOperand = try AllocatorHandle.alloc(u8, 1);
    LoadRawOperand[0] = @intCast(References.StateSlot);
    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = DispatchIdentifier, .Operation = 0x15, .Kind = .Fixed, .Raw = LoadRawOperand });
    try EmitSlotInstruction(AllocatorHandle, &OutputInstructions, &CodeAttribute, 0x15, References.KeySlot);
    try OutputInstructions.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(&CodeAttribute, 0x82, &.{}));
    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = CodeAttribute.NewIdentifier(), .Operation = 0xab, .Kind = .LookupSwitch, .SwitchDefault = BlockList[0].EntryIdentifier, .SwitchPairs = Pairs });
    try NewFrames.append(AllocatorHandle, .{ .Label = DispatchIdentifier, .Locals = UniformFrameLocals, .Stack = &.{} });

    var Order = try AllocatorHandle.alloc(usize, BlockList.len);
    for (0..BlockList.len) |Index| Order[Index] = Index;
    RandomShuffle.Shuffle(usize, Order, PseudoRandom.random());

    const BodyFirst = try AllocatorHandle.alloc(u32, BlockList.len);
    const BodyEnd = try AllocatorHandle.alloc(u32, BlockList.len);
    const Protect = try AllocatorHandle.alloc(bool, BlockList.len);

    for (Order, 0..) |BlockIndex, Position| {
        const CurrentBlock = BlockList[BlockIndex];
        const PhysicalNext: u32 = if (Position + 1 < Order.len) BlockList[Order[Position + 1]].EntryIdentifier else BytecodeInstructionModel.EndLabel;

        if (CurrentBlock.IsHandler) {
            const HandlerLocals = try SlotsToEntries(AllocatorHandle, States[CurrentBlock.Low].Locals, MaxLocals, References);
            try NewFrames.append(AllocatorHandle, .{ .Label = CurrentBlock.EntryIdentifier, .Locals = HandlerLocals, .Stack = try AllocatorHandle.dupe(VerificationType, States[CurrentBlock.Low].Stack) });
        } else {
            try OutputInstructions.append(AllocatorHandle, .{ .Identifier = CurrentBlock.EntryIdentifier, .Operation = 0x00, .Kind = .Fixed, .Raw = &.{} });
            try NewFrames.append(AllocatorHandle, .{ .Label = CurrentBlock.EntryIdentifier, .Locals = UniformFrameLocals, .Stack = &.{} });
            try ReloadLocals(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[CurrentBlock.Low].Locals);
        }
        BodyFirst[BlockIndex] = OriginalInstructions[CurrentBlock.Low].Identifier;

        const LastInstruction = OriginalInstructions[CurrentBlock.High - 1];
        var BodyEndIndex = CurrentBlock.High;
        var Transfer: ?Instruction = null;
        if (LastInstruction.Kind == .Branch or LastInstruction.Kind == .BranchWide or LastInstruction.Kind == .TableSwitch or LastInstruction.Kind == .LookupSwitch or (LastInstruction.Kind == .Fixed and MethodControlFlowGraph.IsTerminator(LastInstruction.Operation))) {
            Transfer = LastInstruction;
            BodyEndIndex = CurrentBlock.High - 1;
        }
        var BodyIndex = CurrentBlock.Low;
        while (BodyIndex < BodyEndIndex) : (BodyIndex += 1) try OutputInstructions.append(AllocatorHandle, OriginalInstructions[BodyIndex]);

        const TailPosition = OutputInstructions.items.len;
        var IsAthrow = false;
        if (Transfer) |TransferInstruction| {
            if (TransferInstruction.Kind == .Fixed and ((TransferInstruction.Operation >= 0xac and TransferInstruction.Operation <= 0xb1) or TransferInstruction.Operation == 0xbf)) {
                try OutputInstructions.append(AllocatorHandle, TransferInstruction);
                if (TransferInstruction.Operation == 0xbf) IsAthrow = true;
            } else if (TransferInstruction.Operation == 0xa7 or TransferInstruction.Operation == 0xc8) {
                const TargetBlock = BlockList[BlockByOriginalId.get(TransferInstruction.Target) orelse return null];
                try DispatchTo(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[TargetBlock.Low].Locals, TargetBlock.StateValue, DispatchIdentifier);
            } else if (TransferInstruction.Kind == .TableSwitch or TransferInstruction.Kind == .LookupSwitch) {
                var TrampolineMap = std.AutoHashMap(u32, u32).init(AllocatorHandle);
                var TrampolineList: std.ArrayList(Trampoline) = .empty;
                var NewTransfer = TransferInstruction;
                NewTransfer.Identifier = CodeAttribute.NewIdentifier();
                NewTransfer.SwitchDefault = try EnsureTrampoline(AllocatorHandle, &TrampolineMap, &TrampolineList, &CodeAttribute, &BlockByOriginalId, TransferInstruction.SwitchDefault);
                if (TransferInstruction.Kind == .TableSwitch) {
                    const NewTargets = try AllocatorHandle.alloc(u32, TransferInstruction.SwitchTargets.len);
                    for (TransferInstruction.SwitchTargets, 0..) |SwitchTarget, TargetIndex| NewTargets[TargetIndex] = try EnsureTrampoline(AllocatorHandle, &TrampolineMap, &TrampolineList, &CodeAttribute, &BlockByOriginalId, SwitchTarget);
                    NewTransfer.SwitchTargets = NewTargets;
                } else {
                    const NewPairs = try AllocatorHandle.alloc(BytecodeInstructionModel.Pair, TransferInstruction.SwitchPairs.len);
                    for (TransferInstruction.SwitchPairs, 0..) |SwitchPairValue, PairIndex| NewPairs[PairIndex] = .{ .Key = SwitchPairValue.Key, .Target = try EnsureTrampoline(AllocatorHandle, &TrampolineMap, &TrampolineList, &CodeAttribute, &BlockByOriginalId, SwitchPairValue.Target) };
                    NewTransfer.SwitchPairs = NewPairs;
                }
                try OutputInstructions.append(AllocatorHandle, NewTransfer);
                const TrampolineLocals = try SlotsToEntries(AllocatorHandle, States[CurrentBlock.High - 1].Locals, MaxLocals, References);
                for (TrampolineList.items) |TrampolineValue| {
                    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = TrampolineValue.TrampolineIdentifier, .Operation = 0x00, .Kind = .Fixed, .Raw = &.{} });
                    try NewFrames.append(AllocatorHandle, .{ .Label = TrampolineValue.TrampolineIdentifier, .Locals = TrampolineLocals, .Stack = &.{} });
                    const TargetBlock = BlockList[TrampolineValue.TargetBlock];
                    try DispatchTo(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[TargetBlock.Low].Locals, TargetBlock.StateValue, DispatchIdentifier);
                }
            } else {
                const TargetBlock = BlockList[BlockByOriginalId.get(TransferInstruction.Target) orelse return null];
                const FallthroughBlock = BlockList[BlockByOriginalId.get(OriginalInstructions[CurrentBlock.High].Identifier) orelse return null];
                const LabelTargetIdentifier = CodeAttribute.NewIdentifier();
                try OutputInstructions.append(AllocatorHandle, .{ .Identifier = CodeAttribute.NewIdentifier(), .Operation = TransferInstruction.Operation, .Kind = .Branch, .Target = LabelTargetIdentifier });
                try DispatchTo(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[FallthroughBlock.Low].Locals, FallthroughBlock.StateValue, DispatchIdentifier);
                try OutputInstructions.append(AllocatorHandle, .{ .Identifier = LabelTargetIdentifier, .Operation = 0x00, .Kind = .Fixed, .Raw = &.{} });
                const TrampolineLocals = try SlotsToEntries(AllocatorHandle, States[CurrentBlock.High - 1].Locals, MaxLocals, References);
                try NewFrames.append(AllocatorHandle, .{ .Label = LabelTargetIdentifier, .Locals = TrampolineLocals, .Stack = &.{} });
                try DispatchTo(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[TargetBlock.Low].Locals, TargetBlock.StateValue, DispatchIdentifier);
            }
        } else {
            const FallthroughBlock = BlockList[BlockByOriginalId.get(OriginalInstructions[CurrentBlock.High].Identifier) orelse return null];
            try DispatchTo(AllocatorHandle, &OutputInstructions, &CodeAttribute, &ClassFile.ConstantPool, References, States[FallthroughBlock.Low].Locals, FallthroughBlock.StateValue, DispatchIdentifier);
        }

        Protect[BlockIndex] = (BodyEndIndex > CurrentBlock.Low) or IsAthrow;
        BodyEnd[BlockIndex] = if (IsAthrow) PhysicalNext else if (TailPosition < OutputInstructions.items.len) OutputInstructions.items[TailPosition].Identifier else PhysicalNext;
    }

    var NewExceptions: std.ArrayList(BytecodeInstructionModel.ExceptionEntry) = .empty;
    for (CodeAttribute.Exceptions.items) |ExceptionEntryValue| {
        const StartIndex: usize = if (ExceptionEntryValue.Start == BytecodeInstructionModel.EndLabel) OriginalInstructions.len else (BytecodeInstructionModel.FindIdentifier(OriginalInstructions, ExceptionEntryValue.Start) orelse return null);
        const EndIndex: usize = if (ExceptionEntryValue.End == BytecodeInstructionModel.EndLabel) OriginalInstructions.len else (BytecodeInstructionModel.FindIdentifier(OriginalInstructions, ExceptionEntryValue.End) orelse return null);
        const HandlerBlockIndex = HandlerBlockMap.get(ExceptionEntryValue.Handler) orelse return null;
        for (BlockList, 0..) |CurrentBlock, BlockIndex| {
            if (Protect[BlockIndex] and CurrentBlock.Low >= StartIndex and CurrentBlock.High <= EndIndex) {
                try NewExceptions.append(AllocatorHandle, .{ .Start = BodyFirst[BlockIndex], .End = BodyEnd[BlockIndex], .Handler = BlockList[HandlerBlockIndex].EntryIdentifier, .CatchType = ExceptionEntryValue.CatchType });
            }
        }
    }
    CodeAttribute.Exceptions = NewExceptions;

    CodeAttribute.Instructions = OutputInstructions;
    CodeAttribute.MaxLocals = MaxLocals + 3;
    CodeAttribute.MaxStack = @max(CodeAttribute.MaxStack, 8);
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &CodeAttribute.Instructions);
    CodeAttribute.Attributes.items[StackMapIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, NewFrames.items, CodeAttribute.Instructions.items);
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &CodeAttribute);
}

pub fn ControlFlowFlattener(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, PseudoRandom: *std.Random.DefaultPrng) !usize {
    var Count: usize = 0;
    for (ClassFile.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        const Info = Member.Attributes.items[CodeAttributeIndex].Info;
        if (TransformMethod(AllocatorHandle, ClassFile, Member, Info, PseudoRandom) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
            Count += 1;
        }
    }
    return Count;
}
