const std = @import("std");
const ConstantPoolBuilder = @import("ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("BytecodeInstructionModel.zig");

const ReadUnsignedShort = ConstantPoolBuilder.ReadUnsignedShort;
const WriteUnsignedShort = ConstantPoolBuilder.WriteUnsignedShort;

pub const VType = union(enum) {
    Top,
    Integer,
    Float,
    Double,
    Long,
    Null,
    UninitializedThis,
    Object: u16,
    Uninitialized: u32,
};

pub const Frame = struct {
    Label: u32,
    Locals: []VType,
    Stack: []VType,
};

fn ReadVerificationType(InfoBytes: []const u8, Position: *usize, OffsetToIdentifierMap: *std.AutoHashMap(u32, u32)) VType {
    const Tag = InfoBytes[Position.*];
    Position.* += 1;
    return switch (Tag) {
        0 => .Top,
        1 => .Integer,
        2 => .Float,
        3 => .Double,
        4 => .Long,
        5 => .Null,
        6 => .UninitializedThis,
        7 => ObjectBlock: {
            const ObjectIndex = ReadUnsignedShort(InfoBytes, Position.*);
            Position.* += 2;
            break :ObjectBlock .{ .Object = ObjectIndex };
        },
        8 => UninitializedBlock: {
            const ByteOffset = ReadUnsignedShort(InfoBytes, Position.*);
            Position.* += 2;
            break :UninitializedBlock .{ .Uninitialized = OffsetToIdentifierMap.get(ByteOffset).? };
        },
        else => .Top,
    };
}

fn ParseFieldType(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, Descriptor: []const u8, Index: *usize) !?VType {
    const TypeChar = Descriptor[Index.*];
    switch (TypeChar) {
        ')' => return null,
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
            const ClassIndex = try Pool.AddClass(Name);
            return .{ .Object = ClassIndex };
        },
        '[' => {
            const Start = Index.*;
            while (Descriptor[Index.*] == '[') Index.* += 1;
            if (Descriptor[Index.*] == 'L') {
                while (Descriptor[Index.*] != ';') Index.* += 1;
                Index.* += 1;
            } else {
                Index.* += 1;
            }
            const ArrayName = try AllocatorHandle.dupe(u8, Descriptor[Start..Index.*]);
            const ClassIndex = try Pool.AddClass(ArrayName);
            return .{ .Object = ClassIndex };
        },
        else => {
            Index.* += 1;
            return .Top;
        },
    }
}

pub fn ComputeInitialLocals(
    AllocatorHandle: std.mem.Allocator,
    Pool: *ConstantPoolBuilder.ConstantPool,
    Descriptor: []const u8,
    IsStatic: bool,
    ThisClass: u16,
    IsInit: bool,
) ![]VType {
    var Locals: std.ArrayList(VType) = .empty;
    if (!IsStatic) {
        if (IsInit) {
            try Locals.append(AllocatorHandle, .UninitializedThis);
        } else {
            try Locals.append(AllocatorHandle, .{ .Object = ThisClass });
        }
    }
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        const VerificationType = (try ParseFieldType(AllocatorHandle, Pool, Descriptor, &Index)) orelse break;
        try Locals.append(AllocatorHandle, VerificationType);
    }
    return Locals.toOwnedSlice(AllocatorHandle);
}

pub fn Parse(
    AllocatorHandle: std.mem.Allocator,
    Info: []const u8,
    Instructions: []const BytecodeInstructionModel.Instruction,
    InitialLocals: []const VType,
) ![]Frame {
    var OffsetToIdentifierMap = std.AutoHashMap(u32, u32).init(AllocatorHandle);
    defer OffsetToIdentifierMap.deinit();
    for (Instructions) |Instruction| try OffsetToIdentifierMap.put(Instruction.Offset, Instruction.Identifier);

    var RunningLocals: std.ArrayList(VType) = .empty;
    try RunningLocals.appendSlice(AllocatorHandle, InitialLocals);

    const Count = ReadUnsignedShort(Info, 0);
    var Position: usize = 2;
    var PreviousOffset: i64 = -1;
    var Frames: std.ArrayList(Frame) = .empty;

    var EntryIndex: usize = 0;
    while (EntryIndex < Count) : (EntryIndex += 1) {
        const FrameType = Info[Position];
        Position += 1;
        var Delta: u32 = 0;
        var Stack: []VType = &.{};
        if (FrameType <= 63) {
            Delta = FrameType;
        } else if (FrameType <= 127) {
            Delta = FrameType - 64;
            var StackList: std.ArrayList(VType) = .empty;
            try StackList.append(AllocatorHandle, ReadVerificationType(Info, &Position, &OffsetToIdentifierMap));
            Stack = StackList.items;
        } else if (FrameType == 247) {
            Delta = ReadUnsignedShort(Info, Position);
            Position += 2;
            var StackList: std.ArrayList(VType) = .empty;
            try StackList.append(AllocatorHandle, ReadVerificationType(Info, &Position, &OffsetToIdentifierMap));
            Stack = StackList.items;
        } else if (FrameType >= 248 and FrameType <= 250) {
            Delta = ReadUnsignedShort(Info, Position);
            Position += 2;
            const ChopCount = 251 - @as(usize, FrameType);
            if (ChopCount > RunningLocals.items.len) return error.BadStackMapFrame;
            RunningLocals.items.len -= ChopCount;
        } else if (FrameType == 251) {
            Delta = ReadUnsignedShort(Info, Position);
            Position += 2;
        } else if (FrameType >= 252 and FrameType <= 254) {
            Delta = ReadUnsignedShort(Info, Position);
            Position += 2;
            const AppendCount = @as(usize, FrameType) - 251;
            var InnerIndex: usize = 0;
            while (InnerIndex < AppendCount) : (InnerIndex += 1) try RunningLocals.append(AllocatorHandle, ReadVerificationType(Info, &Position, &OffsetToIdentifierMap));
        } else {
            Delta = ReadUnsignedShort(Info, Position);
            Position += 2;
            const LocalCount = ReadUnsignedShort(Info, Position);
            Position += 2;
            RunningLocals.clearRetainingCapacity();
            var InnerIndex: usize = 0;
            while (InnerIndex < LocalCount) : (InnerIndex += 1) try RunningLocals.append(AllocatorHandle, ReadVerificationType(Info, &Position, &OffsetToIdentifierMap));
            const StackCount = ReadUnsignedShort(Info, Position);
            Position += 2;
            var StackList: std.ArrayList(VType) = .empty;
            InnerIndex = 0;
            while (InnerIndex < StackCount) : (InnerIndex += 1) try StackList.append(AllocatorHandle, ReadVerificationType(Info, &Position, &OffsetToIdentifierMap));
            Stack = StackList.items;
        }

        const Offset: i64 = if (PreviousOffset < 0) @intCast(Delta) else PreviousOffset + @as(i64, Delta) + 1;
        PreviousOffset = Offset;
        const LabelIdentifier = OffsetToIdentifierMap.get(@intCast(Offset)).?;
        try Frames.append(AllocatorHandle, .{
            .Label = LabelIdentifier,
            .Locals = try AllocatorHandle.dupe(VType, RunningLocals.items),
            .Stack = try AllocatorHandle.dupe(VType, Stack),
        });
    }
    return Frames.toOwnedSlice(AllocatorHandle);
}

fn EmitVerificationType(Writer: *std.Io.Writer, VerificationType: VType, IdentifierToOffsetMap: *std.AutoHashMap(u32, u32)) !void {
    switch (VerificationType) {
        .Top => try Writer.writeByte(0),
        .Integer => try Writer.writeByte(1),
        .Float => try Writer.writeByte(2),
        .Double => try Writer.writeByte(3),
        .Long => try Writer.writeByte(4),
        .Null => try Writer.writeByte(5),
        .UninitializedThis => try Writer.writeByte(6),
        .Object => |ObjectIndex| {
            try Writer.writeByte(7);
            try WriteUnsignedShort(Writer, ObjectIndex);
        },
        .Uninitialized => |LabelIdentifier| {
            try Writer.writeByte(8);
            try WriteUnsignedShort(Writer, @intCast(IdentifierToOffsetMap.get(LabelIdentifier).?));
        },
    }
}

const FrameSortContext = struct {
    IdentifierOffset: *std.AutoHashMap(u32, u32),
    fn Less(Context: FrameSortContext, First: Frame, Second: Frame) bool {
        return Context.IdentifierOffset.get(First.Label).? < Context.IdentifierOffset.get(Second.Label).?;
    }
};

pub fn Regenerate(AllocatorHandle: std.mem.Allocator, Frames: []const Frame, Instructions: []const BytecodeInstructionModel.Instruction) ![]u8 {
    var IdentifierToOffsetMap = std.AutoHashMap(u32, u32).init(AllocatorHandle);
    defer IdentifierToOffsetMap.deinit();
    for (Instructions) |Instruction| try IdentifierToOffsetMap.put(Instruction.Identifier, Instruction.Offset);

    const SortedFrames = try AllocatorHandle.dupe(Frame, Frames);
    std.mem.sort(Frame, SortedFrames, FrameSortContext{ .IdentifierOffset = &IdentifierToOffsetMap }, FrameSortContext.Less);

    var Output = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, 64);
    const Writer = &Output.writer;
    try WriteUnsignedShort(Writer, @intCast(SortedFrames.len));
    var PreviousOffset: i64 = -1;
    for (SortedFrames) |FrameEntry| {
        const Offset: i64 = @intCast(IdentifierToOffsetMap.get(FrameEntry.Label).?);
        const Delta: u32 = if (PreviousOffset < 0) @intCast(Offset) else @intCast(Offset - PreviousOffset - 1);
        PreviousOffset = Offset;
        try Writer.writeByte(255);
        try WriteUnsignedShort(Writer, @intCast(Delta));
        try WriteUnsignedShort(Writer, @intCast(FrameEntry.Locals.len));
        for (FrameEntry.Locals) |VerificationType| try EmitVerificationType(Writer, VerificationType, &IdentifierToOffsetMap);
        try WriteUnsignedShort(Writer, @intCast(FrameEntry.Stack.len));
        for (FrameEntry.Stack) |VerificationType| try EmitVerificationType(Writer, VerificationType, &IdentifierToOffsetMap);
    }
    return Output.written();
}
