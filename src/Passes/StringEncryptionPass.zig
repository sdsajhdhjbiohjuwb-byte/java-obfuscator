const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const ConstantPoolTransformer = @import("../Classfile/ConstantPoolTransformer.zig");
const NativeCipher = @import("../Native/NativeCipher.zig");
const ModifiedUtf8 = @import("../Classfile/ModifiedUtf8.zig");
const DescriptorUtil = @import("../Classfile/DescriptorUtil.zig");
const StringBootstrapSynthesizer = @import("StringBootstrapSynthesizer.zig");
const IdentifierGenerator = @import("IdentifierGenerator.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

const InvokeDynamicDescriptor = "()Ljava/lang/String;";

fn BuildStructuralSet(AllocatorHandle: std.mem.Allocator, ClassFile: *const ClassFileModel.ClassFile) ![]bool {
    const PoolCount = ClassFile.ConstantPool.Count();
    const StructuralSet = try AllocatorHandle.alloc(bool, PoolCount);
    @memset(StructuralSet, false);
    var Index: u16 = 1;
    while (Index < PoolCount) : (Index += 1) {
        const Entry = ClassFile.ConstantPool.Entries.items[Index];
        switch (Entry.Tag) {
            ConstantPoolBuilder.TagClass, ConstantPoolBuilder.TagMethodType => StructuralSet[ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 0)] = true,
            ConstantPoolBuilder.TagNameAndType => {
                StructuralSet[ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 0)] = true;
                StructuralSet[ConstantPoolBuilder.ReadUnsignedShort(Entry.Payload, 2)] = true;
            },
            else => {},
        }
    }
    for (ClassFile.Fields.items) |Field| {
        StructuralSet[Field.NameIndex] = true;
        StructuralSet[Field.DescriptorIndex] = true;
        for (Field.Attributes.items) |AttributeItem| StructuralSet[AttributeItem.NameIndex] = true;
    }
    for (ClassFile.Methods.items) |Method| {
        StructuralSet[Method.NameIndex] = true;
        StructuralSet[Method.DescriptorIndex] = true;
        for (Method.Attributes.items) |AttributeItem| {
            StructuralSet[AttributeItem.NameIndex] = true;
            if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(AttributeItem.NameIndex), "Code")) {
                const ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, AttributeItem.Info);
                for (ParsedCode.Attributes.items) |CodeAttributeItem| StructuralSet[CodeAttributeItem.NameIndex] = true;
            }
        }
    }
    for (ClassFile.Attributes.items) |AttributeItem| StructuralSet[AttributeItem.NameIndex] = true;
    return StructuralSet;
}

fn CollectBootstrapStringArguments(AllocatorHandle: std.mem.Allocator, ClassFile: *const ClassFileModel.ClassFile) !std.AutoHashMap(u16, void) {
    var StringArgumentSet = std.AutoHashMap(u16, void).init(AllocatorHandle);
    const BootstrapAttributeIndex = ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods") orelse return StringArgumentSet;
    const AttributeInfo = ClassFile.Attributes.items[BootstrapAttributeIndex].Info;
    const MethodCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, 0);
    var Offset: usize = 2;
    var Index: usize = 0;
    while (Index < MethodCount) : (Index += 1) {
        Offset += 2;
        const ArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, Offset);
        Offset += 2;
        var InnerIndex: usize = 0;
        while (InnerIndex < ArgumentCount) : (InnerIndex += 1) {
            const Argument = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, Offset);
            if (ClassFile.ConstantPool.TagOf(Argument) == ConstantPoolBuilder.TagString) try StringArgumentSet.put(Argument, {});
            Offset += 2;
        }
    }
    return StringArgumentSet;
}

fn LdcStringConstant(ClassFile: *const ClassFileModel.ClassFile, Instruction: BytecodeInstructionModel.Instruction) ?u16 {
    if (Instruction.Kind != .Fixed) return null;
    const PoolIndex: u16 = if (Instruction.Operation == 0x12) Instruction.Raw[0] else if (Instruction.Operation == 0x13) ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0) else return null;
    if (ClassFile.ConstantPool.TagOf(PoolIndex) != ConstantPoolBuilder.TagString) return null;
    return PoolIndex;
}

const StringInfo = struct { Offset: i32, Length: i32, Salt: i32, Nonce: i32 };

const ConcatOwner = "java/lang/invoke/StringConcatFactory";

fn BootstrapMethodEntry(AttributeInfo: []const u8, EntryIndex: u16) ?struct { Handle: u16, Arguments: []const u8 } {
    const EntryCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, 0);
    if (EntryIndex >= EntryCount) return null;
    var Offset: usize = 2;
    var Index: u16 = 0;
    while (Index < EntryIndex) : (Index += 1) {
        Offset += 2;
        const EntryArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, Offset);
        Offset += 2 + @as(usize, EntryArgumentCount) * 2;
    }
    const HandleIndex = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, Offset);
    Offset += 2;
    const ArgumentCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, Offset);
    Offset += 2;
    return .{ .Handle = HandleIndex, .Arguments = AttributeInfo[Offset .. Offset + @as(usize, ArgumentCount) * 2] };
}

const ConcatSite = struct { Recipe: []const u8, RecipeUtf8: ?u16 };

fn CollectConcatSites(AllocatorHandle: std.mem.Allocator, ClassFile: *const ClassFileModel.ClassFile) !std.AutoHashMap(u16, ConcatSite) {
    var SiteMap = std.AutoHashMap(u16, ConcatSite).init(AllocatorHandle);
    const BootstrapAttributeIndex = ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods") orelse return SiteMap;
    const AttributeInfo = ClassFile.Attributes.items[BootstrapAttributeIndex].Info;
    var PoolIndex: u16 = 1;
    const PoolCount = ClassFile.ConstantPool.Count();
    while (PoolIndex < PoolCount) : (PoolIndex += 1) {
        if (ClassFile.ConstantPool.TagOf(PoolIndex) != ConstantPoolBuilder.TagInvokeDynamic) continue;
        const Payload = ClassFile.ConstantPool.Entries.items[PoolIndex].Payload;
        const BootstrapAttributeNumber = ConstantPoolBuilder.ReadUnsignedShort(Payload, 0);
        const NameAndTypeIndex = ConstantPoolBuilder.ReadUnsignedShort(Payload, 2);
        const Entry = BootstrapMethodEntry(AttributeInfo, BootstrapAttributeNumber) orelse continue;
        if (ClassFile.ConstantPool.TagOf(Entry.Handle) != ConstantPoolBuilder.TagMethodHandle) continue;
        const MethodReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(ClassFile.ConstantPool.Entries.items[Entry.Handle].Payload, 1);
        if (ClassFile.ConstantPool.TagOf(MethodReferenceIndex) != ConstantPoolBuilder.TagMethodref) continue;
        const OwnerName = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(MethodReferenceIndex));
        if (!std.mem.eql(u8, OwnerName, ConcatOwner)) continue;
        const MethodName = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(ClassFile.ConstantPool.RefNameAndTypeIndex(MethodReferenceIndex)));
        const Descriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
        var Recipe: []const u8 = undefined;
        var RecipeUtf8Index: ?u16 = null;
        if (std.mem.eql(u8, MethodName, "makeConcat")) {
            const ParameterTotal = DescriptorUtil.ParameterCount(Descriptor);
            const RecipeBuffer = try AllocatorHandle.alloc(u8, ParameterTotal);
            @memset(RecipeBuffer, 0x01);
            Recipe = RecipeBuffer;
        } else if (std.mem.eql(u8, MethodName, "makeConcatWithConstants")) {
            if (Entry.Arguments.len < 2) continue;
            const RecipeStringIndex = ConstantPoolBuilder.ReadUnsignedShort(Entry.Arguments, 0);
            if (ClassFile.ConstantPool.TagOf(RecipeStringIndex) != ConstantPoolBuilder.TagString) continue;
            const RecipeUtf8Reference = ClassFile.ConstantPool.RefIndex(RecipeStringIndex);
            const RecipeText = ClassFile.ConstantPool.Utf8Text(RecipeUtf8Reference);
            if (std.mem.indexOfScalar(u8, RecipeText, 0x02) != null) continue;
            Recipe = RecipeText;
            RecipeUtf8Index = RecipeUtf8Reference;
        } else continue;
        try SiteMap.put(PoolIndex, .{ .Recipe = Recipe, .RecipeUtf8 = RecipeUtf8Index });
    }
    return SiteMap;
}

fn MemberNameInUse(ClassFile: *const ClassFileModel.ClassFile, CandidateName: []const u8) bool {
    for (ClassFile.Fields.items) |Field| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Field.NameIndex), CandidateName)) return true;
    }
    for (ClassFile.Methods.items) |Method| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Method.NameIndex), CandidateName)) return true;
    }
    return false;
}

fn PushInteger(AssemblerState: *Assembler.AssemblerState, Value: i32) !void {
    try AssemblerState.Iconst(Value);
}

fn EncryptInto(AllocatorHandle: std.mem.Allocator, CipherBytes: *std.ArrayList(u8), Units: []const u16, Salt: i32, CallerKey: i32, Nonce: i32, CipherSecrets: NativeCipher.Secrets) !StringInfo {
    const Offset: i32 = @intCast(CipherBytes.items.len);
    for (Units, 0..) |Unit, InnerIndex| {
        const HighByte: u8 = @intCast(Unit >> 8);
        const LowByte: u8 = @intCast(Unit & 0xFF);
        try CipherBytes.append(AllocatorHandle, HighByte ^ NativeCipher.KeystreamByte(@intCast(2 * InnerIndex), Salt, CallerKey, Nonce, CipherSecrets));
        try CipherBytes.append(AllocatorHandle, LowByte ^ NativeCipher.KeystreamByte(@intCast(2 * InnerIndex + 1), Salt, CallerKey, Nonce, CipherSecrets));
    }
    return .{ .Offset = Offset, .Length = @intCast(Units.len * 2), .Salt = Salt, .Nonce = Nonce };
}

pub fn StringEncryptionPass(
    AllocatorHandle: std.mem.Allocator,
    ClassFile: *ClassFileModel.ClassFile,
    BootstrapInternalName: []const u8,
    NameMapping: Mapping,
    RandomGenerator: *std.Random.DefaultPrng,
    CipherSecrets: NativeCipher.Secrets,
) !usize {
    const StructuralSet = try BuildStructuralSet(AllocatorHandle, ClassFile);
    var ProtectedStrings = try CollectBootstrapStringArguments(AllocatorHandle, ClassFile);
    defer ProtectedStrings.deinit();

    const ThisInternalName = ClassFile.ConstantPool.ClassName(ClassFile.ThisClass);
    const FinalInternalName = NameMapping.RemapInternal(ThisInternalName) orelse ThisInternalName;
    const CallerKey = try ModifiedUtf8.CallerKey(AllocatorHandle, FinalInternalName);

    var ConcatSites = try CollectConcatSites(AllocatorHandle, ClassFile);
    var ConcatInfoMap = std.AutoHashMap(u16, StringInfo).init(AllocatorHandle);

    var InfoByUtf8Map = std.AutoHashMap(u16, StringInfo).init(AllocatorHandle);
    var CipherBytes: std.ArrayList(u8) = .empty;

    for (ClassFile.Methods.items) |*Method| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        const ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
        for (ParsedCode.Instructions.items) |Instruction| {
            const StringConstantIndex = LdcStringConstant(ClassFile, Instruction) orelse continue;
            if (ProtectedStrings.contains(StringConstantIndex)) continue;
            const Utf8Index = ClassFile.ConstantPool.RefIndex(StringConstantIndex);
            if (StructuralSet[Utf8Index]) continue;
            if (InfoByUtf8Map.contains(Utf8Index)) continue;
            const PlainText = try ConstantPoolTransformer.RemapUtf8(AllocatorHandle, ClassFile.ConstantPool.Utf8Text(Utf8Index), NameMapping);
            const Units = try ModifiedUtf8.Decode(AllocatorHandle, PlainText);
            if (Units.len == 0) continue;
            const Salt: i32 = @bitCast(RandomGenerator.random().int(u32));
            const Nonce: i32 = @bitCast(RandomGenerator.random().int(u32));
            const EncryptedInfo = try EncryptInto(AllocatorHandle, &CipherBytes, Units, Salt, CallerKey, Nonce, CipherSecrets);
            try InfoByUtf8Map.put(Utf8Index, EncryptedInfo);
            try ClassFile.ConstantPool.SetUtf8Content(Utf8Index, &.{});
        }
    }

    {
        var SiteIterator = ConcatSites.iterator();
        while (SiteIterator.next()) |Pair| {
            const Site = Pair.value_ptr.*;
            const Units = try ModifiedUtf8.Decode(AllocatorHandle, Site.Recipe);
            if (Units.len == 0) continue;
            const Salt: i32 = @bitCast(RandomGenerator.random().int(u32));
            const Nonce: i32 = @bitCast(RandomGenerator.random().int(u32));
            const EncryptedInfo = try EncryptInto(AllocatorHandle, &CipherBytes, Units, Salt, CallerKey, Nonce, CipherSecrets);
            try ConcatInfoMap.put(Pair.key_ptr.*, EncryptedInfo);
            if (Site.RecipeUtf8) |RecipeUtf8Index| try ClassFile.ConstantPool.SetUtf8Content(RecipeUtf8Index, &.{});
        }
    }

    if (InfoByUtf8Map.count() == 0 and ConcatInfoMap.count() == 0) return 0;

    const LongCount = (CipherBytes.items.len + 7) / 8;
    const Longs = try AllocatorHandle.alloc(i64, LongCount);
    @memset(Longs, 0);
    for (CipherBytes.items, 0..) |CipherByte, ByteIndex| {
        const LongIndex = ByteIndex >> 3;
        const WithinLongShift: u6 = @intCast(7 - (ByteIndex & 7));
        const ShiftedValue: u64 = @as(u64, CipherByte) << (@as(u6, WithinLongShift) * 8);
        Longs[LongIndex] = @bitCast(@as(u64, @bitCast(Longs[LongIndex])) | ShiftedValue);
    }

    var FieldName: []const u8 = undefined;
    var Attempt: u32 = 0;
    while (true) : (Attempt += 1) {
        FieldName = try IdentifierGenerator.AbcName(AllocatorHandle, @as(usize, @intCast(RandomGenerator.random().int(u32) % 9_000_000 + 1000 + Attempt)));
        if (!MemberNameInUse(ClassFile, FieldName)) break;
    }

    var FieldOrdinal: i32 = 0;
    for (ClassFile.Fields.items) |Field| {
        if ((Field.AccessFlags & AccessFlags.AccessStatic) != 0 and std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Field.DescriptorIndex), "[J")) FieldOrdinal += 1;
    }
    const OrdinalIndex = try ClassFile.ConstantPool.AddInteger(FieldOrdinal);
    const FieldNameIndex = try ClassFile.ConstantPool.AddUtf8(FieldName);
    const FieldDescriptorIndex = try ClassFile.ConstantPool.AddUtf8("[J");
    try ClassFile.Fields.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic | AccessFlags.AccessFinal | AccessFlags.AccessPrivate, .NameIndex = FieldNameIndex, .DescriptorIndex = FieldDescriptorIndex, .Attributes = .empty });
    const FieldReference = try ClassFile.ConstantPool.AddFieldref(ThisInternalName, FieldName, "[J");

    const StringBootstrapHandle = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapInternalName, StringBootstrapSynthesizer.StringMethod, StringBootstrapSynthesizer.BootstrapMethodDescriptor));
    const ConcatBootstrapHandle = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapInternalName, StringBootstrapSynthesizer.ConcatMethod, StringBootstrapSynthesizer.BootstrapMethodDescriptor));

    var ExistingEntries: []const u8 = &.{};
    var BaseCount: u16 = 0;
    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods")) |BootstrapAttributeIndex| {
        const AttributeInfo = ClassFile.Attributes.items[BootstrapAttributeIndex].Info;
        BaseCount = ConstantPoolBuilder.ReadUnsignedShort(AttributeInfo, 0);
        ExistingEntries = AttributeInfo[2..];
    }
    var NewEntries: std.ArrayList(u8) = .empty;
    var NewCount: u16 = 0;

    var ConcatRemapMap = std.AutoHashMap(u16, u16).init(AllocatorHandle);
    {
        var InfoIterator = ConcatInfoMap.iterator();
        while (InfoIterator.next()) |Pair| {
            const OldInvokeDynamicIndex = Pair.key_ptr.*;
            const EncryptedInfo = Pair.value_ptr.*;
            const OffsetIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Offset);
            const LengthIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Length);
            const SaltIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Salt);
            const NonceIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Nonce);
            var EntryBytes: [14]u8 = undefined;
            std.mem.writeInt(u16, EntryBytes[0..2], ConcatBootstrapHandle, .big);
            std.mem.writeInt(u16, EntryBytes[2..4], 5, .big);
            std.mem.writeInt(u16, EntryBytes[4..6], OrdinalIndex, .big);
            std.mem.writeInt(u16, EntryBytes[6..8], OffsetIndex, .big);
            std.mem.writeInt(u16, EntryBytes[8..10], LengthIndex, .big);
            std.mem.writeInt(u16, EntryBytes[10..12], SaltIndex, .big);
            std.mem.writeInt(u16, EntryBytes[12..14], NonceIndex, .big);
            try NewEntries.appendSlice(AllocatorHandle, &EntryBytes);
            const BootstrapAttributeIndex = BaseCount + NewCount;
            NewCount += 1;
            const NameAndTypeIndex = ConstantPoolBuilder.ReadUnsignedShort(ClassFile.ConstantPool.Entries.items[OldInvokeDynamicIndex].Payload, 2);
            const NewInvokeDynamicIndex = try ClassFile.ConstantPool.AddInvokeDynamic(BootstrapAttributeIndex, NameAndTypeIndex);
            try ConcatRemapMap.put(OldInvokeDynamicIndex, NewInvokeDynamicIndex);
        }
    }

    var Total: usize = 0;
    for (ClassFile.Methods.items) |*Method| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        var ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
        const MethodName = ClassFile.ConstantPool.Utf8Text(Method.NameIndex);
        const IsInitializer = std.mem.eql(u8, MethodName, "<init>") or std.mem.eql(u8, MethodName, "<clinit>");

        var Changed = false;
        var Frames: []StackMapTableCodec.Frame = &.{};
        const StackMapAttributeIndex = ClassFileModel.FindAttribute(ParsedCode.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
        if (StackMapAttributeIndex) |StackMapEntryIndex| {
            const IsStatic = (Method.AccessFlags & AccessFlags.AccessStatic) != 0;
            const Descriptor = ClassFile.ConstantPool.Utf8Text(Method.DescriptorIndex);
            const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, IsInitializer);
            Frames = try StackMapTableCodec.Parse(AllocatorHandle, ParsedCode.Attributes.items[StackMapEntryIndex].Info, ParsedCode.Instructions.items, InitialLocals);
        }

        for (ParsedCode.Instructions.items) |*Instruction| {
            if (Instruction.Operation == 0xba and Instruction.Kind == .Fixed and Instruction.Raw.len >= 2) {
                const OldInvokeDynamicIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
                if (ConcatRemapMap.get(OldInvokeDynamicIndex)) |NewInvokeDynamicIndex| {
                    std.mem.writeInt(u16, Instruction.Raw[0..2], NewInvokeDynamicIndex, .big);
                    Changed = true;
                    Total += 1;
                    continue;
                }
            }
            const StringConstantIndex = LdcStringConstant(ClassFile, Instruction.*) orelse continue;
            const Utf8Index = ClassFile.ConstantPool.RefIndex(StringConstantIndex);
            const EncryptedInfo = InfoByUtf8Map.get(Utf8Index) orelse continue;
            const OffsetIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Offset);
            const LengthIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Length);
            const SaltIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Salt);
            const NonceIndex = try ClassFile.ConstantPool.AddInteger(EncryptedInfo.Nonce);

            var EntryBytes: [14]u8 = undefined;
            std.mem.writeInt(u16, EntryBytes[0..2], StringBootstrapHandle, .big);
            std.mem.writeInt(u16, EntryBytes[2..4], 5, .big);
            std.mem.writeInt(u16, EntryBytes[4..6], OrdinalIndex, .big);
            std.mem.writeInt(u16, EntryBytes[6..8], OffsetIndex, .big);
            std.mem.writeInt(u16, EntryBytes[8..10], LengthIndex, .big);
            std.mem.writeInt(u16, EntryBytes[10..12], SaltIndex, .big);
            std.mem.writeInt(u16, EntryBytes[12..14], NonceIndex, .big);
            try NewEntries.appendSlice(AllocatorHandle, &EntryBytes);
            const BootstrapAttributeIndex = BaseCount + NewCount;
            NewCount += 1;

            const NameAndTypeIndex = try ClassFile.ConstantPool.AddNameAndType("l", InvokeDynamicDescriptor);
            const InvokeDynamicIndex = try ClassFile.ConstantPool.AddInvokeDynamic(BootstrapAttributeIndex, NameAndTypeIndex);
            const RawBytes = try AllocatorHandle.alloc(u8, 4);
            std.mem.writeInt(u16, RawBytes[0..2], InvokeDynamicIndex, .big);
            RawBytes[2] = 0;
            RawBytes[3] = 0;
            Instruction.Operation = 0xba;
            Instruction.Kind = .Fixed;
            Instruction.Raw = RawBytes;
            Changed = true;
            Total += 1;
        }

        if (Changed) {
            try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &ParsedCode.Instructions);
            if (StackMapAttributeIndex) |StackMapEntryIndex| ParsedCode.Attributes.items[StackMapEntryIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, ParsedCode.Instructions.items);
            Method.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &ParsedCode);
        }
    }

    try EmitFieldInitialize(AllocatorHandle, ClassFile, FieldReference, Longs);

    if (NewCount > 0) {
        var AttributeInfoList: std.ArrayList(u8) = .empty;
        var HeaderBytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &HeaderBytes, BaseCount + NewCount, .big);
        try AttributeInfoList.appendSlice(AllocatorHandle, &HeaderBytes);
        try AttributeInfoList.appendSlice(AllocatorHandle, ExistingEntries);
        try AttributeInfoList.appendSlice(AllocatorHandle, NewEntries.items);
        if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods")) |BootstrapAttributeIndex| {
            ClassFile.Attributes.items[BootstrapAttributeIndex].Info = AttributeInfoList.items;
        } else {
            const NameIndex = try ClassFile.ConstantPool.AddUtf8("BootstrapMethods");
            try ClassFile.Attributes.append(AllocatorHandle, .{ .NameIndex = NameIndex, .Info = AttributeInfoList.items });
        }
    }
    return Total;
}

fn EmitInitializerInstructions(AssemblerState: *Assembler.AssemblerState, FieldReference: u16, Longs: []const i64) !void {
    try PushInteger(AssemblerState, @intCast(Longs.len));
    try AssemblerState.Operation1(0xbc, 11);
    for (Longs, 0..) |Value, Index| {
        try AssemblerState.Operation0(0x59);
        try PushInteger(AssemblerState, @intCast(Index));
        try AssemblerState.Operation2(0x14, try AssemblerState.ConstantPool.AddLong(Value));
        try AssemblerState.Operation0(0x50);
    }
    try AssemblerState.Operation2(0xb3, FieldReference);
}

fn EmitFieldInitialize(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, FieldReference: u16, Longs: []const i64) !void {
    const CodeUtf8Index = try ClassFile.ConstantPool.AddUtf8("Code");
    for (ClassFile.Methods.items) |*Method| {
        if (!std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Method.NameIndex), "<clinit>")) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        var ParsedCode = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
        var Frames: []StackMapTableCodec.Frame = &.{};
        const StackMapAttributeIndex = ClassFileModel.FindAttribute(ParsedCode.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
        if (StackMapAttributeIndex) |StackMapEntryIndex| {
            const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, "()V", true, ClassFile.ThisClass, true);
            Frames = try StackMapTableCodec.Parse(AllocatorHandle, ParsedCode.Attributes.items[StackMapEntryIndex].Info, ParsedCode.Instructions.items, InitialLocals);
        }
        var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFile.ConstantPool);
        try EmitInitializerInstructions(&AssemblerState, FieldReference, Longs);
        const PrefixInstructions = try AssemblerState.Finish();
        var MergedInstructions: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty;
        for (PrefixInstructions) |PrefixInstruction| {
            try MergedInstructions.append(AllocatorHandle, .{ .Identifier = ParsedCode.NewIdentifier(), .Operation = PrefixInstruction.Operation, .Kind = PrefixInstruction.Kind, .Raw = PrefixInstruction.Raw });
        }
        for (ParsedCode.Instructions.items) |Instruction| try MergedInstructions.append(AllocatorHandle, Instruction);
        ParsedCode.Instructions = MergedInstructions;
        if (ParsedCode.MaxStack < 6) ParsedCode.MaxStack = 6;
        try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &ParsedCode.Instructions);
        if (StackMapAttributeIndex) |StackMapEntryIndex| ParsedCode.Attributes.items[StackMapEntryIndex].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, ParsedCode.Instructions.items);
        Method.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &ParsedCode);
        return;
    }

    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFile.ConstantPool);
    try EmitInitializerInstructions(&AssemblerState, FieldReference, Longs);
    try AssemblerState.Operation0(0xb1);
    const MethodAttribute = try Assembler.BuildMethod(AllocatorHandle, &ClassFile.ConstantPool, try AssemblerState.Finish(), &.{}, "()V", true, CodeUtf8Index);
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, MethodAttribute);
    try ClassFile.Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic, .NameIndex = try ClassFile.ConstantPool.AddUtf8("<clinit>"), .DescriptorIndex = try ClassFile.ConstantPool.AddUtf8("()V"), .Attributes = Attributes });
}
