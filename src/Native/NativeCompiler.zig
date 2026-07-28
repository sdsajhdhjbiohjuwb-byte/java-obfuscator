const std = @import("std");
const NativeContainerPacker = @import("NativeContainerPacker.zig");
const Cipher = @import("NativeCipher.zig");
const MetadataStrip = @import("NativeMetadataStrip.zig");
const ProgressLog = @import("../Pipeline/ProgressLog.zig");

fn Substitute(Allocator: std.mem.Allocator, Source: []const u8, Needle: []const u8, comptime Format: []const u8, Value: anytype) ![]const u8 {
    if (std.mem.indexOf(u8, Source, Needle) == null) return error.SecretBakingNeedleMissing;
    const Replacement = try std.fmt.allocPrint(Allocator, Format, .{Value});
    return std.mem.replaceOwned(u8, Allocator, Source, Needle, Replacement);
}

const CoreSource = @embedFile("JniNativeCore.zig");
const CipherSource = @embedFile("NativeCipher.zig");
const PackSource = @embedFile("NativePack.zig");

const Target = struct { Triple: []const u8, Tag: u8, IncludesLibc: bool };

const Targets = [_]Target{
    .{ .Triple = "x86_64-windows", .Tag = NativeContainerPacker.TagWindowsX64, .IncludesLibc = false },
    .{ .Triple = "x86_64-linux-gnu", .Tag = NativeContainerPacker.TagLinuxX64, .IncludesLibc = true },
    .{ .Triple = "x86_64-macos", .Tag = NativeContainerPacker.TagMacosX64, .IncludesLibc = true },
    .{ .Triple = "aarch64-windows", .Tag = NativeContainerPacker.TagWindowsArm64, .IncludesLibc = false },
    .{ .Triple = "aarch64-linux-gnu", .Tag = NativeContainerPacker.TagLinuxArm64, .IncludesLibc = true },
    .{ .Triple = "aarch64-macos", .Tag = NativeContainerPacker.TagMacosArm64, .IncludesLibc = true },
};

pub const CompiledNative = struct { Container: []u8, LibraryHashes: []const NativeContainerPacker.LibraryHash };

const Outcome = struct {
    Ok: bool = false,
    Raw: []u8 = &.{},
    Hash: i64 = 0,
    Tag: u8 = 0,
};

const BuildContext = struct {
    IoInterface: std.Io,
    TargetHandle: Target,
    Index: usize,
    Results: []Outcome,
    Secrets: Cipher.Secrets,
};

fn BuildTarget(Context: *BuildContext) void {
    const Allocator = std.heap.smp_allocator;
    const CurrentTarget = Context.TargetHandle;
    const TargetStart = std.Io.Clock.now(.awake, Context.IoInterface);
    const LibraryName = std.fmt.allocPrint(Allocator, ".nmbuild/m{d}", .{Context.Index}) catch return;
    const EmitBinaryArgument = std.fmt.allocPrint(Allocator, "-femit-bin={s}", .{LibraryName}) catch return;
    var ArgumentVector: std.ArrayList([]const u8) = .empty;
    ArgumentVector.appendSlice(Allocator, &.{ "zig", "build-lib", ".nmbuild/MethodExports.zig", "-dynamic", "-target", CurrentTarget.Triple, "-OReleaseSmall", "-fstrip" }) catch return;
    ArgumentVector.appendSlice(Allocator, &.{ "-fno-unwind-tables", "-ffunction-sections", "-fdata-sections" }) catch return;
    if (std.mem.indexOf(u8, CurrentTarget.Triple, "macos") != null) {
        ArgumentVector.append(Allocator, "-dead_strip") catch return;
    } else {
        ArgumentVector.append(Allocator, "--gc-sections") catch return;
    }
    if (CurrentTarget.IncludesLibc) ArgumentVector.append(Allocator, "-lc") catch return;
    ArgumentVector.append(Allocator, EmitBinaryArgument) catch return;
    var Attempt: u8 = 0;
    while (Attempt < 4) : (Attempt += 1) {
        const Result = std.process.run(Allocator, Context.IoInterface, .{ .argv = ArgumentVector.items }) catch continue;
        if (!Result.term.success()) continue;
        const RawBytes = std.Io.Dir.cwd().readFileAlloc(Context.IoInterface, LibraryName, Allocator, .unlimited) catch continue;
        MetadataStrip.Scrub(RawBytes);
        Context.Results[Context.Index] = .{
            .Ok = true,
            .Raw = RawBytes,
            .Hash = @bitCast(Cipher.IntegrityHash(RawBytes, Context.Secrets)),
            .Tag = CurrentTarget.Tag,
        };
        const Elapsed: u64 = @intCast(@max(TargetStart.durationTo(std.Io.Clock.now(.awake, Context.IoInterface)).toMilliseconds(), 0));
        ProgressLog.Sub("{s}  {d} ms", .{ CurrentTarget.Triple, Elapsed });
        return;
    }
}

pub fn NativeCompiler(IoInterface: std.Io, Allocator: std.mem.Allocator, MethodsZigSource: []const u8, SecretsHandle: Cipher.Secrets, LoaderInternal: []const u8, InterpreterInternal: []const u8) !CompiledNative {
    const CurrentDirectory = std.Io.Dir.cwd();
    try CurrentDirectory.createDirPath(IoInterface, ".nmbuild");
    defer CurrentDirectory.deleteTree(IoInterface, ".nmbuild") catch {};
    var CipherPatched: []const u8 = CipherSource;
    CipherPatched = try Substitute(Allocator, CipherPatched, "pub const BakedArx0: u64 = 0x243F6A8885A308D3;", "pub const BakedArx0: u64 = {d};", SecretsHandle.Arx0);
    CipherPatched = try Substitute(Allocator, CipherPatched, "pub const BakedArx1: u64 = 0x13198A2E03707344;", "pub const BakedArx1: u64 = {d};", SecretsHandle.Arx1);
    CipherPatched = try Substitute(Allocator, CipherPatched, "pub const BakedPepper: i32 = 0;", "pub const BakedPepper: i32 = {d};", SecretsHandle.Pepper);
    CipherPatched = try Substitute(Allocator, CipherPatched, "pub const BakedInteg: u64 = 0xCBF29CE484222325;", "pub const BakedInteg: u64 = {d};", SecretsHandle.Integrity);
    var CorePatched = try Substitute(Allocator, CoreSource, "pub const LoaderClassName: [*:0]const u8 = \"pkg/Loader\";", "pub const LoaderClassName: [*:0]const u8 = \"{s}\";", LoaderInternal);
    CorePatched = try Substitute(Allocator, CorePatched, "pub const InterpreterClassName: [*:0]const u8 = \"pkg/Interpreter\";", "pub const InterpreterClassName: [*:0]const u8 = \"{s}\";", InterpreterInternal);
    try CurrentDirectory.writeFile(IoInterface, .{ .sub_path = ".nmbuild/JniNativeCore.zig", .data = CorePatched });
    try CurrentDirectory.writeFile(IoInterface, .{ .sub_path = ".nmbuild/NativeCipher.zig", .data = CipherPatched });
    try CurrentDirectory.writeFile(IoInterface, .{ .sub_path = ".nmbuild/NativePack.zig", .data = PackSource });
    try CurrentDirectory.writeFile(IoInterface, .{ .sub_path = ".nmbuild/MethodExports.zig", .data = MethodsZigSource });

    var Results: [Targets.len]Outcome = undefined;
    for (&Results) |*Slot| Slot.* = .{};
    var Contexts: [Targets.len]BuildContext = undefined;
    var Threads: [Targets.len]?std.Thread = undefined;
    for (&Threads) |*Slot| Slot.* = null;
    for (Targets, 0..) |CurrentTarget, Index| {
        Contexts[Index] = .{ .IoInterface = IoInterface, .TargetHandle = CurrentTarget, .Index = Index, .Results = &Results, .Secrets = SecretsHandle };
        Threads[Index] = std.Thread.spawn(.{}, BuildTarget, .{&Contexts[Index]}) catch null;
        if (Threads[Index] == null) BuildTarget(&Contexts[Index]);
    }
    for (Threads) |MaybeThread| {
        if (MaybeThread) |Thread| Thread.join();
    }

    var Slices: std.ArrayList(NativeContainerPacker.RawSlice) = .empty;
    var LibraryHashes: std.ArrayList(NativeContainerPacker.LibraryHash) = .empty;
    for (Results) |Item| {
        if (!Item.Ok) return error.NativeMethodCompileFailed;
        try Slices.append(Allocator, .{ .Tag = Item.Tag, .Raw = Item.Raw });
        try LibraryHashes.append(Allocator, .{ .Tag = Item.Tag, .Hash = Item.Hash });
    }

    return .{
        .Container = try NativeContainerPacker.PackRawSlices(Allocator, Slices.items),
        .LibraryHashes = try LibraryHashes.toOwnedSlice(Allocator),
    };
}
