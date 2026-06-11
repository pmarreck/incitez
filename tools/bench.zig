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
        std.debug.print("usage: {s} <vm|pcre2> <file> <iters>\n", .{args[0]});
        return error.BadArgs;
    }

    const engine: incitez.extraction.Engine = if (std.mem.eql(u8, args[1], "vm"))
        .vm
    else if (std.mem.eql(u8, args[1], "pcre2"))
        .pcre2
    else
        return error.UnknownEngine;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
    const iters = try std.fmt.parseInt(usize, args[3], 10);

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
