//! WASM ABI for the browser consumer (incitez_web). VM-only (PCRE2 path
//! comptime-excluded via build_options.enable_pcre2=false). Contract is
//! UTF-8 bytes in → a single JSON string out, mirroring the CLI `--json`
//! schema byte-for-byte (same src/json_out.zig serializer). See
//! docs/wasm_abi.md for the consumer contract.
//!
//! Memory: every buffer handed across the boundary has a hidden 8-byte
//! allocation header immediately before the returned pointer, so `free`
//! needs only the pointer. The exported `memory` is wasm linear memory.
const std = @import("std");
const builtin = @import("builtin");
const extraction = @import("extract.zig");
const resolution = @import("resolve.zig");
const json_out = @import("json_out.zig");

// WasmAllocator reuses freed regions (page_allocator would leak per call).
const gpa = std.heap.wasm_allocator;

const HEADER: usize = 8; // [u32 total_alloc_size][u32 pad]; keeps data 8-aligned

/// Allocate a `data_len`-byte data region; returns a pointer to the data
/// (the 8-byte size header sits just before it for free()).
fn rawAlloc(data_len: usize) ?[*]u8 {
    const total = HEADER + data_len;
    const buf = gpa.alignedAlloc(u8, .@"8", total) catch return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(total), .little);
    return buf.ptr + HEADER;
}

fn rawFree(data_ptr: [*]u8) void {
    const base: [*]align(8) u8 = @alignCast(data_ptr - HEADER);
    const total = std.mem.readInt(u32, base[0..4], .little);
    gpa.free(base[0..total]);
}

/// Allocate `len` writable bytes for the caller to fill with UTF-8 input.
/// Returns the wasm memory offset, or 0 on failure.
export fn incitez_alloc(len: u32) u32 {
    const p = rawAlloc(len) orelse return 0;
    return @intFromPtr(p);
}

/// Free a buffer returned by incitez_alloc or incitez_extract.
export fn incitez_free(ptr: u32) void {
    if (ptr == 0) return;
    rawFree(@ptrFromInt(ptr));
}

/// Extract citations from `len` UTF-8 bytes at `ptr`. Returns the offset of
/// a result buffer laid out as `[u32 json_len (LE)][json_len bytes of UTF-8
/// JSON]` — the `--json` schema (always a JSON array, possibly empty).
/// Returns 0 only on allocation failure. The caller frees the result with
/// incitez_free.
export fn incitez_extract(ptr: u32, len: u32) u32 {
    if (len == 0) return emptyResult();
    const input = @as([*]const u8, @ptrFromInt(ptr))[0..len];

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cites = extraction.extractWithEngine(a, input, .vm) catch return 0;
    const assignment = resolution.resolve(a, cites) catch return 0;

    var aw: std.Io.Writer.Allocating = .init(a);
    json_out.writeJson(&aw.writer, cites, assignment) catch return 0;
    return packResult(aw.written());
}

fn packResult(json: []const u8) u32 {
    const data = rawAlloc(4 + json.len) orelse return 0;
    std.mem.writeInt(u32, data[0..4], @intCast(json.len), .little);
    @memcpy(data[4 .. 4 + json.len], json);
    return @intFromPtr(data);
}

fn emptyResult() u32 {
    return packResult("[]\n");
}

/// Self-test over a small embedded corpus. Returns `(passed << 16) | total`
/// — incitez_web calls this on page load for the "engine self-verified N/N"
/// badge (decode: passed = ret >> 16, total = ret & 0xffff).
export fn incitez_selftest() u32 {
    const Case = struct { text: []const u8, expect: usize };
    const cases = [_]Case{
        .{ .text = "1 U.S. 1", .expect = 1 },
        .{ .text = "Foo v. Bar, 1 U.S. 1 (1982). Id. at 5.", .expect = 2 },
        .{ .text = "1 Minn. L. Rev. 1 (2007)", .expect = 1 },
        .{ .text = "Ohio Rev. Code Ann. \xc2\xa7 5739.02(B)(7) (Lexis Supp. 2010)", .expect = 1 },
        .{ .text = "530 U. S. 238, 241\xe2\x80\x93242 (2000)", .expect = 1 }, // en-dash pin (surpass)
        .{ .text = "the 3 musketeers met 4 friends", .expect = 0 },
    };
    var passed: u32 = 0;
    for (cases) |c| {
        const cites = extraction.extract(gpa, c.text) catch continue;
        defer extraction.freeCitations(gpa, cites);
        // also assert the en-dash case actually recovers the pin (the surpass)
        var ok = cites.len == c.expect;
        if (ok and std.mem.indexOf(u8, c.text, "\xe2\x80\x93") != null and cites.len == 1) {
            ok = cites[0].pin_cite != null;
        }
        if (ok) passed += 1;
    }
    return (passed << 16) | @as(u32, cases.len);
}

/// Library version (offset of a NUL-terminated static string).
const version_z: [:0]const u8 = "0.1.0";
export fn incitez_version_ptr() u32 {
    return @intFromPtr(version_z.ptr);
}

comptime {
    // wasm is a reactor module (no _start); ensure exports are retained.
    if (builtin.target.cpu.arch != .wasm32) @compileError("wasm.zig is wasm32-only");
}
