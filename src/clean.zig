//! Opt-in input normalization for FLAT-text direct callers (those NOT going
//! through docscan). A newline-AWARE variant of eyecite's `clean_text` recipe:
//! strip runs of `__` (a common PDF-extraction artifact) and collapse runs of
//! spaces/tabs, but treat newlines structurally — a blank line (2+ newlines)
//! becomes a "\n\n" paragraph/section break, while a single newline reflows to
//! a space (un-wrapping a hard-wrapped paragraph). Dot-leader lines (ToC/ToA
//! entries, ≥5 consecutive periods) keep their line break. An offset map lets
//! citation spans into the cleaned text map back to the ORIGINAL bytes.
//!
//! This RECOVERS a slice of the structural-boundary surpass for flat text:
//! because the matcher treats a lone `\n` as a hard antecedent stop, the
//! preserved blank-line breaks stop a heading from bleeding into the following
//! party name — even without docscan's explicit markers. (docscan output, which
//! already encodes boundaries as lone `\n`, must keep bypassing clean() — this
//! recipe's single-newline→space rule would otherwise eat those markers.)
//! HTML is out of scope (incitez is text-in; strip markup upstream).
//! See docs/wasm_abi.md §5 and CITATION_PIPELINE_RESPONSIBILITIES.md.
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
    var dot_run: usize = 0; // consecutive '.' count — detects ToC/ToA dot leaders
    var line_has_dotleader = false; // did the current output line carry a ≥5-dot leader?
    while (i < text.len) {
        if (text[i] == '_' and i + 1 < text.len and text[i + 1] == '_') {
            // strip a run of 2+ underscores (single '_' is kept verbatim)
            while (i < text.len and text[i] == '_') i += 1;
            dot_run = 0;
            try recordBreak(allocator, &map, out.items.len, i);
        } else if (std.ascii.isWhitespace(text[i])) {
            // Scan the maximal whitespace run, counting newlines, and pick a
            // replacement that distinguishes STRUCTURE from line-WRAP:
            //   • 2+ newlines (a blank line) → "\n\n": a paragraph/section break.
            //     The matcher treats a lone '\n' as a HARD antecedent stop, so a
            //     heading on the line above a citation no longer bleeds into its
            //     party name.
            //   • exactly 1 newline → a single space: un-wraps a hard-wrapped
            //     paragraph back into one flowing line — UNLESS it terminates a
            //     dot-leader line (a ToC/ToA entry), where it stays "\n" so the
            //     entries don't run together.
            //   • spaces/tabs only (0 newlines) → a single space.
            const run_start = i;
            var newlines: usize = 0;
            while (i < text.len and std.ascii.isWhitespace(text[i])) {
                if (text[i] == '\n') newlines += 1;
                i += 1;
            }
            const replacement: []const u8 = if (newlines >= 2)
                "\n\n"
            else if (newlines == 1 and line_has_dotleader)
                "\n"
            else
                " ";
            try out.appendSlice(allocator, replacement);
            if (i - run_start != replacement.len) {
                try recordBreak(allocator, &map, out.items.len, i);
            }
            if (newlines >= 1) line_has_dotleader = false; // crossed onto a new line
            dot_run = 0; // any whitespace breaks a consecutive-dot run
        } else {
            const ch = text[i];
            try out.append(allocator, ch);
            i += 1;
            if (ch == '.') {
                dot_run += 1;
                if (dot_run >= 5) line_has_dotleader = true;
            } else {
                dot_run = 0;
            }
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

test "clean: single newline + spaces/tabs reflow to a space; a blank line is a break" {
    const a = std.testing.allocator;
    var r = try clean(a, "a  b\n\n\tc   d");
    defer r.deinit(a);
    // "  " (0 nl) → space; "\n\n\t" (2 nl) → "\n\n"; "   " (0 nl) → space
    try std.testing.expectEqualStrings("a b\n\nc d", r.text);
}

test "clean: a single newline (wrapped line) becomes a space" {
    const a = std.testing.allocator;
    var r = try clean(a, "wrapped line one\ncontinues here");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("wrapped line one continues here", r.text);
}

test "clean: a blank line (2+ newlines) is preserved as a paragraph break" {
    const a = std.testing.allocator;
    var r = try clean(a, "para one.\n\npara two.");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("para one.\n\npara two.", r.text);
    // 3+ newlines collapse to a single break
    var r2 = try clean(a, "x\n\n\n\ny");
    defer r2.deinit(a);
    try std.testing.expectEqualStrings("x\n\ny", r2.text);
}

test "clean: spaces around a paragraph break are absorbed into the break" {
    const a = std.testing.allocator;
    var r = try clean(a, "header  \n\n  body");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("header\n\nbody", r.text);
}

test "clean: a dot-leader (ToC) line keeps its line break, not a reflow space" {
    const a = std.testing.allocator;
    // without the dot-leader rule the single \n would reflow these into a run-on
    var r = try clean(a, "Argument...........12\nStatement of Facts.....5");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("Argument...........12\nStatement of Facts.....5", r.text);
}

test "clean: a normal wrapped line with a few periods still reflows (no false dot-leader)" {
    const a = std.testing.allocator;
    // "U.S.C." etc. never reach 5 CONSECUTIVE periods, so the line reflows normally
    var r = try clean(a, "See 28 U.S.C. 1 etc.\nnext line of the paragraph");
    defer r.deinit(a);
    try std.testing.expectEqualStrings("See 28 U.S.C. 1 etc. next line of the paragraph", r.text);
}

test "clean: offset map is identity across a literal paragraph break (no collapse)" {
    const a = std.testing.allocator;
    const orig = "ab\n\ncd";
    var r = try clean(a, orig);
    defer r.deinit(a);
    try std.testing.expectEqualStrings(orig, r.text); // "\n\n" preserved verbatim
    try std.testing.expectEqual(@as(usize, 1), r.map.len); // pure identity: just {0,0}
    for (r.text, 0..) |ch, e| {
        try std.testing.expectEqual(ch, orig[mapToOriginal(r.map, @intCast(e))]);
    }
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
