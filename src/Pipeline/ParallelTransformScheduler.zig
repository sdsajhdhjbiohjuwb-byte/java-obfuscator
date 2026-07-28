const std = @import("std");
const JavaArchiveReader = @import("../Archive/JavaArchiveReader.zig");
const JavaArchiveWriter = @import("../Archive/JavaArchiveWriter.zig");
const ConstantPoolTransformer = @import("../Classfile/ConstantPoolTransformer.zig");
const ObfuscationPipeline = @import("ObfuscationPipeline.zig");
const ArchiveEntry = JavaArchiveReader.ArchiveEntry;

const ClassSuffix = ".class";

pub const Result = struct { Entries: []ArchiveEntry, SoftFails: usize, HardFails: usize };

const Context = struct {
    Entries: []const ArchiveEntry,
    Results: []ArchiveEntry,
    Plan: ObfuscationPipeline.Plan,
    MasterSeed: u64,
    Next: std.atomic.Value(usize),
    Allocators: []std.mem.Allocator,
    SoftFails: std.atomic.Value(usize),
    HardFails: std.atomic.Value(usize),
};

fn Worker(WorkerContext: *Context, ThreadIdentifier: usize) void {
    const AllocatorHandle = WorkerContext.Allocators[ThreadIdentifier];
    while (true) {
        const Index = WorkerContext.Next.fetchAdd(1, .monotonic);
        if (Index >= WorkerContext.Entries.len) break;
        WorkerContext.Results[Index] = TransformOne(AllocatorHandle, WorkerContext.Entries[Index], WorkerContext) catch {
            _ = WorkerContext.HardFails.fetchAdd(1, .monotonic);
            WorkerContext.Results[Index] = WorkerContext.Entries[Index];
            continue;
        };
    }
}

fn TransformOne(AllocatorHandle: std.mem.Allocator, InputEntry: ArchiveEntry, TransformContext: *Context) !ArchiveEntry {
    const RawBytes = try JavaArchiveReader.Inflate(AllocatorHandle, InputEntry);
    const InternalName = InputEntry.Name[0 .. InputEntry.Name.len - ClassSuffix.len];

    var RandomGenerator = std.Random.DefaultPrng.init(TransformContext.MasterSeed ^ std.hash.Wyhash.hash(0x9e3779b9, InternalName));

    const NewBytes = ObfuscationPipeline.ObfuscationPipeline(AllocatorHandle, RawBytes, TransformContext.Plan, &RandomGenerator) catch Block: {
        _ = TransformContext.SoftFails.fetchAdd(1, .monotonic);
        break :Block (ConstantPoolTransformer.Transform(AllocatorHandle, RawBytes, TransformContext.Plan.Mapping.*) catch RawBytes);
    };

    const CompressedBytes = try JavaArchiveWriter.Deflate(AllocatorHandle, NewBytes);
    const NewInternalName = TransformContext.Plan.Mapping.RemapInternal(InternalName) orelse InternalName;
    const NewName = try std.fmt.allocPrint(AllocatorHandle, "{s}.class", .{NewInternalName});

    return .{
        .Name = NewName,
        .Method = 8,
        .Crc32 = JavaArchiveWriter.Crc32(NewBytes),
        .CompressedSize = @intCast(CompressedBytes.len),
        .UncompressedSize = @intCast(NewBytes.len),
        .CompressedData = CompressedBytes,
    };
}

pub fn ParallelTransformScheduler(
    AllocatorHandle: std.mem.Allocator,
    ClassEntries: []const ArchiveEntry,
    TransformPlan: ObfuscationPipeline.Plan,
    MasterSeed: u64,
    RequestedThreadCount: usize,
) !Result {
    const Results = try AllocatorHandle.alloc(ArchiveEntry, ClassEntries.len);
    if (ClassEntries.len == 0) return .{ .Entries = Results, .SoftFails = 0, .HardFails = 0 };

    var ThreadCount = RequestedThreadCount;
    if (ThreadCount < 1) ThreadCount = 1;
    if (ThreadCount > ClassEntries.len) ThreadCount = ClassEntries.len;

    const Arenas = try AllocatorHandle.alloc(std.heap.ArenaAllocator, ThreadCount);
    const Allocators = try AllocatorHandle.alloc(std.mem.Allocator, ThreadCount);
    for (0..ThreadCount) |ThreadIndex| {
        Arenas[ThreadIndex] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        Allocators[ThreadIndex] = Arenas[ThreadIndex].allocator();
    }

    var TransformContext = Context{
        .Entries = ClassEntries,
        .Results = Results,
        .Plan = TransformPlan,
        .MasterSeed = MasterSeed,
        .Next = std.atomic.Value(usize).init(0),
        .Allocators = Allocators,
        .SoftFails = std.atomic.Value(usize).init(0),
        .HardFails = std.atomic.Value(usize).init(0),
    };

    if (ThreadCount == 1) {
        Worker(&TransformContext, 0);
    } else {
        const Threads = try AllocatorHandle.alloc(std.Thread, ThreadCount - 1);
        for (0..ThreadCount - 1) |ThreadIndex| {
            Threads[ThreadIndex] = try std.Thread.spawn(.{}, Worker, .{ &TransformContext, ThreadIndex + 1 });
        }
        Worker(&TransformContext, 0);
        for (Threads) |ThreadHandle| ThreadHandle.join();
    }

    for (Results) |*ResultEntry| {
        ResultEntry.Name = try AllocatorHandle.dupe(u8, ResultEntry.Name);
        ResultEntry.CompressedData = try AllocatorHandle.dupe(u8, ResultEntry.CompressedData);
    }
    for (0..ThreadCount) |ThreadIndex| Arenas[ThreadIndex].deinit();

    return .{
        .Entries = Results,
        .SoftFails = TransformContext.SoftFails.load(.monotonic),
        .HardFails = TransformContext.HardFails.load(.monotonic),
    };
}
