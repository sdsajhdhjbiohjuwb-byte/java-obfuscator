const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");

const List = std.ArrayList(BytecodeInstructionModel.Instruction);

const ConcatOwner = "java/lang/invoke/StringConcatFactory";

fn MakeTwoByteOperand(AllocatorHandle: std.mem.Allocator, Value: u16) ![]u8 {
    const ResultBytes = try AllocatorHandle.alloc(u8, 2);
    std.mem.writeInt(u16, ResultBytes[0..2], Value, .big);
    return ResultBytes;
}

const Bootstrap = struct { HandleReference: u16, Arguments: []u16 };

fn GetBootstrap(AllocatorHandle: std.mem.Allocator, BootstrapMethodsInfo: []const u8, BootstrapIndex: u16) !?Bootstrap {
    const BootstrapCount = ConstantPoolBuilder.ReadUnsignedShort(BootstrapMethodsInfo, 0);
    if (BootstrapIndex >= BootstrapCount) return null;
    var Offset: usize = 2;
    var Index: u16 = 0;
    while (Index < BootstrapIndex) : (Index += 1) {
        Offset += 2;
        const InnerArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(BootstrapMethodsInfo, Offset);
        Offset += 2 + @as(usize, InnerArgumentCount) * 2;
    }
    const HandleReference = ConstantPoolBuilder.ReadUnsignedShort(BootstrapMethodsInfo, Offset);
    Offset += 2;
    const ArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(BootstrapMethodsInfo, Offset);
    Offset += 2;
    var Arguments = try AllocatorHandle.alloc(u16, ArgumentCount);
    var InnerIndex: usize = 0;
    while (InnerIndex < ArgumentCount) : (InnerIndex += 1) {
        Arguments[InnerIndex] = ConstantPoolBuilder.ReadUnsignedShort(BootstrapMethodsInfo, Offset);
        Offset += 2;
    }
    return .{ .HandleReference = HandleReference, .Arguments = Arguments };
}

const ParameterType = enum { Integer, Long, Float, Double, String, Object };

fn ParameterAppendReference(Pool: *ConstantPoolBuilder.ConstantPool, Parameter: ParameterType) !u16 {
    return switch (Parameter) {
        .Integer => Pool.AddMethodref("java/lang/StringBuilder", "append", "(I)Ljava/lang/StringBuilder;"),
        .Long => Pool.AddMethodref("java/lang/StringBuilder", "append", "(J)Ljava/lang/StringBuilder;"),
        .Float => Pool.AddMethodref("java/lang/StringBuilder", "append", "(F)Ljava/lang/StringBuilder;"),
        .Double => Pool.AddMethodref("java/lang/StringBuilder", "append", "(D)Ljava/lang/StringBuilder;"),
        .String => Pool.AddMethodref("java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;"),
        .Object => Pool.AddMethodref("java/lang/StringBuilder", "append", "(Ljava/lang/Object;)Ljava/lang/StringBuilder;"),
    };
}

fn LoadOperation(Parameter: ParameterType) u8 {
    return switch (Parameter) {
        .Integer => 0x15,
        .Long => 0x16,
        .Float => 0x17,
        .Double => 0x18,
        .String, .Object => 0x19,
    };
}

fn StoreOperation(Parameter: ParameterType) u8 {
    return switch (Parameter) {
        .Integer => 0x36,
        .Long => 0x37,
        .Float => 0x38,
        .Double => 0x39,
        .String, .Object => 0x3a,
    };
}

fn Width(Parameter: ParameterType) u16 {
    return switch (Parameter) {
        .Long, .Double => 2,
        else => 1,
    };
}

fn ParseParameters(AllocatorHandle: std.mem.Allocator, Descriptor: []const u8) ![]ParameterType {
    var ParameterList: std.ArrayList(ParameterType) = .empty;
    var Index: usize = 1;
    while (Descriptor[Index] != ')') {
        switch (Descriptor[Index]) {
            'B', 'C', 'I', 'S', 'Z' => {
                try ParameterList.append(AllocatorHandle, .Integer);
                Index += 1;
            },
            'J' => {
                try ParameterList.append(AllocatorHandle, .Long);
                Index += 1;
            },
            'F' => {
                try ParameterList.append(AllocatorHandle, .Float);
                Index += 1;
            },
            'D' => {
                try ParameterList.append(AllocatorHandle, .Double);
                Index += 1;
            },
            'L' => {
                const Start = Index;
                while (Descriptor[Index] != ';') Index += 1;
                Index += 1;
                try ParameterList.append(AllocatorHandle, if (std.mem.eql(u8, Descriptor[Start..Index], "Ljava/lang/String;")) .String else .Object);
            },
            '[' => {
                while (Descriptor[Index] == '[') Index += 1;
                if (Descriptor[Index] == 'L') {
                    while (Descriptor[Index] != ';') Index += 1;
                }
                Index += 1;
                try ParameterList.append(AllocatorHandle, .Object);
            },
            else => return error.BadDescriptor,
        }
    }
    return ParameterList.toOwnedSlice(AllocatorHandle);
}

const Concat = struct { RecipeUtf8: ?u16, Descriptor: []const u8 };

fn DetectConcat(ClassFileHandle: *ClassFileModel.ClassFile, BootstrapMethodsInfo: []const u8, InvokeDynamicIndex: u16, AllocatorHandle: std.mem.Allocator) !?Concat {
    if (ClassFileHandle.ConstantPool.TagOf(InvokeDynamicIndex) != ConstantPoolBuilder.TagInvokeDynamic) return null;
    const Payload = ClassFileHandle.ConstantPool.Entries.items[InvokeDynamicIndex].Payload;
    const BootstrapAttributeIndex = ConstantPoolBuilder.ReadUnsignedShort(Payload, 0);
    const NameAndTypeIndex = ConstantPoolBuilder.ReadUnsignedShort(Payload, 2);
    const Descriptor = ClassFileHandle.ConstantPool.Utf8Text(ClassFileHandle.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
    const BootstrapEntry = (try GetBootstrap(AllocatorHandle, BootstrapMethodsInfo, BootstrapAttributeIndex)) orelse return null;
    if (ClassFileHandle.ConstantPool.TagOf(BootstrapEntry.HandleReference) != ConstantPoolBuilder.TagMethodHandle) return null;
    const MethodHandlePayload = ClassFileHandle.ConstantPool.Entries.items[BootstrapEntry.HandleReference].Payload;
    const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(MethodHandlePayload, 1);
    if (ClassFileHandle.ConstantPool.TagOf(ReferenceIndex) != ConstantPoolBuilder.TagMethodref) return null;
    const OwnerName = ClassFileHandle.ConstantPool.ClassName(ClassFileHandle.ConstantPool.RefClassIndex(ReferenceIndex));
    if (!std.mem.eql(u8, OwnerName, ConcatOwner)) return null;
    const MethodName = ClassFileHandle.ConstantPool.Utf8Text(ClassFileHandle.ConstantPool.NameAndTypeName(ClassFileHandle.ConstantPool.RefNameAndTypeIndex(ReferenceIndex)));
    if (std.mem.eql(u8, MethodName, "makeConcat")) return .{ .RecipeUtf8 = null, .Descriptor = Descriptor };
    if (std.mem.eql(u8, MethodName, "makeConcatWithConstants")) {
        if (BootstrapEntry.Arguments.len < 1 or ClassFileHandle.ConstantPool.TagOf(BootstrapEntry.Arguments[0]) != ConstantPoolBuilder.TagString) return null;
        return .{ .RecipeUtf8 = ClassFileHandle.ConstantPool.RefIndex(BootstrapEntry.Arguments[0]), .Descriptor = Descriptor };
    }
    return null;
}

fn AppendLoad(AllocatorHandle: std.mem.Allocator, Output: *List, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, Parameter: ParameterType, Slot: u16) !void {
    const RawByte = try AllocatorHandle.alloc(u8, 1);
    RawByte[0] = @intCast(Slot);
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, LoadOperation(Parameter), RawByte));
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0xb6, try MakeTwoByteOperand(AllocatorHandle, try ParameterAppendReference(Pool, Parameter))));
}

fn AppendString(AllocatorHandle: std.mem.Allocator, Output: *List, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, Bytes: []const u8) !void {
    const StringIndex = try Pool.AddString(Bytes);
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x13, try MakeTwoByteOperand(AllocatorHandle, StringIndex)));
    const AppendMethodReference = try Pool.AddMethodref("java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;");
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0xb6, try MakeTwoByteOperand(AllocatorHandle, AppendMethodReference)));
}

fn EmitConcat(AllocatorHandle: std.mem.Allocator, Output: *List, CodeAttribute: *BytecodeInstructionModel.CodeAttribute, ClassFileHandle: *ClassFileModel.ClassFile, ConcatInfo: Concat, BaseSlot: u16) !void {
    const Parameters = try ParseParameters(AllocatorHandle, ConcatInfo.Descriptor);
    const StringBuilderClass = try ClassFileHandle.ConstantPool.AddClass("java/lang/StringBuilder");
    const StringBuilderInit = try ClassFileHandle.ConstantPool.AddMethodref("java/lang/StringBuilder", "<init>", "()V");
    const StringBuilderToString = try ClassFileHandle.ConstantPool.AddMethodref("java/lang/StringBuilder", "toString", "()Ljava/lang/String;");

    var Slots = try AllocatorHandle.alloc(u16, Parameters.len);
    var SlotCursor: u16 = BaseSlot;
    for (Parameters, 0..) |Parameter, Index| {
        Slots[Index] = SlotCursor;
        SlotCursor += Width(Parameter);
    }

    var InnerIndex: usize = Parameters.len;
    while (InnerIndex > 0) {
        InnerIndex -= 1;
        const RawByte = try AllocatorHandle.alloc(u8, 1);
        RawByte[0] = @intCast(Slots[InnerIndex]);
        try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, StoreOperation(Parameters[InnerIndex]), RawByte));
    }

    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0xbb, try MakeTwoByteOperand(AllocatorHandle, StringBuilderClass)));
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0x59, &.{}));
    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0xb7, try MakeTwoByteOperand(AllocatorHandle, StringBuilderInit)));

    if (ConcatInfo.RecipeUtf8) |RecipeUtf8Index| {
        const Recipe = ClassFileHandle.ConstantPool.Utf8Text(RecipeUtf8Index);
        var ArgumentIndex: usize = 0;
        var RunStart: usize = 0;
        var Index: usize = 0;
        while (Index <= Recipe.len) : (Index += 1) {
            const AtEnd = Index == Recipe.len;
            if (AtEnd or Recipe[Index] == 0x01) {
                if (Index > RunStart) try AppendString(AllocatorHandle, Output, CodeAttribute, &ClassFileHandle.ConstantPool, Recipe[RunStart..Index]);
                if (!AtEnd) {
                    try AppendLoad(AllocatorHandle, Output, CodeAttribute, &ClassFileHandle.ConstantPool, Parameters[ArgumentIndex], Slots[ArgumentIndex]);
                    ArgumentIndex += 1;
                    RunStart = Index + 1;
                }
            }
        }
    } else {
        for (Parameters, 0..) |Parameter, Index| try AppendLoad(AllocatorHandle, Output, CodeAttribute, &ClassFileHandle.ConstantPool, Parameter, Slots[Index]);
    }

    try Output.append(AllocatorHandle, BytecodeInstructionModel.MakeFixedInstruction(CodeAttribute, 0xb6, try MakeTwoByteOperand(AllocatorHandle, StringBuilderToString)));
    if (ConcatInfo.RecipeUtf8) |RecipeIndex| try ClassFileHandle.ConstantPool.SetUtf8Content(RecipeIndex, &.{});
}

fn TransformMethod(AllocatorHandle: std.mem.Allocator, ClassFileHandle: *ClassFileModel.ClassFile, Member: *ClassFileModel.MemberInfo, CodeInfo: []const u8, BootstrapMethodsInfo: []const u8) !?[]u8 {
    var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfo);

    var AnyConcat = false;
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Kind == .Fixed and Instruction.Operation == 0xba) {
            if ((try DetectConcat(ClassFileHandle, BootstrapMethodsInfo, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), AllocatorHandle)) != null) {
                if ((try DetectConcatRecipeHasConstant(ClassFileHandle, BootstrapMethodsInfo, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), AllocatorHandle))) continue;
                AnyConcat = true;
            }
        }
    }
    if (!AnyConcat) return null;

    var Frames: []StackMapTableCodec.Frame = &.{};
    const StackMapAttributeIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFileHandle.ConstantPool, "StackMapTable");
    if (StackMapAttributeIndex) |AttributeIndex| {
        const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
        const MethodName = ClassFileHandle.ConstantPool.Utf8Text(Member.NameIndex);
        const IsInit = std.mem.eql(u8, MethodName, "<init>") or std.mem.eql(u8, MethodName, "<clinit>");
        const Descriptor = ClassFileHandle.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFileHandle.ConstantPool, Descriptor, IsStatic, ClassFileHandle.ThisClass, IsInit);
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[AttributeIndex].Info, Code.Instructions.items, InitialLocals);
    }

    const BaseSlot = Code.MaxLocals;
    var MaxExtra: u16 = 0;
    var Output: List = .empty;
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Kind == .Fixed and Instruction.Operation == 0xba) {
            if (try DetectConcat(ClassFileHandle, BootstrapMethodsInfo, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), AllocatorHandle)) |ConcatInfo| {
                if (!(try DetectConcatRecipeHasConstant(ClassFileHandle, BootstrapMethodsInfo, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), AllocatorHandle))) {
                    const Start = Output.items.len;
                    try EmitConcat(AllocatorHandle, &Output, &Code, ClassFileHandle, ConcatInfo, BaseSlot);
                    Output.items[Start].Identifier = Instruction.Identifier;
                    const Parameters = try ParseParameters(AllocatorHandle, ConcatInfo.Descriptor);
                    var TotalWidth: u16 = 0;
                    for (Parameters) |Parameter| TotalWidth += Width(Parameter);
                    if (TotalWidth > MaxExtra) MaxExtra = TotalWidth;
                    continue;
                }
            }
        }
        try Output.append(AllocatorHandle, Instruction);
    }
    Code.Instructions = Output;
    Code.MaxLocals = BaseSlot + MaxExtra;
    Code.MaxStack += 4;

    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
    if (StackMapAttributeIndex) |AttributeIndex| Code.Attributes.items[AttributeIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
}

fn DetectConcatRecipeHasConstant(ClassFileHandle: *ClassFileModel.ClassFile, BootstrapMethodsInfo: []const u8, InvokeDynamicIndex: u16, AllocatorHandle: std.mem.Allocator) !bool {
    const ConcatInfo = (try DetectConcat(ClassFileHandle, BootstrapMethodsInfo, InvokeDynamicIndex, AllocatorHandle)) orelse return true;
    const RecipeUtf8Index = ConcatInfo.RecipeUtf8 orelse return false;
    const Recipe = ClassFileHandle.ConstantPool.Utf8Text(RecipeUtf8Index);
    for (Recipe) |Byte| {
        if (Byte == 0x02) return true;
    }
    return false;
}

pub fn DeindyConcatPass(AllocatorHandle: std.mem.Allocator, ClassFileHandle: *ClassFileModel.ClassFile) !usize {
    const BootstrapAttributeIndex = ClassFileModel.FindAttribute(ClassFileHandle.Attributes.items, &ClassFileHandle.ConstantPool, "BootstrapMethods") orelse return 0;
    const BootstrapMethodsInfo = ClassFileHandle.Attributes.items[BootstrapAttributeIndex].Info;
    var Count: usize = 0;
    for (ClassFileHandle.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFileHandle.ConstantPool, "Code") orelse continue;
        if (TransformMethod(AllocatorHandle, ClassFileHandle, Member, Member.Attributes.items[CodeAttributeIndex].Info, BootstrapMethodsInfo) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
            Count += 1;
        }
    }
    return Count;
}
