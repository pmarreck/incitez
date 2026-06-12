//! C FFI boundary: flat structs + arena ownership. This is the real public
//! API — every consumer (including our own C CLI) goes through it. Strings
//! are NUL-terminated copies owned by the result's arena; one free call
//! releases everything.
const std = @import("std");
const extraction = @import("extract.zig");
const resolution = @import("resolve.zig");
const json_out = @import("json_out.zig");

pub const Citation = extern struct {
    kind: [*:0]const u8,
    span_start: u32,
    span_end: u32,
    full_span_start: u32,
    full_span_end: u32,
    volume: ?[*:0]const u8,
    reporter: ?[*:0]const u8,
    page: ?[*:0]const u8,
    corrected_reporter: ?[*:0]const u8,
    pin_cite: ?[*:0]const u8,
    court: ?[*:0]const u8,
    year: i32, // -1 when absent
    parenthetical: ?[*:0]const u8,
    extra: ?[*:0]const u8,
    plaintiff: ?[*:0]const u8,
    defendant: ?[*:0]const u8,
    antecedent_guess: ?[*:0]const u8,
    /// Index of the citation anchoring this one's resolution cluster
    /// (a full cite anchors itself); -1 when unresolved.
    resolution: i32,
};

const Result = struct {
    arena: std.heap.ArenaAllocator,
    citations: []Citation,
};

fn kindName(kind: extraction.Kind) [*:0]const u8 {
    return switch (kind) {
        .full_case => "FullCaseCitation",
        .short_case => "ShortCaseCitation",
        .supra => "SupraCitation",
        .id => "IdCitation",
        .reference => "ReferenceCitation",
        .unknown => "UnknownCitation",
        .full_law => "FullLawCitation",
        .full_journal => "FullJournalCitation",
    };
}

fn dupeZ(arena: std.mem.Allocator, s: ?[]const u8) ?[*:0]const u8 {
    const v = s orelse return null;
    const copy = arena.dupeZ(u8, v) catch return null;
    return copy.ptr;
}

/// Extracts citations from `text` (UTF-8, `len` bytes). `engine` selects the
/// matching implementation: "vm" (default, pass NULL) or "pcre2".
/// Returns NULL on allocation failure or unknown engine.
export fn incitez_extract(
    text: [*]const u8,
    len: usize,
    engine: ?[*:0]const u8,
) ?*Result {
    const gpa = std.heap.c_allocator;
    const eng: extraction.Engine = blk: {
        const e = engine orelse break :blk .vm;
        const es = std.mem.span(e);
        if (es.len == 0 or std.mem.eql(u8, es, "vm")) break :blk .vm;
        if (std.mem.eql(u8, es, "pcre2")) break :blk .pcre2;
        return null;
    };

    const result = gpa.create(Result) catch return null;
    result.arena = std.heap.ArenaAllocator.init(gpa);
    const arena = result.arena.allocator();
    errdefer comptime unreachable;

    const input = text[0..len];
    const cites = extraction.extractWithEngine(arena, input, eng) catch {
        result.arena.deinit();
        gpa.destroy(result);
        return null;
    };
    const assignment = resolution.resolve(arena, cites) catch {
        result.arena.deinit();
        gpa.destroy(result);
        return null;
    };

    const out = arena.alloc(Citation, cites.len) catch {
        result.arena.deinit();
        gpa.destroy(result);
        return null;
    };
    for (cites, assignment, out) |c, res, *o| {
        const is_token = c.kind == .supra or c.kind == .id or c.kind == .unknown;
        o.* = .{
            .kind = kindName(c.kind),
            .span_start = c.span_start,
            .span_end = c.span_end,
            .full_span_start = c.full_span_start,
            .full_span_end = c.full_span_end,
            .volume = dupeZ(arena, c.volume),
            .reporter = if (is_token) null else dupeZ(arena, c.reporter),
            .page = dupeZ(arena, c.page),
            .corrected_reporter = if (is_token) null else dupeZ(arena, c.correctedReporter()),
            .pin_cite = dupeZ(arena, c.pin_cite),
            .court = dupeZ(arena, c.court),
            .year = if (c.year) |y| @intCast(y) else -1,
            .parenthetical = dupeZ(arena, c.parenthetical),
            .extra = dupeZ(arena, c.extra),
            .plaintiff = dupeZ(arena, c.plaintiff),
            .defendant = dupeZ(arena, c.defendant),
            .antecedent_guess = dupeZ(arena, c.antecedent_guess),
            .resolution = if (res) |r| @intCast(r) else -1,
        };
    }
    result.citations = out;
    return result;
}

export fn incitez_result_count(result: ?*const Result) usize {
    const r = result orelse return 0;
    return r.citations.len;
}

export fn incitez_result_get(result: ?*const Result, idx: usize) ?*const Citation {
    const r = result orelse return null;
    if (idx >= r.citations.len) return null;
    return &r.citations[idx];
}

export fn incitez_result_free(result: ?*Result) void {
    const r = result orelse return;
    var arena = r.arena;
    std.heap.c_allocator.destroy(r);
    arena.deinit();
}

/// Convenience export: extract + resolve + serialize to a NUL-terminated
/// JSON string (the `--json` schema, identical bytes to the C CLI because
/// both go through src/json_out.zig). Caller frees with incitez_string_free.
/// Returns NULL on allocation failure or unknown engine.
export fn incitez_extract_json(
    text: [*]const u8,
    len: usize,
    engine: ?[*:0]const u8,
) ?[*:0]u8 {
    const gpa = std.heap.c_allocator;
    const eng: extraction.Engine = blk: {
        const e = engine orelse break :blk .vm;
        const es = std.mem.span(e);
        if (es.len == 0 or std.mem.eql(u8, es, "vm")) break :blk .vm;
        if (std.mem.eql(u8, es, "pcre2")) break :blk .pcre2;
        return null;
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cites = extraction.extractWithEngine(a, text[0..len], eng) catch return null;
    const assignment = resolution.resolve(a, cites) catch return null;

    var aw: std.Io.Writer.Allocating = .init(a);
    json_out.writeJson(&aw.writer, cites, assignment) catch return null;
    const json = aw.written();

    const out = gpa.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(out, json);
    return out.ptr;
}

/// Frees a string returned by incitez_extract_json.
export fn incitez_string_free(s: ?[*:0]u8) void {
    const p = s orelse return;
    std.heap.c_allocator.free(std.mem.span(p));
}

// ── Tests (dogfooding the exports from Zig) ─────────────────────────

const testing = std.testing;

test "ffi roundtrip: extract, read, free" {
    const text = "Foo v. Bar, 1 U.S. 1 (1982). Id. at 5.";
    const result = incitez_extract(text.ptr, text.len, null).?;
    defer incitez_result_free(result);

    try testing.expectEqual(@as(usize, 2), incitez_result_count(result));
    const c0 = incitez_result_get(result, 0).?;
    try testing.expectEqualStrings("FullCaseCitation", std.mem.span(c0.kind));
    try testing.expectEqualStrings("1", std.mem.span(c0.volume.?));
    try testing.expectEqualStrings("U.S.", std.mem.span(c0.reporter.?));
    try testing.expectEqualStrings("Foo", std.mem.span(c0.plaintiff.?));
    try testing.expectEqual(@as(i32, 1982), c0.year);
    try testing.expectEqualStrings("scotus", std.mem.span(c0.court.?));
    try testing.expectEqual(@as(i32, 0), c0.resolution);

    const c1 = incitez_result_get(result, 1).?;
    try testing.expectEqualStrings("IdCitation", std.mem.span(c1.kind));
    try testing.expectEqualStrings("at 5", std.mem.span(c1.pin_cite.?));
    try testing.expectEqual(@as(i32, 0), c1.resolution);

    try testing.expectEqual(@as(?*const Citation, null), incitez_result_get(result, 2));
}

test "ffi: pcre2 engine selection and unknown engine rejection" {
    const text = "1 U.S. 1";
    const r = incitez_extract(text.ptr, text.len, "pcre2").?;
    defer incitez_result_free(r);
    try testing.expectEqual(@as(usize, 1), incitez_result_count(r));
    try testing.expectEqual(@as(?*Result, null), incitez_extract(text.ptr, text.len, "bogus"));
}
