const std = @import("std");

const RuntimeConfig = @import("RuntimeConfig.zig");
const ProgressLog = @import("ProgressLog.zig");
const JavaArchiveReader = @import("../Archive/JavaArchiveReader.zig");
const JavaArchiveWriter = @import("../Archive/JavaArchiveWriter.zig");
const ClassNameMappingRegistry = @import("../Rename/ClassNameMappingRegistry.zig");
const ManifestRewriter = @import("../Archive/ManifestRewriter.zig");
const ParallelTransformScheduler = @import("ParallelTransformScheduler.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const MemberRenameRegistry = @import("../Passes/MemberRenameRegistry.zig");
const RenameKeepSetAnalyzer = @import("../Passes/RenameKeepSetAnalyzer.zig");
const DeadCodeEliminator = @import("../Passes/DeadCodeEliminator.zig");
const IdentifierGenerator = @import("../Passes/IdentifierGenerator.zig");
const ReferenceBootstrapSynthesizer = @import("../Passes/ReferenceBootstrapSynthesizer.zig");
const ControlFlowShuffler = @import("../Passes/ControlFlowShuffler.zig");
const ObfuscationPipeline = @import("ObfuscationPipeline.zig");
const VirtualMachineImageBuilder = @import("../Vm/VirtualMachineImageBuilder.zig");
const InterpreterClassSynthesizer = @import("../Vm/InterpreterClassSynthesizer.zig");
const ClassTierPlanner = @import("../Loader/ClassTierPlanner.zig");
const CustomClassLoaderSynthesizer = @import("../Loader/CustomClassLoaderSynthesizer.zig");
const EncryptedResourceEncoder = @import("../Loader/EncryptedResourceEncoder.zig");
const NativePack = @import("../Native/NativePack.zig");
const NativeMethodBuilder = @import("../Native/NativeMethodBuilder.zig");
const NativeCompiler = @import("../Native/NativeCompiler.zig");
const NativeReaderSynthesizer = @import("../Loader/NativeReaderSynthesizer.zig");
const StringBootstrapSynthesizer = @import("../Passes/StringBootstrapSynthesizer.zig");
const Virtualizer = @import("../Passes/Virtualizer.zig");
const NativeCipher = @import("../Native/NativeCipher.zig");

const ArchiveEntry = JavaArchiveReader.ArchiveEntry;

const ManifestPath = "META-INF/MANIFEST.MF";
const ClassSuffix = ".class";
const InfraPackage = "dev/jnic";
const LibraryPackage = "dev/jnic/lib";
const LoaderName = "JNICLoader";

pub fn ResolveJar(IoInterface: std.Io, Input: []const u8) ![]const u8 {
    if (!EndsWithIgnoreCase(Input, ".jar")) return error.NotAJarFile;
    const FileStat = try std.Io.Dir.cwd().statFile(IoInterface, Input, .{});
    if (FileStat.kind == .directory) return error.NotAJarFile;
    return Input;
}

pub fn ObfuscateJar(
    IoInterface: std.Io,
    Input: []const u8,
) !void {
    var JarArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer JarArena.deinit();
    const Arena = JarArena.allocator();

    ProgressLog.Begin(IoInterface, Input);
    const InputPath = try ResolveJar(IoInterface, Input);

    const CurrentDirectory = std.Io.Dir.cwd();

    const ReadTask = ProgressLog.Start("read jar", .{});
    const JarBytes = try CurrentDirectory.readFileAlloc(IoInterface, InputPath, Arena, .unlimited);
    const Entries = try JavaArchiveReader.Read(Arena, JarBytes);
    ReadTask.Done("{d} entries, {d} bytes", .{ Entries.len, JarBytes.len });

    const SelectTask = ProgressLog.Start("select classes", .{});
    var ClassEntries: std.ArrayList(ArchiveEntry) = .empty;
    var NormalInternalNames: std.ArrayList([]const u8) = .empty;
    const ClassPathPrefix = DetectClassPathPrefix(Entries);
    for (Entries) |Entry| {
        if (!IsAppClass(Entry.Name, ClassPathPrefix)) continue;
        const StrippedName = Entry.Name[ClassPathPrefix.len..];
        var StrippedEntry = Entry;
        StrippedEntry.Name = StrippedName;
        try ClassEntries.append(Arena, StrippedEntry);
        try NormalInternalNames.append(Arena, StrippedName[0 .. StrippedName.len - ClassSuffix.len]);
    }
    if (ClassEntries.items.len == 0) {
        return error.NoClassEntries;
    }
    SelectTask.Done("{d} application classes", .{ClassEntries.items.len});

    const Seed = SeedBlock: {
        var RandomSeed: u64 = undefined;
        IoInterface.random(std.mem.asBytes(&RandomSeed));
        break :SeedBlock RandomSeed ^ Entropy(Arena, JarBytes);
    };
    var PseudoRandom = std.Random.DefaultPrng.init(Seed);
    const RandomGenerator = PseudoRandom.random();

    const RandomSixLetters = try IdentifierGenerator.RandomLetters(Arena, RandomGenerator, 6);
    const InfraClassPackage = try std.fmt.allocPrint(Arena, "{s}/{s}", .{ InfraPackage, RandomSixLetters });
    const AppPackage = "";

    const ParseTask = ProgressLog.Start("parse & map", .{});
    const Mapping = try ClassNameMappingRegistry.Build(Arena, NormalInternalNames.items, AppPackage);

    var Models: std.ArrayList(*ClassFileModel.ClassFile) = .empty;
    for (ClassEntries.items) |Entry| {
        const RawClassBytes = JavaArchiveReader.Inflate(Arena, Entry) catch continue;
        const Model = Arena.create(ClassFileModel.ClassFile) catch continue;
        Model.* = ClassFileModel.Parse(Arena, RawClassBytes) catch continue;
        try Models.append(Arena, Model);
    }
    ParseTask.Done("{d} classes parsed", .{Models.items.len});

    const AnalyzeTask = ProgressLog.Start("analyze members", .{});
    var SafeList = try RenameKeepSetAnalyzer.CollectStringConstants(Arena, Models.items);
    var RenameRegistry = try MemberRenameRegistry.Build(Arena, Models.items, &SafeList);
    var DeadCode = try DeadCodeEliminator.Analyze(Arena, Models.items);
    AnalyzeTask.Done("{d} dead members identified", .{DeadCode.Map.count()});

    const MasterSeed: u64 = RandomGenerator.int(u64);

    const TierTask = ProgressLog.Start("plan tiers", .{});
    var ModuleNames = std.StringHashMap(void).init(Arena);
    for (NormalInternalNames.items) |Name| try ModuleNames.put(Name, {});
    var Roots = std.StringHashMap(void).init(Arena);
    for (Entries) |Entry| {
        if (std.mem.endsWith(u8, Entry.Name, ClassSuffix)) continue;
        const Text = JavaArchiveReader.Inflate(Arena, Entry) catch continue;
        var NameIterator = ModuleNames.keyIterator();
        while (NameIterator.next()) |Key| {
            const DottedName = ClassNameMappingRegistry.SlashToDot(Arena, Key.*) catch continue;
            if (std.mem.indexOf(u8, Text, Key.*) != null or std.mem.indexOf(u8, Text, DottedName) != null) {
                try Roots.put(Key.*, {});
            }
        }
    }
    const Tier1Classes = try ClassTierPlanner.ClassTierPlanner(Arena, Models.items, &ModuleNames, &Roots);
    const UseCustomLoader = RuntimeConfig.Active.CustomLoader and RuntimeConfig.Active.Passes.ReferenceObfuscation and Tier1Classes.count() > 0;
    TierTask.Done("{d} tier-1 classes, custom loader {s}", .{ Tier1Classes.count(), if (UseCustomLoader) "on" else "off" });

    const PrepareTask = ProgressLog.Start("prepare infra", .{});
    const NativeReaderInternal = try std.fmt.allocPrint(Arena, "{s}/{s}", .{ InfraClassPackage, LoaderName });

    var InfraIndex: usize = NormalInternalNames.items.len;
    const ClassLoaderInternal = try InfraLeaf(Arena, InfraClassPackage, &InfraIndex);
    const ClassLoaderExtension = try std.fmt.allocPrint(Arena, ".{s}", .{try IdentifierGenerator.RandomLetters(Arena, RandomGenerator, 5)});

    const BootstrapMethodInternal = try InfraLeaf(Arena, InfraClassPackage, &InfraIndex);
    const Bootstrap = try ReferenceBootstrapSynthesizer.ReferenceBootstrapSynthesizer(Arena, BootstrapMethodInternal, NativeReaderInternal, if (UseCustomLoader) ClassLoaderInternal else "");

    const InterpreterInternal = try InfraLeaf(Arena, InfraClassPackage, &InfraIndex);
    const VirtualMachineResourcePath = try std.fmt.allocPrint(Arena, "{s}/cache.dat", .{LibraryPackage});
    const BuilderAllocator = std.heap.smp_allocator;
    var VirtualMachineBuilder = VirtualMachineImageBuilder.Builder.Initialize(BuilderAllocator);
    VirtualMachineBuilder.ShuffleOpcodes(RandomGenerator);
    ProgressLog.Sub("opcode permutation shuffled", .{});
    VirtualMachineBuilder.NonceBase = RandomGenerator.int(u32);
    var MethodBuilder = NativeMethodBuilder.Builder.Initialize(BuilderAllocator);

    const StringBootstrapInternal = try InfraLeaf(Arena, InfraClassPackage, &InfraIndex);

    var SecretSeed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    IoInterface.random(&SecretSeed);
    var SecretCryptographicRandom = std.Random.DefaultCsprng.init(SecretSeed);
    const SecretRandom = SecretCryptographicRandom.random();
    const NativeSecrets: NativeCipher.Secrets = .{
        .Arx0 = SecretRandom.int(u64),
        .Arx1 = SecretRandom.int(u64),
        .Pepper = @bitCast(SecretRandom.int(u32)),
        .Integrity = SecretRandom.int(u64),
    };
    ProgressLog.Sub("crypto secrets generated", .{});

    const PipelinePlan = ObfuscationPipeline.Plan{
        .Mapping = &Mapping,
        .Registry = &RenameRegistry,
        .Dead = &DeadCode,
        .BootstrapMethods = &Bootstrap,
        .StringBootstrapInternal = StringBootstrapInternal,
        .VirtualMachineBuilder = &VirtualMachineBuilder,
        .MethodBuilder = &MethodBuilder,
        .LoaderInternal = NativeReaderInternal,
        .InterpreterInternal = InterpreterInternal,
        .NativeSecrets = NativeSecrets,
        .VirtualizeBeforeStrings = !UseCustomLoader,
    };
    PrepareTask.Done("{d} infra names reserved", .{InfraIndex - NormalInternalNames.items.len});

    const CpuCount = std.Thread.getCpuCount() catch 1;
    const ThreadCount = std.math.clamp(CpuCount, 1, 64);
    const TransformTask = ProgressLog.Start("transform classes", .{});
    ProgressLog.Sub("{d} classes over {d} threads", .{ ClassEntries.items.len, ThreadCount });
    const Transformed = try ParallelTransformScheduler.ParallelTransformScheduler(Arena, ClassEntries.items, PipelinePlan, MasterSeed, ThreadCount);
    TransformTask.Done("{d} ok, {d} soft-fallback, {d} hard-fallback", .{ Transformed.Entries.len, Transformed.SoftFails, Transformed.HardFails });

    var TranspiledOwners = std.StringHashMap(void).init(Arena);
    for (MethodBuilder.Registrations.items) |Registration| try TranspiledOwners.put(Registration.Owner, {});

    var Tier1NewNames = std.StringHashMap(void).init(Arena);
    if (UseCustomLoader) {
        var Tier1Iterator = Tier1Classes.keyIterator();
        while (Tier1Iterator.next()) |Key| {
            const NewName = Mapping.RemapInternal(Key.*) orelse continue;
            if (TranspiledOwners.contains(NewName)) continue;
            try Tier1NewNames.put(NewName, {});
        }
    }

    const WantManifest = RuntimeConfig.Active.NativeProtection or RuntimeConfig.Active.Passes.StringEncryption;

    const AssembleTask = ProgressLog.Start("encrypt tier-1", .{});
    var EncryptedCount: usize = 0;
    var IntegrityCount: usize = 0;
    var OutputEntries: std.ArrayList(ArchiveEntry) = .empty;
    for (Transformed.Entries) |TransformedEntry| {
        const InternalName = TransformedEntry.Name[0 .. TransformedEntry.Name.len - ClassSuffix.len];
        if (UseCustomLoader and Tier1NewNames.contains(InternalName)) {
            const ClassBytes = try JavaArchiveReader.Inflate(Arena, TransformedEntry);
            const PackedBytes = try NativePack.Compress(Arena, ClassBytes);
            const ClassSeed = JavaStringHashCode(try ClassNameMappingRegistry.SlashToDot(Arena, InternalName));
            const EncryptedBytes = try EncryptedResourceEncoder.EncryptedResourceEncoder(Arena, PackedBytes, ClassSeed, NativeSecrets);
            const ResourceName = try std.fmt.allocPrint(Arena, "{s}{s}", .{ InternalName, ClassLoaderExtension });
            try OutputEntries.append(Arena, try JavaArchiveWriter.Pack(Arena, ResourceName, EncryptedBytes));
            EncryptedCount += 1;
        } else {
            try OutputEntries.append(Arena, TransformedEntry);
            if (WantManifest) {
                const PlainClassBytes = JavaArchiveReader.Inflate(Arena, TransformedEntry) catch continue;
                const ClassIntegrityHash: i64 = @bitCast(NativeCipher.IntegrityHash(PlainClassBytes, NativeSecrets));
                const ClassResourcePath = try std.fmt.allocPrint(Arena, "/{s}", .{TransformedEntry.Name});
                try MethodBuilder.AddIntegrity(ClassResourcePath, ClassIntegrityHash);
                IntegrityCount += 1;
            }
        }
    }
    AssembleTask.Done("{d} tier-1 encrypted, {d} integrity-bound", .{ EncryptedCount, IntegrityCount });
    const SynthTask = ProgressLog.Start("synthesize infra", .{});
    if (UseCustomLoader) {
        const CustomLoader = try CustomClassLoaderSynthesizer.CustomClassLoaderSynthesizer(Arena, ClassLoaderInternal, ClassLoaderExtension, NativeReaderInternal);
        const ClassLoaderFileName = try std.fmt.allocPrint(Arena, "{s}.class", .{ClassLoaderInternal});
        try AppendInfraClass(Arena, &OutputEntries, &MethodBuilder, ClassLoaderInternal, ClassLoaderFileName, HardenInfra(Arena, CustomLoader.Bytes, MasterSeed ^ 0x101), WantManifest, NativeSecrets);
        ProgressLog.Sub("custom class loader", .{});
    }
    if (RuntimeConfig.Active.Passes.StringEncryption) {
        const StringBootstrap = try StringBootstrapSynthesizer.StringBootstrapSynthesizer(Arena, StringBootstrapInternal, NativeReaderInternal);
        const StringBootstrapFileName = try std.fmt.allocPrint(Arena, "{s}.class", .{StringBootstrapInternal});
        try AppendInfraClass(Arena, &OutputEntries, &MethodBuilder, StringBootstrapInternal, StringBootstrapFileName, HardenInfra(Arena, StringBootstrap.Bytes, MasterSeed ^ 0x102), WantManifest, NativeSecrets);
        ProgressLog.Sub("string bootstrap", .{});
    }
    if (RuntimeConfig.Active.Passes.ReferenceObfuscation) {
        const BootstrapFileName = try std.fmt.allocPrint(Arena, "{s}.class", .{BootstrapMethodInternal});
        try AppendInfraClass(Arena, &OutputEntries, &MethodBuilder, BootstrapMethodInternal, BootstrapFileName, HardenInfra(Arena, Bootstrap.Bytes, MasterSeed ^ 0x104), WantManifest, NativeSecrets);
        ProgressLog.Sub("reference bootstrap", .{});
    }
    if (RuntimeConfig.Active.Passes.Virtualizer.Enabled and VirtualMachineBuilder.Count() > 0) {
        const VirtualMachineImage = try VirtualMachineBuilder.Finalize(Arena, NativeSecrets);
        const VirtualMachineImageHash: i64 = @bitCast(NativeCipher.IntegrityHash(VirtualMachineImage, NativeSecrets));
        const ResourceAbsolutePath = try std.fmt.allocPrint(Arena, "/{s}", .{VirtualMachineResourcePath});
        var EncryptedOpcodePermutation = VirtualMachineBuilder.OpcodePermutation;
        for (&EncryptedOpcodePermutation, 0..) |*PermutationByte, PermutationIndex| PermutationByte.* ^= NativeCipher.PermutationKeystreamByte(@intCast(PermutationIndex), NativeSecrets);
        const Interpreter = try InterpreterClassSynthesizer.InterpreterClassSynthesizer(Arena, InterpreterInternal, ResourceAbsolutePath, NativeReaderInternal, VirtualMachineBuilder.NonceBase ^ 0xFFFFFFFF, EncryptedOpcodePermutation, VirtualMachineImageHash);
        const InterpreterFileName = try std.fmt.allocPrint(Arena, "{s}.class", .{InterpreterInternal});
        try AppendInfraClass(Arena, &OutputEntries, &MethodBuilder, InterpreterInternal, InterpreterFileName, HardenInfra(Arena, Interpreter.Bytes, MasterSeed ^ 0x105), WantManifest, NativeSecrets);
        try OutputEntries.append(Arena, try JavaArchiveWriter.Pack(Arena, VirtualMachineResourcePath, VirtualMachineImage));
        ProgressLog.Sub("vm interpreter + image ({d} bytes cache.dat)", .{VirtualMachineImage.len});
    }
    SynthTask.Done("{d} virtualized methods, {d} native methods", .{ VirtualMachineBuilder.Count(), MethodBuilder.Registrations.items.len });

    if (WantManifest) {
        const CompileTask = ProgressLog.Start("compile native", .{});
        const Compiled = try NativeCompiler.NativeCompiler(IoInterface, Arena, try MethodBuilder.ZigSource(Arena), NativeSecrets, NativeReaderInternal, InterpreterInternal);
        const NativeBytes = Compiled.Container;
        const NativeHash: i64 = @bitCast(NativeCipher.IntegrityHash(NativeBytes, NativeSecrets));
        var DatWords: [11]u32 = undefined;
        for (&DatWords) |*Word| Word.* = RandomGenerator.int(u32);
        const EncodedBytes = try NativeCipher.ChaCha20PolyEncrypt(Arena, NativeBytes, DatWords);
        const NativeResourceName = try std.fmt.allocPrint(Arena, "{s}/{s}.dat", .{ LibraryPackage, try IdentifierGenerator.HexLicense(Arena, RandomGenerator) });
        try OutputEntries.append(Arena, try JavaArchiveWriter.Pack(Arena, NativeResourceName, EncodedBytes));
        const ResourceAbsolutePath = try std.fmt.allocPrint(Arena, "/{s}", .{NativeResourceName});
        const NativeReader = try NativeReaderSynthesizer.NativeReaderSynthesizer(Arena, NativeReaderInternal, ResourceAbsolutePath, NativeHash, DatWords, Compiled.LibraryHashes);
        const NativeReaderFileName = try std.fmt.allocPrint(Arena, "{s}.class", .{NativeReaderInternal});
        try OutputEntries.append(Arena, try MakeEntry(Arena, NativeReaderFileName, NativeReader.Bytes));
        CompileTask.Done("6 targets, {d} bytes container", .{NativeBytes.len});
    }

    const ResourceTask = ProgressLog.Start("copy resources", .{});
    var CopiedCount: usize = 0;
    var ManifestRewritten = false;
    if (ClassPathPrefix.len > 0) {
        for (OutputEntries.items) |*OutputEntry| {
            OutputEntry.Name = try std.fmt.allocPrint(Arena, "{s}{s}", .{ ClassPathPrefix, OutputEntry.Name });
        }
    }

    for (Entries) |Entry| {
        if (IsAppClass(Entry.Name, ClassPathPrefix)) continue;
        if (std.mem.eql(u8, Entry.Name, ManifestPath)) {
            const RawManifestBytes = try JavaArchiveReader.Inflate(Arena, Entry);
            const NewManifestBytes = try ManifestRewriter.ManifestRewriter(Arena, RawManifestBytes, Mapping);
            try OutputEntries.append(Arena, try MakeEntry(Arena, Entry.Name, NewManifestBytes));
            ManifestRewritten = true;
        } else {
            try OutputEntries.append(Arena, Entry);
            CopiedCount += 1;
        }
    }
    ResourceTask.Done("{d} resources copied, manifest {s}", .{ CopiedCount, if (ManifestRewritten) "rewritten" else "unchanged" });

    const WriteTask = ProgressLog.Start("write jar", .{});
    const ZipBytes = try JavaArchiveWriter.Write(Arena, OutputEntries.items);

    const OutputDirectory = std.fs.path.dirname(InputPath) orelse ".";
    const RandomName = try IdentifierGenerator.RandomLetters(Arena, RandomGenerator, 20);
    const OutputName = try std.fmt.allocPrint(Arena, "{s}.jar", .{RandomName});
    var DestinationHandle = try CurrentDirectory.openDir(IoInterface, OutputDirectory, .{});
    defer DestinationHandle.close(IoInterface);
    try DestinationHandle.writeFile(IoInterface, .{ .sub_path = OutputName, .data = ZipBytes });
    WriteTask.Done("{d} entries", .{OutputEntries.items.len});

    ProgressLog.Metrics();
    ProgressLog.Metric("application classes", ClassEntries.items.len);
    ProgressLog.Metric("dead members removed", DeadCode.Map.count());
    ProgressLog.Metric("virtualized methods", VirtualMachineBuilder.Count());
    ProgressLog.Metric("aot-native methods", MethodBuilder.Registrations.items.len);
    ProgressLog.Metric("tier-1 encrypted", EncryptedCount);
    ProgressLog.Metric("integrity-bound classes", IntegrityCount);
    ProgressLog.Metric("output entries", OutputEntries.items.len);

    ProgressLog.Wrote(OutputName, OutputDirectory, ZipBytes.len);
}

fn DetectClassPathPrefix(Entries: []const ArchiveEntry) []const u8 {
    for (Entries) |Entry| {
        if (std.mem.startsWith(u8, Entry.Name, "BOOT-INF/classes/") and std.mem.endsWith(u8, Entry.Name, ClassSuffix)) return "BOOT-INF/classes/";
    }
    return "";
}

fn IsAppClass(Name: []const u8, ClassPathPrefix: []const u8) bool {
    if (!std.mem.endsWith(u8, Name, ClassSuffix)) return false;
    if (!std.mem.startsWith(u8, Name, ClassPathPrefix)) return false;
    const Stripped = Name[ClassPathPrefix.len..];
    if (std.mem.endsWith(u8, Stripped, "module-info.class")) return false;
    return true;
}

fn InfraLeaf(AllocatorHandle: std.mem.Allocator, Package: []const u8, IndexPointer: *usize) ![]const u8 {
    const Leaf = try IdentifierGenerator.AbcName(AllocatorHandle, IndexPointer.*);
    IndexPointer.* += 1;
    return std.fmt.allocPrint(AllocatorHandle, "{s}/{s}", .{ Package, Leaf });
}

fn EndsWithIgnoreCase(Str: []const u8, Suffix: []const u8) bool {
    if (Str.len < Suffix.len) return false;
    return std.ascii.eqlIgnoreCase(Str[Str.len - Suffix.len ..], Suffix);
}

fn JavaStringHashCode(Str: []const u8) i32 {
    var HashValue: i32 = 0;
    for (Str) |Char| HashValue = HashValue *% 31 +% @as(i32, Char);
    return HashValue;
}

fn Entropy(AllocatorHandle: std.mem.Allocator, JarBytes: []const u8) u64 {
    var StackSlot: usize = 0xcafebabe;
    const PointerOne: u64 = @intFromPtr(&StackSlot);
    const HeapSlot = AllocatorHandle.create(u64) catch return PointerOne;
    const PointerTwo: u64 = @intFromPtr(HeapSlot);
    var Accumulator: u64 = PointerOne *% 0x9e3779b97f4a7c15;
    Accumulator ^= PointerTwo;
    var Hasher = std.hash.Wyhash.init(Accumulator);
    Hasher.update(JarBytes[0..@min(JarBytes.len, 4096)]);
    return Hasher.final();
}

fn HardenInfra(AllocatorHandle: std.mem.Allocator, Bytes: []const u8, Seed: u64) []const u8 {
    var ParsedClass = ClassFileModel.Parse(AllocatorHandle, Bytes) catch return Bytes;
    var PseudoRandom = std.Random.DefaultPrng.init(Seed);
    _ = ControlFlowShuffler.ShuffleControlFlow(AllocatorHandle, &ParsedClass, &PseudoRandom, false) catch return Bytes;
    return ClassFileModel.Serialize(AllocatorHandle, &ParsedClass) catch return Bytes;
}

fn MakeEntry(AllocatorHandle: std.mem.Allocator, Name: []const u8, Data: []const u8) !ArchiveEntry {
    return JavaArchiveWriter.Pack(AllocatorHandle, Name, Data);
}

fn AppendInfraClass(
    AllocatorHandle: std.mem.Allocator,
    OutputEntries: *std.ArrayList(ArchiveEntry),
    MethodBuilder: *NativeMethodBuilder.Builder,
    Internal: []const u8,
    FileName: []const u8,
    HardenedBytes: []const u8,
    WantManifest: bool,
    NativeSecrets: NativeCipher.Secrets,
) !void {
    try OutputEntries.append(AllocatorHandle, try MakeEntry(AllocatorHandle, FileName, HardenedBytes));
    if (WantManifest) {
        const Hash: i64 = @bitCast(NativeCipher.IntegrityHash(HardenedBytes, NativeSecrets));
        const ResourcePath = try std.fmt.allocPrint(AllocatorHandle, "/{s}.class", .{Internal});
        try MethodBuilder.AddIntegrity(ResourcePath, Hash);
    }
}
