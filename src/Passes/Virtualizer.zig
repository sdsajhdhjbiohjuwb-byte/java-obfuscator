const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const MethodVirtualizer = @import("../Vm/MethodVirtualizer.zig");
const InvokeDynamicBridge = @import("../Vm/InvokeDynamicBridge.zig");
const ConstructorSplit = @import("../Vm/ConstructorSplit.zig");
const StubEmitter = @import("../Vm/StubEmitter.zig");
const VirtualMachineImageBuilder = @import("../Vm/VirtualMachineImageBuilder.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

const MinimumProgramBytes: usize = 10;

pub fn Virtualizer(
    AllocatorHandle: std.mem.Allocator,
    ClassFileHandle: *ClassFileModel.ClassFile,
    BuilderHandle: *VirtualMachineImageBuilder.Builder,
    LoaderInternal: []const u8,
    Budget: usize,
    MappingReference: *const Mapping,
    Random: std.Random,
) !usize {
    const NativeRunMethodReference = try ClassFileHandle.ConstantPool.AddMethodref(LoaderInternal, "nr", "(I[Ljava/lang/Object;)Ljava/lang/Object;");
    const CodeUtf8Index = try ClassFileHandle.ConstantPool.AddUtf8("Code");
    const ThisClassPayload = ClassFileHandle.ConstantPool.GetEntry(ClassFileHandle.ThisClass).Payload;
    const CurrentClass = ClassFileHandle.ConstantPool.Utf8Text(ConstantPoolBuilder.ReadUnsignedShort(ThisClassPayload, 0));
    _ = try ConstructorSplit.SplitConstructors(AllocatorHandle, ClassFileHandle);
    var DoneCount: usize = 0;
    var BridgeMethods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;

    for (ClassFileHandle.Methods.items) |*Member| {
        if (DoneCount >= Budget) break;
        if ((Member.AccessFlags & AccessFlags.AccessNative) != 0) continue;
        if ((Member.AccessFlags & AccessFlags.AccessAbstract) != 0) continue;
        const IsStatic = (Member.AccessFlags & AccessFlags.AccessStatic) != 0;
        const Name = ClassFileHandle.ConstantPool.Utf8Text(Member.NameIndex);
        if (std.mem.eql(u8, Name, "<clinit>")) continue;
        if (std.mem.eql(u8, Name, "<init>")) continue;
        const Descriptor = ClassFileHandle.ConstantPool.Utf8Text(Member.DescriptorIndex);
        const CodeAttributeIndex = ClassFileModel.FindAttribute(Member.Attributes.items, &ClassFileHandle.ConstantPool, "Code") orelse continue;
        var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Member.Attributes.items[CodeAttributeIndex].Info);

        var PendingBridges: ?std.ArrayList(ClassFileModel.MemberInfo) = null;
        if (InvokeDynamicBridge.HasInvokeDynamic(&Code)) {
            PendingBridges = (try InvokeDynamicBridge.ExtractBridges(AllocatorHandle, ClassFileHandle, &Code, Random, CodeUtf8Index)) orelse continue;
        }

        const Program = (try MethodVirtualizer.MethodVirtualizer(AllocatorHandle, &ClassFileHandle.ConstantPool, &Code, Descriptor, BuilderHandle.OpcodePermutation, MappingReference, Random, CurrentClass, ClassFileHandle.ThisClass, IsStatic)) orelse continue;
        if (Program.Bytes.len < MinimumProgramBytes) continue;

        if (PendingBridges) |Bridges| try BridgeMethods.appendSlice(AllocatorHandle, Bridges.items);

        const MethodIdentifier = try BuilderHandle.Add(Program.NumberOfLocals, Program.MaxStack, Program.Bytes);
        BuilderHandle.ApplyRecordPermutation(MethodIdentifier, Program.OpcodeOffsets);
        BuilderHandle.ApplyLocalPermutation(MethodIdentifier, Program.LocalOperandOffsets);
        BuilderHandle.ApplyStackPermutation(MethodIdentifier, Program.StackOperandOffsets);
        const StubMask: i32 = @bitCast(Random.int(u32));
        const StubAttribute = try StubEmitter.EmitStub(AllocatorHandle, &ClassFileHandle.ConstantPool, CodeUtf8Index, MethodIdentifier, NativeRunMethodReference, Descriptor, IsStatic, StubMask);
        Member.Attributes.items[CodeAttributeIndex] = StubAttribute;
        DoneCount += 1;
    }
    try ClassFileHandle.Methods.appendSlice(AllocatorHandle, BridgeMethods.items);
    return DoneCount;
}
