const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const DebugAttributeStripper = @import("../Passes/DebugAttributeStripper.zig");
const ConstantPoolPruner = @import("../Passes/ConstantPoolPruner.zig");
const NativeCipher = @import("../Native/NativeCipher.zig");
const MemberRenameRegistry = @import("../Passes/MemberRenameRegistry.zig");
const RenameKeepSetAnalyzer = @import("../Passes/RenameKeepSetAnalyzer.zig");
const DeadCodeEliminator = @import("../Passes/DeadCodeEliminator.zig");
const DeindyConcatPass = @import("../Passes/DeindyConcatPass.zig");
const StringEncryptionPass = @import("../Passes/StringEncryptionPass.zig");
const ReferenceObfuscationPass = @import("../Passes/ReferenceObfuscationPass.zig");
const ReferenceBootstrapSynthesizer = @import("../Passes/ReferenceBootstrapSynthesizer.zig");
const MethodSplitPass = @import("../Passes/MethodSplitPass.zig");
const ControlFlowFlattener = @import("../Passes/ControlFlowFlattener.zig");
const ControlFlowShuffler = @import("../Passes/ControlFlowShuffler.zig");
const MemberShufflerPass = @import("../Passes/MemberShufflerPass.zig");
const NumberEncryptionPass = @import("../Passes/NumberEncryptionPass.zig");
const LogicScramblerPass = @import("../Passes/LogicScramblerPass.zig");
const MethodMergerPass = @import("../Passes/MethodMergerPass.zig");
const Virtualizer = @import("../Passes/Virtualizer.zig");
const NativeMethodPass = @import("../Passes/NativeMethodPass.zig");
const NativeMethodBuilder = @import("../Native/NativeMethodBuilder.zig");
const VirtualMachineImageBuilder = @import("../Vm/VirtualMachineImageBuilder.zig");
const ConstantPoolTransformer = @import("../Classfile/ConstantPoolTransformer.zig");
const RuntimeConfig = @import("RuntimeConfig.zig");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

pub const Plan = struct {
    Mapping: *const Mapping,
    Registry: *const MemberRenameRegistry.Registry,
    Dead: *const DeadCodeEliminator.DeadSet,
    BootstrapMethods: *const ReferenceBootstrapSynthesizer.Bootstrap,
    StringBootstrapInternal: []const u8,
    VirtualMachineBuilder: *VirtualMachineImageBuilder.Builder,
    MethodBuilder: *NativeMethodBuilder.Builder,
    LoaderInternal: []const u8,
    InterpreterInternal: []const u8,
    NativeSecrets: NativeCipher.Secrets,
    VirtualizeBeforeStrings: bool,
};

pub fn ObfuscationPipeline(
    AllocatorHandle: std.mem.Allocator,
    RawClassBytes: []const u8,
    ObfuscationPlan: Plan,
    PseudoRandomGenerator: *std.Random.DefaultPrng,
) ![]u8 {
    var ClassFile = try ClassFileModel.Parse(AllocatorHandle, RawClassBytes);
    const Passes = RuntimeConfig.Active.Passes;

    if (Passes.DeadCode) _ = try DeadCodeEliminator.Apply(AllocatorHandle, &ClassFile, ObfuscationPlan.Dead);
    if (Passes.DebugStrip) try DebugAttributeStripper.DebugAttributeStripper(AllocatorHandle, &ClassFile);
    if (Passes.Rename) try MemberRenameRegistry.Apply(AllocatorHandle, &ClassFile, ObfuscationPlan.Registry);
    if (Passes.MethodMerger.Enabled) _ = try MethodMergerPass.MethodMergerPass(AllocatorHandle, &ClassFile);
    if (Passes.PromoteAccess) RenameKeepSetAnalyzer.PromoteAccess(&ClassFile);
    if (Passes.MethodSplit) _ = try MethodSplitPass.MethodSplitPass(AllocatorHandle, &ClassFile, PseudoRandomGenerator);
    if (Passes.NumberEncryption.Enabled) _ = try NumberEncryptionPass.NumberEncryptionPass(AllocatorHandle, &ClassFile, PseudoRandomGenerator);
    if (Passes.LogicScrambler.Enabled) _ = try LogicScramblerPass.LogicScramblerPass(AllocatorHandle, &ClassFile, PseudoRandomGenerator);
    if (Passes.DeindyConcat) _ = try DeindyConcatPass.DeindyConcatPass(AllocatorHandle, &ClassFile);
    if (Passes.StringEncryption and !ObfuscationPlan.VirtualizeBeforeStrings) {
        _ = try StringEncryptionPass.StringEncryptionPass(AllocatorHandle, &ClassFile, ObfuscationPlan.StringBootstrapInternal, ObfuscationPlan.Mapping.*, PseudoRandomGenerator, ObfuscationPlan.NativeSecrets);
    }
    if (Passes.NativeMethod.Enabled) {
        _ = try NativeMethodPass.NativeMethodPass(AllocatorHandle, &ClassFile, ObfuscationPlan.MethodBuilder, ObfuscationPlan.Mapping, ObfuscationPlan.LoaderInternal, Passes.NativeMethod.PerClass);
    }
    if (Passes.Virtualizer.Enabled) {
        _ = try Virtualizer.Virtualizer(AllocatorHandle, &ClassFile, ObfuscationPlan.VirtualMachineBuilder, ObfuscationPlan.LoaderInternal, Passes.Virtualizer.PerClass, ObfuscationPlan.Mapping, PseudoRandomGenerator.random());
    }
    if (Passes.StringEncryption and ObfuscationPlan.VirtualizeBeforeStrings) {
        _ = try StringEncryptionPass.StringEncryptionPass(AllocatorHandle, &ClassFile, ObfuscationPlan.StringBootstrapInternal, ObfuscationPlan.Mapping.*, PseudoRandomGenerator, ObfuscationPlan.NativeSecrets);
    }
    if (Passes.ReferenceObfuscation) _ = try ReferenceObfuscationPass.ReferenceObfuscationPass(AllocatorHandle, &ClassFile, ObfuscationPlan.Mapping, ObfuscationPlan.BootstrapMethods, ObfuscationPlan.InterpreterInternal, ObfuscationPlan.LoaderInternal, ObfuscationPlan.NativeSecrets, PseudoRandomGenerator);
    if (Passes.ControlFlowFlattener) _ = try ControlFlowFlattener.ControlFlowFlattener(AllocatorHandle, &ClassFile, PseudoRandomGenerator);
    if (Passes.ControlFlowShuffler) _ = try ControlFlowShuffler.ControlFlowShuffler(AllocatorHandle, &ClassFile, PseudoRandomGenerator);
    if (Passes.MemberShuffler.Enabled) MemberShufflerPass.MemberShufflerPass(&ClassFile, PseudoRandomGenerator);

    try ConstantPoolTransformer.ApplyClassRename(AllocatorHandle, &ClassFile.ConstantPool, ObfuscationPlan.Mapping.*);
    if (Passes.ConstantPoolPruner) try ConstantPoolPruner.ConstantPoolPruner(AllocatorHandle, &ClassFile);
    return ClassFileModel.Serialize(AllocatorHandle, &ClassFile);
}
