const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // module

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // static library

    const lib = b.addStaticLibrary(.{
        .name = "dcf",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // tests

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // check

    const check = b.step("check", "Check if lib compiles");
    const lib_check = b.addStaticLibrary(.{
        .name = "dcf",
        .root_module = lib_mod,
    });
    check.dependOn(&lib_check.step);

    // docs

    const docs_step = b.step("docs", "Emit docs: python -m http.server 8000 -d zig-out/docs");

    const docs_install = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = lib.getEmittedDocs(),
    });

    docs_step.dependOn(&docs_install.step);

    // default target also builds docs
    b.getInstallStep().dependOn(&docs_install.step);
}
