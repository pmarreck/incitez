const std = @import("std");
const reporters = @import("reporters.zig");

pub const Kind = enum {
    full_case,
    short_case,
    supra,
    id,
    reference,
    unknown,
    full_law,
    full_journal,
};

pub const Citation = struct {
    kind: Kind,
    /// [start, end) byte offsets of the core citation in the input text.
    span_start: u32,
    span_end: u32,
    /// Slices into the input text, as found.
    volume: ?[]const u8,
    reporter: []const u8,
    page: ?[]const u8,
    /// Index into reporters.editions — the resolved (corrected) edition.
    edition: u32,
    is_variant: bool,

    /// Canonical reporter spelling (eyecite's corrected_reporter).
    pub fn correctedReporter(self: Citation) []const u8 {
        return reporters.editions[self.edition].abbrev;
    }
};

/// Extracts legal citations from plain text. eyecite-compatible matching:
/// this slice implements the standard full-citation shape
/// `$volume $reporter,? $page` (volume = [1-9]\d*, one space, reporter from
/// the reporters-db match table longest-first, optional comma, one space,
/// page = \d+ | roman numeral | _+ placeholder).
/// Returned slice is owned by the caller (free with `allocator.free`);
/// all string fields are zero-copy slices into `text`.
pub fn extract(allocator: std.mem.Allocator, text: []const u8) ![]Citation {
    var cites: std.ArrayListUnmanaged(Citation) = .empty;
    errdefer cites.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (isVolumeStart(text, i)) {
            if (try matchFullCitation(text, i)) |cite| {
                try cites.append(allocator, cite);
                i = cite.span_end;
                continue;
            }
        }
        i += 1;
    }
    return cites.toOwnedSlice(allocator);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// eyecite's boundary class: every citation extractor is wrapped in
/// `(?:^|[^a-zA-Z0-9])(...)(?:[^a-zA-Z0-9]|$)` — note underscore counts as
/// a boundary there, unlike regex `\w`.
fn isBoundaryAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Volume anchor: nonzero digit at a non-alphanumeric boundary
/// (eyecite nonalphanum_boundaries_re semantics).
fn isVolumeStart(text: []const u8, i: usize) bool {
    if (text[i] < '1' or text[i] > '9') return false;
    return i == 0 or !isBoundaryAlnum(text[i - 1]);
}

fn matchFullCitation(text: []const u8, vol_start: usize) !?Citation {
    // volume digits
    var p = vol_start;
    while (p < text.len and isDigit(text[p])) p += 1;
    const vol_end = p;
    // exactly one space
    if (p >= text.len or text[p] != ' ') return null;
    p += 1;
    // reporter: longest match from the sorted table
    const rep_start = p;
    const rep = reporters.longestMatch(text[rep_start..]) orelse return null;
    p += rep.key_len;
    // optional comma, then exactly one space
    if (p < text.len and text[p] == ',') p += 1;
    if (p >= text.len or text[p] != ' ') return null;
    p += 1;
    // page
    const page_start = p;
    const page_end = matchPage(text, p) orelse return null;
    // trailing boundary: the citation must end at a non-alphanumeric
    if (page_end < text.len and isBoundaryAlnum(text[page_end])) return null;

    // all-underscore page is a "known missing" placeholder: spanned, but null
    const page_text = text[page_start..page_end];
    const page: ?[]const u8 = if (text[page_start] == '_') null else page_text;

    return .{
        .kind = .full_case,
        .span_start = @intCast(vol_start),
        .span_end = @intCast(page_end),
        .volume = text[vol_start..vol_end],
        .reporter = text[rep_start .. rep_start + rep.key_len],
        .page = page,
        .edition = rep.entry.edition,
        .is_variant = rep.entry.is_variant,
    };
}

/// Page: `\d+` | roman numeral (eyecite's restricted set, lowercase) | `_+`.
/// Returns end offset of the page token, or null.
fn matchPage(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    if (isDigit(text[start])) {
        var p = start;
        while (p < text.len and isDigit(text[p])) p += 1;
        return p;
    }
    if (text[start] == '_') {
        var p = start;
        while (p < text.len and text[p] == '_') p += 1;
        return p;
    }
    return matchRomanPage(text, start);
}

/// Roman numerals 1–199 excluding 5, 50, 100 (eyecite ROMAN_NUMERAL_REGEX),
/// lowercase only.
fn matchRomanPage(text: []const u8, start: usize) ?usize {
    var p = start;
    // optional leading c (but bare "c" alone is excluded below)
    if (p < text.len and text[p] == 'c') p += 1;
    // tens part: xc | xl | l?x{1,3}
    var has_tens = false;
    if (p + 1 < text.len and text[p] == 'x' and (text[p + 1] == 'c' or text[p + 1] == 'l')) {
        p += 2;
        has_tens = true;
    } else {
        if (p < text.len and text[p] == 'l') p += 1;
        var xs: usize = 0;
        while (p < text.len and text[p] == 'x' and xs < 3) : (xs += 1) p += 1;
        has_tens = xs > 0;
        if (!has_tens and p > start and text[p - 1] == 'l') {
            // "l" or "cl" prefix without x: keep for ones check ("lv","cl","clv")
        }
    }
    // ones part: ix | iv | v?i{0,3}
    var ones_len: usize = 0;
    if (p + 1 < text.len and text[p] == 'i' and (text[p + 1] == 'x' or text[p + 1] == 'v')) {
        p += 2;
        ones_len = 2;
    } else {
        const v_at = p;
        if (p < text.len and text[p] == 'v') p += 1;
        var is: usize = 0;
        while (p < text.len and text[p] == 'i' and is < 3) : (is += 1) p += 1;
        ones_len = p - v_at;
    }
    if (p == start) return null;
    const len = p - start;
    const s = text[start..p];
    // exclusions: bare v/l/c and 5/50/100 multiples not in the allowed set
    if (len == 1 and (s[0] == 'v' or s[0] == 'l' or s[0] == 'c')) return null;
    // "lv","cv","cl","clv" are allowed; bare "v" handled above.
    // (trailing token boundary is enforced centrally by matchFullCitation)
    if (ones_len == 0 and !has_tens) {
        // only c/l prefixes consumed — allowed combos checked: cl
        if (!(len == 2 and s[0] == 'c' and s[1] == 'l')) return null;
    }
    return p;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn expectSingleFullCite(
    text: []const u8,
    span_start: u32,
    span_end: u32,
    volume: []const u8,
    reporter_found: []const u8,
    page: []const u8,
    corrected: []const u8,
) !void {
    const cites = try extract(testing.allocator, text);
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(Kind.full_case, c.kind);
    try testing.expectEqual(span_start, c.span_start);
    try testing.expectEqual(span_end, c.span_end);
    try testing.expectEqualStrings(volume, c.volume.?);
    try testing.expectEqualStrings(reporter_found, c.reporter);
    try testing.expectEqualStrings(page, c.page.?);
    try testing.expectEqualStrings(corrected, c.correctedReporter());
}

test "bare full citation: 1 U.S. 1" {
    try expectSingleFullCite("1 U.S. 1", 0, 8, "1", "U.S.", "1", "U.S.");
}

test "full citation with surrounding text" {
    try expectSingleFullCite("lissner test 1 U.S. 1", 13, 21, "1", "U.S.", "1", "U.S.");
}

test "full citation with comma before page" {
    try expectSingleFullCite("Lissner v. Test, 1 U.S. 1 (1982)", 17, 25, "1", "U.S.", "1", "U.S.");
}

test "variant reporter is corrected: U. S. -> U.S." {
    try expectSingleFullCite("1 U. S. 1", 0, 9, "1", "U. S.", "1", "U.S.");
}

test "different reporter: F.2d" {
    try expectSingleFullCite("bob Lissner v. Test 1 F.2d 1 (1982)", 20, 28, "1", "F.2d", "1", "F.2d");
}

test "multi-word reporter: F. Supp. 2d" {
    try expectSingleFullCite("12 F. Supp. 2d 100", 0, 18, "12", "F. Supp. 2d", "100", "F. Supp. 2d");
}

test "placeholder page spans the underscores but yields null page (eyecite parity)" {
    const cites = try extract(testing.allocator, "Carpenter v. United States, 585 U.S. ___");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(u32, 28), cites[0].span_start);
    try testing.expectEqual(@as(u32, 40), cites[0].span_end);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].page);
    try testing.expectEqualStrings("585", cites[0].volume.?);
}

test "citation requires non-alphanumeric boundaries (eyecite parity)" {
    // volume glued to a word, and page glued to a word: both rejected
    const cites = try extract(testing.allocator, "foo1 U.S. 1, 1. U.S. 1foo");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "street addresses are not citations: page must end at a token boundary" {
    const a = try extract(testing.allocator, "lorem 111 S.W. 12th St.");
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try extract(testing.allocator, "lorem 111 N. W. 12th St.");
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "roman numeral page" {
    try expectSingleFullCite("1 U.S. xv", 0, 9, "1", "U.S.", "xv", "U.S.");
}

test "no citation in plain prose" {
    const cites = try extract(testing.allocator, "the 3 musketeers met 4 friends in 1982");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "volume must not be zero-led and reporter must be known" {
    const cites = try extract(testing.allocator, "0 U.S. 1 and 1 X.Y.Z. 2");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "two citations in one string" {
    const cites = try extract(testing.allocator, "see 1 U.S. 1; also 2 F.2d 3.");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("U.S.", cites[0].reporter);
    try testing.expectEqualStrings("F.2d", cites[1].reporter);
}
