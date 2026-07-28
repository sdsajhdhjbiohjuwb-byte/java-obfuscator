const std = @import("std");
const InstructionSetArchitecture = @import("InstructionSetArchitecture.zig");
const NativeCipher = @import("../Native/NativeCipher.zig");

const Record = struct {
    NumberOfLocals: u16,
    MaxStack: u16,
    Seed: u32,
    Program: []u8,
};

pub const Builder = struct {
    Lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    Allocator: std.mem.Allocator,
    Records: std.ArrayList(Record) = .empty,
    OpcodePermutation: [64]u8 = InstructionSetArchitecture.IdentityPermutation(),
    NonceBase: u32 = 0,

    pub fn Initialize(AllocatorHandle: std.mem.Allocator) Builder {
        return .{ .Allocator = AllocatorHandle };
    }

    pub fn ShuffleOpcodes(Self: *Builder, RandomSource: std.Random) void {
        Self.OpcodePermutation = InstructionSetArchitecture.ShufflePermutation(RandomSource);
    }

    fn Acquire(Self: *Builder) void {
        while (Self.Lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn Release(Self: *Builder) void {
        Self.Lock.store(false, .release);
    }

    pub fn Add(Self: *Builder, LocalVariableCount: u16, MaxStackDepth: u16, ProgramBytes: []const u8) !u32 {
        Self.Acquire();
        defer Self.Release();
        const RecordIdentifier: u32 = @intCast(Self.Records.items.len);
        try Self.Records.append(Self.Allocator, .{
            .NumberOfLocals = LocalVariableCount,
            .MaxStack = MaxStackDepth,
            .Seed = RecordIdentifier ^ Self.NonceBase,
            .Program = try Self.Allocator.dupe(u8, ProgramBytes),
        });
        return RecordIdentifier;
    }

    pub fn ApplyRecordPermutation(Self: *Builder, RecordIdentifier: u32, OpcodeOffsets: []const u32) void {
        Self.Acquire();
        defer Self.Release();
        const RecordSeed = RecordIdentifier ^ Self.NonceBase;
        const Permutation = InstructionSetArchitecture.PermutationFromSeed(RecordSeed);
        const Program = Self.Records.items[RecordIdentifier].Program;
        for (OpcodeOffsets) |Offset| {
            if (Offset < Program.len) Program[Offset] = Permutation[Program[Offset] & 63];
        }
    }

    pub fn ApplyLocalPermutation(Self: *Builder, RecordIdentifier: u32, LocalOperandOffsets: []const u32) void {
        Self.Acquire();
        defer Self.Release();
        const RecordSeed = RecordIdentifier ^ Self.NonceBase;
        const Modulus: u32 = Self.Records.items[RecordIdentifier].NumberOfLocals;
        const Program = Self.Records.items[RecordIdentifier].Program;
        for (LocalOperandOffsets) |Offset| {
            if (Offset < Program.len) {
                Program[Offset] = @intCast(NativeCipher.RegisterPermute(RecordSeed, Modulus, Program[Offset]));
            }
        }
    }

    pub fn ApplyStackPermutation(Self: *Builder, RecordIdentifier: u32, StackOperandOffsets: []const u32) void {
        Self.Acquire();
        defer Self.Release();
        const RecordSeed = (RecordIdentifier ^ Self.NonceBase) ^ 0x5A5A5A5A;
        const Modulus: u32 = @as(u32, Self.Records.items[RecordIdentifier].MaxStack) + 8;
        const Program = Self.Records.items[RecordIdentifier].Program;
        for (StackOperandOffsets) |Offset| {
            if (Offset + 1 < Program.len) {
                const Logical: u32 = (@as(u32, Program[Offset]) << 8) | @as(u32, Program[Offset + 1]);
                const Physical: u32 = NativeCipher.RegisterPermute(RecordSeed, Modulus, Logical);
                Program[Offset] = @intCast((Physical >> 8) & 0xff);
                Program[Offset + 1] = @intCast(Physical & 0xff);
            }
        }
    }

    pub fn Count(Self: *Builder) usize {
        return Self.Records.items.len;
    }

    pub fn Finalize(Self: *Builder, OutputAllocator: std.mem.Allocator, SecretKeys: InstructionSetArchitecture.Secrets) ![]u8 {
        const RecordCount = Self.Records.items.len;
        const HeaderSize: u32 = @intCast(InstructionSetArchitecture.HeaderPrefix + RecordCount * InstructionSetArchitecture.RecordSize);
        var TotalSize: u32 = HeaderSize;
        const Offsets = try OutputAllocator.alloc(u32, RecordCount);
        for (Self.Records.items, 0..) |CurrentRecord, Index| {
            Offsets[Index] = TotalSize;
            TotalSize += @intCast(CurrentRecord.Program.len);
        }
        const ImageBuffer = try OutputAllocator.alloc(u8, TotalSize);
        @memset(ImageBuffer, 0);
        std.mem.writeInt(u32, ImageBuffer[0..4], @intCast(RecordCount), .big);
        for (Self.Records.items, 0..) |CurrentRecord, Index| {
            const RecordOffset = InstructionSetArchitecture.HeaderPrefix + Index * InstructionSetArchitecture.RecordSize;
            std.mem.writeInt(u32, ImageBuffer[RecordOffset..][0..4], Offsets[Index], .big);
            std.mem.writeInt(u32, ImageBuffer[RecordOffset + 4 ..][0..4], @intCast(CurrentRecord.Program.len), .big);
            std.mem.writeInt(u32, ImageBuffer[RecordOffset + 8 ..][0..4], CurrentRecord.Seed, .big);
            std.mem.writeInt(u16, ImageBuffer[RecordOffset + 12 ..][0..2], CurrentRecord.NumberOfLocals, .big);
            std.mem.writeInt(u16, ImageBuffer[RecordOffset + 14 ..][0..2], CurrentRecord.MaxStack, .big);
            for (CurrentRecord.Program, 0..) |ProgramByte, InnerIndex| {
                ImageBuffer[Offsets[Index] + InnerIndex] = ProgramByte ^ InstructionSetArchitecture.KeystreamByte(@intCast(InnerIndex), CurrentRecord.Seed, SecretKeys);
            }
        }
        const BinSeed: u32 = Self.NonceBase ^ 0xFFFFFFFF;
        for (ImageBuffer, 0..) |*Byte, GlobalIndex| {
            Byte.* ^= InstructionSetArchitecture.KeystreamByte(@intCast(GlobalIndex), BinSeed, SecretKeys);
        }
        return ImageBuffer;
    }
};
