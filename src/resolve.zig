//! Resolution pass: a port of eyecite resolve.py. Clusters citations to
//! resources — full cites anchor clusters (equal-key fulls share one),
//! short cites match by corrected reporter + volume (antecedent refines
//! ambiguity), supra cites match antecedents against party names, id cites
//! follow the previous resolution (pin-cite sanity-checked).
const std = @import("std");
const extraction = @import("extract.zig");
const reporters = @import("reporters.zig");

const Citation = extraction.Citation;

/// eyecite MAX_OPINION_PAGE_COUNT: id pin cites beyond this many pages
/// past the full cite's page are considered invalid.
const MAX_OPINION_PAGE_COUNT = 150;

/// For each citation, the index of the FULL citation anchoring its cluster
/// (a full cite's own anchor is the first equal-key full), or null when
/// unresolved. Caller frees the slice.
pub fn resolve(allocator: std.mem.Allocator, cites: []const Citation) ![]?u32 {
    const assignment = try allocator.alloc(?u32, cites.len);
    errdefer allocator.free(assignment);

    var resolved_fulls: std.ArrayListUnmanaged(u32) = .empty;
    defer resolved_fulls.deinit(allocator);

    var last_resolution: ?u32 = null;
    for (cites, 0..) |c, i| {
        var res: ?u32 = null;
        switch (c.kind) {
            .full_case => {
                res = @intCast(i);
                for (resolved_fulls.items) |fi| {
                    if (sameResourceKey(cites[fi], c)) {
                        res = assignment[fi];
                        break;
                    }
                }
                try resolved_fulls.append(allocator, @intCast(i));
            },
            .short_case => res = resolveShort(c, resolved_fulls.items, cites, assignment),
            .supra => res = resolveSupra(c, resolved_fulls.items, cites, assignment),
            .id => res = resolveId(c, last_resolution, cites),
            else => {},
        }
        assignment[i] = res;
        last_resolution = res;
    }
    return assignment;
}

/// eyecite CaseCitation hash key: {volume, page, corrected reporter,
/// class} — and a citation MISSING its page never equals anything
/// (placeholder cites get identity hashes "for safety").
fn sameResourceKey(a: Citation, b: Citation) bool {
    if (a.page == null or b.page == null) return false;
    return a.kind == b.kind and
        optEq(a.volume, b.volume) and
        std.mem.eql(u8, a.correctedReporter(), b.correctedReporter()) and
        std.mem.eql(u8, a.page.?, b.page.?);
}

fn optEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn resolveShort(
    c: Citation,
    fulls: []const u32,
    cites: []const Citation,
    assignment: []const ?u32,
) ?u32 {
    var candidates_buf: [64]u32 = undefined;
    var n: usize = 0;
    var distinct: ?u32 = null;
    var multiple = false;
    for (fulls) |fi| {
        const f = cites[fi];
        if (f.kind != .full_case) continue;
        if (!std.mem.eql(u8, f.correctedReporter(), c.correctedReporter())) continue;
        if (!optEq(f.volume, c.volume)) continue;
        if (n < candidates_buf.len) {
            candidates_buf[n] = fi;
            n += 1;
        }
        const r = assignment[fi] orelse continue;
        if (distinct == null) {
            distinct = r;
        } else if (distinct.? != r) {
            multiple = true;
        }
    }
    if (distinct != null and !multiple) return distinct;
    if (c.antecedent_guess) |ag| {
        return filterByAntecedent(ag, candidates_buf[0..n], cites, assignment);
    }
    return null;
}

fn resolveSupra(
    c: Citation,
    fulls: []const u32,
    cites: []const Citation,
    assignment: []const ?u32,
) ?u32 {
    const ag = c.antecedent_guess orelse return null;
    return filterByAntecedent(ag, fulls, cites, assignment);
}

/// _filter_by_matching_antecedent: strip_punct the guess, accept iff exactly
/// one distinct resource has it as a substring of defendant or plaintiff.
fn filterByAntecedent(
    antecedent: []const u8,
    fulls: []const u32,
    cites: []const Citation,
    assignment: []const ?u32,
) ?u32 {
    var buf: [128]u8 = undefined;
    const ag = stripPunct(antecedent, &buf);
    if (ag.len == 0) return null;
    var match: ?u32 = null;
    for (fulls) |fi| {
        const f = cites[fi];
        if (f.kind != .full_case) continue;
        const hit = (f.defendant != null and std.mem.indexOf(u8, f.defendant.?, ag) != null) or
            (f.plaintiff != null and std.mem.indexOf(u8, f.plaintiff.?, ag) != null);
        if (!hit) continue;
        const r = assignment[fi] orelse continue;
        if (match == null) {
            match = r;
        } else if (match.? != r) {
            return null; // ambiguous across distinct resources
        }
    }
    return match;
}

fn resolveId(c: Citation, last_resolution: ?u32, cites: []const Citation) ?u32 {
    const last = last_resolution orelse return null;
    const full = cites[last];
    if (hasInvalidPinCite(full, c)) return null;
    return last;
}

/// _has_invalid_pin_cite: a pin pointing before the full cite's page or more
/// than MAX_OPINION_PAGE_COUNT past it cannot belong to that opinion.
fn hasInvalidPinCite(full: Citation, id_cite: Citation) bool {
    if (full.kind == .full_case and full.page == null) return true;
    const pin = id_cite.pin_cite orelse return false;
    const page_str = full.page orelse return false;
    const page = std.fmt.parseInt(u32, page_str, 10) catch return false;
    // ^(?:at )?(\d+)
    var p: []const u8 = pin;
    if (std.mem.startsWith(u8, p, "at ")) p = p[3..];
    var d: usize = 0;
    while (d < p.len and p[d] >= '0' and p[d] <= '9') d += 1;
    if (d == 0) return true; // non-numeric pin: conservatively invalid
    const pin_page = std.fmt.parseInt(u32, p[0..d], 10) catch return true;
    return pin_page < page or pin_page > page + MAX_OPINION_PAGE_COUNT;
}

/// eyecite utils.strip_punct (Penn Treebank-derived): strips quotes,
/// brackets, sentence punctuation and trailing periods from a token.
fn stripPunct(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (text, 0..) |ch, i| {
        if (n == buf.len) break;
        switch (ch) {
            ',', ';', ':', '@', '#', '$', '%', '&', '?', '!' => {},
            '(', ')', '[', ']', '{', '}', '<', '>' => {},
            '"' => {},
            '\'' => {
                // leading quote or trailing possessive/quote dropped
                if (i == 0 or i + 1 >= text.len) {} else if (text[i + 1] == '\'') {} else {
                    buf[n] = ch;
                    n += 1;
                }
            },
            else => {
                buf[n] = ch;
                n += 1;
            },
        }
    }
    var out = buf[0..n];
    // trailing period (but not after another period)
    if (out.len >= 2 and out[out.len - 1] == '.' and out[out.len - 2] != '.') {
        out = out[0 .. out.len - 1];
    }
    return std.mem.trim(u8, out, " ");
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn checkResolution(rows: []const struct { ?u32, []const u8 }) !void {
    var cites: std.ArrayListUnmanaged(Citation) = .empty;
    defer {
        for (cites.items) |*c| {
            if (c.plaintiff) |p| testing.allocator.free(p);
            if (c.defendant) |d| testing.allocator.free(d);
            if (c.antecedent_guess) |a| testing.allocator.free(a);
        }
        cites.deinit(testing.allocator);
    }
    // per eyecite checkResolution: each row's text yields exactly one cite,
    // extracted in its own context, then resolved as one list
    for (rows) |row| {
        const found = try extraction.extract(testing.allocator, row[1]);
        defer testing.allocator.free(found);
        try testing.expectEqual(@as(usize, 1), found.len);
        try cites.append(testing.allocator, found[0]);
    }
    const assignment = try resolve(testing.allocator, cites.items);
    defer testing.allocator.free(assignment);

    // expected cluster index -> first citation index of that cluster
    var anchors: [16]?u32 = @splat(null);
    for (rows, 0..) |row, i| {
        const want: ??u32 = blk: {
            const cluster = row[0] orelse break :blk @as(??u32, @as(?u32, null));
            if (anchors[cluster] == null) anchors[cluster] = @intCast(i);
            break :blk @as(??u32, anchors[cluster]);
        };
        try testing.expectEqual(want.?, assignment[i]);
    }
}

test "resolution: full + short by volume/reporter" {
    try checkResolution(&.{
        .{ 0, "1 U.S. 1." },
        .{ 0, "1 U.S., at 2." },
        .{ 1, "1 F.2d 1." },
        .{ null, "2 U.S., at 2." },
    });
}

test "resolution: id follows previous, fails over invalid pin" {
    try checkResolution(&.{
        .{ 0, "1 U.S. 5." },
        .{ 0, "Id. at 7." },
        .{ null, "Id. at 3." }, // pin before page: invalid, breaks chain
    });
}

test "resolution: supra by antecedent" {
    try checkResolution(&.{
        .{ 0, "Foo v. Bar, 1 U.S. 1." },
        .{ 0, "Bar, supra, at 2." },
    });
}

test "resolution: duplicate fulls share a resource" {
    try checkResolution(&.{
        .{ 0, "Foo v. Bar, 1 U.S. 1." },
        .{ 0, "Foo v. Bar, 1 U.S. 1." },
    });
}
