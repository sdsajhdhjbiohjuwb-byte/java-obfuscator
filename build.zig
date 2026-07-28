const std = @import("std");

pub fn build(B: *std.Build) void {
    const Target = B.standardTargetOptions(.{});
    const Optimize = B.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const RootModule = B.createModule(.{
        .root_source_file = B.path("src/ApplicationEntryPoint.zig"),
        .target = Target,
        .optimize = Optimize,
    });

    const Exe = B.addExecutable(.{ .name = "Program", .root_module = RootModule });
    B.installArtifact(Exe);

    const Tests = B.addTest(.{ .root_module = RootModule });
    const RunTests = B.addRunArtifact(Tests);
    const TestStep = B.step("test", "Run unit tests");
    TestStep.dependOn(&RunTests.step);
}
