const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // Static PCRE2 for the alternate engine path. Flake builds pass
    // -Dpcre2-prefix; the devshell exports PCRE2_PREFIX.
    const pcre2_prefix = b.option(
        []const u8,
        "pcre2-prefix",
        "Path to a static PCRE2 install (include/, lib/libpcre2-8.a)",
    ) orelse b.graph.environ_map.get("PCRE2_PREFIX") orelse {
        std.debug.panic(
            "PCRE2 not found: pass -Dpcre2-prefix=… or enter the dev shell " ++
                "(nix develop exports PCRE2_PREFIX)",
            .{},
        );
    };
    const pcre2_include: std.Build.LazyPath = .{
        .cwd_relative = b.fmt("{s}/include", .{pcre2_prefix}),
    };
    const pcre2_lib: std.Build.LazyPath = .{
        .cwd_relative = b.fmt("{s}/lib/libpcre2-8.a", .{pcre2_prefix}),
    };

    // -- Build-time table codegen: reporters-db JSON → Zig source module --
    // The generator is a host tool; ReleaseSafe keeps it on the LLVM backend
    // (the self-hosted x86_64 Debug backend is still crash-prone in 0.16).
    const gen_exe = b.addExecutable(.{
        .name = "gen-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_tables.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen_run = b.addRunArtifact(gen_exe);
    gen_run.addFileArg(b.path("data/reporters_db/reporters.json"));
    gen_run.addFileArg(b.path("data/reporters_db/regexes.json"));
    const tables_src = gen_run.addOutputFileArg("reporters_tables.zig");
    const tables_mod = b.createModule(.{ .root_source_file = tables_src });
    const tables_import = std.Build.Module.Import{
        .name = "reporters_tables",
        .module = tables_mod,
    };

    const gen_courts_exe = b.addExecutable(.{
        .name = "gen-courts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_courts.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen_courts_run = b.addRunArtifact(gen_courts_exe);
    gen_courts_run.addFileArg(b.path("data/courts_db/courts.json"));
    const courts_src = gen_courts_run.addOutputFileArg("courts_tables.zig");
    const courts_mod = b.createModule(.{ .root_source_file = courts_src });
    const courts_import = std.Build.Module.Import{
        .name = "courts_tables",
        .module = courts_mod,
    };

    // -- Static library with C ABI (the FFI boundary around the pure Zig core) --
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ tables_import, courts_import },
    });
    lib_mod.addIncludePath(pcre2_include);
    lib_mod.addObjectFile(pcre2_lib);
    const lib = b.addLibrary(.{
        .name = "incitez",
        .linkage = .static,
        .root_module = lib_mod,
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
    cli_mod.addObjectFile(pcre2_lib);
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
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // pcre2 needs libc
        .imports = &.{ tables_import, courts_import },
    });
    core_test_mod.addIncludePath(pcre2_include);
    core_test_mod.addObjectFile(pcre2_lib);
    const tests = b.addTest(.{
        .root_module = core_test_mod,
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(tests);

    // -- Acceptance tests (oracle-verified eyecite corpus, ratcheted) --
    const acceptance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/acceptance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "incitez", .module = core_test_mod }},
        }),
        .use_llvm = true,
    });
    const run_acceptance = b.addRunArtifact(acceptance_tests);

    const test_step = b.step("test", "Run unit + acceptance tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_acceptance.step);

    // Compile tests without running them — lets CI patchelf the binaries
    // before execution inside the Nix sandbox on Linux.
    const test_compile = b.step("test-compile", "Compile tests without running");
    test_compile.dependOn(&tests.step);
    test_compile.dependOn(&acceptance_tests.step);

    // -- Engine benchmark tool (driven by ./bm via hyperfine) --
    const bench = b.addExecutable(.{
        .name = "incitez-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "incitez", .module = core_test_mod }},
        }),
    });
    b.installArtifact(bench);
}
