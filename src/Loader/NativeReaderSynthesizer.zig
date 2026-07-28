const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const ConstantPoolBuilder = @import("../Classfile/ConstantPoolBuilder.zig");
const Assembler = @import("../Classfile/Assembler.zig");
const NativeContainerPacker = @import("../Native/NativeContainerPacker.zig");

pub const Synthesized = struct { Bytes: []u8 };
const MajorVersion: u16 = 49;

const ReferenceIndices = struct {
    GetProperty: u16,
    Lower: u16,
    Contains: u16,
    UrlClassLoaderClass: u16,
    UrlClassLoaderInitialize: u16,
    ThisClass: u16,
    GetResource: u16,
    ReadAll: u16,
    InflaterClass: u16,
    InflaterInitialize: u16,
    InflaterSetInput: u16,
    InflaterInflate: u16,
    InflaterEnd: u16,
    GetAbsolutePath: u16,
    FileOutputStreamClass: u16,
    FileOutputStreamInitialize: u16,
    FileOutputStreamWrite: u16,
    FileOutputStreamClose: u16,
    Load: u16,
    SelfG: u16,
    SelfVh: u16,
    ResourcePath: u16,
    StringOperatingSystemName: u16,
    StringOperatingSystemArchitecture: u16,
    StringAmd64: u16,
    StringX8664: u16,
    StringAarch64: u16,
    StringArm64: u16,
    StringWin: u16,
    StringMac: u16,
    StringDarwin: u16,
    StringNux: u16,
    StringNix: u16,
    StringDll: u16,
    StringDylib: u16,
    StringSo: u16,
    RandomClass: u16,
    RandomInitialize: u16,
    RandomNextInt: u16,
    StringBuilderClass: u16,
    StringBuilderInitialize: u16,
    StringBuilderAppendChar: u16,
    StringBuilderAppendString: u16,
    StringBuilderToString: u16,
    FileClass: u16,
    FileInitialize2: u16,
    FileInitializeUri: u16,
    GetParentFile: u16,
    GetPath: u16,
    GetProtectionDomain: u16,
    GetCodeSource: u16,
    GetLocation: u16,
    UrlToUri: u16,
    CipherGetInstance: u16,
    CipherInitialize: u16,
    CipherDoFinal: u16,
    SecretKeySpecClass: u16,
    SecretKeySpecInitialize: u16,
    IvSpecClass: u16,
    IvSpecInitialize: u16,
    ArraysCopyOfRange: u16,
    StringChaCha: u16,
    StringChaChaPoly: u16,
    ObjectInitialize: u16,
    FileToPath: u16,
    FileDeleteOnExit: u16,
    FileDelete: u16,
    FilesReadAllBytes: u16,
    StringJar: u16,
    GetProtocol: u16,
    StringEquals: u16,
    OpenConnection: u16,
    JarUrlConnectionClass: u16,
    GetJarFileUrl: u16,
};

fn Contains(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices, StringVarSlot: u8, StringReference: u16) !void {
    try AssemblerState.Aload(StringVarSlot);
    try AssemblerState.Operation2(0x13, StringReference);
    try AssemblerState.Invoke(0xb6, References.Contains);
}

fn EmitGCall(AssemblerState: *Assembler.AssemblerState, References: ReferenceIndices, ArrayVarSlot: u8, PositionVarSlot: u8, Delta: i32) !void {
    try AssemblerState.Aload(ArrayVarSlot);
    try AssemblerState.Iload(PositionVarSlot);
    if (Delta != 0) {
        try AssemblerState.Iconst(Delta);
        try AssemblerState.Operation0(0x60);
    }
    try AssemblerState.Invoke(0xb8, References.SelfG);
}

fn BuildG(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);
    var ShiftAmount: i32 = 24;
    var ThirdIndex: i32 = 0;
    while (ThirdIndex < 4) : (ThirdIndex += 1) {
        try AssemblerState.Aload(0);
        try AssemblerState.Iload(1);
        if (ThirdIndex != 0) {
            try AssemblerState.Iconst(ThirdIndex);
            try AssemblerState.Operation0(0x60);
        }
        try AssemblerState.Operation0(0x33);
        try AssemblerState.Iconst(255);
        try AssemblerState.Operation0(0x7e);
        if (ShiftAmount != 0) {
            try AssemblerState.Iconst(ShiftAmount);
            try AssemblerState.Operation0(0x78);
        }
        if (ThirdIndex != 0) try AssemblerState.Operation0(0x80);
        ShiftAmount -= 8;
    }
    try AssemblerState.Operation0(0xac);
    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, "([BI)I", true, CodeUtf8Index);
}

fn BuildClinit(AllocatorHandle: std.mem.Allocator, Pool: *ConstantPoolBuilder.ConstantPool, CodeUtf8Index: u16, References: ReferenceIndices, IntegrityHash: i64, DatWords: [11]u32, LibraryHashes: []const NativeContainerPacker.LibraryHash) !ClassFileModel.Attribute {
    var AssemblerState = Assembler.AssemblerState.Initialize(AllocatorHandle, Pool);

    try AssemblerState.Operation2(0x13, References.StringOperatingSystemName);
    try AssemblerState.Invoke(0xb8, References.GetProperty);
    try AssemblerState.Invoke(0xb6, References.Lower);
    try AssemblerState.Astore(0);
    try AssemblerState.Operation2(0x13, References.StringOperatingSystemArchitecture);
    try AssemblerState.Invoke(0xb8, References.GetProperty);
    try AssemblerState.Invoke(0xb6, References.Lower);
    try AssemblerState.Astore(1);

    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(27);
    try AssemblerState.Iconst(1);
    try AssemblerState.Istore(3);
    try Contains(&AssemblerState, References, 1, References.StringAmd64);
    try AssemblerState.Branch(0x9a, "archDone");
    try Contains(&AssemblerState, References, 1, References.StringX8664);
    try AssemblerState.Branch(0x9a, "archDone");
    try AssemblerState.Iconst(1);
    try AssemblerState.Istore(27);
    try Contains(&AssemblerState, References, 1, References.StringAarch64);
    try AssemblerState.Branch(0x9a, "archDone");
    try Contains(&AssemblerState, References, 1, References.StringArm64);
    try AssemblerState.Branch(0x9a, "archDone");
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(3);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(27);
    try AssemblerState.Label("archDone");

    try Contains(&AssemblerState, References, 0, References.StringWin);
    try AssemblerState.Branch(0x99, "notWin");
    try AssemblerState.Iconst(1);
    try AssemblerState.Istore(2);
    try AssemblerState.Goto("tagDone");
    try AssemblerState.Label("notWin");
    try Contains(&AssemblerState, References, 0, References.StringMac);
    try AssemblerState.Branch(0x9a, "isMac");
    try Contains(&AssemblerState, References, 0, References.StringDarwin);
    try AssemblerState.Branch(0x99, "notMac");
    try AssemblerState.Label("isMac");
    try AssemblerState.Iconst(3);
    try AssemblerState.Istore(2);
    try AssemblerState.Goto("tagDone");
    try AssemblerState.Label("notMac");
    try Contains(&AssemblerState, References, 0, References.StringNux);
    try AssemblerState.Branch(0x9a, "isNix");
    try Contains(&AssemblerState, References, 0, References.StringNix);
    try AssemblerState.Branch(0x99, "notNix");
    try AssemblerState.Label("isNix");
    try AssemblerState.Iconst(2);
    try AssemblerState.Istore(2);
    try AssemblerState.Goto("tagDone");
    try AssemblerState.Label("notNix");
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(2);
    try AssemblerState.Label("tagDone");

    try AssemblerState.Iload(3);
    try AssemblerState.Branch(0x99, "doThrow");
    try AssemblerState.Iload(2);
    try AssemblerState.Branch(0x9a, "okPlat");
    try AssemblerState.Label("doThrow");
    try AssemblerState.Operation2(0xbb, References.UrlClassLoaderClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Operation2(0x13, References.StringOperatingSystemName);
    try AssemblerState.Invoke(0xb7, References.UrlClassLoaderInitialize);
    try AssemblerState.Operation0(0xbf);
    try AssemblerState.Label("okPlat");

    try AssemblerState.Iload(27);
    try AssemblerState.Branch(0x99, "notArm");
    try AssemblerState.Iload(2);
    try AssemblerState.Iconst(3);
    try AssemblerState.Operation0(0x60);
    try AssemblerState.Istore(2);
    try AssemblerState.Label("notArm");

    try AssemblerState.Operation2(0x13, References.ThisClass);
    try AssemblerState.Operation2(0x13, References.ResourcePath);
    try AssemblerState.Invoke(0xb6, References.GetResource);
    try AssemblerState.Invoke(0xb6, References.ReadAll);
    try AssemblerState.Astore(4);

    try AssemblerState.Iconst(11);
    try AssemblerState.NewarrayInt();
    try AssemblerState.Astore(32);
    for (DatWords, 0..) |Word, WordIndex| {
        try AssemblerState.Aload(32);
        try AssemblerState.Iconst(@intCast(WordIndex));
        try AssemblerState.Iconst(@bitCast(Word));
        try AssemblerState.Operation0(0x4f);
    }
    try AssemblerState.Iconst(44);
    try AssemblerState.Operation1(0xbc, 8);
    try AssemblerState.Astore(33);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(34);
    try AssemblerState.Label("unpackLoop");
    try AssemblerState.Iload(34);
    try AssemblerState.Iconst(44);
    try AssemblerState.Branch(0xa2, "unpackDone");
    try AssemblerState.Aload(33);
    try AssemblerState.Iload(34);
    try AssemblerState.Aload(32);
    try AssemblerState.Iload(34);
    try AssemblerState.Iconst(2);
    try AssemblerState.Operation0(0x7c);
    try AssemblerState.Operation0(0x2e);
    try AssemblerState.Iload(34);
    try AssemblerState.Iconst(3);
    try AssemblerState.Operation0(0x7e);
    try AssemblerState.Iconst(3);
    try AssemblerState.Operation0(0x78);
    try AssemblerState.Operation0(0x7c);
    try AssemblerState.Operation0(0x91);
    try AssemblerState.Operation0(0x54);
    try AssemblerState.Iinc(34, 1);
    try AssemblerState.Goto("unpackLoop");
    try AssemblerState.Label("unpackDone");

    try AssemblerState.Operation2(0xbb, References.SecretKeySpecClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(33);
    try AssemblerState.Iconst(0);
    try AssemblerState.Iconst(32);
    try AssemblerState.Operation2(0x13, References.StringChaCha);
    try AssemblerState.Invoke(0xb7, References.SecretKeySpecInitialize);
    try AssemblerState.Astore(35);
    try AssemblerState.Aload(33);
    try AssemblerState.Iconst(32);
    try AssemblerState.Iconst(44);
    try AssemblerState.Invoke(0xb8, References.ArraysCopyOfRange);
    try AssemblerState.Astore(36);
    try AssemblerState.Operation2(0xbb, References.IvSpecClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(36);
    try AssemblerState.Invoke(0xb7, References.IvSpecInitialize);
    try AssemblerState.Astore(37);
    try AssemblerState.Operation2(0x13, References.StringChaChaPoly);
    try AssemblerState.Invoke(0xb8, References.CipherGetInstance);
    try AssemblerState.Astore(38);
    try AssemblerState.Aload(38);
    try AssemblerState.Iconst(2);
    try AssemblerState.Aload(35);
    try AssemblerState.Aload(37);
    try AssemblerState.Invoke(0xb6, References.CipherInitialize);
    try AssemblerState.Aload(38);
    try AssemblerState.Aload(4);
    try AssemblerState.Invoke(0xb6, References.CipherDoFinal);
    try AssemblerState.Astore(4);

    try AssemblerState.Aload(4);
    try AssemblerState.Iconst(4);
    try AssemblerState.Operation0(0x33);
    try AssemblerState.Iconst(255);
    try AssemblerState.Operation0(0x7e);
    try AssemblerState.Istore(5);
    try AssemblerState.Iconst(6);
    try AssemblerState.Iload(5);
    try AssemblerState.Iconst(9);
    try AssemblerState.Operation0(0x68);
    try AssemblerState.Operation0(0x60);
    try AssemblerState.Istore(7);
    try AssemblerState.Iconst(6);
    try AssemblerState.Istore(6);
    try AssemblerState.Iconst(-1);
    try AssemblerState.Istore(8);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(9);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(10);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(11);

    try AssemblerState.Label("loopHead");
    try AssemblerState.Iload(11);
    try AssemblerState.Iload(5);
    try AssemblerState.Branch(0xa2, "loopEnd");
    try AssemblerState.Aload(4);
    try AssemblerState.Iload(6);
    try AssemblerState.Operation0(0x33);
    try AssemblerState.Iconst(255);
    try AssemblerState.Operation0(0x7e);
    try AssemblerState.Istore(12);
    try EmitGCall(&AssemblerState, References, 4, 6, 5);
    try AssemblerState.Istore(13);
    try AssemblerState.Iload(12);
    try AssemblerState.Iload(2);
    try AssemblerState.Branch(0xa0, "noMatch");
    try AssemblerState.Iload(7);
    try AssemblerState.Istore(8);
    try EmitGCall(&AssemblerState, References, 4, 6, 1);
    try AssemblerState.Istore(10);
    try AssemblerState.Iload(13);
    try AssemblerState.Istore(9);
    try AssemblerState.Label("noMatch");
    try AssemblerState.Iload(7);
    try AssemblerState.Iload(13);
    try AssemblerState.Operation0(0x60);
    try AssemblerState.Istore(7);
    try AssemblerState.Iinc(6, 9);
    try AssemblerState.Iinc(11, 1);
    try AssemblerState.Goto("loopHead");
    try AssemblerState.Label("loopEnd");

    try AssemblerState.Iload(8);
    try AssemblerState.Branch(0x9c, "haveSlice");
    try AssemblerState.Operation2(0xbb, References.UrlClassLoaderClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Operation2(0x13, References.StringOperatingSystemArchitecture);
    try AssemblerState.Invoke(0xb7, References.UrlClassLoaderInitialize);
    try AssemblerState.Operation0(0xbf);
    try AssemblerState.Label("haveSlice");

    try AssemblerState.Operation2(0xbb, References.InflaterClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Iconst(1);
    try AssemblerState.Invoke(0xb7, References.InflaterInitialize);
    try AssemblerState.Astore(14);
    try AssemblerState.Aload(14);
    try AssemblerState.Aload(4);
    try AssemblerState.Iload(8);
    try AssemblerState.Iload(9);
    try AssemblerState.Invoke(0xb6, References.InflaterSetInput);
    try AssemblerState.Iload(10);
    try AssemblerState.Operation1(0xbc, 8);
    try AssemblerState.Astore(13);
    try AssemblerState.Aload(14);
    try AssemblerState.Aload(13);
    try AssemblerState.Invoke(0xb6, References.InflaterInflate);
    try AssemblerState.Operation0(0x57);
    try AssemblerState.Aload(14);
    try AssemblerState.Invoke(0xb6, References.InflaterEnd);

    try Contains(&AssemblerState, References, 0, References.StringWin);
    try AssemblerState.Branch(0x99, "sNotWin");
    try AssemblerState.Operation2(0x13, References.StringDll);
    try AssemblerState.Goto("sStore");
    try AssemblerState.Label("sNotWin");
    try Contains(&AssemblerState, References, 0, References.StringMac);
    try AssemblerState.Branch(0x99, "sNotMac");
    try AssemblerState.Operation2(0x13, References.StringDylib);
    try AssemblerState.Goto("sStore");
    try AssemblerState.Label("sNotMac");
    try AssemblerState.Operation2(0x13, References.StringSo);
    try AssemblerState.Label("sStore");
    try AssemblerState.Astore(15);

    try AssemblerState.Operation2(0xbb, References.RandomClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Invoke(0xb7, References.RandomInitialize);
    try AssemblerState.Astore(22);
    try AssemblerState.Operation2(0xbb, References.StringBuilderClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Invoke(0xb7, References.StringBuilderInitialize);
    try AssemblerState.Astore(23);
    try AssemblerState.Iconst(0);
    try AssemblerState.Istore(24);
    try AssemblerState.Label("nmHead");
    try AssemblerState.Iload(24);
    try AssemblerState.Iconst(20);
    try AssemblerState.Branch(0xa2, "nmDone");
    try AssemblerState.Aload(22);
    try AssemblerState.Iconst(52);
    try AssemblerState.Invoke(0xb6, References.RandomNextInt);
    try AssemblerState.Istore(25);
    try AssemblerState.Aload(23);
    try AssemblerState.Iload(25);
    try AssemblerState.Iconst(26);
    try AssemblerState.Branch(0xa2, "nmLower");
    try AssemblerState.Iload(25);
    try AssemblerState.Iconst(65);
    try AssemblerState.Operation0(0x60);
    try AssemblerState.Goto("nmPut");
    try AssemblerState.Label("nmLower");
    try AssemblerState.Iload(25);
    try AssemblerState.Iconst(71);
    try AssemblerState.Operation0(0x60);
    try AssemblerState.Label("nmPut");
    try AssemblerState.Invoke(0xb6, References.StringBuilderAppendChar);
    try AssemblerState.Operation0(0x57);
    try AssemblerState.Iinc(24, 1);
    try AssemblerState.Goto("nmHead");
    try AssemblerState.Label("nmDone");
    try AssemblerState.Aload(23);
    try AssemblerState.Aload(15);
    try AssemblerState.Invoke(0xb6, References.StringBuilderAppendString);
    try AssemblerState.Operation0(0x57);
    try AssemblerState.Aload(23);
    try AssemblerState.Invoke(0xb6, References.StringBuilderToString);
    try AssemblerState.Astore(26);
    try AssemblerState.Operation2(0x13, References.ThisClass);
    try AssemblerState.Invoke(0xb6, References.GetProtectionDomain);
    try AssemblerState.Invoke(0xb6, References.GetCodeSource);
    try AssemblerState.Invoke(0xb6, References.GetLocation);
    try AssemblerState.Astore(30);
    try AssemblerState.Aload(30);
    try AssemblerState.Invoke(0xb6, References.GetProtocol);
    try AssemblerState.Operation2(0x13, References.StringJar);
    try AssemblerState.Invoke(0xb6, References.StringEquals);
    try AssemblerState.Branch(0x99, "notJarUrl");
    try AssemblerState.Aload(30);
    try AssemblerState.Invoke(0xb6, References.OpenConnection);
    try AssemblerState.Operation2(0xc0, References.JarUrlConnectionClass);
    try AssemblerState.Invoke(0xb6, References.GetJarFileUrl);
    try AssemblerState.Astore(30);
    try AssemblerState.Label("notJarUrl");
    try AssemblerState.Aload(30);
    try AssemblerState.Invoke(0xb6, References.UrlToUri);
    try AssemblerState.Astore(29);
    try AssemblerState.Operation2(0xbb, References.FileClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(29);
    try AssemblerState.Invoke(0xb7, References.FileInitializeUri);
    try AssemblerState.Invoke(0xb6, References.GetParentFile);
    try AssemblerState.Invoke(0xb6, References.GetPath);
    try AssemblerState.Astore(28);

    try AssemblerState.Operation2(0xbb, References.FileClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(28);
    try AssemblerState.Aload(26);
    try AssemblerState.Invoke(0xb7, References.FileInitialize2);
    try AssemblerState.Astore(16);

    try AssemblerState.Operation2(0xbb, References.FileOutputStreamClass);
    try AssemblerState.Operation0(0x59);
    try AssemblerState.Aload(16);
    try AssemblerState.Invoke(0xb7, References.FileOutputStreamInitialize);
    try AssemblerState.Astore(17);
    try AssemblerState.Aload(17);
    try AssemblerState.Aload(13);
    try AssemblerState.Invoke(0xb6, References.FileOutputStreamWrite);
    try AssemblerState.Aload(17);
    try AssemblerState.Invoke(0xb6, References.FileOutputStreamClose);

    try AssemblerState.Aload(16);
    try AssemblerState.Invoke(0xb6, References.GetAbsolutePath);
    try AssemblerState.Invoke(0xb8, References.Load);

    try AssemblerState.Aload(4);
    try AssemblerState.Operation2(0x14, try Pool.AddLong(IntegrityHash));
    try AssemblerState.Invoke(0xb8, References.SelfVh);

    try AssemblerState.Aload(16);
    try AssemblerState.Invoke(0xb6, References.FileToPath);
    try AssemblerState.Invoke(0xb8, References.FilesReadAllBytes);
    try AssemblerState.Astore(40);
    try AssemblerState.Operation0(0x09);
    try AssemblerState.Operation1(0x37, 42);
    for (LibraryHashes, 0..) |Entry, EntryIndex| {
        const SkipLabel = try std.fmt.allocPrint(AllocatorHandle, "swapSkip{d}", .{EntryIndex});
        try AssemblerState.Iload(2);
        try AssemblerState.Iconst(@as(i32, Entry.Tag));
        try AssemblerState.Branch(0xa0, SkipLabel);
        try AssemblerState.Operation2(0x14, try Pool.AddLong(Entry.Hash));
        try AssemblerState.Operation1(0x37, 42);
        try AssemblerState.Label(SkipLabel);
    }
    try AssemblerState.Aload(40);
    try AssemblerState.Operation1(0x16, 42);
    try AssemblerState.Invoke(0xb8, References.SelfVh);

    try AssemblerState.Aload(16);
    try AssemblerState.Invoke(0xb6, References.FileDeleteOnExit);
    try AssemblerState.Aload(16);
    try AssemblerState.Invoke(0xb6, References.FileDelete);
    try AssemblerState.Operation0(0x57);
    try AssemblerState.Operation0(0xb1);

    return Assembler.BuildMethod(AllocatorHandle, Pool, try AssemblerState.Finish(), &.{}, "()V", true, CodeUtf8Index);
}

fn AddNative(AllocatorHandle: std.mem.Allocator, Methods: *std.ArrayList(ClassFileModel.MemberInfo), Pool: *ConstantPoolBuilder.ConstantPool, Name: []const u8, Descriptor: []const u8) !void {
    try Methods.append(AllocatorHandle, .{ .AccessFlags = AccessFlags.AccessPublic | AccessFlags.AccessStatic | AccessFlags.AccessNative, .NameIndex = try Pool.AddUtf8(Name), .DescriptorIndex = try Pool.AddUtf8(Descriptor), .Attributes = .empty });
}

fn AddCoded(AllocatorHandle: std.mem.Allocator, Methods: *std.ArrayList(ClassFileModel.MemberInfo), Pool: *ConstantPoolBuilder.ConstantPool, Flags: u16, Name: []const u8, Descriptor: []const u8, Info: ClassFileModel.Attribute) !void {
    var Attributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    try Attributes.append(AllocatorHandle, Info);
    try Methods.append(AllocatorHandle, .{ .AccessFlags = Flags, .NameIndex = try Pool.AddUtf8(Name), .DescriptorIndex = try Pool.AddUtf8(Descriptor), .Attributes = Attributes });
}

pub fn NativeReaderSynthesizer(AllocatorHandle: std.mem.Allocator, InternalName: []const u8, ResourcePath: []const u8, IntegrityHash: i64, DatWords: [11]u32, LibraryHashes: []const NativeContainerPacker.LibraryHash) !Synthesized {
    var Pool = try ConstantPoolBuilder.ConstantPool.InitEmpty(AllocatorHandle);
    const ThisClassIndex = try Pool.AddClass(InternalName);
    const ObjectClassIndex = try Pool.AddClass("java/lang/Object");
    const CodeUtf8Index = try Pool.AddUtf8("Code");

    const References = ReferenceIndices{
        .GetProperty = try Pool.AddMethodref("java/lang/System", "getProperty", "(Ljava/lang/String;)Ljava/lang/String;"),
        .Lower = try Pool.AddMethodref("java/lang/String", "toLowerCase", "()Ljava/lang/String;"),
        .Contains = try Pool.AddMethodref("java/lang/String", "contains", "(Ljava/lang/CharSequence;)Z"),
        .UrlClassLoaderClass = try Pool.AddClass("java/lang/UnsatisfiedLinkError"),
        .UrlClassLoaderInitialize = try Pool.AddMethodref("java/lang/UnsatisfiedLinkError", "<init>", "(Ljava/lang/String;)V"),
        .ThisClass = ThisClassIndex,
        .GetResource = try Pool.AddMethodref("java/lang/Class", "getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;"),
        .ReadAll = try Pool.AddMethodref("java/io/InputStream", "readAllBytes", "()[B"),
        .InflaterClass = try Pool.AddClass("java/util/zip/Inflater"),
        .InflaterInitialize = try Pool.AddMethodref("java/util/zip/Inflater", "<init>", "(Z)V"),
        .InflaterSetInput = try Pool.AddMethodref("java/util/zip/Inflater", "setInput", "([BII)V"),
        .InflaterInflate = try Pool.AddMethodref("java/util/zip/Inflater", "inflate", "([B)I"),
        .InflaterEnd = try Pool.AddMethodref("java/util/zip/Inflater", "end", "()V"),
        .GetAbsolutePath = try Pool.AddMethodref("java/io/File", "getAbsolutePath", "()Ljava/lang/String;"),
        .FileOutputStreamClass = try Pool.AddClass("java/io/FileOutputStream"),
        .FileOutputStreamInitialize = try Pool.AddMethodref("java/io/FileOutputStream", "<init>", "(Ljava/io/File;)V"),
        .FileOutputStreamWrite = try Pool.AddMethodref("java/io/FileOutputStream", "write", "([B)V"),
        .FileOutputStreamClose = try Pool.AddMethodref("java/io/FileOutputStream", "close", "()V"),
        .Load = try Pool.AddMethodref("java/lang/System", "load", "(Ljava/lang/String;)V"),
        .SelfG = try Pool.AddMethodref(InternalName, "g", "([BI)I"),
        .SelfVh = try Pool.AddMethodref(InternalName, "vh", "([BJ)V"),
        .ResourcePath = try Pool.AddString(ResourcePath),
        .StringOperatingSystemName = try Pool.AddString("os.name"),
        .StringOperatingSystemArchitecture = try Pool.AddString("os.arch"),
        .StringAmd64 = try Pool.AddString("amd64"),
        .StringX8664 = try Pool.AddString("x86_64"),
        .StringAarch64 = try Pool.AddString("aarch64"),
        .StringArm64 = try Pool.AddString("arm64"),
        .StringWin = try Pool.AddString("win"),
        .StringMac = try Pool.AddString("mac"),
        .StringDarwin = try Pool.AddString("darwin"),
        .StringNux = try Pool.AddString("nux"),
        .StringNix = try Pool.AddString("nix"),
        .StringDll = try Pool.AddString(".dll"),
        .StringDylib = try Pool.AddString(".dylib"),
        .StringSo = try Pool.AddString(".so"),
        .RandomClass = try Pool.AddClass("java/util/Random"),
        .RandomInitialize = try Pool.AddMethodref("java/util/Random", "<init>", "()V"),
        .RandomNextInt = try Pool.AddMethodref("java/util/Random", "nextInt", "(I)I"),
        .StringBuilderClass = try Pool.AddClass("java/lang/StringBuilder"),
        .StringBuilderInitialize = try Pool.AddMethodref("java/lang/StringBuilder", "<init>", "()V"),
        .StringBuilderAppendChar = try Pool.AddMethodref("java/lang/StringBuilder", "append", "(C)Ljava/lang/StringBuilder;"),
        .StringBuilderAppendString = try Pool.AddMethodref("java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;"),
        .StringBuilderToString = try Pool.AddMethodref("java/lang/StringBuilder", "toString", "()Ljava/lang/String;"),
        .FileClass = try Pool.AddClass("java/io/File"),
        .FileInitialize2 = try Pool.AddMethodref("java/io/File", "<init>", "(Ljava/lang/String;Ljava/lang/String;)V"),
        .FileInitializeUri = try Pool.AddMethodref("java/io/File", "<init>", "(Ljava/net/URI;)V"),
        .GetParentFile = try Pool.AddMethodref("java/io/File", "getParentFile", "()Ljava/io/File;"),
        .GetPath = try Pool.AddMethodref("java/io/File", "getPath", "()Ljava/lang/String;"),
        .GetProtectionDomain = try Pool.AddMethodref("java/lang/Class", "getProtectionDomain", "()Ljava/security/ProtectionDomain;"),
        .GetCodeSource = try Pool.AddMethodref("java/security/ProtectionDomain", "getCodeSource", "()Ljava/security/CodeSource;"),
        .GetLocation = try Pool.AddMethodref("java/security/CodeSource", "getLocation", "()Ljava/net/URL;"),
        .UrlToUri = try Pool.AddMethodref("java/net/URL", "toURI", "()Ljava/net/URI;"),
        .CipherGetInstance = try Pool.AddMethodref("javax/crypto/Cipher", "getInstance", "(Ljava/lang/String;)Ljavax/crypto/Cipher;"),
        .CipherInitialize = try Pool.AddMethodref("javax/crypto/Cipher", "init", "(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V"),
        .CipherDoFinal = try Pool.AddMethodref("javax/crypto/Cipher", "doFinal", "([B)[B"),
        .SecretKeySpecClass = try Pool.AddClass("javax/crypto/spec/SecretKeySpec"),
        .SecretKeySpecInitialize = try Pool.AddMethodref("javax/crypto/spec/SecretKeySpec", "<init>", "([BIILjava/lang/String;)V"),
        .IvSpecClass = try Pool.AddClass("javax/crypto/spec/IvParameterSpec"),
        .IvSpecInitialize = try Pool.AddMethodref("javax/crypto/spec/IvParameterSpec", "<init>", "([B)V"),
        .ArraysCopyOfRange = try Pool.AddMethodref("java/util/Arrays", "copyOfRange", "([BII)[B"),
        .StringChaCha = try Pool.AddString("ChaCha20"),
        .StringChaChaPoly = try Pool.AddString("ChaCha20-Poly1305"),
        .ObjectInitialize = try Pool.AddMethodref("java/lang/Object", "<init>", "()V"),
        .FileToPath = try Pool.AddMethodref("java/io/File", "toPath", "()Ljava/nio/file/Path;"),
        .FileDeleteOnExit = try Pool.AddMethodref("java/io/File", "deleteOnExit", "()V"),
        .FileDelete = try Pool.AddMethodref("java/io/File", "delete", "()Z"),
        .FilesReadAllBytes = try Pool.AddMethodref("java/nio/file/Files", "readAllBytes", "(Ljava/nio/file/Path;)[B"),
        .StringJar = try Pool.AddString("jar"),
        .GetProtocol = try Pool.AddMethodref("java/net/URL", "getProtocol", "()Ljava/lang/String;"),
        .StringEquals = try Pool.AddMethodref("java/lang/String", "equals", "(Ljava/lang/Object;)Z"),
        .OpenConnection = try Pool.AddMethodref("java/net/URL", "openConnection", "()Ljava/net/URLConnection;"),
        .JarUrlConnectionClass = try Pool.AddClass("java/net/JarURLConnection"),
        .GetJarFileUrl = try Pool.AddMethodref("java/net/JarURLConnection", "getJarFileURL", "()Ljava/net/URL;"),
    };

    const GInfo = try BuildG(AllocatorHandle, &Pool, CodeUtf8Index);
    const ClinitInfo = try BuildClinit(AllocatorHandle, &Pool, CodeUtf8Index, References, IntegrityHash, DatWords, LibraryHashes);

    var InitAssembler = Assembler.AssemblerState.Initialize(AllocatorHandle, &Pool);
    try InitAssembler.Aload(0);
    try InitAssembler.Invoke(0xb7, References.ObjectInitialize);
    try InitAssembler.Operation0(0xb1);
    const InitInfo = try Assembler.BuildMethod(AllocatorHandle, &Pool, try InitAssembler.Finish(), &.{}, "()V", false, CodeUtf8Index);

    var Methods: std.ArrayList(ClassFileModel.MemberInfo) = .empty;
    try AddCoded(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessPublic, "<init>", "()V", InitInfo);
    try AddCoded(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessStatic, "<clinit>", "()V", ClinitInfo);
    try AddCoded(AllocatorHandle, &Methods, &Pool, AccessFlags.AccessStatic | AccessFlags.AccessPrivate, "g", "([BI)I", GInfo);
    try AddNative(AllocatorHandle, &Methods, &Pool, "p", "()I");
    try AddNative(AllocatorHandle, &Methods, &Pool, "vh", "([BJ)V");
    try AddNative(AllocatorHandle, &Methods, &Pool, "d", "([JIIIII)Ljava/lang/String;");
    try AddNative(AllocatorHandle, &Methods, &Pool, "kb", "(II)I");
    try AddNative(AllocatorHandle, &Methods, &Pool, "unpack", "([B)[B");
    try AddNative(AllocatorHandle, &Methods, &Pool, "vi", "([B[BLjava/lang/Class;)V");
    try AddNative(AllocatorHandle, &Methods, &Pool, "nr", "(I[Ljava/lang/Object;)Ljava/lang/Object;");

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
    return .{ .Bytes = try ClassFileModel.Serialize(AllocatorHandle, &ClassFileValue) };
}
