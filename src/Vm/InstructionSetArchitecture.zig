const std = @import("std");
const NativeCipher = @import("../Native/NativeCipher.zig");
const RandomShuffle = @import("../RandomShuffle.zig");

pub const VirtualPush: u8 = 1;
pub const VirtualLoad: u8 = 2;
pub const VirtualStore: u8 = 3;
pub const VirtualAdd: u8 = 4;
pub const VirtualSubtract: u8 = 5;
pub const VirtualMultiply: u8 = 6;
pub const VirtualNegate: u8 = 7;
pub const VirtualAnd: u8 = 8;
pub const VirtualOr: u8 = 9;
pub const VirtualXor: u8 = 10;
pub const VirtualShiftLeft: u8 = 11;
pub const VirtualShiftRight: u8 = 12;
pub const VirtualUnsignedShiftRight: u8 = 13;
pub const VirtualDivide: u8 = 14;
pub const VirtualRemainder: u8 = 15;
pub const VirtualGoto: u8 = 16;
pub const VirtualIf: u8 = 17;
pub const VirtualIfCompare: u8 = 18;
pub const VirtualReturn: u8 = 19;
pub const VirtualPop: u8 = 20;
pub const VirtualDuplicate: u8 = 21;
pub const VirtualSwap: u8 = 22;
pub const VirtualIncrement: u8 = 23;
pub const VirtualCall: u8 = 24;
pub const VirtualGetStatic: u8 = 25;
pub const VirtualPutStatic: u8 = 26;
pub const VirtualPushLong: u8 = 27;
pub const VirtualConvert: u8 = 28;
pub const VirtualCompareWide: u8 = 29;
pub const VirtualPushFloat: u8 = 30;
pub const VirtualPushDouble: u8 = 31;
pub const VirtualPushString: u8 = 32;
pub const VirtualAConstNull: u8 = 33;
pub const VirtualIfNull: u8 = 34;
pub const VirtualIfAcmp: u8 = 35;
pub const VirtualNew: u8 = 36;
pub const VirtualInit: u8 = 37;
pub const VirtualGetField: u8 = 38;
pub const VirtualPutField: u8 = 39;
pub const VirtualCheckCast: u8 = 40;
pub const VirtualInstanceOf: u8 = 41;
pub const VirtualNewArray: u8 = 42;
pub const VirtualANewArray: u8 = 43;
pub const VirtualArrayLength: u8 = 44;
pub const VirtualArrayLoad: u8 = 45;
pub const VirtualArrayStore: u8 = 46;
pub const VirtualTableSwitch: u8 = 48;
pub const VirtualLookupSwitch: u8 = 49;
pub const VirtualAThrow: u8 = 50;
pub const VirtualMultiANewArray: u8 = 51;
pub const VirtualMonitorEnter: u8 = 52;
pub const VirtualMonitorExit: u8 = 53;
pub const VirtualLoadClass: u8 = 54;
pub const VirtualMove: u8 = 55;

pub const ConditionEqual: u8 = 0;
pub const ConditionNotEqual: u8 = 1;
pub const ConditionLessThan: u8 = 2;
pub const ConditionGreaterEqual: u8 = 3;
pub const ConditionGreaterThan: u8 = 4;
pub const ConditionLessEqual: u8 = 5;

pub const RecordSize: usize = 16;
pub const HeaderPrefix: usize = 4;

pub const OperationMinimum: u8 = 1;
pub const OperationMaximum: u8 = 55;
const PermutationLength: usize = 64;

pub fn IdentityPermutation() [PermutationLength]u8 {
    var Permutation: [PermutationLength]u8 = undefined;
    for (&Permutation, 0..) |*Entry, Index| Entry.* = @intCast(Index);
    return Permutation;
}

pub fn ShufflePermutation(RandomSource: std.Random) [PermutationLength]u8 {
    var Permutation = IdentityPermutation();
    RandomShuffle.Shuffle(u8, Permutation[@as(usize, OperationMinimum) .. @as(usize, OperationMaximum) + 1], RandomSource);
    return Permutation;
}

pub const PermutationFromSeed = NativeCipher.PermutationFromSeed;

pub const Secrets = NativeCipher.Secrets;

pub fn KeystreamByte(Offset: u32, Seed: u32, SecretsHandle: NativeCipher.Secrets) u8 {
    return NativeCipher.VirtualMachineKeystreamByte(Offset, Seed, SecretsHandle);
}

test "ks determinism" {
    try std.testing.expectEqual(KeystreamByte(0, 0, NativeCipher.Baked), KeystreamByte(0, 0, NativeCipher.Baked));
    try std.testing.expect(KeystreamByte(0, 123, NativeCipher.Baked) != KeystreamByte(1, 123, NativeCipher.Baked) or KeystreamByte(2, 123, NativeCipher.Baked) != KeystreamByte(3, 123, NativeCipher.Baked));
}
