const std = @import("std");
const builtin = @import("builtin");
const Cipher = @import("NativeCipher.zig");
const Pack = @import("NativePack.zig");

const FunctionPointer = *const anyopaque;

pub const LoaderClassName: [*:0]const u8 = "pkg/Loader";
pub const InterpreterClassName: [*:0]const u8 = "pkg/Interpreter";

pub const IntegrityEntry = struct { Path: [*:0]const u8, Hash: i64 };

const PageAllocator = std.heap.page_allocator;

var GlobalBaseline: u64 = 0;
var GlobalBaselineMirror: u64 = 0;
var GlobalVtableBaseline: u64 = 0;
var GlobalTamperA: u32 = 0;
var GlobalTamperB: u32 = 0;
var GlobalTamperC: u32 = 0;
var GlobalTamperD: u32 = 0;
var VmSelfCheckTick: u32 = 0;

var GlobalObfuscationSeed: u64 = 0;
threadlocal var RevealBuffers: [8][160]u8 = undefined;
threadlocal var RevealCursor: usize = 0;

fn ObfuscationKeystreamByte(Seed: u64, Position: usize) u8 {
    var State: u64 = Seed ^ (@as(u64, Position) *% 0xD1B54A32D192ED03) ^ 0x94D049BB133111EB;
    State ^= State >> 30;
    State *%= 0xBF58476D1CE4E5B9;
    State ^= State >> 27;
    State *%= 0x94D049BB133111EB;
    State ^= State >> 31;
    return @truncate(State);
}

fn VocabularyBase(comptime Plain: []const u8) usize {
    comptime {
        var Hash: usize = 0x811C9DC5;
        for (Plain) |Character| Hash = (Hash ^ Character) *% 0x01000193;
        return Hash & 0xFFFF;
    }
}

fn EncodeVocabulary(comptime Plain: []const u8) [Plain.len]u8 {
    comptime {
        @setEvalBranchQuota(1 << 20);
        var Output: [Plain.len]u8 = undefined;
        const Base = VocabularyBase(Plain);
        for (Plain, 0..) |Character, Position| Output[Position] = Character ^ ObfuscationKeystreamByte(Cipher.BakedInteg, Base + Position);
        return Output;
    }
}

fn RevealDecode(Encrypted: []const u8, Base: usize) [*:0]const u8 {
    const Seed = @atomicLoad(u64, &GlobalObfuscationSeed, .monotonic);
    const Slot = RevealCursor % RevealBuffers.len;
    RevealCursor +%= 1;
    const Buffer = &RevealBuffers[Slot];
    var Position: usize = 0;
    while (Position < Encrypted.len and Position + 1 < Buffer.len) : (Position += 1) {
        Buffer[Position] = Encrypted[Position] ^ ObfuscationKeystreamByte(Seed, Base + Position);
    }
    Buffer[Position] = 0;
    return @ptrCast(Buffer);
}

inline fn Reveal(comptime Plain: []const u8) [*:0]const u8 {
    const Encrypted = comptime EncodeVocabulary(Plain);
    return RevealDecode(&Encrypted, comptime VocabularyBase(Plain));
}

inline fn TamperState() u32 {
    return @atomicLoad(u32, &GlobalTamperA, .monotonic) | @atomicLoad(u32, &GlobalTamperB, .monotonic) | @atomicLoad(u32, &GlobalTamperC, .monotonic) | @atomicLoad(u32, &GlobalTamperD, .monotonic);
}

inline fn TamperPoison() u8 {
    const Combined = TamperState();
    const NonZero: u32 = (Combined | (0 -% Combined)) >> 31;
    const Derived: u8 = @as(u8, @truncate(Cipher.BakedInteg ^ (Cipher.BakedInteg >> 29) ^ @as(u64, Combined))) | 1;
    return @as(u8, @truncate(NonZero)) *% Derived;
}

inline fn TamperKeyFold() u32 {
    const Combined = TamperState();
    const NonZero: u32 = (Combined | (0 -% Combined)) >> 31;
    const Derived: u32 = @as(u32, @truncate(Cipher.BakedInteg ^ (Cipher.BakedArx0 >> 17) ^ (Cipher.BakedArx1 >> 33)));
    return NonZero *% ((Derived ^ Combined) | 1);
}

inline fn JavaNativeInterfaceVtable(Environment: ?*anyopaque) [*]const FunctionPointer {
    const VtablePointer: [*]const [*]const FunctionPointer = @ptrCast(@alignCast(Environment));
    return VtablePointer[0];
}

const GetArrayLengthFunction = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32;
const GetLongElementsFunction = *const fn (?*anyopaque, ?*anyopaque, ?*u8) callconv(.c) ?[*]i64;
const ReleaseLongElementsFunction = *const fn (?*anyopaque, ?*anyopaque, [*]i64, i32) callconv(.c) void;
const GetByteElementsFunction = *const fn (?*anyopaque, ?*anyopaque, ?*u8) callconv(.c) ?[*]i8;
const ReleaseByteElementsFunction = *const fn (?*anyopaque, ?*anyopaque, [*]i8, i32) callconv(.c) void;
const NewStringFunction = *const fn (?*anyopaque, [*]const u16, i32) callconv(.c) ?*anyopaque;
const NewByteArrayFunction = *const fn (?*anyopaque, i32) callconv(.c) ?*anyopaque;
const SetByteRegionFunction = *const fn (?*anyopaque, ?*anyopaque, i32, i32, [*]const u8) callconv(.c) void;

const IndexNewString: usize = 163;
const IndexGetArrayLength: usize = 171;
const IndexNewByteArray: usize = 176;
const IndexGetByteElements: usize = 184;
const IndexReleaseByteElements: usize = 192;
const IndexGetLongElements: usize = 188;
const IndexReleaseLongElements: usize = 196;
const IndexSetByteRegion: usize = 208;

pub const JavaNativeInterfaceNativeMethod = extern struct {
    Name: [*:0]const u8,
    Signature: [*:0]const u8,
    FunctionPointer: *const anyopaque,
};
const GetEnvironmentFunction = *const fn (?*anyopaque, *?*anyopaque, i32) callconv(.c) i32;
const FindClassFunction = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const RegisterNativesFunction = *const fn (?*anyopaque, ?*anyopaque, [*]const JavaNativeInterfaceNativeMethod, i32) callconv(.c) i32;
const IndexGetEnvironment: usize = 6;
const IndexFindClass: usize = 6;
const IndexRegisterNatives: usize = 215;
const JavaNativeInterfaceVersion18: i32 = 0x00010008;

const IndexGetMethodId: usize = 33;
const IndexCallIntMethodA: usize = 51;
const IndexGetStaticMethodId: usize = 113;
const IndexCallStaticObjectMethodA: usize = 116;
const IndexNewGlobalRef: usize = 21;
const IndexDeleteLocalRef: usize = 23;
const IndexNewObjectArray: usize = 172;
const IndexGetObjectArrayElement: usize = 173;
const IndexSetObjectArrayElement: usize = 174;
const IndexExceptionCheck: usize = 228;
const IndexThrow: usize = 13;
const IndexExceptionOccurred: usize = 15;
const IndexExceptionClear: usize = 17;
const IndexNewObjectA: usize = 30;
const IndexCallObjectMethodA: usize = 36;
const IndexCallVoidMethodA: usize = 63;
const IndexIsSameObject: usize = 24;
const IndexCallStaticIntMethodA: usize = 127;
const IndexCallStaticVoidMethodA: usize = 143;
const IndexThrowNew: usize = 14;
const IndexCallBooleanMethodA: usize = 39;
const IndexNewStringUtf: usize = 167;
const IndexNewIntArray: usize = 179;
const IndexSetIntArrayRegion: usize = 211;
const IndexEnsureLocalCapacity: usize = 26;
const IndexMonitorEnter: usize = 217;
const IndexMonitorExit: usize = 218;
const IndexGetStringUtfChars: usize = 169;
const IndexReleaseStringUtfChars: usize = 170;

const GetStringUtfCharsFunction = *const fn (?*anyopaque, ?*anyopaque, ?*u8) callconv(.c) ?[*:0]const u8;
const ReleaseStringUtfCharsFunction = *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) void;

const EnsureLocalCapacityFunction = *const fn (?*anyopaque, i32) callconv(.c) i32;
const MonitorFunction = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32;

const NewIntArrayFunction = *const fn (?*anyopaque, i32) callconv(.c) ?*anyopaque;
const SetIntArrayRegionFunction = *const fn (?*anyopaque, ?*anyopaque, i32, i32, [*]const i32) callconv(.c) void;

const ThrowNewFunction = *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) i32;
const CallBooleanMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const JValue) callconv(.c) u8;
const NewStringUtfFunction = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

const IsSameObjectFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8;
const CallStaticIntMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const JValue) callconv(.c) i32;
const CallStaticVoidMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const JValue) callconv(.c) void;

const CallVoidMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const JValue) callconv(.c) void;
const NewObjectAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const JValue) callconv(.c) ?*anyopaque;
const ExceptionObjectFunction = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const ExceptionClearFunction = *const fn (?*anyopaque) callconv(.c) void;
const ThrowFunction = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32;

const JValue = extern union {
    Object: ?*anyopaque,
    Int: i32,
    Long: i64,
    Float: f32,
    Double: f64,
};
const GetMethodIdFunction = *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque;
const CallStaticObjectMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, [*]const JValue) callconv(.c) ?*anyopaque;
const CallIntMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const JValue) callconv(.c) i32;
const CallObjectMethodAFunction = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const JValue) callconv(.c) ?*anyopaque;
const NewGlobalReferenceFunction = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
const DeleteLocalReferenceFunction = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const NewObjectArrayFunction = *const fn (?*anyopaque, i32, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
const GetObjectArrayElementFunction = *const fn (?*anyopaque, ?*anyopaque, i32) callconv(.c) ?*anyopaque;
const SetObjectArrayElementFunction = *const fn (?*anyopaque, ?*anyopaque, i32, ?*anyopaque) callconv(.c) void;
const ExceptionCheckFunction = *const fn (?*anyopaque) callconv(.c) u8;

fn JavaNativeInterfaceSecureHalt() noreturn {
    var Value: u64 = 0x9E3779B97F4A7C15;
    var Index: u64 = 0;
    while (Index < 7) : (Index += 1) {
        Value = Value *% 6364136223846793005 +% 1442695040888963407;
        Value ^= Value >> 33;
    }
    std.mem.doNotOptimizeAway(Value);
    @trap();
}

fn JavaNativeInterfaceHashBytes(Environment: ?*anyopaque, Data: ?*anyopaque) u64 {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const GetLength: GetArrayLengthFunction = @ptrCast(@alignCast(Vtable[IndexGetArrayLength]));
    const GetElements: GetByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexGetByteElements]));
    const ReleaseElements: ReleaseByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexReleaseByteElements]));
    const Length: usize = @intCast(GetLength(Environment, Data));
    const Elements = GetElements(Environment, Data, null) orelse JavaNativeInterfaceSecureHalt();
    const Bytes: [*]const u8 = @ptrCast(Elements);
    const Hash = Cipher.IntegrityHash(Bytes[0..Length], Cipher.Baked);
    ReleaseElements(Environment, Data, Elements, 2);
    return Hash;
}

fn VerifyIntegrityManifest(Environment: ?*anyopaque, LoaderClass: ?*anyopaque) void {
    const Manifest = @import("root").IntegrityManifest;
    if (Manifest.len == 0) return;
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const GetMethodId: GetMethodIdFunction = @ptrCast(@alignCast(Vtable[IndexGetMethodId]));
    const CallObjectMethodA: CallObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallObjectMethodA]));
    const NewStringUtf: NewStringUtfFunction = @ptrCast(@alignCast(Vtable[IndexNewStringUtf]));
    const DeleteLocalRef: DeleteLocalReferenceFunction = @ptrCast(@alignCast(Vtable[IndexDeleteLocalRef]));
    const CheckException: ExceptionCheckFunction = @ptrCast(@alignCast(Vtable[IndexExceptionCheck]));
    const ClearException: ExceptionClearFunction = @ptrCast(@alignCast(Vtable[IndexExceptionClear]));

    const ClassClass = FindClass(Environment, Reveal("java/lang/Class")) orelse {
        ClearException(Environment);
        return;
    };
    const StreamClass = FindClass(Environment, Reveal("java/io/InputStream")) orelse {
        ClearException(Environment);
        return;
    };
    const GetResource = GetMethodId(Environment, ClassClass, Reveal("getResourceAsStream"), Reveal("(Ljava/lang/String;)Ljava/io/InputStream;")) orelse {
        ClearException(Environment);
        return;
    };
    const ReadAll = GetMethodId(Environment, StreamClass, Reveal("readAllBytes"), Reveal("()[B")) orelse {
        ClearException(Environment);
        return;
    };
    DeleteLocalRef(Environment, ClassClass);
    DeleteLocalRef(Environment, StreamClass);

    for (Manifest) |Entry| {
        const PathString = NewStringUtf(Environment, Entry.Path) orelse {
            ClearException(Environment);
            continue;
        };
        var Arguments = [_]JValue{.{ .Object = PathString }};
        const Stream = CallObjectMethodA(Environment, LoaderClass, GetResource, &Arguments);
        DeleteLocalRef(Environment, PathString);
        if (CheckException(Environment) != 0) {
            ClearException(Environment);
            continue;
        }
        if (Stream == null) {
            @atomicStore(u32, &GlobalTamperC, 0x5AA5C0DE, .monotonic);
            continue;
        }
        const ByteArray = CallObjectMethodA(Environment, Stream, ReadAll, null);
        const ThrewReading = CheckException(Environment) != 0;
        DeleteLocalRef(Environment, Stream);
        if (ThrewReading) {
            @atomicStore(u32, &GlobalTamperC, 0x5AA5C0DE, .monotonic);
            ClearException(Environment);
            continue;
        }
        if (ByteArray == null) {
            @atomicStore(u32, &GlobalTamperC, 0x5AA5C0DE, .monotonic);
            continue;
        }
        const Actual: i64 = @bitCast(JavaNativeInterfaceHashBytes(Environment, ByteArray));
        DeleteLocalRef(Environment, ByteArray);
        if (Actual != Entry.Hash) @atomicStore(u32, &GlobalTamperA, 0x9E3779B9, .monotonic);
    }
}

fn NativeProbe(Environment: ?*anyopaque, Class: ?*anyopaque) callconv(.c) i32 {
    _ = Environment;
    _ = Class;
    return 0;
}

fn NativeKeystreamByte(Environment: ?*anyopaque, Class: ?*anyopaque, Offset: i32, Seed: i32) callconv(.c) i32 {
    _ = Environment;
    _ = Class;
    const KeystreamByteValue = Cipher.VirtualMachineKeystreamByte(@bitCast(Offset), @as(u32, @bitCast(Seed)) ^ TamperKeyFold(), Cipher.Baked);
    return @as(i32, KeystreamByteValue) ^ @as(i32, TamperPoison());
}

fn NativeUnpack(Environment: ?*anyopaque, Class: ?*anyopaque, Data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = Class;
    if (Data == null) JavaNativeInterfaceSecureHalt();
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const GetLength: GetArrayLengthFunction = @ptrCast(@alignCast(Vtable[IndexGetArrayLength]));
    const GetElements: GetByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexGetByteElements]));
    const ReleaseElements: ReleaseByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexReleaseByteElements]));
    const NewByteArray: NewByteArrayFunction = @ptrCast(@alignCast(Vtable[IndexNewByteArray]));
    const SetByteRegion: SetByteRegionFunction = @ptrCast(@alignCast(Vtable[IndexSetByteRegion]));
    const Length: usize = @intCast(GetLength(Environment, Data));
    if (Length < 4) JavaNativeInterfaceSecureHalt();
    const InputElements = GetElements(Environment, Data, null) orelse JavaNativeInterfaceSecureHalt();
    const InputBytes: [*]const u8 = @ptrCast(InputElements);
    const OriginalLength: usize = @intCast(Pack.OriginalLength(InputBytes[0..4]));
    const Buffer = PageAllocator.alloc(u8, OriginalLength) catch {
        ReleaseElements(Environment, Data, InputElements, 2);
        JavaNativeInterfaceSecureHalt();
    };
    defer PageAllocator.free(Buffer);
    Pack.Decompress(Buffer, InputBytes[0..Length]);
    ReleaseElements(Environment, Data, InputElements, 2);
    const Poison: u8 = TamperPoison();
    for (Buffer) |*ByteValue| ByteValue.* ^= Poison;
    const OutputArray = NewByteArray(Environment, @intCast(OriginalLength)) orelse JavaNativeInterfaceSecureHalt();
    SetByteRegion(Environment, OutputArray, 0, @intCast(OriginalLength), Buffer.ptr);
    return OutputArray;
}

fn NativeVerifyHash(Environment: ?*anyopaque, Class: ?*anyopaque, Data: ?*anyopaque, Expected: i64) callconv(.c) void {
    _ = Class;
    if (Data == null) JavaNativeInterfaceSecureHalt();
    const Hash: i64 = @bitCast(JavaNativeInterfaceHashBytes(Environment, Data));
    if (Hash != Expected) @atomicStore(u32, &GlobalTamperA, 0x9E3779B9, .monotonic);
}

fn NativeDecrypt(Environment: ?*anyopaque, Class: ?*anyopaque, Data: ?*anyopaque, Offset: i32, Length: i32, Salt: i32, Nonce: i32, Caller: i32) callconv(.c) ?*anyopaque {
    _ = Class;
    if (Data == null or Length < 0 or (Length & 1) != 0 or Offset < 0) JavaNativeInterfaceSecureHalt();
    const Poison: u8 = TamperPoison();
    const FoldedNonce: i32 = Nonce ^ @as(i32, @bitCast(TamperKeyFold()));
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const GetLength: GetArrayLengthFunction = @ptrCast(@alignCast(Vtable[IndexGetArrayLength]));
    const GetElements: GetLongElementsFunction = @ptrCast(@alignCast(Vtable[IndexGetLongElements]));
    const ReleaseElements: ReleaseLongElementsFunction = @ptrCast(@alignCast(Vtable[IndexReleaseLongElements]));
    const NewString: NewStringFunction = @ptrCast(@alignCast(Vtable[IndexNewString]));
    const LongCount: usize = @intCast(GetLength(Environment, Data));
    const LongsPointer = GetElements(Environment, Data, null) orelse JavaNativeInterfaceSecureHalt();
    const Longs = LongsPointer[0..LongCount];
    const UnitLength: usize = @intCast(Length);
    const OffsetUsize: usize = @intCast(Offset);
    if ((OffsetUsize + UnitLength + 7) / 8 > LongCount) {
        ReleaseElements(Environment, Data, LongsPointer, 2);
        JavaNativeInterfaceSecureHalt();
    }
    const CharacterCount: usize = UnitLength / 2;
    if (CharacterCount == 0) {
        ReleaseElements(Environment, Data, LongsPointer, 2);
        var Dummy: u16 = 0;
        const EmptyString = NewString(Environment, @ptrCast(&Dummy), 0);
        if (EmptyString == null) JavaNativeInterfaceSecureHalt();
        return EmptyString;
    }
    const Units = PageAllocator.alloc(u16, CharacterCount) catch {
        ReleaseElements(Environment, Data, LongsPointer, 2);
        JavaNativeInterfaceSecureHalt();
    };
    defer PageAllocator.free(Units);
    var Index: usize = 0;
    while (Index < CharacterCount) : (Index += 1) {
        const GlobalIndex = OffsetUsize + 2 * Index;
        const HighByte = Cipher.LongByteBigEndian(Longs, GlobalIndex) ^ Cipher.KeystreamByte(@intCast(2 * Index), Salt, Caller, FoldedNonce, Cipher.Baked) ^ Poison;
        const LowByte = Cipher.LongByteBigEndian(Longs, GlobalIndex + 1) ^ Cipher.KeystreamByte(@intCast(2 * Index + 1), Salt, Caller, FoldedNonce, Cipher.Baked) ^ Poison;
        Units[Index] = (@as(u16, HighByte) << 8) | @as(u16, LowByte);
    }
    ReleaseElements(Environment, Data, LongsPointer, 2);
    const ResultString = NewString(Environment, Units.ptr, @intCast(CharacterCount));
    if (ResultString == null) JavaNativeInterfaceSecureHalt();
    return ResultString;
}

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "c" fn usleep(usec: c_uint) c_int;

fn JavaNativeInterfaceSleepMilliseconds(Milliseconds: u32) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(Milliseconds);
    } else {
        _ = usleep(Milliseconds * 1000);
    }
}

fn VtableHash(Environment: ?*anyopaque) u64 {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const Raw: [*]const usize = @ptrCast(@alignCast(Vtable));
    var Accumulator: u64 = Cipher.BakedInteg;
    var Index: usize = 4;
    while (Index < 230) : (Index += 1) {
        Accumulator ^= Raw[Index];
        Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    }
    return Accumulator;
}

fn HashRegion(FunctionPointerValue: *const anyopaque, Length: usize) u64 {
    const Base: [*]const u8 = @ptrFromInt(@intFromPtr(FunctionPointerValue));
    return Cipher.IntegrityHash(Base[0..Length], Cipher.Baked);
}

fn JavaNativeInterfaceCodeHash() u64 {
    var Accumulator: u64 = Cipher.BakedInteg;
    Accumulator ^= HashRegion(&NativeKeystreamByte, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&NativeUnpack, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&NativeDecrypt, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&NativeVerifyHash, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&NativeVmRun, 1024);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&NativeVmInit, 512);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&ScanHandlerTable, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&VerifyIntegrityManifest, 256);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&VtableHash, 200);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&RegisterForClass, 200);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&JavaNativeInterfaceWatchdog, 128);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&JNI_OnLoad, 384);
    Accumulator = Accumulator *% 0x9E3779B97F4A7C15;
    Accumulator ^= HashRegion(&JavaNativeInterfaceCodeHash, 256);
    return Accumulator;
}

inline fn CodeHashMismatch() bool {
    const Hash = JavaNativeInterfaceCodeHash();
    const Base = @atomicLoad(u64, &GlobalBaseline, .monotonic);
    const Mirror = @atomicLoad(u64, &GlobalBaselineMirror, .monotonic);
    return (Base != 0 and Hash != Base) or (Mirror != 0 and Hash != Mirror);
}

fn JavaNativeInterfaceWatchdog() void {
    while (true) {
        if (CodeHashMismatch()) @atomicStore(u32, &GlobalTamperB, 0x5AA5F00D, .monotonic);
        JavaNativeInterfaceSleepMilliseconds(700);
    }
}

var VmImageData: ?[]u8 = null;
var VmInverse: [64]u8 = undefined;
var VmClass: ?*anyopaque = null;
var VmInteger: ?*anyopaque = null;
var VmLong: ?*anyopaque = null;
var VmFloat: ?*anyopaque = null;
var VmDouble: ?*anyopaque = null;
var VmObject: ?*anyopaque = null;
var VmArith: ?*anyopaque = null;
var VmNegate: ?*anyopaque = null;
var VmConvert: ?*anyopaque = null;
var VmCompareWide: ?*anyopaque = null;
var VmIntegerValueOf: ?*anyopaque = null;
var VmIntegerIntValue: ?*anyopaque = null;
var VmLongValueOf: ?*anyopaque = null;
var VmFloatValueOf: ?*anyopaque = null;
var VmDoubleValueOf: ?*anyopaque = null;
var VmResolveCall: ?*anyopaque = null;
var VmSpecialInvoke: ?*anyopaque = null;
var VmCoerce: ?*anyopaque = null;
var VmNormalize: ?*anyopaque = null;
var VmResolveField: ?*anyopaque = null;
var VmMethodParameterTypes: ?*anyopaque = null;
var VmMethodInvoke: ?*anyopaque = null;
var VmFieldGet: ?*anyopaque = null;
var VmFieldSet: ?*anyopaque = null;
var VmFieldGetType: ?*anyopaque = null;
var VmStringClass: ?*anyopaque = null;
var VmStringInit: ?*anyopaque = null;
var VmGetCause: ?*anyopaque = null;
var VmCachedForName: ?*anyopaque = null;
var VmArrayLoad: ?*anyopaque = null;
var VmArrayStore: ?*anyopaque = null;
var VmArrayType: ?*anyopaque = null;
var VmReflectArray: ?*anyopaque = null;
var VmArrayNewInstance: ?*anyopaque = null;
var VmArrayGetLength: ?*anyopaque = null;
var VmClassIsInstance: ?*anyopaque = null;
var VmClassCastException: ?*anyopaque = null;
var VmResolveConstructor: ?*anyopaque = null;
var VmConstructorParameterCount: ?*anyopaque = null;
var VmConstructorNewInstance: ?*anyopaque = null;
var VmInvocationTarget: ?*anyopaque = null;
var VmMultiComponent: ?*anyopaque = null;
var VmArrayNewInstanceMulti: ?*anyopaque = null;
var VmReady: bool = false;

fn ReadProgramSymbol(NewStringUtf: NewStringUtfFunction, Environment: ?*anyopaque, Image: []const u8, Offset: usize, Seed: u32, StartIndex: usize) struct { String: ?*anyopaque, Length: usize } {
    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, StartIndex)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, StartIndex + 1));
    var Buffer: [8192]u8 = undefined;
    if (SymbolLength >= Buffer.len) return .{ .String = null, .Length = 2 + SymbolLength };
    var Index: usize = 0;
    while (Index < SymbolLength) : (Index += 1) Buffer[Index] = ProgramByte(Image, Offset, Seed, StartIndex + 2 + Index);
    Buffer[SymbolLength] = 0;
    return .{ .String = NewStringUtf(Environment, @ptrCast(&Buffer)), .Length = 2 + SymbolLength };
}

fn ProgramByte(Image: []const u8, Offset: usize, Seed: u32, Index: usize) u8 {
    if (Index >= Image.len) return 0;
    const Position = Offset + Index;
    if (Position >= Image.len) return 0;
    const Poison: u8 = TamperPoison();
    return Image[Position] ^ Cipher.VirtualMachineKeystreamByte(@intCast(Index), Seed ^ TamperKeyFold(), Cipher.Baked) ^ Poison;
}

fn BoundedTarget(Word: i32, Length: usize) ?usize {
    if (Word < 0) return null;
    const Value: usize = @intCast(Word);
    if (Value >= Length) return null;
    return Value;
}
fn ProgramWord(Image: []const u8, Offset: usize, Seed: u32, Index: usize) i32 {
    const Word: u32 =
        (@as(u32, ProgramByte(Image, Offset, Seed, Index)) << 24) |
        (@as(u32, ProgramByte(Image, Offset, Seed, Index + 1)) << 16) |
        (@as(u32, ProgramByte(Image, Offset, Seed, Index + 2)) << 8) |
        @as(u32, ProgramByte(Image, Offset, Seed, Index + 3));
    return @bitCast(Word);
}

fn ReadStackSlot(Image: []const u8, Offset: usize, Seed: u32, ProgramCounter: *usize, StackSize: usize) usize {
    const Value: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter.*)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter.* + 1));
    ProgramCounter.* += 2;
    return if (Value < StackSize) Value else 0;
}
fn SafeUnboxInt(CallIntFunction: CallIntMethodAFunction, Environment: ?*anyopaque, Receiver: ?*anyopaque, MethodId: ?*anyopaque) ?i32 {
    if (Receiver == null) return null;
    return CallIntFunction(Environment, Receiver, MethodId, null);
}
fn ClampLocal(Index: u8, NumberOfLocals: usize) i32 {
    return if (Index < NumberOfLocals) @intCast(Index) else 0;
}
fn RawU32(Image: []const u8, Index: usize) u32 {
    return (@as(u32, Image[Index]) << 24) | (@as(u32, Image[Index + 1]) << 16) | (@as(u32, Image[Index + 2]) << 8) | @as(u32, Image[Index + 3]);
}
fn RawU16(Image: []const u8, Index: usize) usize {
    return (@as(usize, Image[Index]) << 8) | @as(usize, Image[Index + 1]);
}
fn CompareIntegers(Left: i32, Right: i32, Condition: u8) bool {
    return switch (Condition) {
        0 => Left == Right,
        1 => Left != Right,
        2 => Left < Right,
        3 => Left >= Right,
        4 => Left > Right,
        5 => Left <= Right,
        else => false,
    };
}
fn ArithmeticSelector(Logical: u8) i32 {
    return switch (Logical) {
        4 => 0,
        5 => 1,
        6 => 2,
        14 => 3,
        15 => 4,
        8 => 5,
        9 => 6,
        10 => 7,
        11 => 8,
        12 => 9,
        13 => 10,
        else => 0,
    };
}

fn NativeVmInit(Environment: ?*anyopaque, LoaderClass: ?*anyopaque, ImageArray: ?*anyopaque, PermArray: ?*anyopaque, InterpreterClass: ?*anyopaque) callconv(.c) void {
    _ = LoaderClass;
    const Class = InterpreterClass;
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const GetLength: GetArrayLengthFunction = @ptrCast(@alignCast(Vtable[IndexGetArrayLength]));
    const GetBytes: GetByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexGetByteElements]));
    const ReleaseBytes: ReleaseByteElementsFunction = @ptrCast(@alignCast(Vtable[IndexReleaseByteElements]));
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const GetStaticMethodId: GetMethodIdFunction = @ptrCast(@alignCast(Vtable[IndexGetStaticMethodId]));
    const GetMethodId: GetMethodIdFunction = @ptrCast(@alignCast(Vtable[IndexGetMethodId]));
    const NewGlobal: NewGlobalReferenceFunction = @ptrCast(@alignCast(Vtable[IndexNewGlobalRef]));

    if (ImageArray == null or Class == null) return;
    const ImageLength: usize = @intCast(GetLength(Environment, ImageArray));
    const ImageElements = GetBytes(Environment, ImageArray, null) orelse return;
    const Buffer = PageAllocator.alloc(u8, ImageLength) catch {
        ReleaseBytes(Environment, ImageArray, ImageElements, 2);
        return;
    };
    @memcpy(Buffer, @as([*]const u8, @ptrCast(ImageElements))[0..ImageLength]);
    ReleaseBytes(Environment, ImageArray, ImageElements, 2);
    VmImageData = Buffer;

    var IdentityIndex: usize = 0;
    while (IdentityIndex < 64) : (IdentityIndex += 1) VmInverse[IdentityIndex] = @intCast(IdentityIndex);
    if (PermArray != null) {
        const PermLength: usize = @intCast(GetLength(Environment, PermArray));
        if (GetBytes(Environment, PermArray, null)) |PermElements| {
            const PermBytes: [*]const u8 = @ptrCast(PermElements);
            var Operation: usize = 0;
            while (Operation < PermLength and Operation < 64) : (Operation += 1) {
                const Decrypted = PermBytes[Operation] ^ Cipher.PermutationKeystreamByte(@intCast(Operation), Cipher.Baked);
                VmInverse[Decrypted & 63] = @intCast(Operation);
            }
            ReleaseBytes(Environment, PermArray, PermElements, 2);
        }
    }

    VmClass = NewGlobal(Environment, Class);
    VmArith = GetStaticMethodId(Environment, Class, Reveal("ar"), Reveal("(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;"));
    VmNegate = GetStaticMethodId(Environment, Class, Reveal("ng"), Reveal("(Ljava/lang/Object;)Ljava/lang/Object;"));
    VmConvert = GetStaticMethodId(Environment, Class, Reveal("cv"), Reveal("(Ljava/lang/Object;I)Ljava/lang/Object;"));
    VmCompareWide = GetStaticMethodId(Environment, Class, Reveal("cw"), Reveal("(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;"));

    const IntegerClass = FindClass(Environment, Reveal("java/lang/Integer")) orelse return;
    VmInteger = NewGlobal(Environment, IntegerClass);
    VmIntegerValueOf = GetStaticMethodId(Environment, IntegerClass, Reveal("valueOf"), Reveal("(I)Ljava/lang/Integer;"));
    VmIntegerIntValue = GetMethodId(Environment, IntegerClass, Reveal("intValue"), Reveal("()I"));
    const LongClass = FindClass(Environment, Reveal("java/lang/Long")) orelse return;
    VmLong = NewGlobal(Environment, LongClass);
    VmLongValueOf = GetStaticMethodId(Environment, LongClass, Reveal("valueOf"), Reveal("(J)Ljava/lang/Long;"));
    const FloatClass = FindClass(Environment, Reveal("java/lang/Float")) orelse return;
    VmFloat = NewGlobal(Environment, FloatClass);
    VmFloatValueOf = GetStaticMethodId(Environment, FloatClass, Reveal("valueOf"), Reveal("(F)Ljava/lang/Float;"));
    const DoubleClass = FindClass(Environment, Reveal("java/lang/Double")) orelse return;
    VmDouble = NewGlobal(Environment, DoubleClass);
    VmDoubleValueOf = GetStaticMethodId(Environment, DoubleClass, Reveal("valueOf"), Reveal("(D)Ljava/lang/Double;"));
    const ObjectClass = FindClass(Environment, Reveal("java/lang/Object")) orelse return;
    VmObject = NewGlobal(Environment, ObjectClass);

    VmResolveCall = GetStaticMethodId(Environment, Class, Reveal("rc"), Reveal("(Ljava/lang/String;I)Ljava/lang/reflect/Method;"));
    VmSpecialInvoke = GetStaticMethodId(Environment, Class, Reveal("sp"), Reveal("(Ljava/lang/reflect/Method;Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;"));
    VmCoerce = GetStaticMethodId(Environment, Class, Reveal("co"), Reveal("(Ljava/lang/Object;Ljava/lang/Class;)Ljava/lang/Object;"));
    VmNormalize = GetStaticMethodId(Environment, Class, Reveal("nz"), Reveal("(Ljava/lang/Object;)Ljava/lang/Object;"));
    VmResolveField = GetStaticMethodId(Environment, Class, Reveal("rf"), Reveal("(IIII)Ljava/lang/reflect/Field;"));
    const MethodClass = FindClass(Environment, Reveal("java/lang/reflect/Method")) orelse return;
    VmMethodParameterTypes = GetMethodId(Environment, MethodClass, Reveal("getParameterTypes"), Reveal("()[Ljava/lang/Class;"));
    VmMethodInvoke = GetMethodId(Environment, MethodClass, Reveal("invoke"), Reveal("(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;"));
    const FieldClass = FindClass(Environment, Reveal("java/lang/reflect/Field")) orelse return;
    VmFieldGet = GetMethodId(Environment, FieldClass, Reveal("get"), Reveal("(Ljava/lang/Object;)Ljava/lang/Object;"));
    VmFieldSet = GetMethodId(Environment, FieldClass, Reveal("set"), Reveal("(Ljava/lang/Object;Ljava/lang/Object;)V"));
    VmFieldGetType = GetMethodId(Environment, FieldClass, Reveal("getType"), Reveal("()Ljava/lang/Class;"));
    const StringClass = FindClass(Environment, Reveal("java/lang/String")) orelse return;
    VmStringClass = NewGlobal(Environment, StringClass);
    VmStringInit = GetMethodId(Environment, StringClass, Reveal("<init>"), Reveal("([B)V"));
    const ThrowableClass = FindClass(Environment, Reveal("java/lang/Throwable")) orelse return;
    VmGetCause = GetMethodId(Environment, ThrowableClass, Reveal("getCause"), Reveal("()Ljava/lang/Throwable;"));
    VmCachedForName = GetStaticMethodId(Environment, Class, Reveal("cf"), Reveal("(Ljava/lang/String;)Ljava/lang/Class;"));
    VmArrayLoad = GetStaticMethodId(Environment, Class, Reveal("al"), Reveal("(Ljava/lang/Object;II)Ljava/lang/Object;"));
    VmArrayStore = GetStaticMethodId(Environment, Class, Reveal("as"), Reveal("(Ljava/lang/Object;ILjava/lang/Object;I)V"));
    VmArrayType = GetStaticMethodId(Environment, Class, Reveal("at"), Reveal("(I)Ljava/lang/Class;"));
    const ReflectArrayClass = FindClass(Environment, Reveal("java/lang/reflect/Array")) orelse return;
    VmReflectArray = NewGlobal(Environment, ReflectArrayClass);
    VmArrayNewInstance = GetStaticMethodId(Environment, ReflectArrayClass, Reveal("newInstance"), Reveal("(Ljava/lang/Class;I)Ljava/lang/Object;"));
    VmArrayGetLength = GetStaticMethodId(Environment, ReflectArrayClass, Reveal("getLength"), Reveal("(Ljava/lang/Object;)I"));
    const JavaLangClass = FindClass(Environment, Reveal("java/lang/Class")) orelse return;
    VmClassIsInstance = GetMethodId(Environment, JavaLangClass, Reveal("isInstance"), Reveal("(Ljava/lang/Object;)Z"));
    const ClassCastExceptionClass = FindClass(Environment, Reveal("java/lang/ClassCastException")) orelse return;
    VmClassCastException = NewGlobal(Environment, ClassCastExceptionClass);
    VmResolveConstructor = GetStaticMethodId(Environment, Class, Reveal("rk"), Reveal("(Ljava/lang/String;)Ljava/lang/reflect/Constructor;"));
    const ConstructorClass = FindClass(Environment, Reveal("java/lang/reflect/Constructor")) orelse return;
    VmConstructorParameterCount = GetMethodId(Environment, ConstructorClass, Reveal("getParameterCount"), Reveal("()I"));
    VmConstructorNewInstance = GetMethodId(Environment, ConstructorClass, Reveal("newInstance"), Reveal("([Ljava/lang/Object;)Ljava/lang/Object;"));
    const InvocationTargetClass = FindClass(Environment, Reveal("java/lang/reflect/InvocationTargetException")) orelse return;
    VmInvocationTarget = NewGlobal(Environment, InvocationTargetClass);
    VmMultiComponent = GetStaticMethodId(Environment, Class, Reveal("mc"), Reveal("(Ljava/lang/String;)Ljava/lang/Class;"));
    VmArrayNewInstanceMulti = GetStaticMethodId(Environment, ReflectArrayClass, Reveal("newInstance"), Reveal("(Ljava/lang/Class;[I)Ljava/lang/Object;"));

    const RequiredMethods = [_]?*anyopaque{
        VmArith,                 VmNegate,                    VmConvert,                VmCompareWide,
        VmIntegerValueOf,        VmIntegerIntValue,           VmLongValueOf,            VmFloatValueOf,
        VmDoubleValueOf,         VmResolveCall,               VmSpecialInvoke,          VmCoerce,
        VmNormalize,             VmResolveField,              VmMethodParameterTypes,   VmMethodInvoke,
        VmFieldGet,              VmFieldSet,                  VmFieldGetType,           VmStringInit,
        VmGetCause,              VmCachedForName,             VmArrayLoad,              VmArrayStore,
        VmArrayType,             VmArrayNewInstance,          VmArrayGetLength,         VmClassIsInstance,
        VmResolveConstructor,    VmConstructorParameterCount, VmConstructorNewInstance, VmMultiComponent,
        VmArrayNewInstanceMulti,
    };
    for (RequiredMethods) |MethodId| {
        if (MethodId == null) return;
    }
    VmReady = true;
    @atomicStore(u64, &GlobalBaselineMirror, JavaNativeInterfaceCodeHash(), .monotonic);
}

fn ScanHandlerTable(Environment: ?*anyopaque, Image: []const u8, Offset: usize, Seed: u32, CurrentOpPc: usize) ?struct { Handler: usize, Exception: ?*anyopaque } {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const ExceptionObject: ExceptionObjectFunction = @ptrCast(@alignCast(Vtable[IndexExceptionOccurred]));
    const ClearException: ExceptionClearFunction = @ptrCast(@alignCast(Vtable[IndexExceptionClear]));
    const ThrowObject: ThrowFunction = @ptrCast(@alignCast(Vtable[IndexThrow]));
    const CallBoolean: CallBooleanMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallBooleanMethodA]));
    const CallObject: CallStaticObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallStaticObjectMethodA]));
    const CallInstance: CallStaticObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallObjectMethodA]));
    const NewStringUtf: NewStringUtfFunction = @ptrCast(@alignCast(Vtable[IndexNewStringUtf]));
    const DeleteRef: DeleteLocalReferenceFunction = @ptrCast(@alignCast(Vtable[IndexDeleteLocalRef]));

    var Exception = ExceptionObject(Environment);
    ClearException(Environment);
    var CallArgs: [1]JValue = undefined;
    if (Exception != null) {
        CallArgs[0].Object = Exception;
        if (CallBoolean(Environment, VmInvocationTarget, VmClassIsInstance, &CallArgs) != 0) {
            const Cause = CallInstance(Environment, Exception, VmGetCause, &CallArgs);
            if (Cause != null) {
                DeleteRef(Environment, Exception);
                Exception = Cause;
            }
        }
    }

    const Count: usize = (@as(usize, ProgramByte(Image, Offset, Seed, 0)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, 1));
    var Cursor: usize = 2;
    var Entry: usize = 0;
    while (Entry < Count) : (Entry += 1) {
        const StartRaw = ProgramWord(Image, Offset, Seed, Cursor);
        const EndRaw = ProgramWord(Image, Offset, Seed, Cursor + 4);
        const HandlerRaw = ProgramWord(Image, Offset, Seed, Cursor + 8);
        const CatchLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, Cursor + 12)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, Cursor + 13));
        if (StartRaw >= 0 and EndRaw >= 0 and CurrentOpPc >= @as(usize, @intCast(StartRaw)) and CurrentOpPc < @as(usize, @intCast(EndRaw))) {
            var Match = CatchLength == 0;
            if (!Match) {
                const CatchSymbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, Cursor + 12);
                CallArgs[0].Object = CatchSymbol.String;
                const CatchClass = CallObject(Environment, VmClass, VmCachedForName, &CallArgs);
                if (CatchSymbol.String != null) DeleteRef(Environment, CatchSymbol.String);
                if (CatchClass != null) {
                    CallArgs[0].Object = Exception;
                    Match = CallBoolean(Environment, CatchClass, VmClassIsInstance, &CallArgs) != 0;
                    DeleteRef(Environment, CatchClass);
                }
            }
            if (Match) return .{ .Handler = BoundedTarget(HandlerRaw, Image.len) orelse return null, .Exception = Exception };
        }
        Cursor += 14 + CatchLength;
    }
    if (Exception != null) _ = ThrowObject(Environment, Exception);
    return null;
}

fn NativeVmRun(Environment: ?*anyopaque, Class: ?*anyopaque, MethodId: i32, ArgsArray: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = Class;
    if (!VmReady) return null;
    if (MethodId < 0) return null;
    VmSelfCheckTick +%= 1;
    if (VmSelfCheckTick & 0x3FF == 0 and CodeHashMismatch()) @atomicStore(u32, &GlobalTamperC, 0xC0DEBEEF, .monotonic);
    if (VmSelfCheckTick & 0x3FF == 0 and @atomicLoad(u64, &GlobalVtableBaseline, .monotonic) != 0 and VtableHash(Environment) != @atomicLoad(u64, &GlobalVtableBaseline, .monotonic)) @atomicStore(u32, &GlobalTamperD, 0xDEADBEEF, .monotonic);
    const Image = VmImageData orelse return null;
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const GetLength: GetArrayLengthFunction = @ptrCast(@alignCast(Vtable[IndexGetArrayLength]));
    const NewObjectArray: NewObjectArrayFunction = @ptrCast(@alignCast(Vtable[IndexNewObjectArray]));
    const GetElement: GetObjectArrayElementFunction = @ptrCast(@alignCast(Vtable[IndexGetObjectArrayElement]));
    const SetElement: SetObjectArrayElementFunction = @ptrCast(@alignCast(Vtable[IndexSetObjectArrayElement]));
    const DeleteRef: DeleteLocalReferenceFunction = @ptrCast(@alignCast(Vtable[IndexDeleteLocalRef]));
    const CallObject: CallStaticObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallStaticObjectMethodA]));
    const CallInt: CallIntMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallIntMethodA]));
    const CheckException: ExceptionCheckFunction = @ptrCast(@alignCast(Vtable[IndexExceptionCheck]));
    const CallInstanceObject: CallStaticObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallObjectMethodA]));
    const CallInstanceVoid: CallVoidMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallVoidMethodA]));
    const NewObject: NewObjectAFunction = @ptrCast(@alignCast(Vtable[IndexNewObjectA]));
    const NewByteArray: NewByteArrayFunction = @ptrCast(@alignCast(Vtable[IndexNewByteArray]));
    const SetByteRegion: SetByteRegionFunction = @ptrCast(@alignCast(Vtable[IndexSetByteRegion]));
    const ThrowObject: ThrowFunction = @ptrCast(@alignCast(Vtable[IndexThrow]));
    const IsSameObject: IsSameObjectFunction = @ptrCast(@alignCast(Vtable[IndexIsSameObject]));
    const CallStaticInt: CallStaticIntMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallStaticIntMethodA]));
    const CallStaticVoid: CallStaticVoidMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallStaticVoidMethodA]));
    const CallBoolean: CallBooleanMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallBooleanMethodA]));
    const ThrowNew: ThrowNewFunction = @ptrCast(@alignCast(Vtable[IndexThrowNew]));
    const NewStringUtf: NewStringUtfFunction = @ptrCast(@alignCast(Vtable[IndexNewStringUtf]));
    const NewIntArray: NewIntArrayFunction = @ptrCast(@alignCast(Vtable[IndexNewIntArray]));
    const SetIntRegion: SetIntArrayRegionFunction = @ptrCast(@alignCast(Vtable[IndexSetIntArrayRegion]));
    const MonitorEnter: MonitorFunction = @ptrCast(@alignCast(Vtable[IndexMonitorEnter]));
    const MonitorExit: MonitorFunction = @ptrCast(@alignCast(Vtable[IndexMonitorExit]));

    const Base: usize = 4 + @as(usize, @intCast(MethodId)) * 16;
    if (Base + 16 > Image.len) return null;
    const Offset: usize = @intCast(RawU32(Image, Base));
    const Seed: u32 = RawU32(Image, Base + 8);
    const NumberOfLocals: usize = RawU16(Image, Base + 12);
    const MaximumStack: usize = RawU16(Image, Base + 14);
    const RecordInverse = Cipher.InvertPermutation(Cipher.PermutationFromSeed(Seed));

    const EnsureLocalCapacity: EnsureLocalCapacityFunction = @ptrCast(@alignCast(Vtable[IndexEnsureLocalCapacity]));
    _ = EnsureLocalCapacity(Environment, @intCast(MaximumStack + NumberOfLocals + 32));

    const Locals = NewObjectArray(Environment, @intCast(NumberOfLocals), VmObject, null) orelse return null;
    const Stack = NewObjectArray(Environment, @intCast(MaximumStack + 8), VmObject, null) orelse return null;
    const ArgCount: usize = if (ArgsArray == null) 0 else @intCast(@max(0, GetLength(Environment, ArgsArray)));
    var ArgIndex: usize = 0;
    while (ArgIndex < ArgCount and ArgIndex < NumberOfLocals) : (ArgIndex += 1) {
        const Value = GetElement(Environment, ArgsArray, @intCast(ArgIndex));
        SetElement(Environment, Locals, @intCast(Cipher.RegisterPermute(Seed, @intCast(NumberOfLocals), @intCast(ArgIndex))), Value);
        DeleteRef(Environment, Value);
    }

    const EntryCount: usize = (@as(usize, ProgramByte(Image, Offset, Seed, 0)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, 1));
    var Cursor: usize = 2;
    var Entry: usize = 0;
    while (Entry < EntryCount) : (Entry += 1) {
        Cursor += 12;
        const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, Cursor)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, Cursor + 1));
        Cursor += 2 + SymbolLength;
    }

    const StackSize: usize = MaximumStack + 8;
    var ProgramCounter: usize = Cursor;
    var Arguments: [4]JValue = undefined;
    while (true) {
        if (ProgramCounter >= Image.len) return null;
        const CurrentOpPc = ProgramCounter;
        const Logical = VmInverse[RecordInverse[ProgramByte(Image, Offset, Seed, ProgramCounter) & 63]];
        ProgramCounter += 1;
        Dispatch: {
            switch (Logical) {
                1 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    Arguments[0].Int = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const Result = CallObject(Environment, VmInteger, VmIntegerValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Destination), Result);
                    DeleteRef(Environment, Result);
                },
                2 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Index = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Value = GetElement(Environment, Locals, ClampLocal(Index, NumberOfLocals));
                    SetElement(Environment, Stack, @intCast(Destination), Value);
                    DeleteRef(Environment, Value);
                },
                3 => {
                    const Source = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Index = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Value = GetElement(Environment, Stack, @intCast(Source));
                    SetElement(Environment, Locals, ClampLocal(Index, NumberOfLocals), Value);
                    DeleteRef(Environment, Value);
                },
                4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15 => {
                    const RightSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const LeftSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Right = GetElement(Environment, Stack, @intCast(RightSlot));
                    const Left = GetElement(Environment, Stack, @intCast(LeftSlot));
                    Arguments[0].Object = Left;
                    Arguments[1].Object = Right;
                    Arguments[2].Int = ArithmeticSelector(Logical);
                    const Result = CallObject(Environment, VmClass, VmArith, &Arguments);
                    DeleteRef(Environment, Left);
                    DeleteRef(Environment, Right);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(LeftSlot), Result);
                    DeleteRef(Environment, Result);
                },
                7 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Value = GetElement(Environment, Stack, @intCast(Slot));
                    Arguments[0].Object = Value;
                    const Result = CallObject(Environment, VmClass, VmNegate, &Arguments);
                    DeleteRef(Environment, Value);
                    SetElement(Environment, Stack, @intCast(Slot), Result);
                    DeleteRef(Environment, Result);
                },
                16 => {
                    ProgramCounter = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                },
                17 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Condition = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Target: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const Value = GetElement(Environment, Stack, @intCast(Slot));
                    const IntegerValue = (SafeUnboxInt(CallInt, Environment, Value, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, Value);
                    if (CompareIntegers(IntegerValue, 0, Condition)) ProgramCounter = Target;
                },
                18 => {
                    const RightSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const LeftSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Condition = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Target: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const Right = GetElement(Environment, Stack, @intCast(RightSlot));
                    const Left = GetElement(Environment, Stack, @intCast(LeftSlot));
                    const RightValue = SafeUnboxInt(CallInt, Environment, Right, VmIntegerIntValue) orelse return null;
                    const LeftValue = SafeUnboxInt(CallInt, Environment, Left, VmIntegerIntValue) orelse return null;
                    DeleteRef(Environment, Right);
                    DeleteRef(Environment, Left);
                    if (CompareIntegers(LeftValue, RightValue, Condition)) ProgramCounter = Target;
                },
                19 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    return GetElement(Environment, Stack, @intCast(Slot));
                },
                20 => {},
                21 => {
                    const Source = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Value = GetElement(Environment, Stack, @intCast(Source));
                    SetElement(Environment, Stack, @intCast(Destination), Value);
                    DeleteRef(Environment, Value);
                },
                22 => {
                    const TopSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const UnderSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Top = GetElement(Environment, Stack, @intCast(TopSlot));
                    const Under = GetElement(Environment, Stack, @intCast(UnderSlot));
                    SetElement(Environment, Stack, @intCast(TopSlot), Under);
                    SetElement(Environment, Stack, @intCast(UnderSlot), Top);
                    DeleteRef(Environment, Top);
                    DeleteRef(Environment, Under);
                },
                23 => {
                    const Index = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Increment = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const Value = GetElement(Environment, Locals, ClampLocal(Index, NumberOfLocals));
                    const Current = (SafeUnboxInt(CallInt, Environment, Value, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, Value);
                    Arguments[0].Int = Current +% Increment;
                    const Updated = CallObject(Environment, VmInteger, VmIntegerValueOf, &Arguments);
                    SetElement(Environment, Locals, ClampLocal(Index, NumberOfLocals), Updated);
                    DeleteRef(Environment, Updated);
                },
                27 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const High = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const Low = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    Arguments[0].Long = (@as(i64, High) << 32) | @as(i64, @as(u32, @bitCast(Low)));
                    const Result = CallObject(Environment, VmLong, VmLongValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Destination), Result);
                    DeleteRef(Environment, Result);
                },
                28 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    Arguments[1].Int = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Value = GetElement(Environment, Stack, @intCast(Slot));
                    Arguments[0].Object = Value;
                    const Result = CallObject(Environment, VmClass, VmConvert, &Arguments);
                    DeleteRef(Environment, Value);
                    SetElement(Environment, Stack, @intCast(Slot), Result);
                    DeleteRef(Environment, Result);
                },
                29 => {
                    const RightSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const LeftSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    Arguments[2].Int = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Right = GetElement(Environment, Stack, @intCast(RightSlot));
                    const Left = GetElement(Environment, Stack, @intCast(LeftSlot));
                    Arguments[0].Object = Left;
                    Arguments[1].Object = Right;
                    const Result = CallObject(Environment, VmClass, VmCompareWide, &Arguments);
                    DeleteRef(Environment, Left);
                    DeleteRef(Environment, Right);
                    SetElement(Environment, Stack, @intCast(LeftSlot), Result);
                    DeleteRef(Environment, Result);
                },
                30 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    Arguments[0].Float = @bitCast(ProgramWord(Image, Offset, Seed, ProgramCounter));
                    ProgramCounter += 4;
                    const Result = CallObject(Environment, VmFloat, VmFloatValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Destination), Result);
                    DeleteRef(Environment, Result);
                },
                31 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const High = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const Low = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    Arguments[0].Double = @bitCast((@as(i64, High) << 32) | @as(i64, @as(u32, @bitCast(Low))));
                    const Result = CallObject(Environment, VmDouble, VmDoubleValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Destination), Result);
                    DeleteRef(Environment, Result);
                },
                24 => {
                    const Kind = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const HasReturn = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter + 1));
                    ProgramCounter += 2;
                    var SymbolBuffer: [1024]u8 = undefined;
                    if (SymbolLength > SymbolBuffer.len) return null;
                    var SymbolIndex: usize = 0;
                    while (SymbolIndex < SymbolLength) : (SymbolIndex += 1) SymbolBuffer[SymbolIndex] = ProgramByte(Image, Offset, Seed, ProgramCounter + SymbolIndex);
                    ProgramCounter += SymbolLength;
                    const SymbolArray = NewByteArray(Environment, @intCast(SymbolLength)) orelse return null;
                    SetByteRegion(Environment, SymbolArray, 0, @intCast(SymbolLength), &SymbolBuffer);
                    Arguments[0].Object = SymbolArray;
                    const SymbolString = NewObject(Environment, VmStringClass, VmStringInit, &Arguments);
                    DeleteRef(Environment, SymbolArray);
                    Arguments[0].Object = SymbolString;
                    Arguments[1].Int = Kind;
                    const Method = CallObject(Environment, VmClass, VmResolveCall, &Arguments);
                    DeleteRef(Environment, SymbolString);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const ParameterTypes = CallInstanceObject(Environment, Method, VmMethodParameterTypes, &Arguments);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, Method);
                        break :Dispatch;
                    }
                    if (ParameterTypes == null) {
                        DeleteRef(Environment, Method);
                        break :Dispatch;
                    }
                    const ParameterCount: usize = @intCast(@max(0, GetLength(Environment, ParameterTypes)));
                    const ArgumentArray = NewObjectArray(Environment, @intCast(ParameterCount), VmObject, null) orelse return null;
                    var FillIndex: usize = ParameterCount;
                    while (FillIndex > 0) {
                        FillIndex -= 1;
                        const ArgumentSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                        const ArgumentValue = GetElement(Environment, Stack, @intCast(ArgumentSlot));
                        SetElement(Environment, ArgumentArray, @intCast(FillIndex), ArgumentValue);
                        DeleteRef(Environment, ArgumentValue);
                    }
                    var ReceiverSlot: usize = 0;
                    if (Kind != 3) ReceiverSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    var ResultSlot: usize = 0;
                    if (HasReturn != 0) ResultSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    var CoerceIndex: usize = 0;
                    while (CoerceIndex < ParameterCount) : (CoerceIndex += 1) {
                        const CurrentArgument = GetElement(Environment, ArgumentArray, @intCast(CoerceIndex));
                        const ParameterType = GetElement(Environment, ParameterTypes, @intCast(CoerceIndex));
                        Arguments[0].Object = CurrentArgument;
                        Arguments[1].Object = ParameterType;
                        const Coerced = CallObject(Environment, VmClass, VmCoerce, &Arguments);
                        SetElement(Environment, ArgumentArray, @intCast(CoerceIndex), Coerced);
                        DeleteRef(Environment, CurrentArgument);
                        DeleteRef(Environment, ParameterType);
                        DeleteRef(Environment, Coerced);
                    }
                    DeleteRef(Environment, ParameterTypes);
                    var Receiver: ?*anyopaque = null;
                    if (Kind != 3) {
                        Receiver = GetElement(Environment, Stack, @intCast(ReceiverSlot));
                    }
                    var CallResult: ?*anyopaque = undefined;
                    if (Kind == 5) {
                        Arguments[0].Object = Method;
                        Arguments[1].Object = Receiver;
                        Arguments[2].Object = ArgumentArray;
                        CallResult = CallObject(Environment, VmClass, VmSpecialInvoke, &Arguments);
                    } else {
                        Arguments[0].Object = Receiver;
                        Arguments[1].Object = ArgumentArray;
                        CallResult = CallInstanceObject(Environment, Method, VmMethodInvoke, &Arguments);
                    }
                    if (Receiver != null) DeleteRef(Environment, Receiver);
                    DeleteRef(Environment, ArgumentArray);
                    DeleteRef(Environment, Method);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    if (HasReturn != 0) {
                        Arguments[0].Object = CallResult;
                        const Normalized = CallObject(Environment, VmClass, VmNormalize, &Arguments);
                        DeleteRef(Environment, CallResult);
                        SetElement(Environment, Stack, @intCast(ResultSlot), Normalized);
                        DeleteRef(Environment, Normalized);
                    } else if (CallResult != null) {
                        DeleteRef(Environment, CallResult);
                    }
                },
                25 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter + 1));
                    ProgramCounter += 2;
                    Arguments[0].Int = @intCast(Offset);
                    Arguments[1].Int = @bitCast(Seed);
                    Arguments[2].Int = @intCast(ProgramCounter);
                    Arguments[3].Int = @intCast(SymbolLength);
                    const Field = CallObject(Environment, VmClass, VmResolveField, &Arguments);
                    ProgramCounter += SymbolLength;
                    if (CheckException(Environment) != 0) break :Dispatch;
                    Arguments[0].Object = null;
                    const FieldValue = CallInstanceObject(Environment, Field, VmFieldGet, &Arguments);
                    DeleteRef(Environment, Field);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    Arguments[0].Object = FieldValue;
                    const Normalized = CallObject(Environment, VmClass, VmNormalize, &Arguments);
                    DeleteRef(Environment, FieldValue);
                    SetElement(Environment, Stack, @intCast(Destination), Normalized);
                    DeleteRef(Environment, Normalized);
                },
                26 => {
                    const Source = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter + 1));
                    ProgramCounter += 2;
                    Arguments[0].Int = @intCast(Offset);
                    Arguments[1].Int = @bitCast(Seed);
                    Arguments[2].Int = @intCast(ProgramCounter);
                    Arguments[3].Int = @intCast(SymbolLength);
                    const Field = CallObject(Environment, VmClass, VmResolveField, &Arguments);
                    ProgramCounter += SymbolLength;
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const FieldType = CallInstanceObject(Environment, Field, VmFieldGetType, &Arguments);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, Field);
                        break :Dispatch;
                    }
                    const RawValue = GetElement(Environment, Stack, @intCast(Source));
                    Arguments[0].Object = RawValue;
                    Arguments[1].Object = FieldType;
                    const Coerced = CallObject(Environment, VmClass, VmCoerce, &Arguments);
                    DeleteRef(Environment, RawValue);
                    DeleteRef(Environment, FieldType);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, Field);
                        break :Dispatch;
                    }
                    Arguments[0].Object = null;
                    Arguments[1].Object = Coerced;
                    CallInstanceVoid(Environment, Field, VmFieldSet, &Arguments);
                    DeleteRef(Environment, Coerced);
                    DeleteRef(Environment, Field);
                    if (CheckException(Environment) != 0) break :Dispatch;
                },
                38 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter + 1));
                    ProgramCounter += 2;
                    Arguments[0].Int = @intCast(Offset);
                    Arguments[1].Int = @bitCast(Seed);
                    Arguments[2].Int = @intCast(ProgramCounter);
                    Arguments[3].Int = @intCast(SymbolLength);
                    const Field = CallObject(Environment, VmClass, VmResolveField, &Arguments);
                    ProgramCounter += SymbolLength;
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const Receiver = GetElement(Environment, Stack, @intCast(Slot));
                    Arguments[0].Object = Receiver;
                    const FieldValue = CallInstanceObject(Environment, Field, VmFieldGet, &Arguments);
                    DeleteRef(Environment, Receiver);
                    DeleteRef(Environment, Field);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    Arguments[0].Object = FieldValue;
                    const Normalized = CallObject(Environment, VmClass, VmNormalize, &Arguments);
                    DeleteRef(Environment, FieldValue);
                    SetElement(Environment, Stack, @intCast(Slot), Normalized);
                    DeleteRef(Environment, Normalized);
                },
                39 => {
                    const ValueSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const ReceiverSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const SymbolLength: usize = (@as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter)) << 8) | @as(usize, ProgramByte(Image, Offset, Seed, ProgramCounter + 1));
                    ProgramCounter += 2;
                    Arguments[0].Int = @intCast(Offset);
                    Arguments[1].Int = @bitCast(Seed);
                    Arguments[2].Int = @intCast(ProgramCounter);
                    Arguments[3].Int = @intCast(SymbolLength);
                    const Field = CallObject(Environment, VmClass, VmResolveField, &Arguments);
                    ProgramCounter += SymbolLength;
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const RawValue = GetElement(Environment, Stack, @intCast(ValueSlot));
                    const Receiver = GetElement(Environment, Stack, @intCast(ReceiverSlot));
                    const FieldType = CallInstanceObject(Environment, Field, VmFieldGetType, &Arguments);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, Field);
                        DeleteRef(Environment, RawValue);
                        DeleteRef(Environment, Receiver);
                        break :Dispatch;
                    }
                    Arguments[0].Object = RawValue;
                    Arguments[1].Object = FieldType;
                    const Coerced = CallObject(Environment, VmClass, VmCoerce, &Arguments);
                    DeleteRef(Environment, RawValue);
                    DeleteRef(Environment, FieldType);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, Field);
                        DeleteRef(Environment, Receiver);
                        break :Dispatch;
                    }
                    Arguments[0].Object = Receiver;
                    Arguments[1].Object = Coerced;
                    CallInstanceVoid(Environment, Field, VmFieldSet, &Arguments);
                    DeleteRef(Environment, Receiver);
                    DeleteRef(Environment, Coerced);
                    DeleteRef(Environment, Field);
                    if (CheckException(Environment) != 0) break :Dispatch;
                },
                33 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    SetElement(Environment, Stack, @intCast(Destination), null);
                },
                34 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Mode = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Target: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const ReferenceValue = GetElement(Environment, Stack, @intCast(Slot));
                    const IsNull = ReferenceValue == null;
                    if ((Mode == 0 and IsNull) or (Mode != 0 and !IsNull)) ProgramCounter = Target;
                    if (ReferenceValue != null) DeleteRef(Environment, ReferenceValue);
                },
                35 => {
                    const RightSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const LeftSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Mode = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const Target: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const Right = GetElement(Environment, Stack, @intCast(RightSlot));
                    const Left = GetElement(Environment, Stack, @intCast(LeftSlot));
                    const Same = IsSameObject(Environment, Left, Right) != 0;
                    if ((Mode == 0 and Same) or (Mode != 0 and !Same)) ProgramCounter = Target;
                    if (Right != null) DeleteRef(Environment, Right);
                    if (Left != null) DeleteRef(Environment, Left);
                },
                42 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const TypeCode = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const CountValue = GetElement(Environment, Stack, @intCast(Slot));
                    const Count = (SafeUnboxInt(CallInt, Environment, CountValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, CountValue);
                    Arguments[0].Int = TypeCode;
                    const ComponentType = CallObject(Environment, VmClass, VmArrayType, &Arguments);
                    Arguments[0].Object = ComponentType;
                    Arguments[1].Int = Count;
                    const NewArray = CallObject(Environment, VmReflectArray, VmArrayNewInstance, &Arguments);
                    DeleteRef(Environment, ComponentType);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(Slot), NewArray);
                    DeleteRef(Environment, NewArray);
                },
                44 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const ArrayValue = GetElement(Environment, Stack, @intCast(Slot));
                    Arguments[0].Object = ArrayValue;
                    const Length = CallStaticInt(Environment, VmReflectArray, VmArrayGetLength, &Arguments);
                    DeleteRef(Environment, ArrayValue);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    Arguments[0].Int = Length;
                    const Boxed = CallObject(Environment, VmInteger, VmIntegerValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Slot), Boxed);
                    DeleteRef(Environment, Boxed);
                },
                45 => {
                    const IndexSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const ArraySlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const TypeCode = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const IndexValue = GetElement(Environment, Stack, @intCast(IndexSlot));
                    const Index = (SafeUnboxInt(CallInt, Environment, IndexValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, IndexValue);
                    const ArrayValue = GetElement(Environment, Stack, @intCast(ArraySlot));
                    Arguments[0].Object = ArrayValue;
                    Arguments[1].Int = Index;
                    Arguments[2].Int = TypeCode;
                    const Element = CallObject(Environment, VmClass, VmArrayLoad, &Arguments);
                    DeleteRef(Environment, ArrayValue);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(ArraySlot), Element);
                    DeleteRef(Environment, Element);
                },
                46 => {
                    const ValueSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const IndexSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const ArraySlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const TypeCode = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    const StoreValue = GetElement(Environment, Stack, @intCast(ValueSlot));
                    const IndexValue = GetElement(Environment, Stack, @intCast(IndexSlot));
                    const Index = (SafeUnboxInt(CallInt, Environment, IndexValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, IndexValue);
                    const ArrayValue = GetElement(Environment, Stack, @intCast(ArraySlot));
                    Arguments[0].Object = ArrayValue;
                    Arguments[1].Int = Index;
                    Arguments[2].Object = StoreValue;
                    Arguments[3].Int = TypeCode;
                    CallStaticVoid(Environment, VmClass, VmArrayStore, &Arguments);
                    DeleteRef(Environment, StoreValue);
                    DeleteRef(Environment, ArrayValue);
                    if (CheckException(Environment) != 0) break :Dispatch;
                },
                32 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    SetElement(Environment, Stack, @intCast(Destination), Symbol.String);
                    if (Symbol.String != null) DeleteRef(Environment, Symbol.String);
                },
                40 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    const Target = GetElement(Environment, Stack, @intCast(Slot));
                    if (Target != null) {
                        Arguments[0].Object = Symbol.String;
                        const TargetClass = CallObject(Environment, VmClass, VmCachedForName, &Arguments);
                        if (CheckException(Environment) != 0) {
                            DeleteRef(Environment, Target);
                            if (Symbol.String != null) DeleteRef(Environment, Symbol.String);
                            break :Dispatch;
                        }
                        Arguments[0].Object = Target;
                        const Ok = CallBoolean(Environment, TargetClass, VmClassIsInstance, &Arguments);
                        DeleteRef(Environment, TargetClass);
                        DeleteRef(Environment, Target);
                        if (Ok == 0) {
                            _ = ThrowNew(Environment, VmClassCastException, "");
                            if (Symbol.String != null) DeleteRef(Environment, Symbol.String);
                            break :Dispatch;
                        }
                    }
                    if (Symbol.String != null) DeleteRef(Environment, Symbol.String);
                },
                41 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    Arguments[0].Object = Symbol.String;
                    const TargetClass = CallObject(Environment, VmClass, VmCachedForName, &Arguments);
                    DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const ReferenceValue = GetElement(Environment, Stack, @intCast(Slot));
                    Arguments[0].Object = ReferenceValue;
                    const Ok = CallBoolean(Environment, TargetClass, VmClassIsInstance, &Arguments);
                    DeleteRef(Environment, TargetClass);
                    if (ReferenceValue != null) DeleteRef(Environment, ReferenceValue);
                    Arguments[0].Int = @as(i32, Ok);
                    const Boxed = CallObject(Environment, VmInteger, VmIntegerValueOf, &Arguments);
                    SetElement(Environment, Stack, @intCast(Slot), Boxed);
                    DeleteRef(Environment, Boxed);
                },
                43 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    Arguments[0].Object = Symbol.String;
                    const ComponentClass = CallObject(Environment, VmClass, VmCachedForName, &Arguments);
                    DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const CountValue = GetElement(Environment, Stack, @intCast(Slot));
                    const Count = (SafeUnboxInt(CallInt, Environment, CountValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, CountValue);
                    Arguments[0].Object = ComponentClass;
                    Arguments[1].Int = Count;
                    const NewArray = CallObject(Environment, VmReflectArray, VmArrayNewInstance, &Arguments);
                    DeleteRef(Environment, ComponentClass);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(Slot), NewArray);
                    DeleteRef(Environment, NewArray);
                },
                36 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    Arguments[0].Object = Symbol.String;
                    const HolderClass = CallObject(Environment, VmClass, VmCachedForName, &Arguments);
                    DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const Holder = NewObjectArray(Environment, 1, VmObject, null) orelse return null;
                    SetElement(Environment, Holder, 0, HolderClass);
                    DeleteRef(Environment, HolderClass);
                    SetElement(Environment, Stack, @intCast(Destination), Holder);
                    DeleteRef(Environment, Holder);
                },
                37 => {
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    Arguments[0].Object = Symbol.String;
                    const Constructor = CallObject(Environment, VmClass, VmResolveConstructor, &Arguments);
                    DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    const ParameterCount: usize = @intCast(@max(0, SafeUnboxInt(CallInt, Environment, Constructor, VmConstructorParameterCount) orelse return null));
                    const ArgumentArray = NewObjectArray(Environment, @intCast(ParameterCount), VmObject, null) orelse return null;
                    var FillIndex: usize = ParameterCount;
                    while (FillIndex > 0) {
                        FillIndex -= 1;
                        const ArgumentSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                        const ArgumentValue = GetElement(Environment, Stack, @intCast(ArgumentSlot));
                        SetElement(Environment, ArgumentArray, @intCast(FillIndex), ArgumentValue);
                        DeleteRef(Environment, ArgumentValue);
                    }
                    const HolderSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Holder = GetElement(Environment, Stack, @intCast(HolderSlot));
                    Arguments[0].Object = ArgumentArray;
                    const Instance = CallInstanceObject(Environment, Constructor, VmConstructorNewInstance, &Arguments);
                    DeleteRef(Environment, ArgumentArray);
                    DeleteRef(Environment, Constructor);
                    if (CheckException(Environment) != 0) {
                        if (Holder != null) DeleteRef(Environment, Holder);
                        break :Dispatch;
                    }
                    var ScanIndex: usize = 0;
                    while (ScanIndex < StackSize) : (ScanIndex += 1) {
                        const SlotValue = GetElement(Environment, Stack, @intCast(ScanIndex));
                        if (IsSameObject(Environment, SlotValue, Holder) != 0) SetElement(Environment, Stack, @intCast(ScanIndex), Instance);
                        if (SlotValue != null) DeleteRef(Environment, SlotValue);
                    }
                    var ScanLocal: usize = 0;
                    while (ScanLocal < NumberOfLocals) : (ScanLocal += 1) {
                        const SlotValue = GetElement(Environment, Locals, @intCast(ScanLocal));
                        if (IsSameObject(Environment, SlotValue, Holder) != 0) SetElement(Environment, Locals, @intCast(ScanLocal), Instance);
                        if (SlotValue != null) DeleteRef(Environment, SlotValue);
                    }
                    if (Holder != null) DeleteRef(Environment, Holder);
                    DeleteRef(Environment, Instance);
                },
                48 => {
                    const KeySlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Default: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const Low = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const High = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 4;
                    const KeyValue = GetElement(Environment, Stack, @intCast(KeySlot));
                    const Key = (SafeUnboxInt(CallInt, Environment, KeyValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, KeyValue);
                    if (Key < Low or Key > High) {
                        ProgramCounter = Default;
                    } else {
                        const Slot: usize = @intCast(Key - Low);
                        ProgramCounter = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter + Slot * 4), Image.len) orelse return null;
                    }
                },
                49 => {
                    const KeySlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Default: usize = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter), Image.len) orelse return null;
                    ProgramCounter += 4;
                    const CountRaw = ProgramWord(Image, Offset, Seed, ProgramCounter);
                    if (CountRaw < 0 or @as(usize, @intCast(CountRaw)) > Image.len) return null;
                    const Count: usize = @intCast(CountRaw);
                    ProgramCounter += 4;
                    const KeyValue = GetElement(Environment, Stack, @intCast(KeySlot));
                    const Key = (SafeUnboxInt(CallInt, Environment, KeyValue, VmIntegerIntValue) orelse return null);
                    DeleteRef(Environment, KeyValue);
                    var Matched = false;
                    var PairIndex: usize = 0;
                    while (PairIndex < Count) : (PairIndex += 1) {
                        const PairKey = ProgramWord(Image, Offset, Seed, ProgramCounter + PairIndex * 8);
                        if (PairKey == Key) {
                            ProgramCounter = BoundedTarget(ProgramWord(Image, Offset, Seed, ProgramCounter + PairIndex * 8 + 4), Image.len) orelse return null;
                            Matched = true;
                            break;
                        }
                    }
                    if (!Matched) ProgramCounter = Default;
                },
                51 => {
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    const DimensionCount: usize = ProgramByte(Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += 1;
                    var DimensionBuffer: [256]i32 = undefined;
                    if (DimensionCount > DimensionBuffer.len) return null;
                    var DimIndex: usize = DimensionCount;
                    while (DimIndex > 0) {
                        DimIndex -= 1;
                        const DimensionSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                        const DimensionValue = GetElement(Environment, Stack, @intCast(DimensionSlot));
                        DimensionBuffer[DimIndex] = (SafeUnboxInt(CallInt, Environment, DimensionValue, VmIntegerIntValue) orelse return null);
                        DeleteRef(Environment, DimensionValue);
                    }
                    const ResultSlot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const DimensionArray = NewIntArray(Environment, @intCast(DimensionCount)) orelse return null;
                    SetIntRegion(Environment, DimensionArray, 0, @intCast(DimensionCount), &DimensionBuffer);
                    Arguments[0].Object = Symbol.String;
                    const ComponentClass = CallObject(Environment, VmClass, VmMultiComponent, &Arguments);
                    DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) {
                        DeleteRef(Environment, DimensionArray);
                        break :Dispatch;
                    }
                    Arguments[0].Object = ComponentClass;
                    Arguments[1].Object = DimensionArray;
                    const MultiArray = CallObject(Environment, VmReflectArray, VmArrayNewInstanceMulti, &Arguments);
                    DeleteRef(Environment, ComponentClass);
                    DeleteRef(Environment, DimensionArray);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(ResultSlot), MultiArray);
                    DeleteRef(Environment, MultiArray);
                },
                50 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const ThrowValue = GetElement(Environment, Stack, @intCast(Slot));
                    _ = ThrowObject(Environment, ThrowValue);
                    if (ThrowValue != null) DeleteRef(Environment, ThrowValue);
                    break :Dispatch;
                },
                52 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const MonitorObject = GetElement(Environment, Stack, @intCast(Slot));
                    _ = MonitorEnter(Environment, MonitorObject);
                    if (MonitorObject != null) DeleteRef(Environment, MonitorObject);
                    if (CheckException(Environment) != 0) break :Dispatch;
                },
                53 => {
                    const Slot = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const MonitorObject = GetElement(Environment, Stack, @intCast(Slot));
                    _ = MonitorExit(Environment, MonitorObject);
                    if (MonitorObject != null) DeleteRef(Environment, MonitorObject);
                    if (CheckException(Environment) != 0) break :Dispatch;
                },
                54 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Symbol = ReadProgramSymbol(NewStringUtf, Environment, Image, Offset, Seed, ProgramCounter);
                    ProgramCounter += Symbol.Length;
                    Arguments[0].Object = Symbol.String;
                    const Resolved = CallObject(Environment, VmClass, VmCachedForName, &Arguments);
                    if (Symbol.String != null) DeleteRef(Environment, Symbol.String);
                    if (CheckException(Environment) != 0) break :Dispatch;
                    SetElement(Environment, Stack, @intCast(Destination), Resolved);
                    if (Resolved != null) DeleteRef(Environment, Resolved);
                },
                55 => {
                    const Destination = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Source = ReadStackSlot(Image, Offset, Seed, &ProgramCounter, StackSize);
                    const Value = GetElement(Environment, Stack, @intCast(Source));
                    SetElement(Environment, Stack, @intCast(Destination), Value);
                    DeleteRef(Environment, Value);
                },
                else => return null,
            }
        }
        if (CheckException(Environment) != 0) {
            if (ScanHandlerTable(Environment, Image, Offset, Seed, CurrentOpPc)) |Handled| {
                const ExceptionSlot = Cipher.RegisterPermute(Seed ^ 0x5A5A5A5A, @intCast(StackSize), 0);
                SetElement(Environment, Stack, @intCast(ExceptionSlot), Handled.Exception);
                ProgramCounter = Handled.Handler;
                if (Handled.Exception != null) DeleteRef(Environment, Handled.Exception);
            } else {
                return null;
            }
        }
    }
}

pub fn ThrowArithmeticException(Environment: ?*anyopaque) void {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const ThrowNew: ThrowNewFunction = @ptrCast(@alignCast(Vtable[IndexThrowNew]));
    const ExceptionClass = FindClass(Environment, Reveal("java/lang/ArithmeticException")) orelse return;
    _ = ThrowNew(Environment, ExceptionClass, Reveal("/ by zero"));
}

pub fn FloatToInt(Value: f32) i32 {
    if (std.math.isNan(Value)) return 0;
    if (Value >= 2147483648.0) return 2147483647;
    if (Value < -2147483648.0) return -2147483648;
    return @intFromFloat(@trunc(Value));
}

pub fn FloatToLong(Value: f32) i64 {
    if (std.math.isNan(Value)) return 0;
    if (Value >= 9223372036854775808.0) return 9223372036854775807;
    if (Value < -9223372036854775808.0) return -9223372036854775808;
    return @intFromFloat(@trunc(Value));
}

pub fn DoubleToInt(Value: f64) i32 {
    if (std.math.isNan(Value)) return 0;
    if (Value >= 2147483648.0) return 2147483647;
    if (Value < -2147483648.0) return -2147483648;
    return @intFromFloat(@trunc(Value));
}

pub fn DoubleToLong(Value: f64) i64 {
    if (std.math.isNan(Value)) return 0;
    if (Value >= 9223372036854775808.0) return 9223372036854775807;
    if (Value < -9223372036854775808.0) return -9223372036854775808;
    return @intFromFloat(@trunc(Value));
}

pub fn FloatCompare(Left: f32, Right: f32, NanResult: i32) i32 {
    if (std.math.isNan(Left) or std.math.isNan(Right)) return NanResult;
    if (Left < Right) return -1;
    if (Left > Right) return 1;
    return 0;
}

pub fn DoubleCompare(Left: f64, Right: f64, NanResult: i32) i32 {
    if (std.math.isNan(Left) or std.math.isNan(Right)) return NanResult;
    if (Left < Right) return -1;
    if (Left > Right) return 1;
    return 0;
}

pub fn RegisterForClass(Environment: ?*anyopaque, ClassName: [*:0]const u8, Methods: []const JavaNativeInterfaceNativeMethod) void {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const RegisterNatives: RegisterNativesFunction = @ptrCast(@alignCast(Vtable[IndexRegisterNatives]));
    const Class = FindClass(Environment, ClassName) orelse {
        const ClearException: ExceptionClearFunction = @ptrCast(@alignCast(Vtable[IndexExceptionClear]));
        ClearException(Environment);
        return;
    };
    _ = RegisterNatives(Environment, Class, Methods.ptr, @intCast(Methods.len));
}

fn DetectNativeDebugger() bool {
    if (comptime builtin.os.tag == .windows) {
        return std.os.windows.peb().BeingDebugged.toBool();
    }
    if (comptime builtin.os.tag == .linux) {
        const OpenResult = std.os.linux.open("/proc/self/status", .{}, 0);
        if (@as(isize, @bitCast(OpenResult)) < 0) return false;
        const Descriptor: i32 = @intCast(OpenResult);
        defer _ = std.os.linux.close(Descriptor);
        var Buffer: [4096]u8 = undefined;
        const ReadResult = std.os.linux.read(Descriptor, &Buffer, Buffer.len);
        if (@as(isize, @bitCast(ReadResult)) <= 0) return false;
        const Slice = Buffer[0..ReadResult];
        const Marker = "TracerPid:";
        const Position = std.mem.indexOf(u8, Slice, Marker) orelse return false;
        var Cursor = Position + Marker.len;
        while (Cursor < Slice.len and (Slice[Cursor] == ' ' or Slice[Cursor] == '\t')) : (Cursor += 1) {}
        return Cursor < Slice.len and Slice[Cursor] != '0';
    }
    return false;
}

fn ContainsCString(Haystack: [*:0]const u8, Needle: [*:0]const u8) bool {
    return std.mem.indexOf(u8, std.mem.span(Haystack), std.mem.span(Needle)) != null;
}

fn DetectJvmDebugAgent(Environment: ?*anyopaque) bool {
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const GetStaticMethodId: GetMethodIdFunction = @ptrCast(@alignCast(Vtable[IndexGetStaticMethodId]));
    const GetMethodId: GetMethodIdFunction = @ptrCast(@alignCast(Vtable[IndexGetMethodId]));
    const CallStaticObject: CallStaticObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallStaticObjectMethodA]));
    const CallObject: CallObjectMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallObjectMethodA]));
    const CallInt: CallIntMethodAFunction = @ptrCast(@alignCast(Vtable[IndexCallIntMethodA]));
    const GetStringUtf: GetStringUtfCharsFunction = @ptrCast(@alignCast(Vtable[IndexGetStringUtfChars]));
    const ReleaseStringUtf: ReleaseStringUtfCharsFunction = @ptrCast(@alignCast(Vtable[IndexReleaseStringUtfChars]));
    const ClearException: ExceptionClearFunction = @ptrCast(@alignCast(Vtable[IndexExceptionClear]));
    const DeleteRef: DeleteLocalReferenceFunction = @ptrCast(@alignCast(Vtable[IndexDeleteLocalRef]));

    var NoArguments: [1]JValue = undefined;
    const ManagementClass = FindClass(Environment, Reveal("java/lang/management/ManagementFactory")) orelse {
        ClearException(Environment);
        return false;
    };
    const RuntimeAccessor = GetStaticMethodId(Environment, ManagementClass, Reveal("getRuntimeMXBean"), Reveal("()Ljava/lang/management/RuntimeMXBean;")) orelse {
        ClearException(Environment);
        return false;
    };
    const RuntimeBean = CallStaticObject(Environment, ManagementClass, RuntimeAccessor, &NoArguments) orelse {
        ClearException(Environment);
        return false;
    };
    const RuntimeClass = FindClass(Environment, Reveal("java/lang/management/RuntimeMXBean")) orelse {
        ClearException(Environment);
        return false;
    };
    const InputArguments = GetMethodId(Environment, RuntimeClass, Reveal("getInputArguments"), Reveal("()Ljava/util/List;")) orelse {
        ClearException(Environment);
        return false;
    };
    const ArgumentList = CallObject(Environment, RuntimeBean, InputArguments, null) orelse {
        ClearException(Environment);
        return false;
    };
    const ListClass = FindClass(Environment, Reveal("java/util/List")) orelse {
        ClearException(Environment);
        return false;
    };
    const SizeMethod = GetMethodId(Environment, ListClass, Reveal("size"), Reveal("()I")) orelse {
        ClearException(Environment);
        return false;
    };
    const GetMethod = GetMethodId(Environment, ListClass, Reveal("get"), Reveal("(I)Ljava/lang/Object;")) orelse {
        ClearException(Environment);
        return false;
    };
    const ArgumentCount = CallInt(Environment, ArgumentList, SizeMethod, null);
    var Detected = false;
    var Index: i32 = 0;
    while (Index < ArgumentCount and !Detected) : (Index += 1) {
        var IndexArgument: [1]JValue = undefined;
        IndexArgument[0].Int = Index;
        const ArgumentString = CallObject(Environment, ArgumentList, GetMethod, &IndexArgument) orelse continue;
        if (GetStringUtf(Environment, ArgumentString, null)) |Characters| {
            if (ContainsCString(Characters, Reveal("jdwp")) or ContainsCString(Characters, Reveal("-Xdebug"))) Detected = true;
            ReleaseStringUtf(Environment, ArgumentString, Characters);
        }
        DeleteRef(Environment, ArgumentString);
    }
    ClearException(Environment);
    return Detected;
}

export fn JNI_OnLoad(JavaVirtualMachine: ?*anyopaque, Reserved: ?*anyopaque) callconv(.c) i32 {
    _ = Reserved;
    @atomicStore(u64, &GlobalObfuscationSeed, Cipher.BakedInteg, .monotonic);
    const VmVtable = JavaNativeInterfaceVtable(JavaVirtualMachine);
    const GetEnvironment: GetEnvironmentFunction = @ptrCast(@alignCast(VmVtable[IndexGetEnvironment]));
    var EnvironmentPointer: ?*anyopaque = null;
    if (GetEnvironment(JavaVirtualMachine, &EnvironmentPointer, JavaNativeInterfaceVersion18) != 0) return JavaNativeInterfaceVersion18;
    const Environment = EnvironmentPointer;
    const Vtable = JavaNativeInterfaceVtable(Environment);
    const FindClass: FindClassFunction = @ptrCast(@alignCast(Vtable[IndexFindClass]));
    const RegisterNatives: RegisterNativesFunction = @ptrCast(@alignCast(Vtable[IndexRegisterNatives]));
    const Class = FindClass(Environment, LoaderClassName) orelse return JavaNativeInterfaceVersion18;
    const Methods = [_]JavaNativeInterfaceNativeMethod{
        .{ .Name = "p", .Signature = "()I", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeProbe)) },
        .{ .Name = "vh", .Signature = "([BJ)V", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeVerifyHash)) },
        .{ .Name = "d", .Signature = "([JIIIII)Ljava/lang/String;", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeDecrypt)) },
        .{ .Name = "kb", .Signature = "(II)I", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeKeystreamByte)) },
        .{ .Name = "unpack", .Signature = "([B)[B", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeUnpack)) },
        .{ .Name = "vi", .Signature = "([B[BLjava/lang/Class;)V", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeVmInit)) },
        .{ .Name = "nr", .Signature = "(I[Ljava/lang/Object;)Ljava/lang/Object;", .FunctionPointer = @ptrFromInt(@intFromPtr(&NativeVmRun)) },
    };
    _ = RegisterNatives(Environment, Class, &Methods, @intCast(Methods.len));
    @import("root").RegisterTranspiled(Environment);
    _ = FindClass(Environment, InterpreterClassName);
    VerifyIntegrityManifest(Environment, Class);
    const ClearPending: ExceptionClearFunction = @ptrCast(@alignCast(Vtable[IndexExceptionClear]));
    ClearPending(Environment);
    if (DetectNativeDebugger() or DetectJvmDebugAgent(Environment)) {
        @atomicStore(u32, &GlobalTamperD, 1, .monotonic);
    }
    ClearPending(Environment);
    @atomicStore(u64, &GlobalBaseline, JavaNativeInterfaceCodeHash(), .monotonic);
    @atomicStore(u64, &GlobalVtableBaseline, VtableHash(Environment), .monotonic);
    if (std.Thread.spawn(.{}, JavaNativeInterfaceWatchdog, .{})) |SpawnedThread| {
        SpawnedThread.detach();
    } else |_| {}
    return JavaNativeInterfaceVersion18;
}
