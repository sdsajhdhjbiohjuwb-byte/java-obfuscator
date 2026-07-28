const std = @import("std");
const AccessFlags = @import("../Classfile/AccessFlags.zig");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const RenameKeepSetAnalyzer = @import("RenameKeepSetAnalyzer.zig");
const RuntimeConfig = @import("../Pipeline/RuntimeConfig.zig");
const RandomShuffle = @import("../RandomShuffle.zig");

const MaxKeptLongArrayFields = 32;

fn IsStaticLongArrayField(ClassFile: *const ClassFileModel.ClassFile, Member: ClassFileModel.MemberInfo) bool {
    return (Member.AccessFlags & AccessFlags.AccessStatic) != 0 and std.mem.eql(u8, ClassFile.ConstantPool.Utf8Text(Member.DescriptorIndex), "[J");
}

fn ShuffleFields(ClassFile: *ClassFileModel.ClassFile, RandomGenerator: *std.Random.DefaultPrng) void {
    var KeptLongArrayBuffer: [MaxKeptLongArrayFields]ClassFileModel.MemberInfo = undefined;
    var KeptCount: usize = 0;
    for (ClassFile.Fields.items) |Member| {
        if (IsStaticLongArrayField(ClassFile, Member)) {
            if (KeptCount >= MaxKeptLongArrayFields) return;
            KeptLongArrayBuffer[KeptCount] = Member;
            KeptCount += 1;
        }
    }
    RandomShuffle.Shuffle(ClassFileModel.MemberInfo, ClassFile.Fields.items, RandomGenerator.random());
    var Index: usize = 0;
    for (ClassFile.Fields.items) |*Member| {
        if (IsStaticLongArrayField(ClassFile, Member.*)) {
            Member.* = KeptLongArrayBuffer[Index];
            Index += 1;
        }
    }
}

pub fn MemberShufflerPass(ClassFile: *ClassFileModel.ClassFile, RandomGenerator: *std.Random.DefaultPrng) void {
    const IsEnum = RenameKeepSetAnalyzer.IsEnumClass(ClassFile);
    RandomShuffle.Shuffle(ClassFileModel.MemberInfo, ClassFile.Methods.items, RandomGenerator.random());
    if (!IsEnum) ShuffleFields(ClassFile, RandomGenerator);
    if (RuntimeConfig.Active.Passes.MemberShuffler.ShuffleInterfaces) RandomShuffle.Shuffle(u16, ClassFile.Interfaces.items, RandomGenerator.random());
}
