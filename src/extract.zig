const std = @import("std");
const reporters = @import("reporters.zig");
const tables = @import("reporters_tables");
const courts = @import("courts_tables");
const pcre2_engine = @import("pcre2_engine.zig");

/// Which candidate-finding implementation to use. `.vm` is incitez's
/// anchored pattern VM; `.pcre2` runs the eyecite-literal regexes through
/// PCRE2 — an independent second path for differential comparison
/// (selected via INCITEZ_ENGINE at the CLI/FFI edge; the core takes it as
/// a parameter).
pub const Engine = enum { vm, pcre2 };

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
    /// Slices into the input text, as found. Null when the pattern has no
    /// such group or it did not participate in the match.
    volume: ?[]const u8,
    reporter: []const u8,
    page: ?[]const u8,
    /// Index into reporters.editions — the resolved (corrected) edition.
    edition: u32,
    is_variant: bool,
    /// Year as found in the court/date paren, and the validated integer
    /// (eyecite get_year: [1600, max_valid_year]; out-of-range keeps the
    /// text but nulls the number).
    year_text: ?[]const u8 = null,
    year: ?u16 = null,
    /// Raw court string from the paren — resolution to a courts-db id is a
    /// separate pass.
    court_paren: ?[]const u8 = null,
    /// Resolved courts-db court id (e.g. "ca4"), or "scotus" guessed from
    /// the reporter. Static string from the generated table.
    court: ?[]const u8 = null,

    /// Canonical reporter spelling (eyecite's corrected_reporter).
    pub fn correctedReporter(self: Citation) []const u8 {
        return reporters.editions[self.edition].abbrev;
    }
};

/// eyecite computes `date.today().year + 1` at import time; the core is
/// clockless, so the ceiling is a constant matched to the pinned oracle's
/// extraction date (2026). Bump alongside corpus re-extraction, or inject
/// via ExtractOptions when callers need a live clock.
pub const default_max_valid_year: u16 = 2027;

/// Extracts legal citations from plain text, eyecite-compatible.
///
/// Engine: scan for reporter-abbreviation anchors (sorted match table from
/// reporters-db), then run each candidate edition's compiled citation
/// pattern programs (build-time codegen from eyecite's regex templates)
/// around the anchor — PRE must end exactly at the anchor, POST continues
/// after it. Backtracking is bounded (counted classes + optionals only;
/// no general regex engine).
/// Returned slice is owned by the caller (free with `allocator.free`);
/// all string fields are zero-copy slices into `text`.
pub fn extract(allocator: std.mem.Allocator, text: []const u8) ![]Citation {
    return extractWithEngine(allocator, text, .vm);
}

pub fn extractWithEngine(
    allocator: std.mem.Allocator,
    text: []const u8,
    engine: Engine,
) ![]Citation {
    var cites: std.ArrayListUnmanaged(Citation) = .empty;
    errdefer cites.deinit(allocator);
    switch (engine) {
        .vm => try vmScan(allocator, text, &cites),
        .pcre2 => try pcre2Scan(allocator, text, &cites),
    }
    for (cites.items) |*c| finishCitation(text, c);
    return cites.toOwnedSlice(allocator);
}

fn vmScan(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!firstByteCandidate(text[i])) {
            i += 1;
            continue;
        }
        if (bestMatchAt(text, i)) |cite| {
            try cites.append(allocator, cite);
            i = cite.span_end;
            continue;
        }
        i += 1;
    }
}

fn pcre2Scan(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    const cands = try pcre2_engine.scan(allocator, text);
    defer allocator.free(cands);
    for (cands) |cand| {
        try cites.append(allocator, makeCitation(
            text,
            cand.start,
            cand.end,
            cand.volume,
            cand.reporter,
            cand.page,
            cand.edition,
            cand.is_variant,
        ));
    }
}

/// Shared post-candidate metadata: court/date paren, court resolution,
/// scotus guess, pre-citation year. Both engines converge here.
fn finishCitation(text: []const u8, c: *Citation) void {
    const post = parsePostCitation(text, c.span_end);
    c.year_text = post.year_text;
    c.year = post.year;
    c.court_paren = post.court;
    if (post.court) |paren_court| {
        c.court = resolveCourtByParen(paren_court);
    }
    // eyecite guess_court: SCOTUS reporters imply the court
    if (c.court == null and tables.editions[c.edition].is_scotus) {
        c.court = "scotus";
    }
    if (c.year == null) {
        if (preCiteYear(text, c.span_start)) |yt| {
            c.year_text = yt;
            c.year = std.fmt.parseInt(u16, yt, 10) catch unreachable;
        }
    }
}

fn makeCitation(
    text: []const u8,
    start: u32,
    end: u32,
    volume: ?[]const u8,
    reporter_found: []const u8,
    page_raw: ?[]const u8,
    edition: u32,
    is_variant: bool,
) Citation {
    // all-underscore page is a "known missing" placeholder: spanned, but null
    const page: ?[]const u8 = if (page_raw) |pg|
        (if (pg.len > 0 and pg[0] == '_') null else pg)
    else
        null;
    _ = text;
    return .{
        .kind = .full_case,
        .span_start = start,
        .span_end = end,
        .volume = volume,
        .reporter = reporter_found,
        .page = page,
        .edition = edition,
        .is_variant = is_variant,
    };
}

// ── Post-citation metadata (eyecite POST_FULL_CITATION_REGEX) ────────

const PostCitation = struct {
    year_text: ?[]const u8 = null,
    year: ?u16 = null,
    court: ?[]const u8 = null,
};

const MONTHS = [_][]const u8{
    "January",   "Jan.", "February", "Feb.",  "March",    "Mar.",
    "April",     "Apr.", "May",      "June",  "Jun.",     "July",
    "Jul.",      "August", "Aug.",   "September", "Sept.", "Sep.",
    "October",   "Oct.", "November", "Nov.",  "December", "Dec.",
};

/// Scans forward from the end of a citation for the court/date paren:
/// `[pin cite,]? extra [\(\[] court? month? day? YEAR [\)\]]`. The court is
/// everything in the paren before the whitespace that precedes a month or
/// the year (Python's lazy `.*?` + lookahead). The paren must close right
/// after the year or the whole branch fails (no year, no court).
fn parsePostCitation(text: []const u8, start: usize) PostCitation {
    // `extra` window: [^(;]* (newline = paragraph token boundary upstream)
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '(' or c == '[') break;
        if (c == ';' or c == '\n') return .{};
    }
    if (i >= text.len) return .{};
    const open = i;
    const close = blk: {
        var j = open + 1;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (c == ')' or c == ']') break :blk j;
            if (c == '\n') return .{};
        }
        return .{};
    };
    const inner = text[open + 1 .. close];

    // candidate positions: paren start, or after each whitespace run
    var p: usize = 0;
    while (p <= inner.len) {
        const at_start = p == 0;
        const after_ws = p > 0 and inner[p - 1] == ' ';
        if (at_start or after_ws) {
            if (tryDateAt(inner, p)) |date| {
                var court_end = p;
                while (court_end > 0 and inner[court_end - 1] == ' ') court_end -= 1;
                const court = inner[0..court_end];
                return .{
                    .year_text = date.year_text,
                    .year = date.year,
                    .court = if (court.len == 0) null else court,
                };
            }
        }
        p += 1;
    }
    return .{};
}

/// Maps a court paren string ("4th Cir.", "Pa.Super.") to a courts-db id,
/// mirroring eyecite get_court_by_paren: strip non-word chars + lowercase,
/// then exact match wins; otherwise the LAST prefix match in courts.json
/// file order (yes, last — replicated faithfully).
fn resolveCourtByParen(paren: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (paren) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (n == buf.len) return null; // pathological input: no match
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    if (n == 0) return null;
    const query = buf[0..n];

    var prefix_hit: ?[]const u8 = null;
    for (courts.courts) |court| {
        if (std.mem.eql(u8, court.norm, query)) return court.id;
        if (std.mem.startsWith(u8, court.norm, query)) prefix_hit = court.id;
    }
    return prefix_hit;
}

/// eyecite's median case-name backward-seek window, in words.
const BACKWARD_SEEK = 28;

/// California-style pre-citation year: scanning backward word-by-word from
/// the citation (eyecite _scan_for_case_boundaries), a word matching
/// `\(\d{4}\)...` records the year; terminal punctuation (; ” ") or an
/// opening paren after the 4th word stops the scan. The farthest-back match
/// within the window wins, mirroring eyecite's repeated assignment.
/// (Divergence note: eyecite applies this only when a candidate case name
/// is also found; we apply it whenever found — the differential gate will
/// quantify whether that ever matters in the wild.)
fn preCiteYear(text: []const u8, span_start: usize) ?[]const u8 {
    var year: ?[]const u8 = null;
    var end = span_start;
    var count: usize = 0;
    while (count < BACKWARD_SEEK) {
        while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
        if (end == 0) break;
        if (text[end - 1] == '\n') break; // paragraph boundary
        var start = end;
        while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) start -= 1;
        const word = text[start..end];
        if (std.mem.eql(u8, word, ",")) {
            end = start;
            continue;
        }
        count += 1;
        if (word.len >= 6 and word[0] == '(' and word[5] == ')' and
            allDigits(word[1..5]))
        {
            year = word[1..5];
        } else if (std.mem.endsWith(u8, word, ";") or
            std.mem.endsWith(u8, word, "\"") or
            std.mem.endsWith(u8, word, "\xe2\x80\x9d")) // ”
        {
            break;
        } else if (word[0] == '(' and count > 3) {
            break;
        }
        end = start;
    }
    return year;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

const ParsedDate = struct {
    year_text: []const u8,
    year: ?u16,
};

/// Matches `month? \ ? day? ,? \ ? year(-yy)?` ending exactly at the paren
/// close (i.e. at inner.len), with Python-style day backtracking (2, 1, 0
/// digits).
fn tryDateAt(inner: []const u8, start: usize) ?ParsedDate {
    var q = start;
    for (MONTHS) |m| {
        if (std.mem.startsWith(u8, inner[q..], m)) {
            q += m.len;
            if (q < inner.len and inner[q] == ' ') q += 1;
            break;
        }
    }
    var day_len: usize = 2;
    while (true) : (day_len -= 1) {
        var r = q;
        var ok = true;
        var k: usize = 0;
        while (k < day_len) : (k += 1) {
            if (r >= inner.len or !isDigit(inner[r])) {
                ok = false;
                break;
            }
            r += 1;
        }
        if (ok) {
            if (r < inner.len and inner[r] == ',') r += 1;
            if (r < inner.len and inner[r] == ' ') r += 1;
            if (tryYearAt(inner, r)) |date| return date;
        }
        if (day_len == 0) return null;
    }
}

fn tryYearAt(inner: []const u8, start: usize) ?ParsedDate {
    if (start + 4 > inner.len) return null;
    for (inner[start .. start + 4]) |c| {
        if (!isDigit(c)) return null;
    }
    var end = start + 4;
    // optional range suffix "-94"
    if (end + 3 <= inner.len and inner[end] == '-' and
        isDigit(inner[end + 1]) and isDigit(inner[end + 2]))
    {
        end += 3;
    }
    if (end != inner.len) return null; // paren must close right after
    const year_text = inner[start .. start + 4];
    const y = std.fmt.parseInt(u16, year_text, 10) catch return null;
    return .{
        .year_text = year_text,
        .year = if (y >= 1600 and y <= default_max_valid_year) y else null,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn firstByteCandidate(c: u8) bool {
    return tables.key_first_bytes[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0;
}

/// All candidate citations anchored at reporter hits starting at `i`;
/// returns the one with the earliest start, then the longest end.
fn bestMatchAt(text: []const u8, i: usize) ?Citation {
    var best: ?Citation = null;
    const max_len = @min(text.len - i, tables.max_key_len);
    var key_len: usize = max_len;
    while (key_len > 0) : (key_len -= 1) {
        const entries = reporters.lookup(text[i .. i + key_len]);
        for (entries) |*entry| {
            const edition = tables.editions[entry.edition];
            for (edition.programs) |pid| {
                const prog = tables.programs[pid];
                if (prog.pre_min > prog.pre_max) continue; // unanchored placeholder
                if (tryProgram(text, i, key_len, prog)) |hit| {
                    if (best == null or
                        hit.start < best.?.span_start or
                        (hit.start == best.?.span_start and hit.end > best.?.span_end))
                    {
                        best = makeCitation(
                            text,
                            hit.start,
                            hit.end,
                            hit.volume,
                            text[i .. i + key_len],
                            hit.page,
                            entry.edition,
                            entry.is_variant,
                        );
                    }
                }
            }
        }
    }
    return best;
}

const ProgramHit = struct {
    start: u32,
    end: u32,
    volume: ?[]const u8,
    page: ?[]const u8,
};

const Captures = struct {
    start: [tables.group_count]?u32 = @splat(null),
    end: [tables.group_count]?u32 = @splat(null),

    fn slice(self: *const Captures, text: []const u8, g: tables.Group) ?[]const u8 {
        const gi = @intFromEnum(g);
        const s = self.start[gi] orelse return null;
        const e = self.end[gi] orelse return null;
        return text[s..e];
    }
};

fn tryProgram(text: []const u8, anchor: usize, key_len: usize, prog: tables.Program) ?ProgramHit {
    const lo = anchor -| @as(usize, prog.pre_max);
    const hi = anchor -| @as(usize, prog.pre_min);
    var s = lo;
    while (s <= hi) : (s += 1) {
        // leading boundary (eyecite nonalphanum_boundaries_re)
        if (s > 0 and std.ascii.isAlphanumeric(text[s - 1])) continue;
        var caps: Captures = .{};
        // PRE must consume exactly [s, anchor)
        if (matchSeq(prog.pre, text, s, anchor, &caps) == null) continue;
        // POST continues after the anchored reporter key
        const post_end = matchSeq(prog.post, text, anchor + key_len, null, &caps) orelse continue;
        // trailing boundary
        if (post_end < text.len and std.ascii.isAlphanumeric(text[post_end])) continue;

        return .{
            .start = @intCast(s),
            .end = @intCast(post_end),
            .volume = caps.slice(text, .volume),
            .page = caps.slice(text, .page),
        };
    }
    return null;
}

// ── Pattern VM: bounded-backtracking interpreter ─────────────────────

const MAX_FRAMES = 24;

const Frame = struct {
    seq: []const tables.Insn,
    idx: usize,
};

/// Matches `seq` forward from `pos`. When `require_end` is set, the match
/// must consume exactly up to that offset (used to pin PRE to the anchor).
/// Returns the end offset on success.
fn matchSeq(
    seq: []const tables.Insn,
    text: []const u8,
    pos: usize,
    require_end: ?usize,
    caps: *Captures,
) ?usize {
    var frames: [MAX_FRAMES]Frame = undefined;
    frames[0] = .{ .seq = seq, .idx = 0 };
    return run(&frames, 1, text, pos, require_end, caps);
}

fn run(
    frames: *[MAX_FRAMES]Frame,
    depth: usize,
    text: []const u8,
    pos: usize,
    require_end: ?usize,
    caps: *Captures,
) ?usize {
    // find the next instruction across the frame stack
    var d = depth;
    while (d > 0 and frames[d - 1].idx == frames[d - 1].seq.len) d -= 1;
    if (d == 0) {
        if (require_end) |e| return if (pos == e) pos else null;
        return pos;
    }
    const frame = frames[d - 1];
    const insn = frame.seq[frame.idx];
    frames[d - 1].idx += 1;
    defer frames[d - 1] = frame; // restore on unwind for sibling retries

    switch (insn) {
        .lit => |l| {
            if (pos + l.len <= text.len and std.mem.eql(u8, text[pos .. pos + l.len], l)) {
                return run(frames, d, text, pos + l.len, require_end, caps);
            }
            return null;
        },
        .class => |c| {
            var avail: usize = 0;
            while (avail < c.max and pos + avail < text.len and
                classHas(c, text[pos + avail])) avail += 1;
            if (avail < c.min) return null;
            // greedy with backtrack
            var k = avail;
            while (true) {
                if (run(frames, d, text, pos + k, require_end, caps)) |end| return end;
                if (k == c.min) return null;
                k -= 1;
            }
        },
        .open => |g| {
            const saved = caps.start[g];
            caps.start[g] = @intCast(pos);
            if (run(frames, d, text, pos, require_end, caps)) |end| return end;
            caps.start[g] = saved;
            return null;
        },
        .close => |g| {
            const saved = caps.end[g];
            caps.end[g] = @intCast(pos);
            if (run(frames, d, text, pos, require_end, caps)) |end| return end;
            caps.end[g] = saved;
            return null;
        },
        .alt => |branches| {
            if (d >= MAX_FRAMES) return null; // depth guard (generated data is shallow)
            for (branches) |b| {
                frames[d] = .{ .seq = b, .idx = 0 };
                if (run(frames, d + 1, text, pos, require_end, caps)) |end| return end;
            }
            return null;
        },
        .opt => |body| {
            if (d >= MAX_FRAMES) return null;
            frames[d] = .{ .seq = body, .idx = 0 };
            if (run(frames, d + 1, text, pos, require_end, caps)) |end| return end;
            return run(frames, d, text, pos, require_end, caps);
        },
    }
}

fn classHas(c: tables.Class, ch: u8) bool {
    return c.bits[ch >> 6] & (@as(u64, 1) << @intCast(ch & 63)) != 0;
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

test "roman numeral page" {
    try expectSingleFullCite("1 U.S. xv", 0, 9, "1", "U.S.", "xv", "U.S.");
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

test "format-neutral: 2006-Ohio-2095" {
    try expectSingleFullCite("2006-Ohio-2095", 0, 14, "2006", "Ohio", "2095", "Ohio");
}

test "format-neutral 3-4 digit page: 2007-NMCERT-008" {
    try expectSingleFullCite("2007-NMCERT-008", 0, 15, "2007", "NMCERT", "008", "NMCERT");
}

test "illinois neutral: 2017 IL App (1st) 143684-B" {
    try expectSingleFullCite("2017 IL App (1st) 143684-B", 0, 26, "2017", "IL App (1st)", "143684-B", "IL App (1st)");
}

test "year-volume with suffixed page: 1993 Conn. Super. Ct. 5243-P" {
    try expectSingleFullCite("Failed to recognize 1993 Conn. Super. Ct. 5243-P", 20, 48, "1993", "Conn. Super. Ct.", "5243-P", "Conn. Super. Ct.");
}

test "year_page: T.C. Memo. 2019-233" {
    try expectSingleFullCite("word T.C. Memo. 2019-233", 5, 24, "2019", "T.C. Memo.", "233", "T.C. Memo.");
}

test "year_page multiword reporter: T.C. Summary Opinion 2018-133" {
    try expectSingleFullCite("T.C. Summary Opinion 2018-133", 0, 29, "2018", "T.C. Summary Opinion", "133", "T.C. Summary Opinion");
}

test "CCH paragraph cite: volume-less with comma page" {
    const cites = try extract(testing.allocator, "blah blah Bankr. L. Rep. (CCH) P12,345. blah blah");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(@as(u32, 10), c.span_start);
    try testing.expectEqual(@as(u32, 38), c.span_end);
    try testing.expectEqual(@as(?[]const u8, null), c.volume);
    try testing.expectEqualStrings("Bankr. L. Rep. (CCH)", c.reporter);
    try testing.expectEqualStrings("12,345", c.page.?);
    try testing.expectEqualStrings("Bankr. L. Rep.", c.correctedReporter());
}

test "louisiana format: 2009 12345 (La.App. 1 Cir. 05/10/10)" {
    const cites = try extract(testing.allocator, "blah blah, 2009 12345 (La.App. 1 Cir. 05/10/10). blah blah");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(@as(u32, 11), c.span_start);
    try testing.expectEqual(@as(u32, 47), c.span_end);
    try testing.expectEqualStrings("2009", c.volume.?);
    try testing.expectEqualStrings("La.App. 1 Cir.", c.reporter);
    try testing.expectEqualStrings("12345", c.page.?);
}

test "custom-shape editions do not match the standard shape: 1 T.C. Memo. 5" {
    // T.C. Memo.'s template list replaces $full_cite entirely
    const cites = try extract(testing.allocator, "1 T.C. Memo. 5");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "year from simple paren: (1982)" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (1982)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("1982", cites[0].year_text.?);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].court_paren);
}

test "year and court from paren: (4th Cir. 1982)" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (4th Cir. 1982)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("4th Cir.", cites[0].court_paren.?);
}

test "year and court without space: (Pa.Super. 1982)" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (Pa.Super. 1982)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("Pa.Super.", cites[0].court_paren.?);
}

test "misformatted year yields no year: (198⁴)" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (198⁴)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "no paren yields no year" {
    const cites = try extract(testing.allocator, "1 U.S. 1");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "out-of-range year: text kept, numeric year null (eyecite get_year parity)" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1500)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
    try testing.expectEqualStrings("1500", cites[0].year_text.?);
}

test "year not at paren end is rejected: (1982 Pa.)" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1982 Pa.)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "court resolution: (4th Cir. 1982) -> ca4" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (4th Cir. 1982)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("ca4", cites[0].court.?);
}

test "court resolution without internal space: (Pa.Super. 1982) -> pasuperct" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (Pa.Super. 1982)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("pasuperct", cites[0].court.?);
}

test "court resolution exact: (Pa. 2017) -> pa" {
    const cites = try extract(testing.allocator, "Commonwealth v. Muniz, 164 A.3d 1189 (Pa. 2017)");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("pa", cites[0].court.?);
}

test "scotus guessed from reporter without paren (guess_court parity)" {
    const cites = try extract(testing.allocator, "1 U.S. 1");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("scotus", cites[0].court.?);
}

test "non-scotus reporter without paren has no court" {
    const cites = try extract(testing.allocator, "1 F.2d 1");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].court);
}

test "pcre2 engine agrees with vm engine on representative citations" {
    const samples = [_][]const u8{
        "Lissner v. Test, 1 U.S. 1 (1982)",
        "bob Lissner v. Test 1 F.2d 1 (1982)",
        "2006-Ohio-2095",
        "blah blah Bankr. L. Rep. (CCH) P12,345. blah blah",
        "word T.C. Memo. 2019-233",
        "see 1 U.S. 1; also 2 F.2d 3.",
        "the 3 musketeers met 4 friends in 1982",
        "lorem 111 S.W. 12th St.",
    };
    for (samples) |text| {
        const vm_cites = try extractWithEngine(testing.allocator, text, .vm);
        defer testing.allocator.free(vm_cites);
        const p_cites = try extractWithEngine(testing.allocator, text, .pcre2);
        defer testing.allocator.free(p_cites);
        try testing.expectEqual(vm_cites.len, p_cites.len);
        for (vm_cites, p_cites) |a, b| {
            try testing.expectEqual(a.span_start, b.span_start);
            try testing.expectEqual(a.span_end, b.span_end);
            try testing.expectEqual(a.edition, b.edition);
            try testing.expectEqual(a.year, b.year);
            try testing.expectEqualStrings(a.correctedReporter(), b.correctedReporter());
        }
    }
}

test "two citations in one string" {
    const cites = try extract(testing.allocator, "see 1 U.S. 1; also 2 F.2d 3.");
    defer testing.allocator.free(cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("U.S.", cites[0].reporter);
    try testing.expectEqualStrings("F.2d", cites[1].reporter);
}
