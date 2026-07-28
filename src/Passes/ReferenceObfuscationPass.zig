const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const NativeCipher = @import("../Native/NativeCipher.zig");
const ModifiedUtf8 = @import("../Classfile/ModifiedUtf8.zig");
const ReferenceBootstrapSynthesizer = @import("ReferenceBootstrapSynthesizer.zig");
const IdentifierGenerator = @import("IdentifierGenerator.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

const EncryptedStringInfo = struct { Offset: i32, Length: i32, Salt: i32, Nonce: i32 };

fn EncryptName(AllocatorHandle: std.mem.Allocator, CipherBytes: *std.ArrayList(u8), Name: []const u8, CallerKey: i32, RandomGenerator: *std.Random.DefaultPrng, CipherSecrets: NativeCipher.Secrets) !EncryptedStringInfo {
    const CodeUnits = try ModifiedUtf8.Decode(AllocatorHandle, Name);
    const Salt: i32 = @bitCast(RandomGenerator.random().int(u32));
    const Nonce: i32 = @bitCast(RandomGenerator.random().int(u32));
    const Offset: i32 = @intCast(CipherBytes.items.len);
    for (CodeUnits, 0..) |Unit, InnerIndex| {
        const HighByte: u8 = @intCast(Unit >> 8);
        const LowByte: u8 = @intCast(Unit & 0xFF);
        try CipherBytes.append(AllocatorHandle, HighByte ^ NativeCipher.KeystreamByte(@intCast(2 * InnerIndex), Salt, CallerKey, Nonce, CipherSecrets));
        try CipherBytes.append(AllocatorHandle, LowByte ^ NativeCipher.KeystreamByte(@intCast(2 * InnerIndex + 1), Salt, CallerKey, Nonce, CipherSecrets));
    }
    return .{ .Offset = Offset, .Length = @intCast(CodeUnits.len * 2), .Salt = Salt, .Nonce = Nonce };
}

fn Dotted(AllocatorHandle: std.mem.Allocator, InternalName: []const u8) ![]u8 {
    const Result = try AllocatorHandle.dupe(u8, InternalName);
    for (Result) |*Character| {
        if (Character.* == '/') Character.* = '.';
    }
    return Result;
}

const Handles = struct {
    Static: u16,
    Virtual: u16,
    FieldGet: u16,
    FieldStaticGet: u16,
    FieldSet: u16,
    FieldStaticSet: u16,
    Constructor: u16,
    Special: u16,
};

const Site = struct { Handle: u16, InvokeDynamicDescriptor: []u8, Owner: []const u8, Member: []const u8 };

fn MethodSite(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, HandleSet: Handles, ReferenceIndex: u16, IsStatic: bool) !Site {
    const Owner = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(ReferenceIndex));
    const NameAndTypeIndex = ClassFile.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
    const Member = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(NameAndTypeIndex));
    const MethodDescriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
    if (IsStatic) {
        return .{ .Handle = HandleSet.Static, .InvokeDynamicDescriptor = try AllocatorHandle.dupe(u8, MethodDescriptor), .Owner = Owner, .Member = Member };
    }
    const InvokeDynamicDescriptor = try std.fmt.allocPrint(AllocatorHandle, "(L{s};{s}", .{ Owner, MethodDescriptor[1..] });
    return .{ .Handle = HandleSet.Virtual, .InvokeDynamicDescriptor = InvokeDynamicDescriptor, .Owner = Owner, .Member = Member };
}

fn SpecialSite(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, HandleSet: Handles, ReferenceIndex: u16) !Site {
    const Owner = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(ReferenceIndex));
    const NameAndTypeIndex = ClassFile.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
    const Member = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(NameAndTypeIndex));
    const MethodDescriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
    const InvokeDynamicDescriptor = try std.fmt.allocPrint(AllocatorHandle, "(L{s};{s}", .{ Owner, MethodDescriptor[1..] });
    return .{ .Handle = HandleSet.Special, .InvokeDynamicDescriptor = InvokeDynamicDescriptor, .Owner = Owner, .Member = Member };
}

fn FieldSite(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, HandleSet: Handles, ReferenceIndex: u16, Opcode: u8) !Site {
    const Owner = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(ReferenceIndex));
    const NameAndTypeIndex = ClassFile.ConstantPool.RefNameAndTypeIndex(ReferenceIndex);
    const Member = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(NameAndTypeIndex));
    const FieldType = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
    const Descriptor = switch (Opcode) {
        0xb4 => try std.fmt.allocPrint(AllocatorHandle, "(L{s};){s}", .{ Owner, FieldType }),
        0xb2 => try std.fmt.allocPrint(AllocatorHandle, "(){s}", .{FieldType}),
        0xb5 => try std.fmt.allocPrint(AllocatorHandle, "(L{s};{s})V", .{ Owner, FieldType }),
        else => try std.fmt.allocPrint(AllocatorHandle, "({s})V", .{FieldType}),
    };
    const HandleIndex = switch (Opcode) {
        0xb4 => HandleSet.FieldGet,
        0xb2 => HandleSet.FieldStaticGet,
        0xb5 => HandleSet.FieldSet,
        else => HandleSet.FieldStaticSet,
    };
    return .{ .Handle = HandleIndex, .InvokeDynamicDescriptor = Descriptor, .Owner = Owner, .Member = Member };
}

fn MemberNameInUse(ClassFile: *const ClassFileModel.ClassFile, Name: []const u8) bool {
    for (ClassFile.Fields.items) |Field| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Field.NameIndex), Name)) return true;
    }
    for (ClassFile.Methods.items) |Method| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Method.NameIndex), Name)) return true;
    }
    return false;
}

pub fn ReferenceObfuscationPass(
    AllocatorHandle: std.mem.Allocator,
    ClassFile: *ClassFileModel.ClassFile,
    ClassNameMapping: *const Mapping,
    BootstrapMethod: *const ReferenceBootstrapSynthesizer.Bootstrap,
    InterpreterInternal: []const u8,
    LoaderInternal: []const u8,
    CipherSecrets: NativeCipher.Secrets,
    RandomGenerator: *std.Random.DefaultPrng,
) !usize {
    const HandleSet = Handles{
        .Static = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.StaticName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .Virtual = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.VirtualName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .FieldGet = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.FieldGetName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .FieldStaticGet = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.FieldStaticGetName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .FieldSet = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.FieldSetName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .FieldStaticSet = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.FieldStaticSetName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .Constructor = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.ConstructorName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
        .Special = try ClassFile.ConstantPool.AddMethodHandle(6, try ClassFile.ConstantPool.AddMethodref(BootstrapMethod.InternalName, BootstrapMethod.SpecialName, ReferenceBootstrapSynthesizer.BootstrapMethodDescriptor)),
    };

    const ThisInternal = ClassFile.ConstantPool.ClassName(ClassFile.ThisClass);
    const FinalInternal = ClassNameMapping.RemapInternal(ThisInternal) orelse ThisInternal;
    const CallerKey = try ModifiedUtf8.CallerKey(AllocatorHandle, FinalInternal);

    var FieldOrdinal: i32 = 0;
    for (ClassFile.Fields.items) |Field| {
        if ((Field.AccessFlags & AccessFlags.AccessStatic) != 0 and std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Field.DescriptorIndex), "[J")) FieldOrdinal += 1;
    }

    var CipherBytes: std.ArrayList(u8) = .empty;

    var ExistingEntries: []const u8 = &.{};
    var BaseCount: u16 = 0;
    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods")) |BootstrapAttributeIndex| {
        const BootstrapInfo = ClassFile.Attributes.items[BootstrapAttributeIndex].Info;
        BaseCount = ConstantPoolBuilder.ReadUnsignedShort(BootstrapInfo, 0);
        ExistingEntries = BootstrapInfo[2..];
    }
    var NewEntries: std.ArrayList(u8) = .empty;
    var NewCount: u16 = 0;

    const OrdinalIndex = try ClassFile.ConstantPool.AddInteger(FieldOrdinal);

    var Total: usize = 0;
    for (ClassFile.Methods.items) |*Method| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
        const MethodName = ClassFile.ConstantPool.Utf8Text(Method.NameIndex);
        const IsClinit = std.mem.eql(u8, MethodName, "<clinit>") or std.mem.eql(u8, MethodName, "<init>");

        var Changed = false;
        var Frames: []StackMapTableCodec.Frame = &.{};
        const StackMapAttributeIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
        if (StackMapAttributeIndex) |Index| {
            const IsStatic = (Method.AccessFlags & AccessFlags.AccessStatic) != 0;
            const Descriptor = ClassFile.ConstantPool.Utf8Text(Method.DescriptorIndex);
            const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, IsClinit);
            Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[Index].Info, Code.Instructions.items, InitialLocals);
        }

        for (Code.Instructions.items) |*Instruction| {
            if (Instruction.Kind != .Fixed) continue;
            const Opcode = Instruction.Operation;
            var MaybeSite: ?Site = null;
            switch (Opcode) {
                0xb8 => MaybeSite = try MethodSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), true),
                0xb6 => MaybeSite = try MethodSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), false),
                0xb9 => MaybeSite = try MethodSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), false),
                0xb7 => MaybeSite = try SpecialSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0)),
                0xb2 => MaybeSite = try FieldSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), 0xb2),
                0xb4 => MaybeSite = try FieldSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), 0xb4),
                0xb3 => if (!IsClinit) {
                    MaybeSite = try FieldSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), 0xb3);
                },
                0xb5 => if (!IsClinit) {
                    MaybeSite = try FieldSite(AllocatorHandle, ClassFile, HandleSet, ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0), 0xb5);
                },
                else => {},
            }
            const ResolvedSite = MaybeSite orelse continue;
            if (std.mem.eql(u8, ResolvedSite.Member, "<init>")) continue;
            if (ResolvedSite.Owner.len > 0 and ResolvedSite.Owner[0] == '[') continue;
            if (std.mem.eql(u8, ResolvedSite.Owner, BootstrapMethod.InternalName) or std.mem.eql(u8, ResolvedSite.Owner, InterpreterInternal) or std.mem.eql(u8, ResolvedSite.Owner, LoaderInternal)) continue;

            const FinalOwner = ClassNameMapping.RemapInternal(ResolvedSite.Owner) orelse ResolvedSite.Owner;
            const OwnerDotted = try Dotted(AllocatorHandle, FinalOwner);
            const OwnerInfo = try EncryptName(AllocatorHandle, &CipherBytes, OwnerDotted, CallerKey, RandomGenerator, CipherSecrets);
            const MemberInfo = try EncryptName(AllocatorHandle, &CipherBytes, ResolvedSite.Member, CallerKey, RandomGenerator, CipherSecrets);

            const Arguments = [_]u16{
                OrdinalIndex,
                try ClassFile.ConstantPool.AddInteger(OwnerInfo.Offset),
                try ClassFile.ConstantPool.AddInteger(OwnerInfo.Length),
                try ClassFile.ConstantPool.AddInteger(OwnerInfo.Salt),
                try ClassFile.ConstantPool.AddInteger(OwnerInfo.Nonce),
                try ClassFile.ConstantPool.AddInteger(MemberInfo.Offset),
                try ClassFile.ConstantPool.AddInteger(MemberInfo.Length),
                try ClassFile.ConstantPool.AddInteger(MemberInfo.Salt),
                try ClassFile.ConstantPool.AddInteger(MemberInfo.Nonce),
            };

            var EntryBuffer: std.ArrayList(u8) = .empty;
            var HeaderBytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &HeaderBytes, ResolvedSite.Handle, .big);
            try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
            std.mem.writeInt(u16, &HeaderBytes, 9, .big);
            try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
            for (Arguments) |ArgumentIndex| {
                std.mem.writeInt(u16, &HeaderBytes, ArgumentIndex, .big);
                try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
            }
            try NewEntries.appendSlice(AllocatorHandle, EntryBuffer.items);
            const BootstrapMethodAttributeIndex = BaseCount + NewCount;
            NewCount += 1;

            const NameAndTypeIndex = try ClassFile.ConstantPool.AddNameAndType("l", ResolvedSite.InvokeDynamicDescriptor);
            const InvokeDynamicIndex = try ClassFile.ConstantPool.AddInvokeDynamic(BootstrapMethodAttributeIndex, NameAndTypeIndex);
            const RawBytes = try AllocatorHandle.alloc(u8, 4);
            std.mem.writeInt(u16, RawBytes[0..2], InvokeDynamicIndex, .big);
            RawBytes[2] = 0;
            RawBytes[3] = 0;
            Instruction.Operation = 0xba;
            Instruction.Raw = RawBytes;
            Changed = true;
            Total += 1;
        }

        {
            var UninitializedNewIdentifiers = std.AutoHashMap(u32, void).init(AllocatorHandle);
            for (Frames) |FrameEntry| {
                for (FrameEntry.Locals) |VerificationType| switch (VerificationType) {
                    .Uninitialized => |Identifier| try UninitializedNewIdentifiers.put(Identifier, {}),
                    else => {},
                };
                for (FrameEntry.Stack) |VerificationType| switch (VerificationType) {
                    .Uninitialized => |Identifier| try UninitializedNewIdentifiers.put(Identifier, {}),
                    else => {},
                };
            }
            const Items = Code.Instructions.items;
            var ScanIndex: usize = 0;
            while (ScanIndex + 1 < Items.len) : (ScanIndex += 1) {
                if (Items[ScanIndex].Kind != .Fixed or Items[ScanIndex].Operation != 0xbb) continue;
                if (Items[ScanIndex + 1].Kind != .Fixed or Items[ScanIndex + 1].Operation != 0x59) continue;
                var PendingDepth: i32 = 0;
                var InitializerIndex: ?usize = null;
                var Forward: usize = ScanIndex + 2;
                while (Forward < Items.len) : (Forward += 1) {
                    if (Items[Forward].Kind != .Fixed) continue;
                    const ForwardOpcode = Items[Forward].Operation;
                    if (ForwardOpcode == 0xbb) {
                        PendingDepth += 1;
                    } else if (ForwardOpcode == 0xb7) {
                        const CandidateRef = ConstantPoolBuilder.ReadUnsignedShort(Items[Forward].Raw, 0);
                        const CandidateName = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(ClassFile.ConstantPool.RefNameAndTypeIndex(CandidateRef)));
                        if (std.mem.eql(u8, CandidateName, "<init>")) {
                            if (PendingDepth == 0) {
                                InitializerIndex = Forward;
                                break;
                            }
                            PendingDepth -= 1;
                        }
                    }
                }
                const InitializerAt = InitializerIndex orelse continue;
                if (UninitializedNewIdentifiers.contains(Items[ScanIndex].Identifier)) continue;

                const InitializerRef = ConstantPoolBuilder.ReadUnsignedShort(Items[InitializerAt].Raw, 0);
                const Owner = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(InitializerRef));
                if (Owner.len == 0 or Owner[0] == '[') continue;
                if (std.mem.eql(u8, Owner, BootstrapMethod.InternalName) or std.mem.eql(u8, Owner, InterpreterInternal) or std.mem.eql(u8, Owner, LoaderInternal)) continue;
                const ConstructorDescriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(ClassFile.ConstantPool.RefNameAndTypeIndex(InitializerRef)));
                if (ConstructorDescriptor.len < 3 or ConstructorDescriptor[ConstructorDescriptor.len - 1] != 'V') continue;

                const FinalOwner = ClassNameMapping.RemapInternal(Owner) orelse Owner;
                const InvokeDynamicDescriptor = try std.fmt.allocPrint(AllocatorHandle, "{s}L{s};", .{ ConstructorDescriptor[0 .. ConstructorDescriptor.len - 1], FinalOwner });
                const OwnerDotted = try Dotted(AllocatorHandle, FinalOwner);
                const OwnerInfo = try EncryptName(AllocatorHandle, &CipherBytes, OwnerDotted, CallerKey, RandomGenerator, CipherSecrets);
                const MemberInfo = try EncryptName(AllocatorHandle, &CipherBytes, "<init>", CallerKey, RandomGenerator, CipherSecrets);
                const Arguments = [_]u16{
                    OrdinalIndex,
                    try ClassFile.ConstantPool.AddInteger(OwnerInfo.Offset),
                    try ClassFile.ConstantPool.AddInteger(OwnerInfo.Length),
                    try ClassFile.ConstantPool.AddInteger(OwnerInfo.Salt),
                    try ClassFile.ConstantPool.AddInteger(OwnerInfo.Nonce),
                    try ClassFile.ConstantPool.AddInteger(MemberInfo.Offset),
                    try ClassFile.ConstantPool.AddInteger(MemberInfo.Length),
                    try ClassFile.ConstantPool.AddInteger(MemberInfo.Salt),
                    try ClassFile.ConstantPool.AddInteger(MemberInfo.Nonce),
                };
                var EntryBuffer: std.ArrayList(u8) = .empty;
                var HeaderBytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &HeaderBytes, HandleSet.Constructor, .big);
                try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
                std.mem.writeInt(u16, &HeaderBytes, 9, .big);
                try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
                for (Arguments) |ArgumentIndex| {
                    std.mem.writeInt(u16, &HeaderBytes, ArgumentIndex, .big);
                    try EntryBuffer.appendSlice(AllocatorHandle, &HeaderBytes);
                }
                try NewEntries.appendSlice(AllocatorHandle, EntryBuffer.items);
                const BootstrapMethodAttributeIndex = BaseCount + NewCount;
                NewCount += 1;
                const NameAndTypeIndex = try ClassFile.ConstantPool.AddNameAndType("l", InvokeDynamicDescriptor);
                const InvokeDynamicIndex = try ClassFile.ConstantPool.AddInvokeDynamic(BootstrapMethodAttributeIndex, NameAndTypeIndex);

                Items[ScanIndex].Operation = 0x00;
                Items[ScanIndex].Raw = &.{};
                Items[ScanIndex + 1].Operation = 0x00;
                Items[ScanIndex + 1].Raw = &.{};
                const InvokeDynamicRaw = try AllocatorHandle.alloc(u8, 4);
                std.mem.writeInt(u16, InvokeDynamicRaw[0..2], InvokeDynamicIndex, .big);
                InvokeDynamicRaw[2] = 0;
                InvokeDynamicRaw[3] = 0;
                Items[InitializerAt].Operation = 0xba;
                Items[InitializerAt].Raw = InvokeDynamicRaw;
                Changed = true;
                Total += 1;
            }
        }

        if (Changed) {
            try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
            if (StackMapAttributeIndex) |Index| Code.Attributes.items[Index].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
            Method.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
        }
    }

    if (NewCount == 0) return 0;

    const LongCount = (CipherBytes.items.len + 7) / 8;
    const Longs = try AllocatorHandle.alloc(i64, LongCount);
    @memset(Longs, 0);
    for (CipherBytes.items, 0..) |ByteValue, Index| {
        const LongIndex = Index >> 3;
        const WithinOffset: u6 = @intCast(7 - (Index & 7));
        const ShiftedValue: u64 = @as(u64, ByteValue) << (@as(u6, WithinOffset) * 8);
        Longs[LongIndex] = @bitCast(@as(u64, @bitCast(Longs[LongIndex])) | ShiftedValue);
    }

    var FieldName: []const u8 = undefined;
    var Attempt: u32 = 0;
    while (true) : (Attempt += 1) {
        FieldName = try IdentifierGenerator.AbcName(AllocatorHandle, @as(usize, @intCast(RandomGenerator.random().int(u32) % 9_000_000 + 1000 + Attempt)));
        if (!MemberNameInUse(ClassFile, FieldName)) break;
    }
    const FieldNameIndex = try ClassFile.ConstantPool.AddUtf8(FieldName);
    const FieldDescriptorIndex = try ClassFile.ConstantPool.AddUtf8("[J");
    try ClassFile.Fields.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic | AccessFlags.AccessFinal | AccessFlags.AccessPrivate, .NameIndex = FieldNameIndex, .DescriptorIndex = FieldDescriptorIndex, .Attributes = .empty });
    const FieldRefIndex = try ClassFile.ConstantPool.AddFieldref(ThisInternal, FieldName, "[J");

    try EmitFieldInit(AllocatorHandle, ClassFile, FieldRefIndex, Longs);

    var InfoBuffer: std.ArrayList(u8) = .empty;
    var SecondHeaderBytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &SecondHeaderBytes, BaseCount + NewCount, .big);
    try InfoBuffer.appendSlice(AllocatorHandle, &SecondHeaderBytes);
    try InfoBuffer.appendSlice(AllocatorHandle, ExistingEntries);
    try InfoBuffer.appendSlice(AllocatorHandle, NewEntries.items);
    if (ClassFileModel.FindAttribute(ClassFile.Attributes.items, &ClassFile.ConstantPool, "BootstrapMethods")) |BootstrapAttributeIndex| {
        ClassFile.Attributes.items[BootstrapAttributeIndex].Info = InfoBuffer.items;
    } else {
        const NameIndex = try ClassFile.ConstantPool.AddUtf8("BootstrapMethods");
        try ClassFile.Attributes.append(AllocatorHandle, .{ .NameIndex = NameIndex, .Info = InfoBuffer.items });
    }
    return Total;
}

fn EmitInitInstructions(AssemblerState: *Assembler.AssemblerState, FieldRefIndex: u16, Longs: []const i64) !void {
    try AssemblerState.Iconst(@intCast(Longs.len));
    try AssemblerState.Operation1(0xbc, 11);
    for (Longs, 0..) |Value, Index| {
        try AssemblerState.Operation0(0x59);
        try AssemblerState.Iconst(@intCast(Index));
        try AssemblerState.Operation2(0x14, try AssemblerState.ConstantPool.AddLong(Value));
        try AssemblerState.Operation0(0x50);
    }
    try AssemblerState.Operation2(0xb3, FieldRefIndex);
}

fn EmitFieldInit(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, FieldRefIndex: u16, Longs: []const i64) !void {
    const CodeUtf8Index = try ClassFile.ConstantPool.AddUtf8("Code");
    for (ClassFile.Methods.items) |*Method| {
        if (!std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Method.NameIndex), "<clinit>")) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
        var Frames: []StackMapTableCodec.Frame = &.{};
        const StackMapAttributeIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
        if (StackMapAttributeIndex) |Index| {
            const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, "()V", true, ClassFile.ThisClass, true);
            Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[Index].Info, Code.Instructions.items, InitialLocals);
        }
        var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFile.ConstantPool);
        try EmitInitInstructions(&AssemblerState, FieldRefIndex, Longs);
        const PrefixInstructions = try AssemblerState.Finish();
        var MergedInstructions: std.ArrayList(BytecodeInstructionModel.Instruction) = .empty;
        for (PrefixInstructions) |PrefixInstruction| {
            try MergedInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = PrefixInstruction.Operation, .Kind = PrefixInstruction.Kind, .Raw = PrefixInstruction.Raw });
        }
        for (Code.Instructions.items) |Instruction| try MergedInstructions.append(AllocatorHandle, Instruction);
        Code.Instructions = MergedInstructions;
        if (Code.MaxStack < 6) Code.MaxStack = 6;
        try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
        if (StackMapAttributeIndex) |Index| Code.Attributes.items[Index].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
        Method.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
        return;
    }

    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, &ClassFile.ConstantPool);
    try EmitInitInstructions(&AssemblerState, FieldRefIndex, Longs);
    try AssemblerState.Operation0(0xb1);
    const MethodAttribute = try Assembler.BuildMethod(AllocatorHandle, &ClassFile.ConstantPool, try AssemblerState.Finish(), &.{}, "()V", true, CodeUtf8Index);
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, MethodAttribute);
    try ClassFile.Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessStatic, .NameIndex = try ClassFile.ConstantPool.AddUtf8("<clinit>"), .DescriptorIndex = try ClassFile.ConstantPool.AddUtf8("()V"), .Attributes = Attributes });
}
