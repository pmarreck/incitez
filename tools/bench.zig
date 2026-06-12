//! Engine benchmark: extract citations from a document with the chosen
//! engine, timing steady-state iterations. Driven by ./bm via hyperfine
//! (which also captures one-shot cost: process start + lazy engine init —
//! the honest per-document-gate number).
const std = @import("std");
const builtin = @import("builtin");
const incitez = @import("incitez");

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.mode == .Debug) {
        std.debug.print("\x1b[33mDEBUG BUILD — benchmarks refuse to run\x1b[0m\n", .{});
        return error.DebugBuild;
    }

    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: {s} <vm|pcre2|micro> <file> <iters>\n", .{args[0]});
        return error.BadArgs;
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
    const iters = try std.fmt.parseInt(usize, args[3], 10);

    // Per-key-function microbench (CLAUDE.md: log perf over key functions,
    // flag sudden deltas). One line per phase: "<name>: <ns> ns/iter".
    if (std.mem.eql(u8, args[1], "micro")) {
        return runMicro(io, arena, text, iters);
    }

    const engine: incitez.extraction.Engine = if (std.mem.eql(u8, args[1], "vm"))
        .vm
    else if (std.mem.eql(u8, args[1], "pcre2"))
        .pcre2
    else
        return error.UnknownEngine;

    // warmup (also triggers lazy pcre2 compile outside the timed loop)
    var n_cites: usize = 0;
    {
        const cites = try incitez.extraction.extractWithEngine(arena, text, engine);
        n_cites = cites.len;
    }

    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..iters) |_| {
        const cites = try incitez.extraction.extractWithEngine(arena, text, engine);
        std.mem.doNotOptimizeAway(cites.len);
    }
    const t1 = std.Io.Timestamp.now(io, .awake);

    const ns_total: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
    const ns_per: u64 = ns_total / iters;
    const mb_s = (@as(f64, @floatFromInt(text.len)) * @as(f64, @floatFromInt(iters)) * 1000.0) /
        @as(f64, @floatFromInt(ns_total));

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "{s}: {d} bytes, {d} cites, {d} ns/iter, {d:.1} MB/s\n",
        .{ args[1], text.len, n_cites, ns_per, mb_s },
    );
    try w.interface.flush();
}

/// Per-key-function microbench: prints one "<phase>: <ns> ns/iter" line per
/// pipeline phase plus resolve + end-to-end total. ./bm logs these to
/// MICROBENCHMARKS.md and two-sided-gates each phase against its own history.
fn runMicro(io: std.Io, arena: std.mem.Allocator, text: []const u8, iters: usize) !void {
    const phases = try incitez.extraction.benchPhases(io, arena, text, iters);

    // resolve lives downstream of the extraction module — timed here on the
    // final citation set (resolve returns an assignment array; cites unmutated).
    const final_cites = try incitez.extraction.extractWithEngine(arena, text, .vm);
    _ = try incitez.resolution.resolve(arena, final_cites); // warmup
    var resolve_acc: u64 = 0;
    for (0..iters) |_| {
        const s = std.Io.Timestamp.now(io, .awake);
        const a = try incitez.resolution.resolve(arena, final_cites);
        const e = std.Io.Timestamp.now(io, .awake);
        resolve_acc += @intCast(e.nanoseconds - s.nanoseconds);
        std.mem.doNotOptimizeAway(a.len);
    }

    var total_acc: u64 = 0;
    for (0..iters) |_| {
        const s = std.Io.Timestamp.now(io, .awake);
        const c = try incitez.extraction.extractWithEngine(arena, text, .vm);
        const e = std.Io.Timestamp.now(io, .awake);
        total_acc += @intCast(e.nanoseconds - s.nanoseconds);
        std.mem.doNotOptimizeAway(c.len);
    }

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "match: {d} ns/iter\nfinish: {d} ns/iter\nreference: {d} ns/iter\nfilter: {d} ns/iter\nresolve: {d} ns/iter\ntotal: {d} ns/iter\n",
        .{ phases.match, phases.finish, phases.reference, phases.filter, resolve_acc / iters, total_acc / iters },
    );
    try w.interface.flush();
}
