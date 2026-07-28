const std = @import("std");

pub const Secrets = struct {
    Arx0: u64,
    Arx1: u64,
    Pepper: i32,
    Integrity: u64,
};

pub const BakedArx0: u64 = 0x243F6A8885A308D3;
pub const BakedArx1: u64 = 0x13198A2E03707344;
pub const BakedPepper: i32 = 0;
pub const BakedInteg: u64 = 0xCBF29CE484222325;
pub const Baked = Secrets{ .Arx0 = BakedArx0, .Arx1 = BakedArx1, .Pepper = BakedPepper, .Integrity = BakedInteg };

pub fn PermutationFromSeed(Seed: u32) [64]u8 {
    var Permutation: [64]u8 = undefined;
    var Fill: usize = 0;
    while (Fill < 64) : (Fill += 1) Permutation[Fill] = @intCast(Fill);
    var State: u32 = Seed ^ 0x9E3779B9;
    var Index: usize = 63;
    while (Index > 1) : (Index -= 1) {
        State = State *% 0x6C078965 +% 0x85EBCA6B;
        var Mixed: u32 = State;
        Mixed ^= Mixed >> 16;
        Mixed *%= 0x7FEB352D;
        Mixed ^= Mixed >> 15;
        const InnerIndex: usize = 1 + @as(usize, @intCast(Mixed % @as(u32, @intCast(Index))));
        const Temporary = Permutation[Index];
        Permutation[Index] = Permutation[InnerIndex];
        Permutation[InnerIndex] = Temporary;
    }
    return Permutation;
}

pub fn InvertPermutation(Permutation: [64]u8) [64]u8 {
    var Inverse: [64]u8 = undefined;
    var Index: usize = 0;
    while (Index < 64) : (Index += 1) Inverse[Permutation[Index]] = @intCast(Index);
    return Inverse;
}

pub fn RegisterPermute(Seed: u32, Modulus: u32, Index: u32) u32 {
    if (Modulus <= 1 or Modulus > 256) return Index;
    var Permutation: [256]u16 = undefined;
    var Fill: u32 = 0;
    while (Fill < Modulus) : (Fill += 1) Permutation[Fill] = @intCast(Fill);
    var State: u32 = Seed ^ 0x9E3779B9 ^ (Modulus *% 0x85EBCA6B);
    var Position: u32 = Modulus - 1;
    while (Position >= 1) : (Position -= 1) {
        State = State *% 0x6C078965 +% 0x1B54A32D;
        var Mixed: u32 = State;
        Mixed ^= Mixed >> 15;
        Mixed *%= 0x2C1B3C6D;
        Mixed ^= Mixed >> 13;
        const SwapIndex: u32 = Mixed % (Position + 1);
        const Temporary = Permutation[Position];
        Permutation[Position] = Permutation[SwapIndex];
        Permutation[SwapIndex] = Temporary;
    }
    return Permutation[Index % Modulus];
}

fn KeyWords(SecretsHandle: Secrets) [8]u32 {
    const Pepper: u32 = @bitCast(SecretsHandle.Pepper);
    return .{
        @truncate(SecretsHandle.Arx0),
        @truncate(SecretsHandle.Arx0 >> 32),
        @truncate(SecretsHandle.Arx1),
        @truncate(SecretsHandle.Arx1 >> 32),
        @truncate(SecretsHandle.Integrity),
        @truncate(SecretsHandle.Integrity >> 32),
        Pepper,
        @as(u32, @truncate(SecretsHandle.Arx0 ^ SecretsHandle.Arx1 ^ SecretsHandle.Integrity)) ^ 0x9E3779B9 ^ Pepper,
    };
}

fn KeyWordsDomain(SecretsHandle: Secrets, Domain: u32) [8]u32 {
    var Words = KeyWords(SecretsHandle);
    var Mix: u32 = Domain ^ 0x9E3779B9;
    for (&Words) |*Word| {
        Mix ^= Mix >> 15;
        Mix *%= 0x2C1B3C6D;
        Mix ^= Mix >> 13;
        Mix *%= 0x297A2D39;
        Word.* ^= Mix;
    }
    return Words;
}

const DomainString: u32 = 0x53545247;
const DomainVirtualMachine: u32 = 0x564D494D;

fn ChaChaBlock(Key: [8]u32, Counter: u32, Nonce: [3]u32) [64]u8 {
    var KeyBytes: [32]u8 = undefined;
    for (0..8) |WordIndex| std.mem.writeInt(u32, KeyBytes[WordIndex * 4 ..][0..4], Key[WordIndex], .little);
    var NonceBytes: [12]u8 = undefined;
    for (0..3) |WordIndex| std.mem.writeInt(u32, NonceBytes[WordIndex * 4 ..][0..4], Nonce[WordIndex], .little);
    var Output: [64]u8 = undefined;
    std.crypto.stream.chacha.ChaCha20IETF.stream(&Output, Counter, KeyBytes, NonceBytes);
    return Output;
}

pub fn ChaCha20PolyEncrypt(Allocator: std.mem.Allocator, Plaintext: []const u8, KeyNonceWords: [11]u32) ![]u8 {
    const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
    var Key: [32]u8 = undefined;
    for (0..8) |WordIndex| std.mem.writeInt(u32, Key[WordIndex * 4 ..][0..4], KeyNonceWords[WordIndex], .little);
    var Nonce: [12]u8 = undefined;
    for (0..3) |WordIndex| std.mem.writeInt(u32, Nonce[WordIndex * 4 ..][0..4], KeyNonceWords[8 + WordIndex], .little);
    const Output = try Allocator.alloc(u8, Plaintext.len + Aead.tag_length);
    var Tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(Output[0..Plaintext.len], &Tag, Plaintext, "", Nonce, Key);
    @memcpy(Output[Plaintext.len..], &Tag);
    return Output;
}

pub fn KeystreamByte(Index: u32, Salt: i32, Caller: i32, Nonce: i32, SecretsHandle: Secrets) u8 {
    const Key = KeyWordsDomain(SecretsHandle, DomainString);
    const NonceWords = [3]u32{ @bitCast(Salt), @bitCast(Caller), @bitCast(Nonce) };
    const Block = ChaChaBlock(Key, Index >> 6, NonceWords);
    return Block[Index & 63];
}

pub fn VirtualMachineKeystreamByte(Offset: u32, Seed: u32, SecretsHandle: Secrets) u8 {
    const Key = KeyWordsDomain(SecretsHandle, DomainVirtualMachine);
    const Salt: u32 = @truncate(SecretsHandle.Integrity ^ (SecretsHandle.Arx0 >> 19) ^ (SecretsHandle.Arx1 >> 7));
    const NonceWords = [3]u32{ Seed, (Seed *% 0x9E3779B9) ^ Salt, ((Seed ^ Salt) *% 0x85EBCA6B) +% 0x7F4A7C15 };
    const Block = ChaChaBlock(Key, Offset >> 6, NonceWords);
    return Block[Offset & 63];
}

const DomainPermutation: u32 = 0x5045524D;

pub fn PermutationKeystreamByte(Offset: u32, SecretsHandle: Secrets) u8 {
    const Key = KeyWordsDomain(SecretsHandle, DomainPermutation);
    const Salt: u32 = @truncate(SecretsHandle.Arx1 ^ (SecretsHandle.Integrity >> 29) ^ (SecretsHandle.Arx0 >> 11));
    const NonceWords = [3]u32{ Salt, Salt ^ 0x9E3779B9, Salt *% 0x85EBCA6B };
    const Block = ChaChaBlock(Key, Offset >> 6, NonceWords);
    return Block[Offset & 63];
}

pub fn LongByteBigEndian(Longs: []const i64, GlobalIndex: usize) u8 {
    const Word: u64 = @bitCast(Longs[GlobalIndex >> 3]);
    const WithinIndex: u6 = @intCast(7 - (GlobalIndex & 7));
    return @truncate(Word >> (@as(u6, WithinIndex) * 8));
}

fn MessageAuthenticationCodeKey(SecretsHandle: Secrets) [16]u8 {
    const Pepper: u64 = @as(u32, @bitCast(SecretsHandle.Pepper));
    var Key: [16]u8 = undefined;
    std.mem.writeInt(u64, Key[0..8], SecretsHandle.Arx0 ^ SecretsHandle.Integrity, .little);
    std.mem.writeInt(u64, Key[8..16], SecretsHandle.Arx1 ^ (SecretsHandle.Integrity *% 0x9E3779B97F4A7C15) ^ Pepper, .little);
    return Key;
}

pub fn IntegrityHash(Bytes: []const u8, SecretsHandle: Secrets) u64 {
    const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);
    const Key = MessageAuthenticationCodeKey(SecretsHandle);
    var Output: [8]u8 = undefined;
    SipHash.create(&Output, Bytes, &Key);
    return std.mem.readInt(u64, &Output, .little);
}

test "chacha keystream determinism and agreement" {
    const SecretsHandle = Baked;
    const FirstByte = KeystreamByte(5, 111, 222, 333, SecretsHandle);
    const SecondByte = KeystreamByte(5, 111, 222, 333, SecretsHandle);
    try std.testing.expectEqual(FirstByte, SecondByte);
    try std.testing.expect(KeystreamByte(6, 111, 222, 333, SecretsHandle) != FirstByte or KeystreamByte(70, 111, 222, 333, SecretsHandle) != FirstByte);
    const FirstVmByte = VirtualMachineKeystreamByte(0, 42, SecretsHandle);
    const SecondVmByte = VirtualMachineKeystreamByte(0, 42, SecretsHandle);
    try std.testing.expectEqual(FirstVmByte, SecondVmByte);
    var Differ = false;
    var Probe: u32 = 0;
    while (Probe < 48) : (Probe += 1) {
        if (KeystreamByte(Probe, 42, 0, 0, SecretsHandle) != VirtualMachineKeystreamByte(Probe, 42, SecretsHandle)) Differ = true;
    }
    try std.testing.expect(Differ);
}

test "register permutation is a bijection" {
    const Seeds = [_]u32{ 0, 1, 7, 42, 65535, 0x9E3779B9, 0xDEADBEEF, 2654435761 };
    for (Seeds) |Seed| {
        var Modulus: u32 = 1;
        while (Modulus <= 256) : (Modulus += 1) {
            var Seen = std.mem.zeroes([256]bool);
            var Index: u32 = 0;
            while (Index < Modulus) : (Index += 1) {
                const Mapped = RegisterPermute(Seed, Modulus, Index);
                try std.testing.expect(Mapped < Modulus);
                try std.testing.expect(!Seen[Mapped]);
                Seen[Mapped] = true;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 5), RegisterPermute(123, 300, 5));
    try std.testing.expectEqual(@as(u32, 3), RegisterPermute(999, 1, 3));
}
