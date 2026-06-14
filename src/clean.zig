//! Opt-in input normalization for FLAT-text direct callers (those NOT going
//! through docscan). The eyecite `clean_text` recipe — collapse `\s+` → a single
//! space, strip runs of `__` (a common PDF-extraction artifact) — plus an
//! offset map so citation spans into the cleaned text map back to the ORIGINAL
//! bytes. This degrades gracefully to eyecite parity: the structural-boundary
//! surpass needs docscan's preserved lone-`\n` signal, and collapsing `\s+`
//! throws it away. HTML is out of scope (incitez is text-in; strip markup
//! upstream). See docs/wasm_abi.md §5 and CITATION_PIPELINE_RESPONSIBILITIES.md.
const std = @import("std");

/// Piecewise-1:1 breakpoint mapping cleaned (emitted) offsets back to original
/// offsets — same shape docscan emits: sorted ascending by `emitted_off`, first
/// entry `{0,0}`, both coordinates monotonically non-decreasing. To map a
/// cleaned offset E: binary-search the largest entry with `emitted_off ≤ E`,
/// then `original_off + (E − emitted_off)`.
pub const Breakpoint = extern struct { emitted_off: u32, original_off: u32 };

pub const CleanResult = struct {
    text: []u8,
    map: []Breakpoint,

    pub fn deinit(self: *CleanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.map);
    }
};

/// Apply the recipe and build the emitted↔original offset map. Caller owns both
/// returned slices (CleanResult.deinit frees them).
pub fn clean(allocator: std.mem.Allocator, text: []const u8) !CleanResult {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var map: std.ArrayListUnmanaged(Breakpoint) = .empty;
    errdefer map.deinit(allocator);
    try map.append(allocator, .{ .emitted_off = 0, .original_off = 0 });

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '_' and i + 1 < text.len and text[i + 1] == '_') {
            // strip a run of 2+ underscores (single '_' is kept verbatim)
            while (i < text.len and text[i] == '_') i += 1;
            try recordBreak(allocator, &map, out.items.len, i);
        } else if (std.ascii.isWhitespace(text[i])) {
            try out.append(allocator, ' ');
            i += 1;
            if (i < text.len and std.ascii.isWhitespace(text[i])) {
                // a RUN of whitespace collapses to the one space already emitted
                while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
                try recordBreak(allocator, &map, out.items.len, i);
            }
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .map = try map.toOwnedSlice(allocator),
    };
}

/// Record a delta jump at `emitted`↔`original`. If the last breakpoint already
/// sits at this emitted offset (back-to-back collapses), update its target
/// rather than append a duplicate — keeps the map binary-searchable.
fn recordBreak(
    allocator: std.mem.Allocator,
    map: *std.ArrayListUnmanaged(Breakpoint),
    emitted: usize,
    original: usize,
) !void {
    const e: u32 = @intCast(emitted);
    const o: u32 = @intCast(original);
    const last = &map.items[map.items.len - 1];
    if (last.emitted_off == e) {
        last.original_off = o;
    } else {
        try map.append(allocator, .{ .emitted_off = e, .original_off = o });
    }
}

/// Map a byte offset in the cleaned text back to the original input.
pub fn mapToOriginal(map: []const Breakpoint, emitted_off: u32) u32 {
    var lo: usize = 0;
    var hi: usize = map.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (map[mid].emitted_off <= emitted_off) lo = mid + 1 else hi = mid;
    }
    const bp = map[lo - 1]; // map[0] is {0,0}, so lo >= 1 always
    return bp.original_off + (emitted_off - bp.emitted_off);
}

// ── Tests ───────────────────────────────────────────────────────────

test "clean: collapse whitespace runs (incl. newlines/tabs) to single space" {
    const a = std.testing.allocator;
    var r = try clean(a, "a  b\n\n\tc   d");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("a b c d", r.text);
}

test "clean: strip runs of 2+ underscores, keep a lone underscore" {
    const a = std.testing.allocator;
    var r = try clean(a, "a__b_c___d");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("ab_cd", r.text);
}

test "clean: offset map round-trips cleaned offsets back to original" {
    const a = std.testing.allocator;
    const orig = "a  b__c"; // → "a bc"
    var r = try clean(a, orig);
    defer r.deinit(a);
    try std.testing.expectEqualStrings("a bc", r.text);
    // emitted 'a'@0→0, ' '@1→1, 'b'@2→3, 'c'@3→6
    try std.testing.expectEqual(@as(u32, 0), mapToOriginal(r.map, 0));
    try std.testing.expectEqual(@as(u32, 1), mapToOriginal(r.map, 1));
    try std.testing.expectEqual(@as(u32, 3), mapToOriginal(r.map, 2));
    try std.testing.expectEqual(@as(u32, 6), mapToOriginal(r.map, 3));
    // every cleaned byte must map to its real original byte
    for (r.text, 0..) |ch, e| {
        try std.testing.expectEqual(ch, orig[mapToOriginal(r.map, @intCast(e))]);
    }
}

test "clean: no-op text yields identity map and unchanged bytes" {
    const a = std.testing.allocator;
    var r = try clean(a, "Foo v. Bar, 1 U.S. 1 (1982).");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("Foo v. Bar, 1 U.S. 1 (1982).", r.text);
    try std.testing.expectEqual(@as(usize, 1), r.map.len); // just {0,0}
}
