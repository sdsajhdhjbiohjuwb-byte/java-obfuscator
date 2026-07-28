const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");
const Assembler = @import("../Classfile/Assembler.zig");

pub const Synthesized = struct { Bytes: []u8 };
const GetName = "g";
const MajorVersion: u16 = 49;

pub fn CustomClassLoaderSynthesizer(
    AllocatorHandle: std.mem.Allocator,
    InternalName: []const u8,
    Extension: []const u8,
    NativeReaderInternalName: []const u8,
) !Synthesized {
    var Pool = try ConstantPoolBuilder.ConstantPool.InitEmpty(AllocatorHandle);
    const ThisClassIndex = try Pool.AddClass(InternalName);
    const ClassLoaderClassIndex = try Pool.AddClass("java/lang/ClassLoader");
    const ClassLoaderInitializeIndex = try Pool.AddMethodref("java/lang/ClassLoader", "<init>", "(Ljava/lang/ClassLoader;)V");
    const GetParentIndex = try Pool.AddMethodref("java/lang/ClassLoader", "getParent", "()Ljava/lang/ClassLoader;");
    const GetResourceIndex = try Pool.AddMethodref("java/lang/ClassLoader", "getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;");
    const DefineClassIndex = try Pool.AddMethodref("java/lang/ClassLoader", "defineClass", "(Ljava/lang/String;[BII)Ljava/lang/Class;");
    const StringReplaceIndex = try Pool.AddMethodref("java/lang/String", "replace", "(CC)Ljava/lang/String;");
    const StringConcatIndex = try Pool.AddMethodref("java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;");
    const ReadAllBytesIndex = try Pool.AddMethodref("java/io/InputStream", "readAllBytes", "()[B");
    const ClassNotFoundExceptionIndex = try Pool.AddClass("java/lang/ClassNotFoundException");
    const ClassNotFoundExceptionInitializeIndex = try Pool.AddMethodref("java/lang/ClassNotFoundException", "<init>", "(Ljava/lang/String;)V");
    const ExtensionStringIndex = try Pool.AddString(Extension);

    const ThisDescriptor = try std.fmt.allocPrint(AllocatorHandle, "L{s};", .{InternalName});
    const KbMethodReferenceIndex = try Pool.AddMethodref(NativeReaderInternalName, "kb", "(II)I");
    const GetReferenceDescriptor = try std.fmt.allocPrint(AllocatorHandle, "(Ljava/lang/ClassLoader;)L{s};", .{InternalName});
    const HolderFieldIndex = try Pool.AddFieldref(InternalName, "H", ThisDescriptor);

    const CodeUtf8Index = try Pool.AddUtf8("Code");

    var InitializeAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &Pool);
    try InitializeAssembler.Aload(0);
    try InitializeAssembler.Aload(1);
    try InitializeAssembler.Invoke(0xb7, ClassLoaderInitializeIndex);
    try InitializeAssembler.Operation0(0xb1);
    const InitializeMethodAttribute = try Assembler.BuildMethod(AllocatorHandle, &Pool, try InitializeAssembler.Finish(), &.{}, "(Ljava/lang/ClassLoader;)V", false, CodeUtf8Index);

    var GetAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &Pool);
    try GetAssembler.Invoke(0xb2, HolderFieldIndex);
    try GetAssembler.Branch(0xc7, "have");
    try GetAssembler.Operation2(0xbb, ThisClassIndex);
    try GetAssembler.Operation0(0x59);
    try GetAssembler.Aload(0);
    try GetAssembler.Invoke(0xb7, try Pool.AddMethodref(InternalName, "<init>", "(Ljava/lang/ClassLoader;)V"));
    try GetAssembler.Invoke(0xb3, HolderFieldIndex);
    try GetAssembler.Label("have");
    try GetAssembler.Invoke(0xb2, HolderFieldIndex);
    try GetAssembler.Operation0(0xb0);
    const GetMethodAttribute = try Assembler.BuildMethod(AllocatorHandle, &Pool, try GetAssembler.Finish(), &.{}, GetReferenceDescriptor, true, CodeUtf8Index);

    const FindMethodAttribute = try BuildFind(AllocatorHandle, &Pool, CodeUtf8Index, .{
        .Name = 1,
        .GetParent = GetParentIndex,
        .GetResource = GetResourceIndex,
        .ReadAll = ReadAllBytesIndex,
        .Define = DefineClassIndex,
        .StringReplace = StringReplaceIndex,
        .StringConcat = StringConcatIndex,
        .ExtensionString = ExtensionStringIndex,
        .ClassNotFoundException = ClassNotFoundExceptionIndex,
        .ClassNotFoundExceptionInitialize = ClassNotFoundExceptionInitializeIndex,
        .KeystreamReference = KbMethodReferenceIndex,
        .HashCodeReference = try Pool.AddMethodref("java/lang/String", "hashCode", "()I"),
        .UnpackReference = try Pool.AddMethodref(NativeReaderInternalName, "unpack", "([B)[B"),
    });

    var Fields: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    try Fields.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessPrivate | AccessFlags.AccessStatic | AccessFlags.AccessVolatile, .NameIndex = try Pool.AddUtf8("H"), .DescriptorIndex = try Pool.AddUtf8(ThisDescriptor), .Attributes = .empty });

    var Methods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    try Add(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic, "<init>", "(Ljava/lang/ClassLoader;)V", InitializeMethodAttribute);
    try Add(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic | AccessFlags.AccessStatic, GetName, GetReferenceDescriptor, GetMethodAttribute);
    try Add(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessProtected, "findClass", "(Ljava/lang/String;)Ljava/lang/Class;", FindMethodAttribute);

    var ClassFileInstance = ClassFileModel.ClassFile{
        .Allocator = AllocatorHandle,
        .Minor = 0,
        .Major = MajorVersion,
        .ConstantPool = Pool,
        .AccessFlags = AccessFlags.AccessPublic | AccessFlags.AccessFinal | AccessFlags.AccessSuper,
        .ThisClass = ThisClassIndex,
        .SuperClass = ClassLoaderClassIndex,
        .Interfaces = .empty,
        .Fields = Fields,
        .Methods = Methods,
        .Attributes = .empty,
    };
    return .{ .Bytes = try ClassFileModel.Serialize(AllocatorHandle, &ClassFileInstance) };
}

const FindMethodReferences = struct {
    Name: u8,
    GetParent: u16,
    GetResource: u16,
    ReadAll: u16,
    Define: u16,
    StringReplace: u16,
    StringConcat: u16,
    ExtensionString: u16,
    ClassNotFoundException: u16,
    ClassNotFoundExceptionInitialize: u16,
    KeystreamReference: u16,
    HashCodeReference: u16,
    UnpackReference: u16,
};

fn BuildFind(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: FindMethodReferences) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    try AssemblerState.Aload(1);
    try AssemblerState.Iconst('.');
    try AssemblerState.Iconst('/');
    try AssemblerState.Invoke(0xb6, References.StringReplace);
    try AssemblerState.Operation2(0x13, References.ExtensionString);
    try AssemblerState.Invoke(0xb6, References.StringConcat);
    try AssemblerState.Astore(2);
    try AssemblerState.Aload(0);
    try AssemblerState.Invoke(0xb6, References.GetParent);
    try AssemblerState.Aload(2);
    try AssemblerState.Invoke(0xb6, References.GetResource);
    try AssemblerState.Astore(3);
    try AssemblerState.Aload(3);
    try AssemblerState.Branch(0xc7, "have");
    try ThrowClassNotFoundException(&AssemblerState, References);
    try AssemblerState.Label("have");
    try AssemblerState.Label("tryStart");
    try AssemblerState.Aload(3);
    try AssemblerState.Invoke(0xb6, References.ReadAll);
    try AssemblerState.Astore(4);
    try AssemblerState.Label("tryEnd");
    try AssemblerState.Goto("after");
    try AssemblerState.Label("handler");
    try AssemblerState.Astore(6);
    try ThrowClassNotFoundException(&AssemblerState, References);
    try AssemblerState.Label("after");
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(5);
    try AssemblerState.Label("decHead");
    try AssemblerState.Iload(5);
    try AssemblerState.Aload(4);
    try AssemblerState.Operation0(0xbe);
    try AssemblerState.Branch(0xa2, "decEnd");
    try AssemblerState.Aload(4);
    try AssemblerState.Iload(5);
    try AssemblerState.Aload(4);
    try AssemblerState.Iload(5);
    try AssemblerState.Operation0(0x33);
    try AssemblerState.Iload(5);
    try AssemblerState.Aload(References.Name);
    try AssemblerState.Invoke(0xb6, References.HashCodeReference);
    try AssemblerState.Invoke(0xb8, References.KeystreamReference);
    try AssemblerState.Operation0(0x82);
    try AssemblerState.Operation0(0x91);
    try AssemblerState.Operation0(0x54);
    try AssemblerState.Iinc(5, 1);
    try AssemblerState.Goto("decHead");
    try AssemblerState.Label("decEnd");
    try AssemblerState.Aload(4);
    try AssemblerState.Invoke(0xb8, References.UnpackReference);
    try AssemblerState.Astore(4);
    try AssemblerState.Aload(0);
    try AssemblerState.Aload(1);
    try AssemblerState.Aload(4);
    try AssemblerState.Iconst(0);
    try AssemblerState.Aload(4);
    try AssemblerState.Operation0(0xbe);
    try AssemblerState.Invoke(0xb6, References.Define);
    try AssemblerState.Operation0(0xb0);

    const Instructions = try AssemblerState.Finish();
    var ExceptionTable: std.ArrayList(BytecodeInstructionModel.ExceptionEntry) = .empty;
    try ExceptionTable.append(AllocatorHandle, .{ .Start = AssemblerState.LabelIdentifier("tryStart"), .End = AssemblerState.LabelIdentifier("tryEnd"), .Handler = AssemblerState.LabelIdentifier("handler"), .CatchType = 0 });
    return Assembler.BuildMethod(AllocatorHandle, Pool, Instructions, ExceptionTable.items, "(Ljava/lang/String;)Ljava/lang/Class;", false, CodeUtf8Index);
}

fn ThrowClassNotFoundException(AssemblerState: *Assembler.AssemblerState, References: FindMethodReferences) !void {
    try AssemblerState.Operation2(0xbb, References.ClassNotFoundException);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(1);
    try AssemblerState.Invoke(0xb7, References.ClassNotFoundExceptionInitialize);
    try AssemblerState.Operation0(0xbf);
}

fn Add(AllocatorHandle: std.mem.Allocator, Methods: *std.ArrayList(ClassFileModel.MemberInfo), Pool: *ConstantPoolBuilder.ConstantPool, Flags: u16, Name: []const u8, Descriptor: []const u8, Info: ClassFileModel.Attribute) !void {
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, Info);
    try Methods.append(AllocatorHandle, .{ .AccessFlags = Flags, .NameIndex = try Pool.AddUtf8(Name), .DescriptorIndex = try Pool.AddUtf8(Descriptor), .Attributes = Attributes });
}
