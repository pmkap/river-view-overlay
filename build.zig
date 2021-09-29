const std = @import("std");

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addProtocolPath("protocol/river-status-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");

    const exe = b.addExecutable("agertu", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.step.dependOn(&scanner.step);
    exe.addPackage(scanner.getPkg());

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    const pixman = std.build.Pkg{
        .name = "pixman",
        .path = "deps/zig-pixman/pixman.zig",
    };
    exe.addPackage(pixman);
    exe.linkSystemLibrary("pixman-1");

    const fcft = std.build.Pkg{
        .name = "fcft",
        .path = "deps/zig-fcft/fcft.zig",
        .dependencies = &[_]std.build.Pkg{pixman},
    };
    exe.addPackage(fcft);
    exe.linkSystemLibrary("fcft");

    {
        const tests = b.addTest("src/test_main.zig");
        tests.setTarget(target);
        tests.addPackage(scanner.getPkg());
        tests.addPackage(pixman);
        tests.linkSystemLibrary("pixman-1");
        tests.addPackage(fcft);
        tests.linkSystemLibrary("fcft");
        tests.setBuildMode(mode);
        const test_step = b.step("test", "Run all tests");
        test_step.dependOn(&tests.step);
    }

    // TODO: remove when https://github.com/ziglang/zig/issues/131 is implemented
    scanner.addCSource(exe);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
