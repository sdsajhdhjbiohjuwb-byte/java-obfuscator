const std = @import("std");
const ClassFileModel = @import("ClassFileModel.zig");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("BytecodeInstructionModel.zig");
const MaxStackLocalsComputer = @import("MaxStackLocalsComputer.zig");

const TableSwitchFixup = struct { InstructionIndex: usize, DefaultName: []const u8, Names: [][]const u8 };

pub const AssemblerState = struct {
    Allocator: std.mem.Allocator,
    ConstantPool: *ConstantPoolBuilder.ConstantPool,
    List: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty,
    Labels: std.StringHashMap(u32),
    BranchFixups: std.ArrayList(struct { Index: usize, Name: []const u8 }) = .empty,
    TableSwitchFixups: std.ArrayList(TableSwitchFixup) = .empty,

    pub fn Initialize(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool) AssemblerState {
        return .{ .Allocator = AllocatorHandle, .ConstantPool = Pool, .Labels = std.StringHashMap(u32).init(AllocatorHandle) };
    }
    pub fn Here(Self: *AssemblerState) u32 {
        return @intCast(Self.List.items.len);
    }
    pub fn Raw(Self: *AssemblerState, Opcode: u8, Bytes: []u8) !void {
        try Self.List.append(Self.Allocator, .{ .Identifier = Self.Here(), .Operation = Opcode, .Kind = .Fixed, .Raw = Bytes });
    }
    pub fn Operation0(Self: *AssemblerState, Opcode: u8) !void {
        try Self.Raw(Opcode, &.{});
    }
    pub fn Operation1(Self: *AssemblerState, Opcode: u8, ByteValue: u8) !void {
        const ScratchBuffer = try Self.Allocator.alloc(u8, 1);
        ScratchBuffer[0] = ByteValue;
        try Self.Raw(Opcode, ScratchBuffer);
    }
    pub fn Operation2(Self: *AssemblerState, Opcode: u8, Value: u16) !void {
        const ScratchBuffer = try Self.Allocator.alloc(u8, 2);
        std.mem.writeInt(u16, ScratchBuffer[0..2], Value, .big);
        try Self.Raw(Opcode, ScratchBuffer);
    }
    pub fn Iload(Self: *AssemblerState, SlotIndex: u8) !void {
        try Self.Operation1(0x15, SlotIndex);
    }
    pub fn Istore(Self: *AssemblerState, SlotIndex: u8) !void {
        try Self.Operation1(0x36, SlotIndex);
    }
    pub fn Aload(Self: *AssemblerState, SlotIndex: u8) !void {
        try Self.Operation1(0x19, SlotIndex);
    }
    pub fn Astore(Self: *AssemblerState, SlotIndex: u8) !void {
        try Self.Operation1(0x3a, SlotIndex);
    }
    pub fn Iinc(Self: *AssemblerState, IndexOperand: u8, Increment: i8) !void {
        const ScratchBuffer = try Self.Allocator.alloc(u8, 2);
        ScratchBuffer[0] = IndexOperand;
        ScratchBuffer[1] = @bitCast(Increment);
        try Self.Raw(0x84, ScratchBuffer);
    }
    pub fn Ldci(Self: *AssemblerState, Value: i32) !void {
        try Self.Operation2(0x13, try Self.ConstantPool.AddInteger(Value));
    }
    pub fn Iconst(Self: *AssemblerState, Value: i32) !void {
        if (Value >= -1 and Value <= 5) {
            try Self.Operation0(@intCast(0x03 + Value));
        } else if (Value >= -128 and Value <= 127) {
            try Self.Operation1(0x10, @bitCast(@as(i8, @intCast(Value))));
        } else if (Value >= -32768 and Value <= 32767) {
            const ScratchBuffer = try Self.Allocator.alloc(u8, 2);
            std.mem.writeInt(i16, ScratchBuffer[0..2], @intCast(Value), .big);
            try Self.Raw(0x11, ScratchBuffer);
        } else try Self.Ldci(Value);
    }
    pub fn Invoke(Self: *AssemblerState, Opcode: u8, ReferenceIndex: u16) !void {
        try Self.Operation2(Opcode, ReferenceIndex);
    }
    pub fn NewarrayInt(Self: *AssemblerState) !void {
        try Self.Operation1(0xbc, 10);
    }
    pub fn Label(Self: *AssemblerState, LabelName: []const u8) !void {
        try Self.Labels.put(LabelName, Self.Here());
    }
    pub fn Branch(Self: *AssemblerState, Opcode: u8, LabelName: []const u8) !void {
        const InstructionIndex = Self.List.items.len;
        try Self.List.append(Self.Allocator, .{ .Identifier = Self.Here(), .Operation = Opcode, .Kind = .Branch, .Target = 0 });
        try Self.BranchFixups.append(Self.Allocator, .{ .Index = InstructionIndex, .Name = LabelName });
    }
    pub fn Goto(Self: *AssemblerState, LabelName: []const u8) !void {
        try Self.Branch(0xa7, LabelName);
    }
    pub fn TableSwitch(Self: *AssemblerState, LowValue: i32, HighValue: i32, DefaultLabelName: []const u8, LabelNames: [][]const u8) !void {
        const InstructionIndex = Self.List.items.len;
        try Self.List.append(Self.Allocator, .{ .Identifier = Self.Here(), .Operation = 0xaa, .Kind = .TableSwitch, .SwitchLow = LowValue, .SwitchHigh = HighValue, .SwitchDefault = 0, .SwitchTargets = try Self.Allocator.alloc(u32, LabelNames.len) });
        try Self.TableSwitchFixups.append(Self.Allocator, .{ .InstructionIndex = InstructionIndex, .DefaultName = DefaultLabelName, .Names = LabelNames });
    }
    pub fn Finish(Self: *AssemblerState) ![]BytecodeInstructionModel.Instruction {
        for (Self.BranchFixups.items) |Fixup| {
            Self.List.items[Fixup.Index].Target = Self.Labels.get(Fixup.Name).?;
        }
        for (Self.TableSwitchFixups.items) |TableFixup| {
            Self.List.items[TableFixup.InstructionIndex].SwitchDefault = Self.Labels.get(TableFixup.DefaultName).?;
            const TargetSlice = Self.List.items[TableFixup.InstructionIndex].SwitchTargets;
            for (TableFixup.Names, 0..) |LabelName, Index| TargetSlice[Index] = Self.Labels.get(LabelName).?;
        }
        return Self.List.items;
    }
    pub fn LabelIdentifier(Self: *AssemblerState, LabelName: []const u8) u32 {
        return Self.Labels.get(LabelName).?;
    }
};

pub fn BuildMethod(
    AllocatorHandle: std.mem.Allocator,
    Pool: *ConstantPoolBuilder.ConstantPool,
    Instructions: []BytecodeInstructionModel.Instruction,
    Exceptions: []BytecodeInstructionModel.ExceptionEntry,
    Descriptor: []const u8,
    IsStatic: bool,
    CodeUtf8Index: u16,
) !ClassFileModel.Attribute {
    var CodeAttribute = BytecodeInstructionModel.CodeAttribute{ .MaxStack = 0, .MaxLocals = 0, .Instructions = .empty, .Exceptions = .empty, .Attributes = .empty, .NextIdentifier = 0 };
    CodeAttribute.Instructions.items = Instructions;
    CodeAttribute.Instructions.capacity = Instructions.len;
    CodeAttribute.Exceptions.items = Exceptions;
    CodeAttribute.Exceptions.capacity = Exceptions.len;
    var MaxNextIdentifier: u32 = 0;
    for (Instructions) |Instruction| {
        if (Instruction.Identifier < 0x10000000 and Instruction.Identifier + 1 > MaxNextIdentifier) MaxNextIdentifier = Instruction.Identifier + 1;
    }
    CodeAttribute.NextIdentifier = MaxNextIdentifier;
    const MaxStackLocals = try MaxStackLocalsComputer.Compute(AllocatorHandle, Pool, &CodeAttribute, Descriptor, IsStatic);
    CodeAttribute.MaxStack = if (Exceptions.len > 0 and MaxStackLocals.MaxStack < 1) 1 else MaxStackLocals.MaxStack;
    CodeAttribute.MaxLocals = MaxStackLocals.MaxLocals;
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &CodeAttribute.Instructions);
    return .{ .NameIndex = CodeUtf8Index, .Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &CodeAttribute) };
}
