pub const MethodMergerConfig = struct {
    Enabled: bool = true,
    MinGroup: usize = 2,
    MaxGroup: usize = 24,
    MaxBody: usize = 300,
    MaxMerged: usize = 3000,
};

pub const NumberEncryptionConfig = struct {
    Enabled: bool = true,
    MaxDepth: u8 = 3,
    EncryptSwitchKeys: bool = true,
    MaxPerMethod: usize = 96,
    MaxInstructionsGuard: usize = 6000,
};

pub const LogicScramblerConfig = struct {
    Enabled: bool = true,
    SyntheticFlags: bool = true,
    MbaProbability: u8 = 85,
    MaxOps: usize = 160,
    MaxDepth: u8 = 2,
    MaxInstructionsGuard: usize = 6000,
};

pub const NativeMethodConfig = struct {
    Enabled: bool = true,
    PerClass: usize = 256,
};

pub const VirtualizerConfig = struct {
    Enabled: bool = true,
    PerClass: usize = 256,
    MbaEnabled: bool = true,
    MbaMaxDepth: u8 = 3,
    MbaSplitPercent: u8 = 88,
};

pub const MemberShufflerConfig = struct {
    Enabled: bool = true,
    ShuffleInterfaces: bool = true,
};

pub const PassConfig = struct {
    DeadCode: bool = true,
    DebugStrip: bool = true,
    Rename: bool = true,
    PromoteAccess: bool = true,
    MethodMerger: MethodMergerConfig = .{},
    MethodSplit: bool = true,
    NumberEncryption: NumberEncryptionConfig = .{},
    LogicScrambler: LogicScramblerConfig = .{},
    DeindyConcat: bool = true,
    StringEncryption: bool = true,
    NativeMethod: NativeMethodConfig = .{},
    Virtualizer: VirtualizerConfig = .{},
    ReferenceObfuscation: bool = true,
    ControlFlowFlattener: bool = true,
    ControlFlowShuffler: bool = true,
    MemberShuffler: MemberShufflerConfig = .{},
    ConstantPoolPruner: bool = true,
};

pub const Config = struct {
    NativeProtection: bool = true,
    CustomLoader: bool = true,
    Passes: PassConfig = .{},
};

pub var Active: Config = .{};
