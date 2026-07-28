const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const NativeMethodBuilder = @import("../Native/NativeMethodBuilder.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

fn EncodeTwoBytes(AllocatorHandle: std.mem.Allocator, Value: u16) ![]u8 {
    const ResultBytes = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, ResultBytes[0..2], Value, .big);
    return ResultBytes;
}

fn EnsureLoaderInit(AllocatorHandle: std.mem.Allocator, ClassFileRef: *ClassFileModel.ClassFile, LoaderInternalName: []const u8) !void {
    const MethodReferenceIndex = try ClassFileRef.ConstantPool.AddMethodref(LoaderInternalName, "p", "()I");
    const CodeUtf8Index = try ClassFileRef.ConstantPool.AddUtf8("Code");
    for (ClassFileRef.Methods.items) |*Member| {
        if (!std.mem.eql(u8, ClassFileRef.ConstantPool.Utf8Text(Member.NameIndex), "<clinit>")) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFileRef.ConstantPool, "Code") orelse continue;
        var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Member.Attributes.items[CodeAttributeIndex].Info);
        var Frames: []StackMapTableCodec.Frame = &.{};
        const StackMapAttributeIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFileRef.ConstantPool, "StackMapTable");
        if (StackMapAttributeIndex) |AttributeIndex| {
            const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFileRef.ConstantPool, "()V", true, ClassFileRef.ThisClass, true);
            Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[AttributeIndex].Info, Code.Instructions.items, InitialLocals);
        }
        var MergedInstructions: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty;
        try MergedInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0xb8, .Kind = .Fixed, .Raw = try EncodeTwoBytes(AllocatorHandle, MethodReferenceIndex) });
        try MergedInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0x57, .Kind = .Fixed, .Raw = &.{} });
        for (Code.Instructions.items) |Instruction| try MergedInstructions.append(AllocatorHandle, Instruction);
        Code.Instructions = MergedInstructions;
        if (Code.MaxStack < 1) Code.MaxStack = 1;
        try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
        if (StackMapAttributeIndex) |AttributeIndex| Code.Attributes.items[AttributeIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
        Member.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
        return;
    }
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFileRef.ConstantPool);
    try AssemblerState.Invoke(0xb8, MethodReferenceIndex);
    try AssemblerState.Operation0(0x57);
    try AssemblerState.Operation0(0xb1);
    const MethodAttribute = try Assembler.BuildMethod(AllocatorHandle, &ClassFileRef.ConstantPool, try AssemblerState.Finish(), &.{}, "()V", true, CodeUtf8Index);
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, MethodAttribute);
    try ClassFileRef.Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic, .NameIndex = try ClassFileRef.ConstantPool.AddUtf8("<clinit>"), .DescriptorIndex = try ClassFileRef.ConstantPool.AddUtf8("()V"), .Attributes = Attributes });
}

fn Mangle(AllocatorHandle: std.mem.Allocator, Input: []const u8) ![]u8 {
    var Output: std.ArrayList(u8) = .empty;
    for (Input) |Character| {
        switch (Character) {
            '/' => try Output.append(AllocatorHandle, '_'),
            '_' => try Output.appendSlice(AllocatorHandle, "_1"),
            ';' => try Output.appendSlice(AllocatorHandle, "_2"),
            '[' => try Output.appendSlice(AllocatorHandle, "_3"),
            else => try Output.append(AllocatorHandle, Character),
        }
    }
    return Output.toOwnedSlice(AllocatorHandle);
}

fn IntegerConstant(ClassFileRef: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?i32 {
    return switch (Instruction.Operation) {
        0x02 => -1,
        0x03...0x08 => @as(i32, Instruction.Operation) - 0x03,
        0x10 => @as(i32, @as(i8, @bitCast(Instruction.Raw[0]))),
        0x11 => @as(i32, std.mem.readInt(i16, Instruction.Raw[0..2], .big)),
        0x12, 0x13 => Block: {
            const Index: u16 = if (Instruction.Operation == 0x12) Instruction.Raw[0] else ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (ClassFileRef.ConstantPool.TagOf(Index) != ConstantPoolBuilder.TagInteger) break :Block null;
            break :Block @bitCast(ConstantPoolBuilder.ReadUnsignedInt(ClassFileRef.ConstantPool.GetEntry(Index).Payload, 0));
        },
        else => null,
    };
}

fn LongConstant(ClassFileRef: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?i64 {
    return switch (Instruction.Operation) {
        0x09 => 0,
        0x0a => 1,
        0x14 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (ClassFileRef.ConstantPool.TagOf(Index) != ConstantPoolBuilder.TagLong) break :Block null;
            break :Block std.mem.readInt(i64, ClassFileRef.ConstantPool.GetEntry(Index).Payload[0..8], .big);
        },
        else => null,
    };
}

fn FloatConstant(ClassFileRef: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?u32 {
    return switch (Instruction.Operation) {
        0x0b => 0x00000000,
        0x0c => 0x3F800000,
        0x0d => 0x40000000,
        0x12, 0x13 => Block: {
            const Index: u16 = if (Instruction.Operation == 0x12) Instruction.Raw[0] else ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (ClassFileRef.ConstantPool.TagOf(Index) != ConstantPoolBuilder.TagFloat) break :Block null;
            break :Block ConstantPoolBuilder.ReadUnsignedInt(ClassFileRef.ConstantPool.GetEntry(Index).Payload, 0);
        },
        else => null,
    };
}

fn DoubleConstant(ClassFileRef: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?u64 {
    return switch (Instruction.Operation) {
        0x0e => 0x0000000000000000,
        0x0f => 0x3FF0000000000000,
        0x14 => Block: {
            const Index = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (ClassFileRef.ConstantPool.TagOf(Index) != ConstantPoolBuilder.TagDouble) break :Block null;
            break :Block std.mem.readInt(u64, ClassFileRef.ConstantPool.GetEntry(Index).Payload[0..8], .big);
        },
        else => null,
    };
}

fn Supported(ClassFileRef: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) bool {
    if (Instruction.Kind != .Fixed and Instruction.Kind != .Branch) return false;
    return switch (Instruction.Operation) {
        0x00, 0x57, 0x59, 0x5f => true,
        0x02...0x08, 0x10, 0x11 => true,
        0x12, 0x13 => IntegerConstant(ClassFileRef, Instruction) != null or FloatConstant(ClassFileRef, Instruction) != null,
        0x09, 0x0a => true,
        0x14 => LongConstant(ClassFileRef, Instruction) != null or DoubleConstant(ClassFileRef, Instruction) != null,
        0x0b, 0x0c, 0x0d, 0x0e, 0x0f => true,
        0x15, 0x1a...0x1d => true,
        0x16, 0x1e...0x21 => true,
        0x17, 0x22...0x25 => true,
        0x18, 0x26...0x29 => true,
        0x36, 0x3b...0x3e => true,
        0x37, 0x3f...0x42 => true,
        0x38, 0x43...0x46 => true,
        0x39, 0x47...0x4a => true,
        0x60, 0x64, 0x68, 0x6c, 0x70, 0x74 => true,
        0x61, 0x65, 0x69, 0x6d, 0x71, 0x75 => true,
        0x62, 0x66, 0x6a, 0x6e, 0x72, 0x76 => true,
        0x63, 0x67, 0x6b, 0x6f, 0x73, 0x77 => true,
        0x78, 0x7a, 0x7c, 0x7e, 0x80, 0x82 => true,
        0x79, 0x7b, 0x7d, 0x7f, 0x81, 0x83 => true,
        0x84 => true,
        0x85, 0x88, 0x91, 0x92, 0x93, 0x94 => true,
        0x86, 0x87, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90 => true,
        0x95, 0x96, 0x97, 0x98 => true,
        0x99...0x9e, 0x9f...0xa4 => true,
        0xa7, 0xac, 0xad, 0xae, 0xaf => true,
        else => false,
    };
}

fn IsNumericType(Character: u8) bool {
    return Character == 'I' or Character == 'J' or Character == 'F' or Character == 'D';
}

fn NumericDescriptor(Descriptor: []const u8) bool {
    if (Descriptor.len < 3 or Descriptor[0] != '(') return false;
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') : (Index += 1) {
        if (!IsNumericType(Descriptor[Index])) return false;
    }
    if (Index + 1 >= Descriptor.len) return false;
    return IsNumericType(Descriptor[Index + 1]) and Index + 2 == Descriptor.len;
}

fn ZigType(Character: u8) []const u8 {
    return switch (Character) {
        'J' => "i64",
        'F' => "f32",
        'D' => "f64",
        else => "i32",
    };
}

fn CompareOperator(Opcode: u8) []const u8 {
    return switch (Opcode) {
        0x99, 0x9f => "==",
        0x9a, 0xa0 => "!=",
        0x9b, 0xa1 => "<",
        0x9c, 0xa2 => ">=",
        0x9d, 0xa3 => ">",
        0x9e, 0xa4 => "<=",
        else => unreachable,
    };
}

fn WriteFormatted(AllocatorHandle: std.mem.Allocator, Output: *std.ArrayList(u8), comptime Format: []const u8, Arguments: anytype) !void {
    try Output.appendSlice(AllocatorHandle, try std.fmt.allocPrint(AllocatorHandle, Format, Arguments));
}

fn FloatSlot(AllocatorHandle: std.mem.Allocator, Offset: usize) ![]const u8 {
    return std.fmt.allocPrint(AllocatorHandle, "@as(f32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(st[sp-{d}]))))))", .{Offset});
}

fn DoubleSlot(AllocatorHandle: std.mem.Allocator, Offset: usize) ![]const u8 {
    return std.fmt.allocPrint(AllocatorHandle, "@as(f64, @bitCast(st[sp-{d}]))", .{Offset});
}

fn Transpile(AllocatorHandle: std.mem.Allocator, ClassFileRef: *ClassFileModel.ClassFile, Member: *ClassFileModel.MemberInfo, ExportName: []const u8) !?[]u8 {
    if ((Member.AccessFlags & AccessFlags.AccessStatic) == 0) return null;
    const Descriptor = ClassFileRef.ConstantPool.Utf8Text(Member.DescriptorIndex);
    if (!NumericDescriptor(Descriptor)) return null;
    const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFileRef.ConstantPool, "Code") orelse return null;
    const Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Member.Attributes.items[CodeAttributeIndex].Info);
    if (Code.Exceptions.items.len != 0) return null;
    const Instructions = Code.Instructions.items;
    if (Instructions.len == 0) return null;
    var UsesEnvironment = false;
    for (Instructions) |Instruction| {
        if (!Supported(ClassFileRef, Instruction)) return null;
        switch (Instruction.Operation) {
            0x6c, 0x70, 0x6d, 0x71 => UsesEnvironment = true,
            else => {},
        }
    }

    var CloseParen: usize = 1;
    while (Descriptor[CloseParen] != ')') CloseParen += 1;
    const ReturnChar = Descriptor[CloseParen + 1];
    const LocalCount = Code.MaxLocals;
    const StackSize = if (Code.MaxStack == 0) 1 else Code.MaxStack;

    var Output: std.ArrayList(u8) = .empty;
    try WriteFormatted(AllocatorHandle, &Output, "fn {s}(env: ?*anyopaque, cls: ?*anyopaque", .{ExportName});
    {
        var Index: usize = 1;
        var ArgumentIndex: usize = 0;
        while (Descriptor[Index] != ')') : (Index += 1) {
            try WriteFormatted(AllocatorHandle, &Output, ", a{d}: {s}", .{ ArgumentIndex, ZigType(Descriptor[Index]) });
            ArgumentIndex += 1;
        }
    }
    try WriteFormatted(AllocatorHandle, &Output, ") callconv(.c) {s} {{\n", .{ZigType(ReturnChar)});
    if (!UsesEnvironment) try Output.appendSlice(AllocatorHandle, "_ = env;\n");
    try Output.appendSlice(AllocatorHandle, "_ = cls;\n");
    try WriteFormatted(AllocatorHandle, &Output, "var st: [{d}]i64 = undefined; var sp: usize = 0; _ = &st; _ = &sp;\n", .{StackSize});
    try WriteFormatted(AllocatorHandle, &Output, "var L: [{d}]i64 = @splat(0); _ = &L;\n", .{LocalCount});
    {
        var Index: usize = 1;
        var ArgumentIndex: usize = 0;
        var Slot: u16 = 0;
        while (Descriptor[Index] != ')') : (Index += 1) {
            switch (Descriptor[Index]) {
                'J' => {
                    try WriteFormatted(AllocatorHandle, &Output, "L[{d}] = a{d};\n", .{ Slot, ArgumentIndex });
                    Slot += 2;
                },
                'D' => {
                    try WriteFormatted(AllocatorHandle, &Output, "L[{d}] = @bitCast(a{d});\n", .{ Slot, ArgumentIndex });
                    Slot += 2;
                },
                'F' => {
                    try WriteFormatted(AllocatorHandle, &Output, "L[{d}] = @as(i64, @as(u32, @bitCast(a{d})));\n", .{ Slot, ArgumentIndex });
                    Slot += 1;
                },
                else => {
                    try WriteFormatted(AllocatorHandle, &Output, "L[{d}] = @as(i64, a{d});\n", .{ Slot, ArgumentIndex });
                    Slot += 1;
                },
            }
            ArgumentIndex += 1;
        }
    }
    try WriteFormatted(AllocatorHandle, &Output, "var pc: u32 = {d};\n", .{Instructions[0].Identifier});
    try Output.appendSlice(AllocatorHandle, "while (true) { switch (pc) {\n");

    for (Instructions, 0..) |Instruction, Index| {
        const NextIdentifier: u32 = if (Index + 1 < Instructions.len) Instructions[Index + 1].Identifier else 0xFFFFFFFF;
        try WriteFormatted(AllocatorHandle, &Output, "{d} => {{ ", .{Instruction.Identifier});
        if (IntegerConstant(ClassFileRef, Instruction)) |ConstantValue| {
            try WriteFormatted(AllocatorHandle, &Output, "st[sp] = @as(i64, {d}); sp += 1; pc = {d};", .{ ConstantValue, NextIdentifier });
        } else if (FloatConstant(ClassFileRef, Instruction)) |ConstantBits| {
            try WriteFormatted(AllocatorHandle, &Output, "st[sp] = @as(i64, {d}); sp += 1; pc = {d};", .{ ConstantBits, NextIdentifier });
        } else if (LongConstant(ClassFileRef, Instruction)) |ConstantValue| {
            try WriteFormatted(AllocatorHandle, &Output, "st[sp] = {d}; sp += 2; pc = {d};", .{ ConstantValue, NextIdentifier });
        } else if (DoubleConstant(ClassFileRef, Instruction)) |ConstantBits| {
            try WriteFormatted(AllocatorHandle, &Output, "st[sp] = @bitCast(@as(u64, {d})); sp += 2; pc = {d};", .{ ConstantBits, NextIdentifier });
        } else switch (Instruction.Operation) {
            0x00 => try WriteFormatted(AllocatorHandle, &Output, "pc = {d};", .{NextIdentifier}),
            0x15 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 1; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x1a...0x1d => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 1; pc = {d};", .{ Instruction.Operation - 0x1a, NextIdentifier }),
            0x16 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 2; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x1e...0x21 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 2; pc = {d};", .{ Instruction.Operation - 0x1e, NextIdentifier }),
            0x36 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x3b...0x3e => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Operation - 0x3b, NextIdentifier }),
            0x37 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 2; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x3f...0x42 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 2; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Operation - 0x3f, NextIdentifier }),
            0x60 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) +% @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x64 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) -% @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x68 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) *% @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x6c => try WriteFormatted(AllocatorHandle, &Output, "if (@as(i32, @truncate(st[sp-1])) == 0) {{ JniNativeCore.ThrowArithmeticException(env); return 0; }} st[sp-2] = @as(i64, if (@as(i32, @truncate(st[sp-2])) == -2147483648 and @as(i32, @truncate(st[sp-1])) == -1) -2147483648 else @divTrunc(@as(i32, @truncate(st[sp-2])), @as(i32, @truncate(st[sp-1])))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x70 => try WriteFormatted(AllocatorHandle, &Output, "if (@as(i32, @truncate(st[sp-1])) == 0) {{ JniNativeCore.ThrowArithmeticException(env); return 0; }} st[sp-2] = @as(i64, if (@as(i32, @truncate(st[sp-2])) == -2147483648 and @as(i32, @truncate(st[sp-1])) == -1) 0 else @rem(@as(i32, @truncate(st[sp-2])), @as(i32, @truncate(st[sp-1])))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x7e => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) & @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x80 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) | @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x82 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) ^ @as(i32, @truncate(st[sp-1]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x78 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) << @as(u5, @intCast(@as(i32, @truncate(st[sp-1])) & 31))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x7a => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2])) >> @as(u5, @intCast(@as(i32, @truncate(st[sp-1])) & 31))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x7c => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @bitCast(@as(u32, @bitCast(@as(i32, @truncate(st[sp-2])))) >> @as(u5, @intCast(@as(i32, @truncate(st[sp-1])) & 31))))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x74 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, 0 -% @as(i32, @truncate(st[sp-1]))); pc = {d};", .{NextIdentifier}),
            0x61 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] +% st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x65 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] -% st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x69 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] *% st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x6d => try WriteFormatted(AllocatorHandle, &Output, "if (st[sp-2] == 0) {{ JniNativeCore.ThrowArithmeticException(env); return 0; }} st[sp-4] = if (st[sp-4] == -9223372036854775808 and st[sp-2] == -1) -9223372036854775808 else @divTrunc(st[sp-4], st[sp-2]); sp -= 2; pc = {d};", .{NextIdentifier}),
            0x71 => try WriteFormatted(AllocatorHandle, &Output, "if (st[sp-2] == 0) {{ JniNativeCore.ThrowArithmeticException(env); return 0; }} st[sp-4] = if (st[sp-4] == -9223372036854775808 and st[sp-2] == -1) 0 else @rem(st[sp-4], st[sp-2]); sp -= 2; pc = {d};", .{NextIdentifier}),
            0x7f => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] & st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x81 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] | st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x83 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = st[sp-4] ^ st[sp-2]; sp -= 2; pc = {d};", .{NextIdentifier}),
            0x75 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = 0 -% st[sp-2]; pc = {d};", .{NextIdentifier}),
            0x79 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-3] = st[sp-3] << @as(u6, @intCast(@as(i32, @truncate(st[sp-1])) & 63)); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x7b => try WriteFormatted(AllocatorHandle, &Output, "st[sp-3] = st[sp-3] >> @as(u6, @intCast(@as(i32, @truncate(st[sp-1])) & 63)); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x7d => try WriteFormatted(AllocatorHandle, &Output, "st[sp-3] = @bitCast(@as(u64, @bitCast(st[sp-3])) >> @as(u6, @intCast(@as(i32, @truncate(st[sp-1])) & 63))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x94 => try WriteFormatted(AllocatorHandle, &Output, "{{ const cl = st[sp-4]; const cr = st[sp-2]; st[sp-4] = if (cl < cr) -1 else if (cl > cr) 1 else 0; }} sp -= 3; pc = {d};", .{NextIdentifier}),
            0x85 => try WriteFormatted(AllocatorHandle, &Output, "sp += 1; pc = {d};", .{NextIdentifier}),
            0x88 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(i32, @truncate(st[sp-2]))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x91 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, @as(i32, @as(i8, @truncate(st[sp-1])))); pc = {d};", .{NextIdentifier}),
            0x92 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, @as(i32, @truncate(st[sp-1])) & 0xFFFF); pc = {d};", .{NextIdentifier}),
            0x93 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, @as(i32, @as(i16, @truncate(st[sp-1])))); pc = {d};", .{NextIdentifier}),
            0x84 => try WriteFormatted(AllocatorHandle, &Output, "L[{d}] = @as(i64, @as(i32, @truncate(L[{d}])) +% {d}); pc = {d};", .{ Instruction.Raw[0], Instruction.Raw[0], @as(i32, @as(i8, @bitCast(Instruction.Raw[1]))), NextIdentifier }),
            0x57 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; pc = {d};", .{NextIdentifier}),
            0x59 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = st[sp-1]; sp += 1; pc = {d};", .{NextIdentifier}),
            0x5f => try WriteFormatted(AllocatorHandle, &Output, "{{ const t = st[sp-1]; st[sp-1] = st[sp-2]; st[sp-2] = t; }} pc = {d};", .{NextIdentifier}),
            0xa7 => try WriteFormatted(AllocatorHandle, &Output, "pc = {d};", .{Instruction.Target}),
            0x99...0x9e => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; pc = if (@as(i32, @truncate(st[sp])) {s} 0) {d} else {d};", .{ CompareOperator(Instruction.Operation), Instruction.Target, NextIdentifier }),
            0x9f...0xa4 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 2; pc = if (@as(i32, @truncate(st[sp])) {s} @as(i32, @truncate(st[sp+1]))) {d} else {d};", .{ CompareOperator(Instruction.Operation), Instruction.Target, NextIdentifier }),
            0x17 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 1; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x22...0x25 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 1; pc = {d};", .{ Instruction.Operation - 0x22, NextIdentifier }),
            0x18 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 2; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x26...0x29 => try WriteFormatted(AllocatorHandle, &Output, "st[sp] = L[{d}]; sp += 2; pc = {d};", .{ Instruction.Operation - 0x26, NextIdentifier }),
            0x38 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x43...0x46 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 1; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Operation - 0x43, NextIdentifier }),
            0x39 => try WriteFormatted(AllocatorHandle, &Output, "sp -= 2; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Raw[0], NextIdentifier }),
            0x47...0x4a => try WriteFormatted(AllocatorHandle, &Output, "sp -= 2; L[{d}] = st[sp]; pc = {d};", .{ Instruction.Operation - 0x47, NextIdentifier }),
            0x62 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast({s} + {s}))); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x66 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast({s} - {s}))); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x6a => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast({s} * {s}))); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x6e => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast({s} / {s}))); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x72 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast(@rem({s}, {s})))); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x76 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, @as(u32, @truncate(@as(u64, @bitCast(st[sp-1])))) ^ 0x80000000); pc = {d};", .{NextIdentifier}),
            0x63 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @bitCast({s} + {s}); sp -= 2; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x67 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @bitCast({s} - {s}); sp -= 2; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x6b => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @bitCast({s} * {s}); sp -= 2; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x6f => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @bitCast({s} / {s}); sp -= 2; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x73 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @bitCast(@rem({s}, {s})); sp -= 2; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x77 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @bitCast(@as(u64, @bitCast(st[sp-2])) ^ 0x8000000000000000); pc = {d};", .{NextIdentifier}),
            0x86 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, @as(u32, @bitCast(@as(f32, @floatFromInt(@as(i32, @truncate(st[sp-1]))))))); pc = {d};", .{NextIdentifier}),
            0x87 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @bitCast(@as(f64, @floatFromInt(@as(i32, @truncate(st[sp-1]))))); sp += 1; pc = {d};", .{NextIdentifier}),
            0x89 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast(@as(f32, @floatFromInt(st[sp-2]))))); sp -= 1; pc = {d};", .{NextIdentifier}),
            0x8a => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @bitCast(@as(f64, @floatFromInt(st[sp-2]))); pc = {d};", .{NextIdentifier}),
            0x8b => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @as(i64, JniNativeCore.FloatToInt({s})); pc = {d};", .{ try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x8c => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = JniNativeCore.FloatToLong({s}); sp += 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x8d => try WriteFormatted(AllocatorHandle, &Output, "st[sp-1] = @bitCast(@as(f64, {s})); sp += 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x8e => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, JniNativeCore.DoubleToInt({s})); sp -= 1; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x8f => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = JniNativeCore.DoubleToLong({s}); pc = {d};", .{ try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x90 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, @as(u32, @bitCast(@as(f32, @floatCast({s}))))); sp -= 1; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x95 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, JniNativeCore.FloatCompare({s}, {s}, -1)); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x96 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-2] = @as(i64, JniNativeCore.FloatCompare({s}, {s}, 1)); sp -= 1; pc = {d};", .{ try FloatSlot(AllocatorHandle, 2), try FloatSlot(AllocatorHandle, 1), NextIdentifier }),
            0x97 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @as(i64, JniNativeCore.DoubleCompare({s}, {s}, -1)); sp -= 3; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0x98 => try WriteFormatted(AllocatorHandle, &Output, "st[sp-4] = @as(i64, JniNativeCore.DoubleCompare({s}, {s}, 1)); sp -= 3; pc = {d};", .{ try DoubleSlot(AllocatorHandle, 4), try DoubleSlot(AllocatorHandle, 2), NextIdentifier }),
            0xac => try Output.appendSlice(AllocatorHandle, "return @as(i32, @truncate(st[sp-1]));"),
            0xad => try Output.appendSlice(AllocatorHandle, "return st[sp-2];"),
            0xae => try Output.appendSlice(AllocatorHandle, "return @as(f32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(st[sp-1]))))));"),
            0xaf => try Output.appendSlice(AllocatorHandle, "return @as(f64, @bitCast(st[sp-2]));"),
            else => return null,
        }
        try Output.appendSlice(AllocatorHandle, " },\n");
    }
    try Output.appendSlice(AllocatorHandle, "else => unreachable,\n} }\n}\n");
    return try Output.toOwnedSlice(AllocatorHandle);
}

pub fn NativeMethodPass(AllocatorHandle: std.mem.Allocator, ClassFileRef: *ClassFileModel.ClassFile, BuilderRef: *NativeMethodBuilder.Builder, MappingRef: *const Mapping, LoaderInternalName: []const u8, PerClassLimit: usize) !usize {
    const ThisInternalName = ClassFileRef.ConstantPool.ClassName(ClassFileRef.ThisClass);
    const OwnerFinalName = MappingRef.RemapInternal(ThisInternalName) orelse ThisInternalName;
    const OwnerMangled = try Mangle(AllocatorHandle, OwnerFinalName);
    var Total: usize = 0;
    for (ClassFileRef.Methods.items) |*Member| {
        if (Total >= PerClassLimit) break;
        const MethodName = ClassFileRef.ConstantPool.Utf8Text(Member.NameIndex);
        if (std.mem.eql(u8, MethodName, "<init>") or std.mem.eql(u8, MethodName, "<clinit>")) continue;
        const MethodMangled = try Mangle(AllocatorHandle, MethodName);
        const ExportName = try std.fmt.allocPrint(AllocatorHandle, "Java_{s}_{s}", .{ OwnerMangled, MethodMangled });
        const GeneratedFunction = (try Transpile(AllocatorHandle, ClassFileRef, Member, ExportName)) orelse continue;
        const Descriptor = ClassFileRef.ConstantPool.Utf8Text(Member.DescriptorIndex);
        try BuilderRef.Add(GeneratedFunction, OwnerFinalName, MethodName, Descriptor, ExportName);
        Member.AccessFlags |= AccessFlags.AccessNative;
        Member.Attributes = .empty;
        Total += 1;
    }
    if (Total > 0) try EnsureLoaderInit(AllocatorHandle, ClassFileRef, LoaderInternalName);
    return Total;
}
