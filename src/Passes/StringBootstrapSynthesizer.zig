const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const Assembler = @import("../Classfile/Assembler.zig");

pub const BootstrapMethodDescriptor = "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;IIIII)Ljava/lang/invoke/CallSite;";
pub const StringMethod = "b";
pub const ConcatMethod = "c";
const MajorVersion: u16 = 49;

pub const Synthesized = struct {
    Bytes: []u8,
};

const ReferenceIndices = struct {
    LookupClass: u16,
    GetDeclaredFields: u16,
    GetModifiers: u16,
    IsStatic: u16,
    GetType: u16,
    SetAccessible: u16,
    FieldGet: u16,
    LongArray: u16,
    GetName: u16,
    HashCode: u16,
    NativeReaderD: u16,
    StringClass: u16,
    MethodHandleConstant: u16,
    ConstantCallSiteClass: u16,
    ConstantCallSiteInit: u16,
    ObjectClass: u16,
    StringConcatFactory: u16,
};

fn Prologue(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices) !void {
    try AssemblerState.Aload(0);
    try AssemblerState.Invoke(0xb6, References.LookupClass);
    try AssemblerState.Astore(8);
    try AssemblerState.Aload(8);
    try AssemblerState.Invoke(0xb6, References.GetName);
    try AssemblerState.Invoke(0xb6, References.HashCode);
    try AssemblerState.Istore(9);
    try AssemblerState.Aload(8);
    try AssemblerState.Invoke(0xb6, References.GetDeclaredFields);
    try AssemblerState.Astore(10);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(11);
    try AssemblerState.Iload(3);
    try AssemblerState.Istore(12);
    try AssemblerState.Label("L");
    try AssemblerState.Aload(10);
    try AssemblerState.Iload(11);
    try AssemblerState.Operation0(0x32);
    try AssemblerState.Astore(13);
    try AssemblerState.Aload(13);
    try AssemblerState.Invoke(0xb6, References.GetModifiers);
    try AssemblerState.Invoke(0xb8, References.IsStatic);
    try AssemblerState.Branch(0x99, "N");
    try AssemblerState.Aload(13);
    try AssemblerState.Invoke(0xb6, References.GetType);
    try AssemblerState.Operation2(0x13, References.LongArray);
    try AssemblerState.Branch(0xa6, "N");
    try AssemblerState.Iload(12);
    try AssemblerState.Branch(0x99, "F");
    try AssemblerState.Iinc(12, -1);
    try AssemblerState.Label("N");
    try AssemblerState.Iinc(11, 1);
    try AssemblerState.Goto("L");
    try AssemblerState.Label("F");
    try AssemblerState.Aload(13);
    try AssemblerState.Iconst(1);
    try AssemblerState.Invoke(0xb6, References.SetAccessible);
    try AssemblerState.Aload(13);
    try AssemblerState.Operation0(0x01);
    try AssemblerState.Invoke(0xb6, References.FieldGet);
    try AssemblerState.Operation2(0xc0, References.LongArray);
    try AssemblerState.Astore(14);
    try AssemblerState.Aload(14);
    try AssemblerState.Iload(4);
    try AssemblerState.Iload(5);
    try AssemblerState.Iload(6);
    try AssemblerState.Iload(7);
    try AssemblerState.Iload(9);
    try AssemblerState.Invoke(0xb8, References.NativeReaderD);
    try AssemblerState.Astore(15);
}

fn BuildString(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try AssemblerState.Operation2(0xbb, References.ConstantCallSiteClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Operation2(0x13, References.StringClass);
    try AssemblerState.Aload(15);
    try AssemblerState.Invoke(0xb8, References.MethodHandleConstant);
    try AssemblerState.Invoke(0xb7, References.ConstantCallSiteInit);
    try AssemblerState.Operation0(0xb0);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn BuildConcat(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try AssemblerState.Aload(0);
    try AssemblerState.Aload(1);
    try AssemblerState.Aload(2);
    try AssemblerState.Aload(15);
    try AssemblerState.Iconst(0);
    try AssemblerState.Operation2(0xbd, References.ObjectClass);
    try AssemblerState.Invoke(0xb8, References.StringConcatFactory);
    try AssemblerState.Operation0(0xb0);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

pub fn StringBootstrapSynthesizer(AllocatorHandle: std.mem.Allocator, InternalName: []const u8, NativeReaderInternal: []const u8) !Synthesized {
    var Pool = try ConstantPoolBuilder.ConstantPool.InitEmpty(AllocatorHandle);
    const ThisClassIndex = try Pool.AddClass(InternalName);
    const ObjectClassIndex = try Pool.AddClass("java/lang/Object");
    const ObjectInitIndex = try Pool.AddMethodref("java/lang/Object", "<init>", "()V");
    const CodeUtf8Index = try Pool.AddUtf8("Code");

    const References = ReferenceIndices{
        .LookupClass = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "lookupClass", "()Ljava/lang/Class;"),
        .GetDeclaredFields = try Pool.AddMethodref("java/lang/Class", "getDeclaredFields", "()[Ljava/lang/reflect/Field;"),
        .GetModifiers = try Pool.AddMethodref("java/lang/reflect/Field", "getModifiers", "()I"),
        .IsStatic = try Pool.AddMethodref("java/lang/reflect/Modifier", "isStatic", "(I)Z"),
        .GetType = try Pool.AddMethodref("java/lang/reflect/Field", "getType", "()Ljava/lang/Class;"),
        .SetAccessible = try Pool.AddMethodref("java/lang/reflect/AccessibleObject", "setAccessible", "(Z)V"),
        .FieldGet = try Pool.AddMethodref("java/lang/reflect/Field", "get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
        .LongArray = try Pool.AddClass("[J"),
        .GetName = try Pool.AddMethodref("java/lang/Class", "getName", "()Ljava/lang/String;"),
        .HashCode = try Pool.AddMethodref("java/lang/String", "hashCode", "()I"),
        .NativeReaderD = try Pool.AddMethodref(NativeReaderInternal, "d", "([JIIIII)Ljava/lang/String;"),
        .StringClass = try Pool.AddClass("java/lang/String"),
        .MethodHandleConstant = try Pool.AddMethodref("java/lang/invoke/MethodHandles", "constant", "(Ljava/lang/Class;Ljava/lang/Object;)Ljava/lang/invoke/MethodHandle;"),
        .ConstantCallSiteClass = try Pool.AddClass("java/lang/invoke/ConstantCallSite"),
        .ConstantCallSiteInit = try Pool.AddMethodref("java/lang/invoke/ConstantCallSite", "<init>", "(Ljava/lang/invoke/MethodHandle;)V"),
        .ObjectClass = ObjectClassIndex,
        .StringConcatFactory = try Pool.AddMethodref("java/lang/invoke/StringConcatFactory", "makeConcatWithConstants", "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/invoke/CallSite;"),
    };

    var InitAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &Pool);
    try InitAssembler.Aload(0);
    try InitAssembler.Invoke(0xb7, ObjectInitIndex);
    try InitAssembler.Operation0(0xb1);
    const InitInfo = try Assembler.BuildMethod(AllocatorHandle, &Pool, try InitAssembler.Finish(), &.{}, "()V", false, CodeUtf8Index);

    const StringMethodInfo = try BuildString(AllocatorHandle, &Pool, CodeUtf8Index, References);
    const ConcatMethodInfo = try BuildConcat(AllocatorHandle, &Pool, CodeUtf8Index, References);

    var Methods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    try AddMethod(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic, "<init>", "()V", InitInfo);
    try AddMethod(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic | AccessFlags.AccessStatic, StringMethod, BootstrapMethodDescriptor, StringMethodInfo);
    try AddMethod(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic | AccessFlags.AccessStatic, ConcatMethod, BootstrapMethodDescriptor, ConcatMethodInfo);

    var ClassFileData = ClassFileModel.ClassFile{
        .Allocator = AllocatorHandle,
        .Minor = 0,
        .Major = MajorVersion,
        .ConstantPool = Pool,
        .AccessFlags = AccessFlags.AccessPublic | AccessFlags.AccessFinal | AccessFlags.AccessSuper,
        .ThisClass = ThisClassIndex,
        .SuperClass = ObjectClassIndex,
        .Interfaces = .empty,
        .Fields = .empty,
        .Methods = Methods,
        .Attributes = .empty,
    };
    return .{ .Bytes = try ClassFileModel.Serialize(AllocatorHandle, &ClassFileData) };
}

fn AddMethod(AllocatorHandle: std.mem.Allocator, Methods: *std.ArrayList(ClassFileModel.MemberInfo), Pool: *ConstantPoolBuilder.ConstantPool, Flags: u16, Name: []const u8, Descriptor: []const u8, Info: ClassFileModel.Attribute) !void {
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, Info);
    try Methods.append(AllocatorHandle, .{ .AccessFlags = Flags, .NameIndex = try Pool.AddUtf8(Name), .DescriptorIndex = try Pool.AddUtf8(Descriptor), .Attributes = Attributes });
}
