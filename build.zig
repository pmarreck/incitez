const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // -- Static library with C ABI (the FFI boundary around the pure Zig core) --
    const lib = b.addLibrary(.{
        .name = "incitez",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);
    b.installFile("include/incitez.h", "include/incitez.h");

    // -- C CLI executable (dogfoods the FFI; all I/O lives here) --
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    cli_mod.addIncludePath(b.path("include"));
    cli_mod.linkLibrary(lib);
    const cli = b.addExecutable(.{
        .name = "incitez",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // -- Run step --
    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    // -- Unit tests --
    // use_llvm: the self-hosted x86_64 backend SEGVs compiling test binaries
    // in Debug mode (Zig 0.16); force the LLVM backend on test steps.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // Compile tests without running them — lets CI patchelf the binaries
    // before execution inside the Nix sandbox on Linux.
    b.step("test-compile", "Compile tests without running").dependOn(&tests.step);
}
