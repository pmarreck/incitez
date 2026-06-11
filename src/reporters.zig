const std = @import("std");
/// Build-time-generated tables from reporters-db (see tools/gen_tables.zig).
const tables = @import("reporters_tables");

pub const CiteType = tables.CiteType;
pub const Edition = tables.Edition;
pub const MatchEntry = tables.MatchEntry;

pub const editions = tables.editions;

/// Resolves a reporter abbreviation (canonical edition like "F.3d" or a known
/// variant spelling like "Atl.") to all candidate editions, preserving
/// ambiguity. Binary search over the sorted match table; duplicate keys are
/// adjacent, so the result is a contiguous subslice.
pub fn lookup(key: []const u8) []const MatchEntry {
    const table = tables.match_table;
    // lower bound
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, table[mid].key, key) == .lt) lo = mid + 1 else hi = mid;
    }
    const start = lo;
    // upper bound
    hi = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, table[mid].key, key) == .gt) hi = mid else lo = mid + 1;
    }
    return table[start..lo];
}

// ── Tests ───────────────────────────────────────────────────────────

test "match table is sorted by key with valid edition indices (whole-set sweep)" {
    var prev: ?[]const u8 = null;
    for (tables.match_table) |entry| {
        try std.testing.expect(entry.key.len > 0);
        try std.testing.expect(entry.edition < tables.editions.len);
        if (prev) |p| try std.testing.expect(std.mem.order(u8, p, entry.key) != .gt);
        prev = entry.key;
    }
    // sanity on scale: reporters-db has >1k editions and >2k variants
    try std.testing.expect(tables.editions.len > 1000);
    try std.testing.expect(tables.match_table.len > tables.editions.len);
}

test "lookup finds canonical U.S. reporter" {
    const matches = lookup("U.S.");
    try std.testing.expect(matches.len >= 1);
    const ed = editions[matches[0].edition];
    try std.testing.expectEqualStrings("U.S.", ed.abbrev);
    try std.testing.expectEqualStrings("United States Supreme Court Reports", ed.reporter_name);
    try std.testing.expectEqual(CiteType.federal, ed.cite_type);
    try std.testing.expect(!matches[0].is_variant);
}

test "lookup finds F.3d (Federal Reporter, Third Series)" {
    const matches = lookup("F.3d");
    try std.testing.expect(matches.len >= 1);
    const ed = editions[matches[0].edition];
    try std.testing.expectEqualStrings("F.3d", ed.abbrev);
    try std.testing.expectEqual(CiteType.federal, ed.cite_type);
}

test "lookup maps variant spelling to canonical edition" {
    const matches = lookup("Atl.");
    try std.testing.expect(matches.len >= 1);
    const ed = editions[matches[0].edition];
    try std.testing.expectEqualStrings("A.", ed.abbrev);
    try std.testing.expectEqualStrings("Atlantic Reporter", ed.reporter_name);
    try std.testing.expect(matches[0].is_variant);
}

test "lookup of unknown string returns empty slice" {
    try std.testing.expectEqual(@as(usize, 0), lookup("Not A Reporter").len);
    try std.testing.expectEqual(@as(usize, 0), lookup("").len);
}

test "every lookup by canonical edition abbrev finds itself (whole-set classifier)" {
    // Filters/lookups are tested over the full set, not single examples:
    // every edition's canonical abbreviation must resolve to at least one
    // match entry pointing back at an edition with that same abbreviation.
    for (editions, 0..) |ed, i| {
        const matches = lookup(ed.abbrev);
        var found = false;
        for (matches) |m| {
            if (m.edition == i) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("edition '{s}' (#{d}) not reachable via lookup\n", .{ ed.abbrev, i });
            return error.TestUnexpectedResult;
        }
    }
}
