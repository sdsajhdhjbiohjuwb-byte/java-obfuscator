const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const StackMapTableCodec = @import("../Classfile/StackMapTableCodec.zig");
const IdentifierGenerator = @import("IdentifierGenerator.zig");
const RenameKeepSetAnalyzer = @import("RenameKeepSetAnalyzer.zig");
const RuntimeConfig = @import("../Pipeline/RuntimeConfig.zig");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const MemberKey = @import("MemberKey.zig");

const InstructionList = std.ArrayList(BytecodeInstructionModel.Instruction);
const MergedReference = struct { Reference: u16, Selector: i32 };
const Candidate = struct { MemberIndex: usize, Code: BytecodeInstructionModel.CodeAttribute };

fn ParamSlots(Descriptor: []const u8) ?u16 {
    var Slots: u16 = 0;
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        switch (Descriptor[Index]) {
            'B', 'C', 'I', 'S', 'Z', 'F' => {
                Slots += 1;
                Index += 1;
            },
            'J', 'D' => {
                Slots += 2;
                Index += 1;
            },
            'L' => {
                while (Index < Descriptor.len and Descriptor[Index] != ';') Index += 1;
                Index += 1;
                Slots += 1;
            },
            '[' => {
                while (Index < Descriptor.len and Descriptor[Index] == '[') Index += 1;
                if (Index < Descriptor.len and Descriptor[Index] == 'L') while (Index < Descriptor.len and Descriptor[Index] != ';') {
                    Index += 1;
                };
                Index += 1;
                Slots += 1;
            },
            else => return null,
        }
    }
    return Slots;
}

fn WithSelector(AllocatorHandle: std.mem.Allocator, Descriptor: []const u8) ![]u8 {
    const RightParenIndex = std.mem.indexOfScalar(u8, Descriptor, ')') orelse return error.BadDescriptor;
    return std.fmt.allocPrint(AllocatorHandle, "{s}I{s}", .{ Descriptor[0..RightParenIndex], Descriptor[RightParenIndex..] });
}

fn Branchless(Code: *const BytecodeInstructionModel.CodeAttribute) bool {
    if (Code.Exceptions.items.len != 0) return false;
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Kind != .Fixed) return false;
    }
    return true;
}

fn NameInStrings(ClassFile: *ClassFileModel.ClassFile, Name: []const u8) bool {
    var Index: u16 = 1;
    while (Index < ClassFile.ConstantPool.Count()) : (Index += 1) {
        if (ClassFile.ConstantPool.Entries.items[Index].Tag != ConstantPoolBuilder.TagString) continue;
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.RefIndex(Index)), Name)) return true;
    }
    return false;
}

fn NameUsed(ClassFile: *ClassFileModel.ClassFile, Name: []const u8) bool {
    for (ClassFile.Methods.items) |Member| {
        if (std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Member.NameIndex), Name)) return true;
    }
    return false;
}

fn PushInteger(AllocatorHandle: std.mem.Allocator, Instructions: *InstructionList, Code: *BytecodeInstructionModel.CodeAttribute, Pool: *ConstantPoolBuilder.ConstantPool, Value: i32) !void {
    if (Value >= -1 and Value <= 5) {
        try Instructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = @intCast(0x03 + Value), .Kind = .Fixed, .Raw = &.{} });
    } else if (Value >= -128 and Value <= 127) {
        const RawBytes = try AllocatorHandle.alloc(u8, 1);
        RawBytes[0] = @bitCast(@as(i8, @intCast(Value)));
        try Instructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0x10, .Kind = .Fixed, .Raw = RawBytes });
    } else {
        const PoolIndex = try Pool.AddInteger(Value);
        const RawBytes = try AllocatorHandle.alloc(u8, 2);
        std.mem.writeInt(u16, RawBytes[0..2], PoolIndex, .big);
        try Instructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0x13, .Kind = .Fixed, .Raw = RawBytes });
    }
}

fn BuildMerged(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, Descriptor: []const u8, Candidates: []const Candidate) !?ClassFileModel.MemberInfo {
    const ParameterSlots = ParamSlots(Descriptor) orelse return null;
    if (@as(usize, ParameterSlots) + 1 > 255) return null;
    const DescriptorWithSelector = try WithSelector(AllocatorHandle, Descriptor);

    var MaxLocals: u16 = ParameterSlots + 1;
    var MaxStack: u16 = 2;
    var TotalInstructions: usize = 0;
    for (Candidates) |CandidateEntry| {
        if (CandidateEntry.Code.MaxLocals > MaxLocals) MaxLocals = CandidateEntry.Code.MaxLocals;
        if (CandidateEntry.Code.MaxStack > MaxStack) MaxStack = CandidateEntry.Code.MaxStack;
        TotalInstructions += CandidateEntry.Code.Instructions.items.len;
    }
    if (MaxLocals > 255 or TotalInstructions > RuntimeConfig.Active.Passes.MethodMerger.MaxMerged) return null;

    var Code = BytecodeInstructionModel.CodeAttribute{ .MaxStack = MaxStack, .MaxLocals = MaxLocals, .Instructions = .empty, .Exceptions = .empty, .Attributes = .empty, .NextIdentifier = 0 };

    const BranchTargetIdentifiers = try AllocatorHandle.alloc(u32, Candidates.len);
    for (BranchTargetIdentifiers) |*BranchIdentifier| BranchIdentifier.* = Code.NewIdentifier();

    var OutputInstructions: InstructionList = .empty;
    const LoadRawBytes = try AllocatorHandle.alloc(u8, 1);
    LoadRawBytes[0] = @intCast(ParameterSlots);
    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0x15, .Kind = .Fixed, .Raw = LoadRawBytes });
    const LookupSwitchPairs = try AllocatorHandle.alloc(BytecodeInstructionModel.Pair, Candidates.len);
    for (0..Candidates.len) |Index| LookupSwitchPairs[Index] = .{ .Key = @intCast(Index), .Target = BranchTargetIdentifiers[Index] };
    try OutputInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0xab, .Kind = .LookupSwitch, .SwitchDefault = BranchTargetIdentifiers[0], .SwitchPairs = LookupSwitchPairs });

    const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, DescriptorWithSelector, true, ClassFile.ThisClass, false);
    var Frames: std.ArrayList(StackMapTableCodec.Frame) = .empty;
    for (Candidates, 0..) |CandidateEntry, Index| {
        for (CandidateEntry.Code.Instructions.items, 0..) |Instruction, InnerIndex| {
            const NewInstructionIdentifier = if (InnerIndex == 0) BranchTargetIdentifiers[Index] else Code.NewIdentifier();
            try OutputInstructions.append(AllocatorHandle, .{ .Identifier = NewInstructionIdentifier, .Operation = Instruction.Operation, .Kind = .Fixed, .Raw = try AllocatorHandle.dupe(u8, Instruction.Raw) });
        }
        try Frames.append(AllocatorHandle, .{ .Label = BranchTargetIdentifiers[Index], .Locals = InitialLocals, .Stack = &.{} });
    }

    Code.Instructions = OutputInstructions;
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
    const StackMapInfo = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames.items, Code.Instructions.items);
    try Code.Attributes.append(AllocatorHandle, .{ .NameIndex = try ClassFile.ConstantPool.AddUtf8("StackMapTable"), .Info = StackMapInfo });
    const CodeInfo = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);

    var Name: []const u8 = undefined;
    var Attempt: u32 = 0;
    while (true) : (Attempt += 1) {
        Name = try IdentifierGenerator.AbcName(AllocatorHandle, 700000 + Attempt);
        if (!NameUsed(ClassFile, Name)) break;
    }
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, .{ .NameIndex = try ClassFile.ConstantPool.AddUtf8("Code"), .Info = CodeInfo });
    return ClassFileModel.MemberInfo{
        .AccessFlags = AccessFlags.AccessPrivate | AccessFlags.AccessStatic,
        .NameIndex = try ClassFile.ConstantPool.AddUtf8(Name),
        .DescriptorIndex = try ClassFile.ConstantPool.AddUtf8(DescriptorWithSelector),
        .Attributes = Attributes,
    };
}

pub fn MethodMergerPass(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile) !usize {
    if (ClassFile.Major < 50) return 0;
    const ThisInternalName = ClassFile.ThisName();

    var MethodHandleTargets = try RenameKeepSetAnalyzer.CollectMethodHandleTargets(AllocatorHandle, &.{ClassFile});

    var Groups = std.StringHashMap(std.ArrayList(Candidate)).init(AllocatorHandle);
    for (ClassFile.Methods.items, 0..) |Member, MemberIndex| {
        const Flags = Member.AccessFlags;
        if ((Flags & AccessFlags.AccessStatic) == 0 or (Flags & AccessFlags.AccessPrivate) == 0) continue;
        if ((Flags & (AccessFlags.AccessNative | AccessFlags.AccessAbstract | AccessFlags.AccessSynchronized | AccessFlags.AccessBridge)) != 0) continue;
        const Name = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
        if (std.mem.eql(u8, Name, "<init>") or std.mem.eql(u8, Name, "<clinit>")) continue;
        if (NameInStrings(ClassFile, Name)) continue;
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        const Code = BytecodeInstructionModel.ParseCode(AllocatorHandle, Member.Attributes.items[CodeAttributeIndex].Info) catch continue;
        if (!Branchless(&Code)) continue;
        if (Code.Instructions.items.len == 0 or Code.Instructions.items.len > RuntimeConfig.Active.Passes.MethodMerger.MaxBody) continue;
        const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
        if (ParamSlots(Descriptor) == null) continue;
        const MethodHandleKey = try MemberKey.Signature(AllocatorHandle, Name, Descriptor);
        if (MethodHandleTargets.contains(MethodHandleKey)) continue;
        const GroupEntry = try Groups.getOrPut(Descriptor);
        if (!GroupEntry.found_existing) GroupEntry.value_ptr.* = .empty;
        try GroupEntry.value_ptr.append(AllocatorHandle, .{ .MemberIndex = MemberIndex, .Code = Code });
    }

    var RemovedKeys = std.StringHashMap(MergedReference).init(AllocatorHandle);
    var NewMergedMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    var RemovedIndices = std.AutoHashMap(usize, void).init(AllocatorHandle);
    var Count: usize = 0;

    var GroupIterator = Groups.iterator();
    while (GroupIterator.next()) |GroupValue| {
        const Descriptor = GroupValue.key_ptr.*;
        const Candidates = GroupValue.value_ptr.items;
        if (Candidates.len < RuntimeConfig.Active.Passes.MethodMerger.MinGroup) continue;
        const UseCount = @min(Candidates.len, RuntimeConfig.Active.Passes.MethodMerger.MaxGroup);
        const Merged = (try BuildMerged(AllocatorHandle, ClassFile, Descriptor, Candidates[0..UseCount])) orelse continue;
        const MethodReferenceIndex = try ClassFile.ConstantPool.AddMethodref(ThisInternalName, ClassFile.ConstantPool.Utf8Text(Merged.NameIndex), ClassFile.ConstantPool.Utf8Text(Merged.DescriptorIndex));
        for (Candidates[0..UseCount], 0..) |CandidateEntry, Index| {
            const OriginalMember = ClassFile.Methods.items[CandidateEntry.MemberIndex];
            const Key = try MemberKey.Signature(AllocatorHandle, ClassFile.ConstantPool.Utf8Text(OriginalMember.NameIndex), ClassFile.ConstantPool.Utf8Text(OriginalMember.DescriptorIndex));
            try RemovedKeys.put(Key, .{ .Reference = MethodReferenceIndex, .Selector = @intCast(Index) });
            try RemovedIndices.put(CandidateEntry.MemberIndex, {});
        }
        try NewMergedMethods.append(AllocatorHandle, Merged);
        Count += 1;
    }
    if (Count == 0) return 0;

    var References = std.AutoHashMap(u16, MergedReference).init(AllocatorHandle);
    {
        var Index: u16 = 1;
        const PoolCount = ClassFile.ConstantPool.Count();
        while (Index < PoolCount) : (Index += 1) {
            if (ClassFile.ConstantPool.Entries.items[Index].Tag != ConstantPoolBuilder.TagMethodref) continue;
            const Owner = ClassFile.ConstantPool.ClassName(ClassFile.ConstantPool.RefClassIndex(Index));
            if (!std.mem.eql(u8, Owner, ThisInternalName)) continue;
            const NameAndTypeIndex = ClassFile.ConstantPool.RefNameAndTypeIndex(Index);
            const ReferenceName = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeName(NameAndTypeIndex));
            const ReferenceDescriptor = ClassFile.ConstantPool.Utf8Text(ClassFile.ConstantPool.NameAndTypeDesc(NameAndTypeIndex));
            const Key = try MemberKey.Signature(AllocatorHandle, ReferenceName, ReferenceDescriptor);
            if (RemovedKeys.get(Key)) |MergedReferenceValue| try References.put(Index, MergedReferenceValue);
        }
    }

    var KeptMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    for (ClassFile.Methods.items, 0..) |Member, MemberIndex| {
        if (RemovedIndices.contains(MemberIndex)) continue;
        try KeptMethods.append(AllocatorHandle, Member);
    }
    for (NewMergedMethods.items) |Member| try KeptMethods.append(AllocatorHandle, Member);
    ClassFile.Methods = KeptMethods;

    for (ClassFile.Methods.items) |*Member| {
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFile.ConstantPool, "Code") orelse continue;
        if (RewriteCallsites(AllocatorHandle, ClassFile, Member, Member.Attributes.items[CodeAttributeIndex].Info, &References) catch null) |NewInfo| {
            Member.Attributes.items[CodeAttributeIndex].Info = NewInfo;
        }
    }
    return Count;
}

fn RewriteCallsites(AllocatorHandle: std.mem.Allocator, ClassFile: *ClassFileModel.ClassFile, Member: *ClassFileModel.MemberInfo, CodeInfo: []const u8, References: *std.AutoHashMap(u16, MergedReference)) !?[]u8 {
    var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, CodeInfo);
    const MemberName = ClassFile.ConstantPool.Utf8Text(Member.NameIndex);
    var Frames: []StackMapTableCodec.Frame = &.{};
    const StackMapIndex = ClassFileModel.FindAttribute(Code.Attributes.items, &ClassFile.ConstantPool, "StackMapTable");
    if (StackMapIndex) |Index| {
        const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
        const IsClinit = std.mem.eql(u8, MemberName, "<clinit>");
        const Descriptor = ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const InitialLocals = try StackMapTableCodec.ComputeInitialLocals(AllocatorHandle, &ClassFile.ConstantPool, Descriptor, IsStatic, ClassFile.ThisClass, IsClinit);
        Frames = try StackMapTableCodec.Parse(AllocatorHandle, Code.Attributes.items[Index].Info, Code.Instructions.items, InitialLocals);
    }

    var OutputInstructions: InstructionList = .empty;
    var Changed = false;
    for (Code.Instructions.items) |Instruction| {
        if (Instruction.Operation == 0xb8 and Instruction.Raw.len == 2) {
            const ReferenceIndex = ConstantPoolBuilder.ReadUnsignedShort(Instruction.Raw, 0);
            if (References.get(ReferenceIndex)) |MergedReferenceValue| {
                const StartIndex = OutputInstructions.items.len;
                try PushInteger(AllocatorHandle, &OutputInstructions, &Code, &ClassFile.ConstantPool, MergedReferenceValue.Selector);
                const RawBytes = try AllocatorHandle.alloc(u8, 2);
                std.mem.writeInt(u16, RawBytes[0..2], MergedReferenceValue.Reference, .big);
                try OutputInstructions.append(AllocatorHandle, .{ .Identifier = Code.NewIdentifier(), .Operation = 0xb8, .Kind = .Fixed, .Raw = RawBytes });
                OutputInstructions.items[StartIndex].Identifier = Instruction.Identifier;
                Changed = true;
                continue;
            }
        }
        try OutputInstructions.append(AllocatorHandle, Instruction);
    }
    if (!Changed) return null;
    Code.Instructions = OutputInstructions;
    Code.MaxStack = @intCast(@min(@as(u32, 65535), @as(u32, Code.MaxStack) + 1));
    try BytecodeInstructionModel.PrepareLayout(AllocatorHandle, &Code.Instructions);
    if (StackMapIndex) |Index| Code.Attributes.items[Index].Info = try StackMapTableCodec.Regenerate(AllocatorHandle, Frames, Code.Instructions.items);
    return try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
}
