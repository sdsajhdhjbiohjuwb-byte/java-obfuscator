const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const MethodControlFlowGraph = @import("../Classfile/MethodControlFlowGraph.zig");
const TypeSimulator = @import("../Classfile/TypeSimulator.zig");
const MaxStackLocalsComputer = @import("../Classfile/MaxStackLocalsComputer.zig");

const VerificationType = StackMapTableCodec.VType;
const OpaquePlan = MethodControlFlowGraph.OpaquePlan;

fn LocalsEqual(Left: []const VerificationType, Right: []const VerificationType) bool {
    if (Left.len != Right.len) return false;
    for (Left, Right) |LeftType, RightType| {
        if (!std.meta.eql(LeftType, RightType)) return false;
    }
    return true;
}

fn BuildOpaquePlans(
    AllocatorHandle: std.mem.Allocator,
    ClassFile: *ClassFileModel.ClassFile,
    Code: *BytecodeInstructionModel.CodeAttribute,
    Frames: []StackMapTableCodec.Frame,
    InitialLocals: []const StackMapTableCodec.VType,
    Blocks: []const MethodControlFlowGraph.Block,
    PseudoRandom: *std.Random.DefaultPrng,
) ?[]?OpaquePlan {
    var InitialSlots: std.ArrayList(StackMapTableCodec.VType) = .empty;
    for (InitialLocals) |LocalVerificationType| {
        InitialSlots.append(AllocatorHandle, LocalVerificationType) catch return null;
        if (LocalVerificationType == .Long or LocalVerificationType == .Double) InitialSlots.append(AllocatorHandle, .Top) catch return null;
    }
    while (InitialSlots.items.len < Code.MaxLocals) InitialSlots.append(AllocatorHandle, .Top) catch return null;
    const States = TypeSimulator.Simulate(AllocatorHandle, &ClassFile.ConstantPool, Code.Instructions.items, Frames, InitialSlots.items, ClassFile.ThisClass) catch return null;
    const Provider = AllocatorHandle.alloc(?OpaquePlan, Blocks.len) catch return null;
    const Random = PseudoRandom.random();
    for (Blocks, 0..) |CurrentBlock, BlockIndex| {
        Provider[BlockIndex] = null;
        if (CurrentBlock.High >= Code.Instructions.items.len or CurrentBlock.High >= States.len) continue;
        const ExitState = States[CurrentBlock.High];
        if (ExitState.Stack.len != 0) continue;

        var SlotX: ?u16 = null;
        var SlotY: ?u16 = null;
        for (ExitState.Locals, 0..) |SlotVerificationType, SlotIndex| {
            if (SlotVerificationType == .Integer and SlotIndex <= 255) {
                if (SlotX == null) {
                    SlotX = @intCast(SlotIndex);
                } else if (SlotY == null) {
                    SlotY = @intCast(SlotIndex);
                    break;
                }
            }
        }
        if (SlotX == null) continue;
        const TwoVariable = SlotY != null;
        const TwoVarVariants = [_]u8{ 0, 1, 5 };
        const SingleVarVariants = [_]u8{ 2, 3, 4 };
        const Variant: u8 = if (TwoVariable) TwoVarVariants[Random.intRangeLessThan(usize, 0, TwoVarVariants.len)] else SingleVarVariants[Random.intRangeLessThan(usize, 0, SingleVarVariants.len)];
        const Key: i32 = Random.intRangeAtMost(i32, 2, 29999);

        var FalseTarget = Code.Instructions.items[CurrentBlock.High].Identifier;
        var MatchCount: usize = 0;
        for (Blocks, 0..) |CandidateBlock, CandidateIndex| {
            if (CandidateIndex == BlockIndex) continue;
            if (CandidateBlock.Low >= States.len) continue;
            const CandidateState = States[CandidateBlock.Low];
            if (CandidateState.Stack.len != 0) continue;
            if (!LocalsEqual(CandidateState.Locals, ExitState.Locals)) continue;
            MatchCount += 1;
            if (Random.intRangeLessThan(usize, 0, MatchCount) == 0) {
                FalseTarget = Code.Instructions.items[CandidateBlock.Low].Identifier;
            }
        }

        Provider[BlockIndex] = .{
            .SlotX = SlotX.?,
            .SlotY = SlotY orelse 0,
            .TwoVariable = TwoVariable,
            .Variant = Variant,
            .Key = Key,
            .FalseTarget = FalseTarget,
        };
    }
    return Provider;
}

fn Leaders(AllocatorHandle: std.mem.Allocator, Instructions: []const BytecodeInstructionModel.Instruction) ![]u32 {
    var LeaderList: std.ArrayList(u32) = .empty;
    if (Instructions.len == 0) return LeaderList.toOwnedSlice(AllocatorHandle);
    try LeaderList.append(AllocatorHandle, Instructions[0].Identifier);
    for (Instructions, 0..) |Instruction, Index| {
        var FlowBreak = false;
        switch (Instruction.Kind) {
            .Branch, .BranchWide => {
                try LeaderList.append(AllocatorHandle, Instruction.Target);
                FlowBreak = true;
            },
            .TableSwitch => {
                try LeaderList.append(AllocatorHandle, Instruction.SwitchDefault);
                for (Instruction.SwitchTargets) |Target| try LeaderList.append(AllocatorHandle, Target);
                FlowBreak = true;
            },
            .LookupSwitch => {
                try LeaderList.append(AllocatorHandle, Instruction.SwitchDefault);
                for (Instruction.SwitchPairs) |Pair| try LeaderList.append(AllocatorHandle, Pair.Target);
                FlowBreak = true;
            },
            .Fixed => {
                if (MethodControlFlowGraph.IsTerminator(Instruction.Operation)) FlowBreak = true;
            },
        }
        if (FlowBreak and Index + 1 < Instructions.len) try LeaderList.append(AllocatorHandle, Instructions[Index + 1].Identifier);
    }
    return LeaderList.toOwnedSlice(AllocatorHandle);
}

fn TransformMethodCode(
    AllocatorHandle: std.mem.Allocator,
    ClassFile: *ClassFileModel.ClassFile,
    Member: *ClassFileModel.MemberInfo,
    CodeInfo: []const u8,
    PseudoRandom: *std.Random.DefaultPrng,
    RegenerateStackMap: bool,
) !?[]u8 {
    var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfo);
    if (Code.Exceptions.items.len != 0) return null;
    const StackMapIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
    const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
    const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);

    var Frames: []StackMapTableCodec.Frame = &.{};
    var LeaderIdentifiers: []u32 = undefined;
    var InitialLocalsOptional: ?[]const StackMapTableCodec.VType = null;
    if (RegenerateStackMap) {
        const Index = StackMapIndex orelse return null;
        const MethodName = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
        const IsInit = std.mem.eql(u8, MethodName, "<init>") or std.mem.eql(u8, MethodName, "<clinit>");
        const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, IsInit);
        InitialLocalsOptional = InitialLocals;
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[Index].Info, Code.Instructions.items, InitialLocals);
        LeaderIdentifiers = try AllocatorHandle.alloc(u32, Frames.len);
        for (Frames, 0..) |Frame, FrameIndex| LeaderIdentifiers[FrameIndex] = Frame.Label;
    } else {
        if (StackMapIndex != null) return null;
        LeaderIdentifiers = try Leaders(AllocatorHandle, Code.Instructions.items);
    }

    const Blocks = try MethodControlFlowGraph.BuildBlocks(AllocatorHandle, Code.Instructions.items, LeaderIdentifiers);
    if (Blocks.len <= 2) return null;

    var Plans: ?[]?OpaquePlan = null;
    if (InitialLocalsOptional) |InitialLocals| Plans = BuildOpaquePlans(AllocatorHandle, ClassFile, &Code, Frames, InitialLocals, Blocks, PseudoRandom);

    Code.Instructions = try MethodControlFlowGraph.ShuffleBlocks(AllocatorHandle, &Code, Blocks, PseudoRandom, Plans);
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
    if (BytecodeInstructionModel.AssignOffsets(Code.Instructions.items) > 32767) return null;
    if (Plans != null) {
        if (MaxStackLocalsComputer.Compute(AllocatorHandle, &ClassFile.ConstantPool, &Code, Descriptor, IsStatic) catch null) |Maximums| {
            Code.MaxStack = @max(Code.MaxStack, Maximums.MaxStack);
        }
    }
    if (RegenerateStackMap) {
        Code.Attributes.items[StackMapIndex.?].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
    }
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
}

pub fn ShuffleControlFlow(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, PseudoRandom: *std.Random.DefaultPrng, RegenerateStackMap: bool) !usize {
    var Count: usize = 0;
    for (ClassFile.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        const Info = Member.Attributes.items[CodeAttributeIndex].Info;
        if (TransformMethodCode(AllocatorHandle, ClassFile, Member, Info, PseudoRandom, RegenerateStackMap) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
            Count += 1;
        }
    }
    return Count;
}

pub fn ControlFlowShuffler(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, PseudoRandom: *std.Random.DefaultPrng) !usize {
    return ShuffleControlFlow(AllocatorHandle, ClassFile, PseudoRandom, true);
}
