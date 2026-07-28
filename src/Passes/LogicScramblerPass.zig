const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const MaxStackLocalsComputer = @import("../Classfile/MaxStackLocalsComputer.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const RuntimeConfig = @import("../Pipeline/RuntimeConfig.zig");
const AccessFlags = @import("../Classfile/AccessFlags.zig");

const Instruction = BytecodeInstructionModel.Instruction;
const CodeAttribute = BytecodeInstructionModel.CodeAttribute;
const ConstantPool = ConstantPoolBuilder.ConstantPool;
const InstructionList = std.ArrayList(Instruction);

const ValueType = enum { Int, Long };
const BinaryOperator = enum { Xor, Or, And, Add, Sub };

const NodeTag = enum { Leaf, Constant, Complement, ShiftLeft, Binary, Multiply };

const Node = struct {
    Tag: NodeTag,
    Type: ValueType,
    Slot: u16 = 0,
    IntConstant: i32 = 0,
    LongConstant: i64 = 0,
    Operator: BinaryOperator = .Xor,
    ShiftAmount: u8 = 1,
    Left: ?*Node = null,
    Right: ?*Node = null,
    Child: ?*Node = null,
};

const OperandTerm = struct {
    Operator: BinaryOperator,
    ComplementA: bool = false,
    ComplementB: bool = false,
    Shift: u8 = 0,
};

const IdentityShape = struct { Connector: BinaryOperator, Left: OperandTerm, Right: OperandTerm };

fn IdentityTable(Operator: BinaryOperator) []const IdentityShape {
    return switch (Operator) {
        .Xor => &.{
            .{ .Connector = .Sub, .Left = .{ .Operator = .Or }, .Right = .{ .Operator = .And } },
            .{ .Connector = .Or, .Left = .{ .Operator = .And, .ComplementB = true }, .Right = .{ .Operator = .And, .ComplementA = true } },
            .{ .Connector = .Sub, .Left = .{ .Operator = .Add }, .Right = .{ .Operator = .And, .Shift = 1 } },
            .{ .Connector = .Add, .Left = .{ .Operator = .And, .ComplementB = true }, .Right = .{ .Operator = .And, .ComplementA = true } },
            .{ .Connector = .And, .Left = .{ .Operator = .Or }, .Right = .{ .Operator = .Or, .ComplementA = true, .ComplementB = true } },
        },
        .Or => &.{
            .{ .Connector = .Add, .Left = .{ .Operator = .And }, .Right = .{ .Operator = .Xor } },
            .{ .Connector = .Sub, .Left = .{ .Operator = .Add }, .Right = .{ .Operator = .And } },
            .{ .Connector = .Add, .Left = .{ .Operator = .Xor }, .Right = .{ .Operator = .And } },
            .{ .Connector = .Or, .Left = .{ .Operator = .Xor }, .Right = .{ .Operator = .And } },
        },
        .And => &.{
            .{ .Connector = .Sub, .Left = .{ .Operator = .Or }, .Right = .{ .Operator = .Xor } },
            .{ .Connector = .Sub, .Left = .{ .Operator = .Add }, .Right = .{ .Operator = .Or } },
        },
        .Add => &.{
            .{ .Connector = .Add, .Left = .{ .Operator = .Xor }, .Right = .{ .Operator = .And, .Shift = 1 } },
            .{ .Connector = .Add, .Left = .{ .Operator = .Or }, .Right = .{ .Operator = .And } },
            .{ .Connector = .Add, .Left = .{ .Operator = .And, .Shift = 1 }, .Right = .{ .Operator = .Xor } },
            .{ .Connector = .Sub, .Left = .{ .Operator = .Or, .Shift = 1 }, .Right = .{ .Operator = .Xor } },
        },
        .Sub => &.{
            .{ .Connector = .Sub, .Left = .{ .Operator = .Xor }, .Right = .{ .Operator = .And, .ComplementA = true, .Shift = 1 } },
            .{ .Connector = .Sub, .Left = .{ .Operator = .And, .ComplementB = true }, .Right = .{ .Operator = .And, .ComplementA = true } },
        },
    };
}

fn IdentityFor(Operator: BinaryOperator, Random: std.Random) IdentityShape {
    const Table = IdentityTable(Operator);
    return Table[Random.intRangeLessThan(usize, 0, Table.len)];
}

fn Allocate(AllocatorHandle: std.mem.Allocator, Value: Node) !*Node {
    const Pointer = try AllocatorHandle.create(Node);
    Pointer.* = Value;
    return Pointer;
}

fn LeafNode(AllocatorHandle: std.mem.Allocator, Type: ValueType, Slot: u16) !*Node {
    return Allocate(AllocatorHandle, .{ .Tag = .Leaf, .Type = Type, .Slot = Slot });
}

fn ComplementNode(AllocatorHandle: std.mem.Allocator, Child: *Node) !*Node {
    return Allocate(AllocatorHandle, .{ .Tag = .Complement, .Type = Child.Type, .Child = Child });
}

fn ShiftLeftNode(AllocatorHandle: std.mem.Allocator, Child: *Node, Amount: u8) !*Node {
    return Allocate(AllocatorHandle, .{ .Tag = .ShiftLeft, .Type = Child.Type, .Child = Child, .ShiftAmount = Amount });
}

fn BinaryNode(AllocatorHandle: std.mem.Allocator, Operator: BinaryOperator, Left: *Node, Right: *Node) !*Node {
    return Allocate(AllocatorHandle, .{ .Tag = .Binary, .Type = Left.Type, .Operator = Operator, .Left = Left, .Right = Right });
}

fn MultiplyNode(AllocatorHandle: std.mem.Allocator, Left: *Node, Right: *Node) !*Node {
    return Allocate(AllocatorHandle, .{ .Tag = .Multiply, .Type = Left.Type, .Left = Left, .Right = Right });
}

fn NonLinearBlind(AllocatorHandle: std.mem.Allocator, Root: *Node, LeafA: *Node, LeafB: *Node) !*Node {
    const OrTerm = try BinaryNode(AllocatorHandle, .Or, LeafA, LeafB);
    const XorTerm = try BinaryNode(AllocatorHandle, .Xor, LeafA, LeafB);
    const AndTerm = try BinaryNode(AllocatorHandle, .And, LeafA, LeafB);
    const Difference = try BinaryNode(AllocatorHandle, .Sub, OrTerm, XorTerm);
    const ZeroExpression = try BinaryNode(AllocatorHandle, .Sub, Difference, AndTerm);
    const Product = try MultiplyNode(AllocatorHandle, ZeroExpression, LeafA);
    return BinaryNode(AllocatorHandle, .Add, Root, Product);
}

fn BuildTerm(AllocatorHandle: std.mem.Allocator, Random: std.Random, Term: OperandTerm, LeafA: *Node, LeafB: *Node, Type: ValueType, Depth: u8) !*Node {
    const OperandA = if (Term.ComplementA) try ComplementNode(AllocatorHandle, LeafA) else LeafA;
    const OperandB = if (Term.ComplementB) try ComplementNode(AllocatorHandle, LeafB) else LeafB;
    var Result = if (Depth > 0 and Random.boolean())
        try BuildExpression(AllocatorHandle, Random, Term.Operator, OperandA, OperandB, Type, Depth - 1)
    else
        try BinaryNode(AllocatorHandle, Term.Operator, OperandA, OperandB);
    if (Term.Shift > 0) Result = try ShiftLeftNode(AllocatorHandle, Result, Term.Shift);
    return Result;
}

fn BuildExpression(AllocatorHandle: std.mem.Allocator, Random: std.Random, Operator: BinaryOperator, LeafA: *Node, LeafB: *Node, Type: ValueType, Depth: u8) error{OutOfMemory}!*Node {
    const Identity = IdentityFor(Operator, Random);
    const Left = try BuildTerm(AllocatorHandle, Random, Identity.Left, LeafA, LeafB, Type, Depth);
    const Right = try BuildTerm(AllocatorHandle, Random, Identity.Right, LeafA, LeafB, Type, Depth);
    return BinaryNode(AllocatorHandle, Identity.Connector, Left, Right);
}

fn BlindExpression(AllocatorHandle: std.mem.Allocator, Random: std.Random, Root: *Node, Type: ValueType) !*Node {
    const UseXor = Random.boolean();
    var FirstConstant = Node{ .Tag = .Constant, .Type = Type };
    var SecondConstant = Node{ .Tag = .Constant, .Type = Type };
    if (Type == .Int) {
        const Value = Random.int(i32);
        FirstConstant.IntConstant = Value;
        SecondConstant.IntConstant = Value;
    } else {
        const Value = Random.int(i64);
        FirstConstant.LongConstant = Value;
        SecondConstant.LongConstant = Value;
    }
    const FirstPointer = try Allocate(AllocatorHandle, FirstConstant);
    const SecondPointer = try Allocate(AllocatorHandle, SecondConstant);
    if (UseXor) {
        const Inner = try BinaryNode(AllocatorHandle, .Xor, Root, FirstPointer);
        return BinaryNode(AllocatorHandle, .Xor, Inner, SecondPointer);
    }
    const Inner = try BinaryNode(AllocatorHandle, .Add, Root, FirstPointer);
    return BinaryNode(AllocatorHandle, .Sub, Inner, SecondPointer);
}

fn BinaryOpcode(Operator: BinaryOperator, Type: ValueType) u8 {
    return switch (Type) {
        .Int => switch (Operator) {
            .Xor => 0x82,
            .Or => 0x80,
            .And => 0x7e,
            .Add => 0x60,
            .Sub => 0x64,
        },
        .Long => switch (Operator) {
            .Xor => 0x83,
            .Or => 0x81,
            .And => 0x7f,
            .Add => 0x61,
            .Sub => 0x65,
        },
    };
}

fn EmitZeroOperand(AllocatorHandle: std.mem.Allocator, Output: *InstructionList, Code: *CodeAttribute, Opcode: u8) !void {
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, Opcode, &.{}));
}

fn EmitSlot(AllocatorHandle: std.mem.Allocator, Output: *InstructionList, Code: *CodeAttribute, Opcode: u8, Slot: u16) !void {
    const Raw = try AllocatorHandle.alloc(u8, 1);
    Raw[0] = @intCast(Slot);
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, Opcode, Raw));
}

fn EmitLongConstant(AllocatorHandle: std.mem.Allocator, Output: *InstructionList, Code: *CodeAttribute, Pool: *ConstantPool, Value: i64) !void {
    const Index = try Pool.AddLong(Value);
    const Raw = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, Raw[0..2], Index, .big);
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(Code, 0x14, Raw));
}

fn EmitNode(AllocatorHandle: std.mem.Allocator, Output: *InstructionList, Code: *CodeAttribute, Pool: *ConstantPool, TreeNode: *Node) error{OutOfMemory}!void {
    switch (TreeNode.Tag) {
        .Leaf => try EmitSlot(AllocatorHandle, Output, Code, if (TreeNode.Type == .Int) 0x15 else 0x16, TreeNode.Slot),
        .Constant => {
            if (TreeNode.Type == .Int)
                try BytecodeInstructionModel.PushInteger(AllocatorHandle, Output, Code, Pool, TreeNode.IntConstant)
            else
                try EmitLongConstant(AllocatorHandle, Output, Code, Pool, TreeNode.LongConstant);
        },
        .Complement => {
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Child.?);
            try EmitZeroOperand(AllocatorHandle, Output, Code, 0x02);
            if (TreeNode.Type == .Int) {
                try EmitZeroOperand(AllocatorHandle, Output, Code, 0x82);
            } else {
                try EmitZeroOperand(AllocatorHandle, Output, Code, 0x85);
                try EmitZeroOperand(AllocatorHandle, Output, Code, 0x83);
            }
        },
        .ShiftLeft => {
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Child.?);
            try BytecodeInstructionModel.PushInteger(AllocatorHandle, Output, Code, Pool, @as(i32, TreeNode.ShiftAmount));
            try EmitZeroOperand(AllocatorHandle, Output, Code, if (TreeNode.Type == .Int) 0x78 else 0x79);
        },
        .Binary => {
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Left.?);
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Right.?);
            try EmitZeroOperand(AllocatorHandle, Output, Code, BinaryOpcode(TreeNode.Operator, TreeNode.Type));
        },
        .Multiply => {
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Left.?);
            try EmitNode(AllocatorHandle, Output, Code, Pool, TreeNode.Right.?);
            try EmitZeroOperand(AllocatorHandle, Output, Code, if (TreeNode.Type == .Int) 0x68 else 0x69);
        },
    }
}

fn ClassifyOperation(Opcode: u8) ?struct { Operator: BinaryOperator, Type: ValueType } {
    return switch (Opcode) {
        0x82 => .{ .Operator = .Xor, .Type = .Int },
        0x80 => .{ .Operator = .Or, .Type = .Int },
        0x7e => .{ .Operator = .And, .Type = .Int },
        0x60 => .{ .Operator = .Add, .Type = .Int },
        0x64 => .{ .Operator = .Sub, .Type = .Int },
        0x83 => .{ .Operator = .Xor, .Type = .Long },
        0x81 => .{ .Operator = .Or, .Type = .Long },
        0x7f => .{ .Operator = .And, .Type = .Long },
        0x61 => .{ .Operator = .Add, .Type = .Long },
        0x65 => .{ .Operator = .Sub, .Type = .Long },
        else => null,
    };
}

fn EmitExpansion(AllocatorHandle: std.mem.Allocator, Random: std.Random, Output: *InstructionList, Code: *CodeAttribute, Pool: *ConstantPool, Operator: BinaryOperator, Type: ValueType, BaseSlot: u16, Depth: u8) !void {
    if (Type == .Int) {
        try EmitSlot(AllocatorHandle, Output, Code, 0x36, BaseSlot + 1);
        try EmitSlot(AllocatorHandle, Output, Code, 0x36, BaseSlot);
    } else {
        try EmitSlot(AllocatorHandle, Output, Code, 0x37, BaseSlot + 2);
        try EmitSlot(AllocatorHandle, Output, Code, 0x37, BaseSlot);
    }
    const LeafA = try LeafNode(AllocatorHandle, Type, BaseSlot);
    const LeafB = try LeafNode(AllocatorHandle, Type, if (Type == .Int) BaseSlot + 1 else BaseSlot + 2);
    var Tree = try BuildExpression(AllocatorHandle, Random, Operator, LeafA, LeafB, Type, Depth);
    if (Random.boolean()) Tree = try BlindExpression(AllocatorHandle, Random, Tree, Type);
    if (Random.boolean()) Tree = try NonLinearBlind(AllocatorHandle, Tree, LeafA, LeafB);
    try EmitNode(AllocatorHandle, Output, Code, Pool, Tree);
}

fn TransformMethod(AllocatorHandle: std.mem.Allocator, ClassFileRef: *ClassFileModel.ClassFile, Member: *ClassFileModel.MemberInfo, CodeInfoBytes: []const u8, Random: std.Random) !?[]u8 {
    var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfoBytes);
    if (Code.Instructions.items.len > RuntimeConfig.Active.Passes.LogicScrambler.MaxInstructionsGuard) return null;
    const BaseSlot = Code.MaxLocals;
    if (@as(usize, BaseSlot) + 4 > 255) return null;
    const MethodName = ClassFileRef.ConstantPool.Utf8Text(Member.NameIndex);
    const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
    const Descriptor = ClassFileRef.ConstantPool.Utf8Text(Member.DescriptorIndex);

    var Frames: []StackMapTableCodec.Frame = &.{};
    const StackMapAttributeIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFileRef.ConstantPool, "StackMapTable");
    if (StackMapAttributeIndex) |AttributeIndex| {
        const IsClinit = std.mem.eql(u8, MethodName, "<clinit>");
        const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFileRef.ConstantPool, Descriptor, IsStatic, ClassFileRef.ThisClass, IsClinit);
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[AttributeIndex].Info, Code.Instructions.items, InitialLocals);
    }

    var Output: InstructionList = .empty;
    var Changed = false;
    var Budget: usize = RuntimeConfig.Active.Passes.LogicScrambler.MaxOps;
    const Depth = RuntimeConfig.Active.Passes.LogicScrambler.MaxDepth;

    for (Code.Instructions.items) |CurrentInstruction| {
        const ShouldExpand = Budget > 0 and CurrentInstruction.Kind == .Fixed and Random.intRangeAtMost(u8, 0, 99) < RuntimeConfig.Active.Passes.LogicScrambler.MbaProbability;
        if (ShouldExpand) {
            if (ClassifyOperation(CurrentInstruction.Operation)) |Classified| {
                const StartIndex = Output.items.len;
                try EmitExpansion(AllocatorHandle, Random, &Output, &Code, &ClassFileRef.ConstantPool, Classified.Operator, Classified.Type, BaseSlot, Depth);
                Output.items[StartIndex].Identifier = CurrentInstruction.Identifier;
                Changed = true;
                Budget -= 1;
                continue;
            }
            if (CurrentInstruction.Operation == 0x92) {
                const StartIndex = Output.items.len;
                try BytecodeInstructionModel.PushInteger(AllocatorHandle, &Output, &Code, &ClassFileRef.ConstantPool, 0xFFFF);
                try EmitZeroOperand(AllocatorHandle, &Output, &Code, 0x7e);
                Output.items[StartIndex].Identifier = CurrentInstruction.Identifier;
                Changed = true;
                Budget -= 1;
                continue;
            }
        }
        try Output.append(AllocatorHandle, CurrentInstruction);
    }

    if (!Changed) return null;
    Code.Instructions = Output;
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
    const Maximums = try MaxStackLocalsComputer.Compute(AllocatorHandle, &ClassFileRef.ConstantPool, &Code, Descriptor, IsStatic);
    Code.MaxStack = Maximums.MaxStack;
    Code.MaxLocals = Maximums.MaxLocals;
    if (StackMapAttributeIndex) |AttributeIndex| Code.Attributes.items[AttributeIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
}

pub fn LogicScramblerPass(AllocatorHandle: std.mem.Allocator, ClassFileRef: *ClassFileModel.ClassFile, RandomGenerator: *std.Random.DefaultPrng) !usize {
    const Random = RandomGenerator.random();
    var Count: usize = 0;
    for (ClassFileRef.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFileRef.ConstantPool, "Code") orelse continue;
        const CodeInfo = Member.Attributes.items[CodeAttributeIndex].Info;
        if (TransformMethod(AllocatorHandle, ClassFileRef, Member, CodeInfo, Random) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
            Count += 1;
        }
    }

    if (RuntimeConfig.Active.Passes.LogicScrambler.SyntheticFlags) {
        for (ClassFileRef.Methods.items) |*Member| {
            const MethodName = ClassFileRef.ConstantPool.Utf8Text(Member.NameIndex);
            if (std.mem.eql(u8, MethodName, "<init>") or std.mem.eql(u8, MethodName, "<clinit>")) continue;
            Member.AccessFlags |= AccessFlags.AccessSynthetic;
        }
    }
    return Count;
}

test "mba identities are exact over the ring" {
    const Evaluate = struct {
        fn Operate(Op: BinaryOperator, X: i32, Y: i32) i32 {
            return switch (Op) { .Xor => X ^ Y, .Or => X | Y, .And => X & Y, .Add => X +% Y, .Sub => X -% Y };
        }
        fn Term(T: OperandTerm, A: i32, B: i32) i32 {
            const OperandA = if (T.ComplementA) ~A else A;
            const OperandB = if (T.ComplementB) ~B else B;
            var Result = Operate(T.Operator, OperandA, OperandB);
            if (T.Shift > 0) Result = Result *% (@as(i32, 1) << @as(u5, @intCast(T.Shift)));
            return Result;
        }
        fn Identity(Shape: IdentityShape, A: i32, B: i32) i32 {
            return Operate(Shape.Connector, Term(Shape.Left, A, B), Term(Shape.Right, A, B));
        }
    };
    const Operators = [_]BinaryOperator{ .Xor, .Or, .And, .Add, .Sub };
    const Edges = [_]i32{ 0, 1, -1, 2, -2, std.math.maxInt(i32), std.math.minInt(i32), 305419896, -1412567295, 1431655765, 1073741824 };
    for (Operators) |Op| {
        for (IdentityTable(Op)) |Shape| {
            for (Edges) |A| {
                for (Edges) |B| {
                    try std.testing.expectEqual(Evaluate.Operate(Op, A, B), Evaluate.Identity(Shape, A, B));
                }
            }
        }
    }
    var Seed: u32 = 0x9E3779B9;
    var Trials: usize = 0;
    while (Trials < 20000) : (Trials += 1) {
        Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
        const A: i32 = @bitCast(Seed);
        Seed = Seed *% 0x6C078965 +% 0x85EBCA6B;
        const B: i32 = @bitCast(Seed);
        for (Operators) |Op| {
            for (IdentityTable(Op)) |Shape| {
                try std.testing.expectEqual(Evaluate.Operate(Op, A, B), Evaluate.Identity(Shape, A, B));
            }
        }
    }
}

test "non-linear zero-blind is exact over the ring" {
    const Edges32 = [_]i32{ 0, 1, -1, 2, -2, std.math.maxInt(i32), std.math.minInt(i32), 305419896, -1412567295, 1431655765, 1073741824 };
    for (Edges32) |A| {
        for (Edges32) |Root| {
            for (Edges32) |B| {
                const Zero = ((A | B) -% (A ^ B)) -% (A & B);
                try std.testing.expectEqual(@as(i32, 0), Zero);
                try std.testing.expectEqual(Root, Root +% (Zero *% A));
            }
        }
    }
    const Edges64 = [_]i64{ 0, 1, -1, 2, -2, std.math.maxInt(i64), std.math.minInt(i64), 0x0123456789ABCDEF, -0x0011223344556677, 0x5555555555555555 };
    for (Edges64) |A| {
        for (Edges64) |Root| {
            for (Edges64) |B| {
                const Zero = ((A | B) -% (A ^ B)) -% (A & B);
                try std.testing.expectEqual(@as(i64, 0), Zero);
                try std.testing.expectEqual(Root, Root +% (Zero *% A));
            }
        }
    }
    var Seed: u64 = 0x243F6A8885A308D3;
    var Trials: usize = 0;
    while (Trials < 20000) : (Trials += 1) {
        Seed = Seed *% 0x6C078965D2C1B3C6 +% 0x85EBCA6B7F4A7C15;
        const A: i64 = @bitCast(Seed);
        Seed = Seed *% 0x6C078965D2C1B3C6 +% 0x85EBCA6B7F4A7C15;
        const B: i64 = @bitCast(Seed);
        Seed = Seed *% 0x6C078965D2C1B3C6 +% 0x85EBCA6B7F4A7C15;
        const Root: i64 = @bitCast(Seed);
        const Zero = ((A | B) -% (A ^ B)) -% (A & B);
        try std.testing.expectEqual(@as(i64, 0), Zero);
        try std.testing.expectEqual(Root, Root +% (Zero *% A));
    }
}
