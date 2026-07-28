const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const IdentifierGenerator = @import("IdentifierGenerator.zig");

pub const BootstrapMethodDescriptor = "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;IIIIIIIII)Ljava/lang/invoke/CallSite;";
const MajorVersion: u16 = 49;

pub const Bootstrap = struct {
    InternalName: []const u8,
    Bytes: []u8,
    StaticName: []const u8,
    VirtualName: []const u8,
    FieldGetName: []const u8,
    FieldStaticGetName: []const u8,
    FieldSetName: []const u8,
    FieldStaticSetName: []const u8,
    ConstructorName: []const u8,
    SpecialName: []const u8,
};

const ReferenceIndices = struct {
    LookupClass: u16,
    GetName: u16,
    HashCode: u16,
    GetDeclaredFields: u16,
    GetModifiers: u16,
    IsStatic: u16,
    GetType: u16,
    SetAccessible: u16,
    FieldGet: u16,
    LongArray: u16,
    NrD: u16,
    ConstantCallSite: u16,
    ConstantCallSiteInitialize: u16,
    GetClassLoader: u16,
    ForName: u16,
    FindStatic: u16,
    FindVirtual: u16,
    AsType: u16,
    Drop: u16,
    ReturnType: u16,
    FindGetter: u16,
    FindStaticGetter: u16,
    FindSetter: u16,
    FindStaticSetter: u16,
    ParameterType: u16,
    ClassLoaderGetter: u16,
    VoidType: u16,
    ChangeReturnType: u16,
    FindConstructor: u16,
    FindSpecial: u16,
};

fn Prologue(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices) !void {
    try AssemblerState.Aload(0);
    try AssemblerState.Invoke(0xb6, References.LookupClass);
    try AssemblerState.Astore(12);
    try AssemblerState.Aload(12);
    try AssemblerState.Invoke(0xb6, References.GetName);
    try AssemblerState.Invoke(0xb6, References.HashCode);
    try AssemblerState.Istore(13);
    try AssemblerState.Aload(12);
    try AssemblerState.Invoke(0xb6, References.GetDeclaredFields);
    try AssemblerState.Astore(14);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(15);
    try AssemblerState.Iload(3);
    try AssemblerState.Istore(16);
    try AssemblerState.Label("L");
    try AssemblerState.Aload(14);
    try AssemblerState.Iload(15);
    try AssemblerState.Operation0(0x32);
    try AssemblerState.Astore(17);
    try AssemblerState.Aload(17);
    try AssemblerState.Invoke(0xb6, References.GetModifiers);
    try AssemblerState.Invoke(0xb8, References.IsStatic);
    try AssemblerState.Branch(0x99, "N");
    try AssemblerState.Aload(17);
    try AssemblerState.Invoke(0xb6, References.GetType);
    try AssemblerState.Operation2(0x13, References.LongArray);
    try AssemblerState.Branch(0xa6, "N");
    try AssemblerState.Iload(16);
    try AssemblerState.Branch(0x99, "F");
    try AssemblerState.Iinc(16, -1);
    try AssemblerState.Label("N");
    try AssemblerState.Iinc(15, 1);
    try AssemblerState.Goto("L");
    try AssemblerState.Label("F");
    try AssemblerState.Aload(17);
    try AssemblerState.Iconst(1);
    try AssemblerState.Invoke(0xb6, References.SetAccessible);
    try AssemblerState.Aload(17);
    try AssemblerState.Operation0(0x01);
    try AssemblerState.Invoke(0xb6, References.FieldGet);
    try AssemblerState.Operation2(0xc0, References.LongArray);
    try AssemblerState.Astore(18);
    try AssemblerState.Aload(18);
    try AssemblerState.Iload(4);
    try AssemblerState.Iload(5);
    try AssemblerState.Iload(6);
    try AssemblerState.Iload(7);
    try AssemblerState.Iload(13);
    try AssemblerState.Invoke(0xb8, References.NrD);
    try AssemblerState.Astore(19);
    try AssemblerState.Aload(18);
    try AssemblerState.Iload(8);
    try AssemblerState.Iload(9);
    try AssemblerState.Iload(10);
    try AssemblerState.Iload(11);
    try AssemblerState.Iload(13);
    try AssemblerState.Invoke(0xb8, References.NrD);
    try AssemblerState.Astore(20);
}

fn ResolveOwner(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices) !void {
    try AssemblerState.Operation2(0xbb, References.ConstantCallSite);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(0);
    try AssemblerState.Aload(19);
    try AssemblerState.Iconst(0);
    try AssemblerState.Aload(0);
    try AssemblerState.Invoke(0xb6, References.LookupClass);
    try AssemblerState.Invoke(0xb6, References.GetClassLoader);
    if (References.ClassLoaderGetter != 0) try AssemblerState.Invoke(0xb8, References.ClassLoaderGetter);
    try AssemblerState.Invoke(0xb8, References.ForName);
}

fn Finish(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices) !void {
    try AssemblerState.Aload(2);
    try AssemblerState.Invoke(0xb6, References.AsType);
    try AssemblerState.Invoke(0xb7, References.ConstantCallSiteInitialize);
    try AssemblerState.Operation0(0xb0);
}

fn StaticBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(20);
    try AssemblerState.Aload(2);
    try AssemblerState.Invoke(0xb6, References.FindStatic);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn VirtualBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(20);
    try AssemblerState.Aload(2);
    try AssemblerState.Iconst(0);
    try AssemblerState.Iconst(1);
    try AssemblerState.Invoke(0xb6, References.Drop);
    try AssemblerState.Invoke(0xb6, References.FindVirtual);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn FieldGetBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices, FindReferenceIndex: u16) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(20);
    try AssemblerState.Aload(2);
    try AssemblerState.Invoke(0xb6, References.ReturnType);
    try AssemblerState.Invoke(0xb6, FindReferenceIndex);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn FieldSetBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices, FindReferenceIndex: u16, ArgumentIndex: i32) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(20);
    try AssemblerState.Aload(2);
    try AssemblerState.Iconst(ArgumentIndex);
    try AssemblerState.Invoke(0xb6, References.ParameterType);
    try AssemblerState.Invoke(0xb6, FindReferenceIndex);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn ConstructorBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(2);
    try AssemblerState.Operation2(0xb2, References.VoidType);
    try AssemblerState.Invoke(0xb6, References.ChangeReturnType);
    try AssemblerState.Invoke(0xb6, References.FindConstructor);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

fn SpecialBody(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try Prologue(&AssemblerState, References);
    try ResolveOwner(&AssemblerState, References);
    try AssemblerState.Aload(20);
    try AssemblerState.Aload(2);
    try AssemblerState.Iconst(0);
    try AssemblerState.Iconst(1);
    try AssemblerState.Invoke(0xb6, References.Drop);
    try AssemblerState.Aload(0);
    try AssemblerState.Invoke(0xb6, References.LookupClass);
    try AssemblerState.Invoke(0xb6, References.FindSpecial);
    try Finish(&AssemblerState, References);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, BootstrapMethodDescriptor, true, CodeUtf8Index);
}

pub fn ReferenceBootstrapSynthesizer(AllocatorHandle: std.mem.Allocator, InternalName: []const u8, LoaderInternalName: []const u8, ClassLoaderInternalName: []const u8) !Bootstrap {
    var Pool = try ConstantPoolBuilder.ConstantPool.InitEmpty(AllocatorHandle);
    const ThisClassIndex = try Pool.AddClass(InternalName);
    const ObjectClassIndex = try Pool.AddClass("java/lang/Object");
    const ObjectInitIndex = try Pool.AddMethodref("java/lang/Object", "<init>", "()V");
    const CodeUtf8Index = try Pool.AddUtf8("Code");

    const ClassLoaderGetterIndex: u16 = if (ClassLoaderInternalName.len > 0)
        try Pool.AddMethodref(ClassLoaderInternalName, "g", try std.fmt.allocPrint(AllocatorHandle, "(Ljava/lang/ClassLoader;)L{s};", .{ClassLoaderInternalName}))
    else
        0;

    const References = ReferenceIndices{
        .LookupClass = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "lookupClass", "()Ljava/lang/Class;"),
        .GetName = try Pool.AddMethodref("java/lang/Class", "getName", "()Ljava/lang/String;"),
        .HashCode = try Pool.AddMethodref("java/lang/String", "hashCode", "()I"),
        .GetDeclaredFields = try Pool.AddMethodref("java/lang/Class", "getDeclaredFields", "()[Ljava/lang/reflect/Field;"),
        .GetModifiers = try Pool.AddMethodref("java/lang/reflect/Field", "getModifiers", "()I"),
        .IsStatic = try Pool.AddMethodref("java/lang/reflect/Modifier", "isStatic", "(I)Z"),
        .GetType = try Pool.AddMethodref("java/lang/reflect/Field", "getType", "()Ljava/lang/Class;"),
        .SetAccessible = try Pool.AddMethodref("java/lang/reflect/AccessibleObject", "setAccessible", "(Z)V"),
        .FieldGet = try Pool.AddMethodref("java/lang/reflect/Field", "get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
        .LongArray = try Pool.AddClass("[J"),
        .NrD = try Pool.AddMethodref(LoaderInternalName, "d", "([JIIIII)Ljava/lang/String;"),
        .ConstantCallSite = try Pool.AddClass("java/lang/invoke/ConstantCallSite"),
        .ConstantCallSiteInitialize = try Pool.AddMethodref("java/lang/invoke/ConstantCallSite", "<init>", "(Ljava/lang/invoke/MethodHandle;)V"),
        .GetClassLoader = try Pool.AddMethodref("java/lang/Class", "getClassLoader", "()Ljava/lang/ClassLoader;"),
        .ForName = try Pool.AddMethodref("java/lang/Class", "forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;"),
        .FindStatic = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findStatic", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;"),
        .FindVirtual = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findVirtual", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;"),
        .AsType = try Pool.AddMethodref("java/lang/invoke/MethodHandle", "asType", "(Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;"),
        .Drop = try Pool.AddMethodref("java/lang/invoke/MethodType", "dropParameterTypes", "(II)Ljava/lang/invoke/MethodType;"),
        .ReturnType = try Pool.AddMethodref("java/lang/invoke/MethodType", "returnType", "()Ljava/lang/Class;"),
        .FindGetter = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findGetter", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;"),
        .FindStaticGetter = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findStaticGetter", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;"),
        .FindSetter = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findSetter", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;"),
        .FindStaticSetter = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findStaticSetter", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;"),
        .ParameterType = try Pool.AddMethodref("java/lang/invoke/MethodType", "parameterType", "(I)Ljava/lang/Class;"),
        .ClassLoaderGetter = ClassLoaderGetterIndex,
        .VoidType = try Pool.AddFieldref("java/lang/Void", "TYPE", "Ljava/lang/Class;"),
        .ChangeReturnType = try Pool.AddMethodref("java/lang/invoke/MethodType", "changeReturnType", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodType;"),
        .FindConstructor = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findConstructor", "(Ljava/lang/Class;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;"),
        .FindSpecial = try Pool.AddMethodref("java/lang/invoke/MethodHandles$Lookup", "findSpecial", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;"),
    };

    var InitAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &Pool);
    try InitAssembler.Aload(0);
    try InitAssembler.Invoke(0xb7, ObjectInitIndex);
    try InitAssembler.Operation0(0xb1);
    const InitMethodInfo = try Assembler.BuildMethod(AllocatorHandle, &Pool, try InitAssembler.Finish(), &.{}, "()V", false, CodeUtf8Index);

    var Names: [8][]const u8 = undefined;
    for (0..8) |BootstrapIndex| Names[BootstrapIndex] = try IdentifierGenerator.AbcName(AllocatorHandle, BootstrapIndex);

    const Bodies = [_]ClassFileModel.Attribute{
        try StaticBody(AllocatorHandle, &Pool, CodeUtf8Index, References),
        try VirtualBody(AllocatorHandle, &Pool, CodeUtf8Index, References),
        try FieldGetBody(AllocatorHandle, &Pool, CodeUtf8Index, References, References.FindGetter),
        try FieldGetBody(AllocatorHandle, &Pool, CodeUtf8Index, References, References.FindStaticGetter),
        try FieldSetBody(AllocatorHandle, &Pool, CodeUtf8Index, References, References.FindSetter, 1),
        try FieldSetBody(AllocatorHandle, &Pool, CodeUtf8Index, References, References.FindStaticSetter, 0),
        try ConstructorBody(AllocatorHandle, &Pool, CodeUtf8Index, References),
        try SpecialBody(AllocatorHandle, &Pool, CodeUtf8Index, References),
    };

    var Methods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    var InitAttributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try InitAttributes.append(AllocatorHandle, InitMethodInfo);
    try Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessPublic, .NameIndex = try Pool.AddUtf8("<init>"), .DescriptorIndex = try Pool.AddUtf8("()V"), .Attributes = InitAttributes });

    for (Names, 0..) |Name, Index| {
        var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
        try Attributes.append(AllocatorHandle, Bodies[Index]);
        try Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessPublic | AccessFlags.AccessStatic, .NameIndex = try Pool.AddUtf8(Name), .DescriptorIndex = try Pool.AddUtf8(BootstrapMethodDescriptor), .Attributes = Attributes });
    }

    var ClassFileValue = ClassFileModel.ClassFile{
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
    return .{
        .InternalName = InternalName,
        .Bytes = try ClassFileModel.Serialize(AllocatorHandle, &ClassFileValue),
        .StaticName = Names[0],
        .VirtualName = Names[1],
        .FieldGetName = Names[2],
        .FieldStaticGetName = Names[3],
        .FieldSetName = Names[4],
        .FieldStaticSetName = Names[5],
        .ConstructorName = Names[6],
        .SpecialName = Names[7],
    };
}
