const std = @import("std");
const reporters = @import("reporters.zig");
const tables = @import("reporters_tables");
const courts = @import("courts_tables");
const enable_pcre2 = @import("build_options").enable_pcre2;
const pcre2_engine = if (enable_pcre2) @import("pcre2_engine.zig") else struct {};
const case_name = @import("case_name.zig");

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
    /// Pin cite (clean_pin_cite semantics: raw capture stripped of leading/
    /// trailing commas and spaces). Slice into the input text.
    pin_cite: ?[]const u8 = null,
    /// Parenthetical comment after the court/date paren, e.g.
    /// "overruling foo" — process_parenthetical trimming applied.
    parenthetical: ?[]const u8 = null,
    /// Text between the pin cite and the court/date paren (often parallel
    /// citations), whitespace-stripped.
    extra: ?[]const u8 = null,
    /// Case-name parties (find_case_name backward scan). ALLOCATED — free
    /// via freeCitations, not allocator.free on the slice alone.
    plaintiff: ?[]const u8 = null,
    defendant: ?[]const u8 = null,
    /// Short-form antecedent ("Foo" in "Foo, 1 U.S., at 5"). ALLOCATED.
    antecedent_guess: ?[]const u8 = null,
    /// Volume before a supra token ("123" in "asdf, 123 supra"). Slice.
    supra_volume: ?[]const u8 = null,
    /// Law-citation publisher from the trailing paren ("West", "Lexis
    /// Supp."). Slice.
    publisher: ?[]const u8 = null,
    /// Full extent including case name/antecedent (eyecite full_span);
    /// defaults to the core span when nothing extends it.
    full_span_start: u32 = 0,
    full_span_end: u32 = 0,

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
        .pcre2 => if (enable_pcre2) try pcre2Scan(allocator, text, &cites) else return error.Pcre2Disabled,
    }
    try tokenScan(allocator, text, &cites);
    mergeCites(&cites);
    for (cites.items, 0..) |*c, i| try finishCitation(allocator, text, cites.items, i, c);
    try referenceScan(allocator, text, &cites);
    try filterCitations(allocator, text, &cites);
    return cites.toOwnedSlice(allocator);
}

/// Frees a citation slice including the allocated case-name strings.
pub fn freeCitations(allocator: std.mem.Allocator, cites: []Citation) void {
    for (cites) |c| {
        if (c.plaintiff) |p| allocator.free(p);
        if (c.defendant) |d| allocator.free(d);
        if (c.antecedent_guess) |a| allocator.free(a);
    }
    allocator.free(cites);
}

/// Merge engine candidates and id/supra tokens into the canonical list: sort
/// by (earliest start, longest end), drop overlaps, seed full_span = span.
/// Factored out of extractWithEngine so the per-phase benchmark reproduces the
/// exact same candidate-merge step.
fn mergeCites(cites: *std.ArrayListUnmanaged(Citation)) void {
    std.mem.sort(Citation, cites.items, {}, citeLessThan);
    var n: usize = 0;
    var last_end: u32 = 0;
    for (cites.items) |c| {
        if (n == 0 or c.span_start >= last_end) {
            cites.items[n] = c;
            last_end = c.span_end;
            n += 1;
        }
    }
    cites.shrinkRetainingCapacity(n);
    for (cites.items) |*c| {
        c.full_span_start = c.span_start;
        c.full_span_end = c.span_end;
    }
}

/// Per-key-function wall-clock timings (ns/iter) for the extraction pipeline.
/// CLAUDE.md mandates benchmarking "over key functions" and flagging sudden
/// deltas — a single end-to-end number hid the referenceScan O(cites×text)
/// quadratic until it dominated. Each phase is timed in isolation with its
/// input reset every iteration (the reset is untimed). resolve + end-to-end
/// total are timed by the bench harness (resolve lives downstream of here).
pub const PhaseNs = struct {
    match: u64, // vmScan + tokenScan + merge — reporter-anchor candidate finding
    finish: u64, // finishCitation loop — case-name backward walk + metadata
    reference: u64, // referenceScan — pincited-reference scan (the guarded phase)
    filter: u64, // filterCitations — overlap/containment dedup
};

/// Times each extraction phase in isolation `iters` times; see PhaseNs.
pub fn benchPhases(io: std.Io, allocator: std.mem.Allocator, text: []const u8, iters: usize) !PhaseNs {
    const List = std.ArrayListUnmanaged(Citation);
    var r: PhaseNs = .{ .match = 0, .finish = 0, .reference = 0, .filter = 0 };

    // ---- match: fresh candidate list each iteration ----
    {
        var acc: u64 = 0;
        for (0..iters) |_| {
            var cites: List = .empty;
            defer cites.deinit(allocator);
            const s = std.Io.Timestamp.now(io, .awake);
            try vmScan(allocator, text, &cites);
            try tokenScan(allocator, text, &cites);
            mergeCites(&cites);
            const e = std.Io.Timestamp.now(io, .awake);
            acc += @intCast(e.nanoseconds - s.nanoseconds);
            std.mem.doNotOptimizeAway(cites.items.len);
        }
        r.match = acc / iters;
    }

    // Snapshot the post-merge state (input to finishCitation).
    var merged: List = .empty;
    defer merged.deinit(allocator);
    try vmScan(allocator, text, &merged);
    try tokenScan(allocator, text, &merged);
    mergeCites(&merged);
    const merge_snap = try allocator.dupe(Citation, merged.items);
    defer allocator.free(merge_snap);

    // Reusable work list; reset (untimed) from a snapshot before each phase run.
    var work: List = .empty;
    defer work.deinit(allocator);
    try work.ensureTotalCapacity(allocator, merge_snap.len + 1);

    // ---- finish: post-merge snapshot → finishCitation loop ----
    {
        var acc: u64 = 0;
        for (0..iters) |_| {
            work.clearRetainingCapacity();
            work.appendSliceAssumeCapacity(merge_snap);
            const s = std.Io.Timestamp.now(io, .awake);
            for (work.items, 0..) |*c, i| try finishCitation(allocator, text, work.items, i, c);
            const e = std.Io.Timestamp.now(io, .awake);
            acc += @intCast(e.nanoseconds - s.nanoseconds);
        }
        r.finish = acc / iters;
    }

    // Snapshot the post-finish state (input to referenceScan / filter).
    work.clearRetainingCapacity();
    work.appendSliceAssumeCapacity(merge_snap);
    for (work.items, 0..) |*c, i| try finishCitation(allocator, text, work.items, i, c);
    const finish_snap = try allocator.dupe(Citation, work.items);
    defer allocator.free(finish_snap);

    // ---- reference: post-finish snapshot → referenceScan (it appends) ----
    {
        var acc: u64 = 0;
        for (0..iters) |_| {
            work.clearRetainingCapacity();
            work.appendSliceAssumeCapacity(finish_snap);
            const s = std.Io.Timestamp.now(io, .awake);
            try referenceScan(allocator, text, &work);
            const e = std.Io.Timestamp.now(io, .awake);
            acc += @intCast(e.nanoseconds - s.nanoseconds);
        }
        r.reference = acc / iters;
    }

    // Snapshot the post-reference state (input to filter).
    work.clearRetainingCapacity();
    work.appendSliceAssumeCapacity(finish_snap);
    try referenceScan(allocator, text, &work);
    const ref_snap = try allocator.dupe(Citation, work.items);
    defer allocator.free(ref_snap);
    try work.ensureTotalCapacity(allocator, ref_snap.len + 1);

    // ---- filter: post-reference snapshot → filterCitations ----
    {
        var acc: u64 = 0;
        for (0..iters) |_| {
            work.clearRetainingCapacity();
            work.appendSliceAssumeCapacity(ref_snap);
            const s = std.Io.Timestamp.now(io, .awake);
            try filterCitations(allocator, text, &work);
            const e = std.Io.Timestamp.now(io, .awake);
            acc += @intCast(e.nanoseconds - s.nanoseconds);
        }
        r.filter = acc / iters;
    }

    return r;
}
/// Matcher candidate-scan: one left-to-right pass over the text; a first-byte
/// bitset gate then a bounded per-anchor probe (prefix-narrowing match-table
/// walk, see reporters.matchesAt). complexity: O(n)
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
    // comptime-gated: when enable_pcre2 is false (e.g. the WASM target) this
    // body is not analyzed, so the empty pcre2_engine stub is never touched.
    if (enable_pcre2) {
        const cands = try pcre2_engine.scan(allocator, text);
        defer allocator.free(cands);
        for (cands) |cand| {
            var c = makeCitation(
                text,
                cand.start,
                cand.end,
                cand.volume,
                cand.reporter,
                cand.page,
                cand.edition,
                cand.is_variant,
            );
            if (cand.short) {
                c.kind = .short_case;
            } else c.kind = switch (tables.editions[cand.edition].source) {
                .reporters => .full_case,
                .journals => .full_journal,
                .laws => .full_law,
            };
            try cites.append(allocator, c);
        }
    } else unreachable;
}

const RefHit = struct { pos: u32, end: u32, pin: ?[]const u8 };

/// Every position where `name` occurs at a word boundary immediately followed
/// by whitespace + a valid pin cite — i.e. every place `name` could anchor a
/// pincited reference. Scanned ONCE per unique name (memchr-speed indexOf) and
/// shared across all citations bearing it. Returned slice is allocator-owned.
fn buildRefHits(allocator: std.mem.Allocator, text: []const u8, name: []const u8) ![]const RefHit {
    var hits: std.ArrayListUnmanaged(RefHit) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |occ| {
        pos = occ + 1;
        if (occ != 0 and isWordChar(text[occ - 1])) continue; // \b before name
        var q = occ + name.len;
        if (q >= text.len or !std.ascii.isWhitespace(text[q])) continue; // \s+
        while (q < text.len and std.ascii.isWhitespace(text[q])) q += 1;
        const pin = parsePinCite(text, q) orelse continue;
        try hits.append(allocator, .{ .pos = @intCast(occ), .end = @intCast(pin.end), .pin = pin.cleaned });
    }
    return hits.toOwnedSlice(allocator);
}

/// eyecite extract_pincited_reference_citations: for each FullCaseCitation,
/// emit a ReferenceCitation wherever a valid party name recurs ahead of it
/// followed by a pin cite. SURPASS over eyecite's (and our old) per-citation
/// full-text rescan: each unique name's valid-hit positions are scanned ONCE
/// and cached, so cost is O(unique_names × text) instead of
/// O(full_case_cites × text) — no longer quadratic on repetition-heavy input
/// (treatises, the perf corpus). Output is byte-identical to referenceScanRef
/// (guarded by the equivalence test below).
fn referenceScan(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    const original_len = cites.items.len;
    if (original_len == 0) return;
    var cache: std.StringHashMapUnmanaged([]const RefHit) = .empty;
    defer {
        // free the per-name hit slices the map owns (keys are borrowed name
        // slices, not freed here); no-op cost under an arena, required under GPA.
        var vit = cache.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        cache.deinit(allocator);
    }

    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        const c = cites.items[i];
        if (c.kind != .full_case) continue;
        // name_fields order: plaintiff, then defendant (resolved names unsupported)
        const NameRole = struct { name: []const u8, is_plaintiff: bool };
        var names: [2]NameRole = undefined;
        var n_names: usize = 0;
        if (c.plaintiff) |p| {
            if (isValidName(p)) {
                names[n_names] = .{ .name = p, .is_plaintiff = true };
                n_names += 1;
            }
        }
        if (c.defendant) |d| {
            if (isValidName(d)) {
                names[n_names] = .{ .name = d, .is_plaintiff = false };
                n_names += 1;
            }
        }
        if (n_names == 0) continue;

        // Fetch/build each name's cached valid-hit list (dedup across citations).
        var lists: [2][]const RefHit = .{ &.{}, &.{} };
        for (names[0..n_names], 0..) |nr, k| {
            const gop = try cache.getOrPut(allocator, nr.name);
            if (!gop.found_existing) gop.value_ptr.* = try buildRefHits(allocator, text, nr.name);
            lists[k] = gop.value_ptr.*;
        }

        // Greedy left-to-right merge of the names' hits at positions ≥ span_end,
        // plaintiff-priority on a tie, jumping past each emitted reference —
        // byte-identical to the old per-position forward scan.
        var cursor: u32 = c.span_end;
        var idx: [2]usize = .{ 0, 0 };
        while (true) {
            var best_k: ?usize = null;
            var best_pos: u32 = std.math.maxInt(u32);
            for (0..n_names) |k| {
                while (idx[k] < lists[k].len and lists[k][idx[k]].pos < cursor) idx[k] += 1;
                if (idx[k] < lists[k].len and lists[k][idx[k]].pos < best_pos) {
                    best_pos = lists[k][idx[k]].pos;
                    best_k = k;
                }
            }
            const k = best_k orelse break;
            const hit = lists[k][idx[k]];
            const nr = names[k];
            try cites.append(allocator, .{
                .kind = .reference,
                .span_start = hit.pos,
                .span_end = hit.end,
                .volume = null,
                .reporter = text[hit.pos..hit.end],
                .page = null,
                .edition = 0,
                .is_variant = false,
                .pin_cite = hit.pin,
                .plaintiff = if (nr.is_plaintiff) try allocator.dupe(u8, nr.name) else null,
                .defendant = if (nr.is_plaintiff) null else try allocator.dupe(u8, nr.name),
                .full_span_start = hit.pos,
                .full_span_end = hit.end,
            });
            cursor = hit.end;
        }
    }
}

/// Reference implementation of referenceScan: the original per-citation
/// full-text scan (O(cites × text)). Kept ONLY as the independent oracle for
/// the equivalence test — the cached referenceScan must match it
/// append-for-append.
fn referenceScanRef(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    const original_len = cites.items.len;
    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        const c = cites.items[i];
        if (c.kind != .full_case) continue;
        const NameRole = struct { name: []const u8, is_plaintiff: bool };
        var names: [2]NameRole = undefined;
        var n_names: usize = 0;
        if (c.plaintiff) |p| {
            if (isValidName(p)) {
                names[n_names] = .{ .name = p, .is_plaintiff = true };
                n_names += 1;
            }
        }
        if (c.defendant) |d| {
            if (isValidName(d)) {
                names[n_names] = .{ .name = d, .is_plaintiff = false };
                n_names += 1;
            }
        }
        if (n_names == 0) continue;

        var pos: usize = c.span_end;
        while (pos < text.len) {
            const at_boundary = pos == 0 or !isWordChar(text[pos - 1]);
            if (at_boundary) {
                var matched = false;
                for (names[0..n_names]) |nr| {
                    if (!std.mem.startsWith(u8, text[pos..], nr.name)) continue;
                    var q = pos + nr.name.len;
                    if (q >= text.len or !std.ascii.isWhitespace(text[q])) continue;
                    while (q < text.len and std.ascii.isWhitespace(text[q])) q += 1;
                    const pin = parsePinCite(text, q) orelse continue;
                    try cites.append(allocator, .{
                        .kind = .reference,
                        .span_start = @intCast(pos),
                        .span_end = @intCast(pin.end),
                        .volume = null,
                        .reporter = text[pos..pin.end],
                        .page = null,
                        .edition = 0,
                        .is_variant = false,
                        .pin_cite = pin.cleaned,
                        .plaintiff = if (nr.is_plaintiff) try allocator.dupe(u8, nr.name) else null,
                        .defendant = if (nr.is_plaintiff) null else try allocator.dupe(u8, nr.name),
                        .full_span_start = @intCast(pos),
                        .full_span_end = @intCast(pin.end),
                    });
                    pos = pin.end;
                    matched = true;
                    break;
                }
                if (matched) continue;
            }
            pos += 1;
        }
    }
}

test "referenceScan (cached) matches the per-citation oracle on repeated names" {
    // Arena: the surpass and the oracle each dupe reference name strings; we
    // only care about output equality here, not leak-freedom (tested elsewhere).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Repeated party names with later pin-cite references — the path the cache
    // changes (eyecite-distinct-corpus tests never exercise name recurrence).
    const text =
        "Smith v. Jones, 1 U.S. 1 (1990). Smith at 5; Jones at 9. " ++
        "Smith v. Jones, 2 U.S. 2 (1991). Smith at 7. Jones at 3. " ++
        "Brown v. Board, 3 U.S. 3 (1992). Brown at 11. Smith at 99. Board at 2.";
    var base: std.ArrayListUnmanaged(Citation) = .empty;
    try vmScan(a, text, &base);
    try tokenScan(a, text, &base);
    mergeCites(&base);
    for (base.items, 0..) |*c, i| try finishCitation(a, text, base.items, i, c);
    const base_len = base.items.len;

    var la = try base.clone(a);
    var lb = try base.clone(a);
    try referenceScanRef(a, text, &la);
    try referenceScan(a, text, &lb);

    try std.testing.expectEqual(la.items.len, lb.items.len);
    // there must actually BE references (otherwise the test is vacuous)
    try std.testing.expect(la.items.len > base_len);
    for (la.items[base_len..], lb.items[base_len..]) |ra, rb| {
        try std.testing.expectEqual(ra.span_start, rb.span_start);
        try std.testing.expectEqual(ra.span_end, rb.span_end);
        try std.testing.expectEqualStrings(ra.pin_cite orelse "", rb.pin_cite orelse "");
        try std.testing.expectEqualStrings(ra.plaintiff orelse "", rb.plaintiff orelse "");
        try std.testing.expectEqualStrings(ra.defendant orelse "", rb.defendant orelse "");
    }
}

/// eyecite is_valid_name: >2 chars, starts uppercase, not ending in '.', not
/// all digits, and not a disallowed name. We implement only the working
/// lowercase disallow set — NOT eyecite's ~80 Attorney-General surnames,
/// which are dead code there (capitalized entries vs a .lower() compare) and
/// whose intent (exclude common surnames) would, if activated, drop REAL
/// references like "Smith at 5" referring to "Smith v. Jones". This is a
/// reasoned correctness choice, not bug-replication — see
/// docs/principled_divergences.md section 2.
fn isValidName(name: []const u8) bool {
    if (name.len <= 2) return false;
    if (!(name[0] >= 'A' and name[0] <= 'Z')) return false;
    if (name[name.len - 1] == '.') return false;
    var all_digits = true;
    for (name) |ch| {
        if (!isDigit(ch)) all_digits = false;
    }
    if (all_digits) return false;
    return !isDisallowedName(name);
}

fn isDisallowedName(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |ch, k| buf[k] = std.ascii.toLower(ch);
    const lower = buf[0..name.len];
    // Only eyecite's EFFECTIVE lowercase exclusions. Its ~80 AG surnames are
    // dead code (see isValidName); its "commissioner" entry was typo-joined
    // to "commissionerAkerman" by a missing comma and can never match a real
    // name, so it is dead too — dropped rather than carried as noise.
    const disallowed = [_][]const u8{
        "state", "united states", "people", "commonwealth", "mass",
    };
    for (disallowed) |d| {
        if (std.mem.eql(u8, lower, d)) return true;
    }
    return false;
}

fn citeLessThan(_: void, a: Citation, b: Citation) bool {
    if (a.span_start != b.span_start) return a.span_start < b.span_start;
    return a.span_end > b.span_end;
}

/// eyecite filter_citations: dedupe by span (last wins), order by full_span,
/// then resolve overlaps — a supra overlapping a preceding short cite's full
/// span is dropped; a citation named inside the previous parenthetical is
/// kept; everything else coexists (parallel cites).
fn filterCitations(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    const items = cites.items;
    if (items.len == 0) return;
    // dedupe by exact span, last occurrence wins (Python dict semantics).
    // O(n) via a span -> last-index map; the old pairwise scan was O(n²) and
    // dominated runtime on citation-dense input. complexity: O(n)
    var last_idx: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer last_idx.deinit(allocator);
    for (items, 0..) |c, i| {
        const key = (@as(u64, c.span_start) << 32) | @as(u64, c.span_end);
        try last_idx.put(allocator, key, i); // last write wins → max index per span
    }
    var n: usize = 0;
    for (items, 0..) |c, i| {
        const key = (@as(u64, c.span_start) << 32) | @as(u64, c.span_end);
        if (last_idx.get(key).? == i) {
            items[n] = c;
            n += 1;
        } else {
            freeCitationStrings(allocator, c);
        }
    }
    cites.shrinkRetainingCapacity(n);

    std.mem.sort(Citation, cites.items, {}, fullSpanLessThan);

    var kept: usize = 0;
    for (cites.items) |c| {
        if (kept > 0) {
            const last = cites.items[kept - 1];
            const overlapping = @max(c.full_span_start, last.full_span_start) <
                @min(c.full_span_end, last.full_span_end);
            if (overlapping) {
                // eyecite filter_citations overlap order: prefer anything to
                // a reference citation, then drop supra over short.
                if (last.kind == .reference) {
                    freeCitationStrings(allocator, last);
                    cites.items[kept - 1] = c; // current replaces the dropped reference
                    continue;
                }
                if (c.kind == .reference) {
                    freeCitationStrings(allocator, c);
                    continue;
                }
                if (c.kind == .supra and last.kind == .short_case) {
                    freeCitationStrings(allocator, c);
                    continue;
                }
            }
        }
        cites.items[kept] = c;
        kept += 1;
    }
    _ = text;
    cites.shrinkRetainingCapacity(kept);
}

fn fullSpanLessThan(_: void, a: Citation, b: Citation) bool {
    if (a.full_span_start != b.full_span_start) return a.full_span_start < b.full_span_start;
    return a.full_span_end < b.full_span_end;
}

fn freeCitationStrings(allocator: std.mem.Allocator, c: Citation) void {
    if (c.plaintiff) |p| allocator.free(p);
    if (c.defendant) |d| allocator.free(d);
    if (c.antecedent_guess) |a| allocator.free(a);
}

/// Scans for id./ibid. and supra tokens (space-bounded, case-insensitive,
/// punctuation shells included in the span — eyecite ID_REGEX/SUPRA_REGEX).
fn tokenScan(
    allocator: std.mem.Allocator,
    text: []const u8,
    cites: *std.ArrayListUnmanaged(Citation),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        // word start at text start or after whitespace
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        var we = i;
        while (we < text.len and !std.ascii.isWhitespace(text[we])) we += 1;
        const word = text[i..we];
        defer i = we;

        // ID_REGEX: (id\.,?|ibid\.) — token must end at a \s|$ boundary
        if (std.ascii.startsWithIgnoreCase(word, "ibid.")) {
            if (word.len == 5) {
                try cites.append(allocator, tokenCitation(.id, i, i + 5, text));
                continue;
            }
        } else if (std.ascii.startsWithIgnoreCase(word, "id.")) {
            const tok_len: usize = if (word.len >= 4 and word[3] == ',') 4 else 3;
            if (word.len == tok_len) {
                try cites.append(allocator, tokenCitation(.id, i, i + tok_len, text));
                continue;
            }
        }
        // SECTION_REGEX (\S*[section-sign]\S*): any word containing a
        // section sign becomes an UnknownCitation token (SectionToken)
        if (std.mem.indexOf(u8, word, "\xc2\xa7") != null) {
            try cites.append(allocator, tokenCitation(.unknown, i, we, text));
            continue;
        }
        // SUPRA_REGEX: punct* supra punct* spanning the whole word
        var cs: usize = 0;
        while (cs < word.len and !std.ascii.isAlphanumeric(word[cs])) cs += 1;
        var ce = word.len;
        while (ce > cs and !std.ascii.isAlphanumeric(word[ce - 1])) ce -= 1;
        if (std.ascii.eqlIgnoreCase(word[cs..ce], "supra")) {
            try cites.append(allocator, tokenCitation(.supra, i, we, text));
        }
    }
}

fn tokenCitation(kind: Kind, start: usize, end: usize, text: []const u8) Citation {
    return .{
        .kind = kind,
        .span_start = @intCast(start),
        .span_end = @intCast(end),
        .volume = null,
        .reporter = text[start..end],
        .page = null,
        .edition = 0, // meaningless for non-case tokens; never exposed
        .is_variant = false,
    };
}

/// Shared post-candidate metadata: pin cite, court/date paren, court
/// resolution, scotus guess, case names + pre-citation year. Both engines
/// converge here.
fn finishCitation(
    allocator: std.mem.Allocator,
    text: []const u8,
    all: []const Citation,
    self_idx: usize,
    c: *Citation,
) !void {
    switch (c.kind) {
        .full_law => {
            finishLawCitation(text, c);
            return;
        },
        .full_journal => {
            finishJournalCitation(text, c);
            return;
        },
        .full_case => {
            const post = parsePostCitation(text, c.span_end);
            c.year_text = post.year_text;
            c.year = post.year;
            c.court_paren = post.court;
            c.pin_cite = post.pin_cite;
            c.parenthetical = post.parenthetical;
            c.extra = post.extra;
            if (post.court) |paren_court| {
                c.court = resolveCourtByParen(paren_court);
            }
        },
        .short_case => finishShortCitation(text, c),
        else => {},
    }

    var spans_buf: [32]case_name.CiteSpan = undefined;
    var n_spans: usize = 0;
    // Only the first ≤33 citations can supply the first-32 non-self spans the
    // case-name walk consumes, so bound the scan: identical result, but O(1)
    // per call instead of O(n) (which made finishCitation O(n²) over the
    // pipeline). complexity: O(1) per call
    for (all[0..@min(all.len, spans_buf.len + 1)], 0..) |other, oi| {
        if (oi == self_idx or n_spans == spans_buf.len) continue;
        spans_buf[n_spans] = .{ .start = other.span_start, .end = other.span_end };
        n_spans += 1;
    }

    if (c.kind == .unknown) return; // SectionTokens carry no metadata
    if (c.kind == .id or c.kind == .supra) {
        finishToken(text, c, all);
        if (c.kind == .supra) {
            try supraAntecedent(allocator, text, c, spans_buf[0..n_spans]);
        }
        return;
    }

    // eyecite guess_court: SCOTUS reporters imply the court
    if (c.court == null and tables.editions[c.edition].is_scotus) {
        c.court = "scotus";
    }

    // case names (find_case_name backward scan); other citations' spans act
    // as the CitationTokens of eyecite's word list
    const names = try case_name.findCaseName(
        allocator,
        text,
        .{ .start = c.span_start, .end = c.span_end },
        spans_buf[0..n_spans],
        c.kind == .short_case,
    );
    c.plaintiff = names.plaintiff;
    c.defendant = names.defendant;
    c.antecedent_guess = names.antecedent;
    if (names.full_span_start) |fs| c.full_span_start = fs;
    // eyecite's pre-citation year OVERRIDES a post-paren year (observed
    // live: "... (1982). Baz v. Qux, 2 F.2d 2 (1983)" yields year 1982)
    if (names.year_text) |yt| {
        c.year_text = yt;
        c.year = std.fmt.parseInt(u16, yt, 10) catch unreachable;
    }

    // add_pre_citation: party-less full cites get an antecedent guess from
    // the text immediately before ("Bar, 1 U.S. 1" → "Bar")
    if (c.kind == .full_case and c.plaintiff == null and c.defendant == null) {
        try preCiteAntecedent(allocator, text, c, spans_buf[0..n_spans]);
    }
}

/// eyecite add_law_metadata / POST_LAW_CITATION_REGEX:
/// `LAW_PIN? \ ? (\(publisher? month? day? year?\))? \ ? PARENTHETICAL?`.
/// LAW_PIN = subsections `(a)(2)`, optional ` and (d)`, optional ` et seq.`.
fn finishLawCitation(text: []const u8, c: *Citation) void {
    const nl = std.mem.indexOfScalarPos(u8, text, c.span_end, '\n') orelse text.len;
    const win = text[0..@min(nl, c.span_end + MAX_MATCH_CHARS)];
    var p: usize = c.span_end;

    // LAW_PIN_CITE (may match empty; eyecite keeps null for empty)
    const pin_start = p;
    while (parseLawSubsection(win, p)) |e| p = e;
    if (p > pin_start) {
        // optional ` and (d)...`
        if (std.mem.startsWith(u8, win[p..], " and ")) {
            var q = p + 5;
            var any = false;
            while (parseLawSubsection(win, q)) |e| {
                q = e;
                any = true;
            }
            if (any) p = q;
        }
    }
    if (std.mem.startsWith(u8, win[p..], " et seq.")) p += 8;
    if (p > pin_start) {
        c.pin_cite = std.mem.trim(u8, win[pin_start..p], ", ");
        c.span_end = @intCast(p); // full_span per eyecite; span unchanged?
        c.span_end = @intCast(pin_start); // span stays at the cite; pin extends full_span only
        c.full_span_end = @max(c.full_span_end, @as(u32, @intCast(p)));
    }

    if (p < win.len and win[p] == ' ') p += 1;
    // optional (publisher month day year) paren
    if (p < win.len and win[p] == '(') {
        const close = std.mem.indexOfScalarPos(u8, win, p + 1, ')') orelse win.len;
        if (close < win.len) {
            const inner = win[p + 1 .. close];
            if (parseLawParen(inner)) |meta| {
                c.publisher = meta.publisher;
                if (meta.year_text) |yt| {
                    c.year_text = yt;
                    const y = std.fmt.parseInt(u16, yt, 10) catch unreachable;
                    c.year = if (y >= 1600 and y <= default_max_valid_year) y else null;
                }
                p = close + 1;
                c.full_span_end = @max(c.full_span_end, @as(u32, @intCast(p)));
                if (p < win.len and win[p] == ' ') p += 1;
            }
        }
    }
    c.parenthetical = parseParenthetical(win, p -| 1);
}

/// One `\([0-9a-zA-Z]{1,4}\)` subsection; returns end offset.
fn parseLawSubsection(win: []const u8, p: usize) ?usize {
    if (p >= win.len or win[p] != '(') return null;
    var q = p + 1;
    var n: usize = 0;
    while (q < win.len and n < 4 and std.ascii.isAlphanumeric(win[q])) {
        q += 1;
        n += 1;
    }
    if (n == 0 or q >= win.len or win[q] != ')') return null;
    return q + 1;
}

const LawParen = struct {
    publisher: ?[]const u8 = null,
    year_text: ?[]const u8 = null,
};

/// Inside the law paren: `publisher? \ ? month? day? ,? \ ? year?` — at
/// least one of publisher/year must be present for the paren to count.
fn parseLawParen(inner: []const u8) ?LawParen {
    var out: LawParen = .{};
    var p: usize = 0;
    // publisher: [A-Z][a-z]+\.? (\ Supp\.)?
    if (p < inner.len and inner[p] >= 'A' and inner[p] <= 'Z') {
        var q = p + 1;
        while (q < inner.len and inner[q] >= 'a' and inner[q] <= 'z') q += 1;
        if (q > p + 1) {
            if (q < inner.len and inner[q] == '.') q += 1;
            if (std.mem.startsWith(u8, inner[q..], " Supp.")) q += 6;
            out.publisher = inner[p..q];
            p = q;
            if (p < inner.len and inner[p] == ' ') p += 1;
        }
    }
    // month (reuse MONTHS table) + day
    for (MONTHS) |m| {
        if (std.mem.startsWith(u8, inner[p..], m)) {
            p += m.len;
            if (p < inner.len and inner[p] == ' ') p += 1;
            break;
        }
    }
    var d: usize = 0;
    var dp = p;
    while (dp < inner.len and d < 2 and isDigit(inner[dp]) and
        !(dp + 4 <= inner.len and allDigits(inner[dp .. @min(dp + 4, inner.len)]))) : (d += 1) dp += 1;
    if (d > 0 and d <= 2) {
        p = dp;
        if (p < inner.len and inner[p] == ',') p += 1;
        if (p < inner.len and inner[p] == ' ') p += 1;
    }
    // year: \d{4}(-\d{2})?
    if (p + 4 <= inner.len and allDigits(inner[p .. p + 4])) {
        var e = p + 4;
        if (e + 3 <= inner.len and inner[e] == '-' and isDigit(inner[e + 1]) and isDigit(inner[e + 2])) e += 3;
        if (e == inner.len) {
            out.year_text = inner[p .. p + 4];
            return out;
        }
        return null; // trailing garbage after year: not a law paren
    }
    if (p == inner.len and out.publisher != null) return out;
    return null;
}

/// eyecite add_journal_metadata / POST_JOURNAL_CITATION_REGEX:
/// `PIN? \ ? (\(YEAR\))? \ ? PARENTHETICAL?` — no court, no case names.
fn finishJournalCitation(text: []const u8, c: *Citation) void {
    const nl = std.mem.indexOfScalarPos(u8, text, c.span_end, '\n') orelse text.len;
    const win = text[0..@min(nl, c.span_end + MAX_MATCH_CHARS)];
    var p: usize = c.span_end;
    if (parsePinCite(win, p)) |pin| {
        c.pin_cite = pin.cleaned;
        p = pin.end;
    }
    if (p < win.len and win[p] == ' ') p += 1;
    // optional (YEAR) with optional -dd range
    if (p + 6 <= win.len and win[p] == '(' and allDigits(win[p + 1 .. p + 5])) {
        var e = p + 5;
        if (e + 3 <= win.len and win[e] == '-' and isDigit(win[e + 1]) and isDigit(win[e + 2])) e += 3;
        if (e < win.len and win[e] == ')') {
            c.year_text = win[p + 1 .. p + 5];
            const y = std.fmt.parseInt(u16, c.year_text.?, 10) catch unreachable;
            c.year = if (y >= 1600 and y <= default_max_valid_year) y else null;
            p = e + 1;
            if (p < win.len and win[p] == ' ') p += 1;
        }
    }
    c.parenthetical = parseParenthetical(win, p -| 1);
    c.full_span_end = @max(c.full_span_end, c.span_end);
}

/// eyecite extract_pin_cite for id/supra tokens: pin + parenthetical in a
/// strings-only forward window; the pin tail extends the span.
fn finishToken(text: []const u8, c: *Citation, all: []const Citation) void {
    var wend = @min(text.len, c.span_end + MAX_MATCH_CHARS);
    if (std.mem.indexOfScalarPos(u8, text, c.span_end, '\n')) |nl| wend = @min(wend, nl);
    for (all) |other| {
        if (other.span_start >= c.span_end and other.span_start < wend and
            other.kind != .id and other.kind != .supra)
        {
            wend = other.span_start;
        }
    }
    const win = text[0..wend];
    if (parsePinCite(win, c.span_end)) |pin| {
        c.pin_cite = pin.cleaned;
        const stripped = std.mem.trimEnd(u8, win[c.span_end..pin.end], ", ");
        c.span_end += @intCast(stripped.len);
        c.full_span_end = @max(c.full_span_end, c.span_end);
    } else {
        c.parenthetical = parseParenthetical(win, c.span_end);
        return;
    }
    c.parenthetical = parseParenthetical(win, c.span_end + (if (win.len > c.span_end and win[c.span_end] == ',') @as(usize, 1) else 0));
}

/// eyecite SUPRA_ANTECEDENT_REGEX, matched backward (anchored at the supra
/// token) in a strings-only window:
/// `(word ,? vol | vol | word ,?) ` — leftmost alternative per position.
fn supraAntecedent(
    allocator: std.mem.Allocator,
    text: []const u8,
    c: *Citation,
    other_spans: []const case_name.CiteSpan,
) !void {
    const wstart = case_name.preCiteWindowStart(
        text,
        .{ .start = c.span_start, .end = c.span_end },
        other_spans,
    );
    const win = text[0..c.span_start];
    var p = wstart;
    while (p < win.len) : (p += 1) {
        if (!supraWordChar(win[p])) continue;
        var q = p;
        while (q < win.len and supraWordChar(win[q])) q += 1;
        const word = win[p..q];
        const all_digits = blk: {
            for (word) |ch| {
                if (!isDigit(ch)) break :blk false;
            }
            break :blk word.len > 0;
        };
        // optional-space / optional-comma combos (regex backtracking:
        // `\ ?` must be able to yield its space to the required final `\ `)
        const combos = [_][2]bool{
            .{ true, true }, .{ true, false }, .{ false, true }, .{ false, false },
        };
        // alt 1: antecedent ` ?,? ` volume `\ `$
        for (combos) |combo| {
            var r = q;
            if (combo[0]) {
                if (r < win.len and win[r] == ' ') r += 1 else continue;
            }
            if (combo[1]) {
                if (r < win.len and win[r] == ',') r += 1 else continue;
            }
            if (r >= win.len or win[r] != ' ') continue;
            r += 1;
            var v = r;
            while (v < win.len and isDigit(win[v])) v += 1;
            if (v > r and v < win.len and win[v] == ' ' and v + 1 == win.len) {
                c.antecedent_guess = try allocator.dupe(u8, word);
                c.supra_volume = win[r..v];
                c.full_span_start = @intCast(p);
                return;
            }
        }
        // alt 2: bare volume `\ `$
        if (all_digits and q < win.len and win[q] == ' ' and q + 1 == win.len) {
            c.supra_volume = word;
            c.full_span_start = @intCast(p);
            return;
        }
        // alt 3: antecedent ` ?,?` `\ `$
        for (combos) |combo| {
            var r = q;
            if (combo[0]) {
                if (r < win.len and win[r] == ' ') r += 1 else continue;
            }
            if (combo[1]) {
                if (r < win.len and win[r] == ',') r += 1 else continue;
            }
            if (r < win.len and win[r] == ' ' and r + 1 == win.len) {
                c.antecedent_guess = try allocator.dupe(u8, word);
                c.full_span_start = @intCast(p);
                return;
            }
        }
    }
}

fn supraWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.';
}

/// eyecite add_pre_citation / PRE_FULL_CITATION_REGEX:
/// `(?P<antecedent>[A-Z][a-z\-.]+) ?,? PIN_CITE? ,? ?` matched backward
/// (anchored at the citation start) within a strings-only token window.
/// The pin assignment intentionally overwrites (faithful to upstream).
fn preCiteAntecedent(
    allocator: std.mem.Allocator,
    text: []const u8,
    c: *Citation,
    other_spans: []const case_name.CiteSpan,
) !void {
    const wstart = case_name.preCiteWindowStart(
        text,
        .{ .start = c.span_start, .end = c.span_end },
        other_spans,
    );
    const win = text[0..c.span_start];
    var p = wstart;
    while (p < win.len) : (p += 1) {
        if (win[p] < 'A' or win[p] > 'Z') continue;
        var q = p + 1;
        while (q < win.len and ((win[q] >= 'a' and win[q] <= 'z') or win[q] == '-' or win[q] == '.')) q += 1;
        if (q == p + 1) continue; // [a-z\-.]+ requires at least one
        var r = q;
        if (r < win.len and win[r] == ' ') r += 1;
        if (r < win.len and win[r] == ',') r += 1;
        // try with pin, then without (regex backtracking on PIN_CITE?)
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            var r2 = r;
            var pin: ?[]const u8 = null;
            if (attempt == 0) {
                if (parsePinCite(win, r)) |pc| {
                    pin = pc.cleaned;
                    r2 = pc.end;
                } else continue;
            }
            var r3 = r2;
            if (r3 < win.len and win[r3] == ',') r3 += 1;
            if (r3 < win.len and win[r3] == ' ') r3 += 1;
            if (r3 == win.len) {
                c.antecedent_guess = try allocator.dupe(u8, win[p..q]);
                c.pin_cite = pin;
                return;
            }
        }
    }
}

/// eyecite _extract_shortform_citation: the pin cite is re-derived with the
/// citation's own PAGE as prefix (so "at 20-25" yields pin "20-25" and the
/// span extends over the pin tail), followed by an optional parenthetical.
/// No year/court paren for shorts.
fn finishShortCitation(text: []const u8, c: *Citation) void {
    const page = c.page orelse {
        const nl = std.mem.indexOfScalarPos(u8, text, c.span_end, '\n') orelse text.len;
        const win = text[0..@min(nl, c.span_end + MAX_MATCH_CHARS)];
        c.parenthetical = parseParenthetical(win, c.span_end);
        return;
    };
    const page_start = @intFromPtr(page.ptr) - @intFromPtr(text.ptr);
    const nl = std.mem.indexOfScalarPos(u8, text, page_start, '\n') orelse text.len;
    const win = text[0..@min(nl, page_start + MAX_MATCH_CHARS)];
    if (parsePinCite(win, page_start)) |pin| {
        c.pin_cite = pin.cleaned;
        // span_end = token.end + len(rstrip(pin, ", ")) - len(page)
        const stripped = std.mem.trimEnd(u8, win[page_start..pin.end], ", ");
        c.span_end = @intCast(page_start + stripped.len);
        c.parenthetical = parseParenthetical(win, pin.end);
    } else {
        // eyecite quirk: pinless shorts shrink span_end by the page length
        c.span_end -= @intCast(page.len);
    }
    c.full_span_end = @max(c.full_span_end, c.span_end);
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
    pin_cite: ?[]const u8 = null,
    parenthetical: ?[]const u8 = null,
    extra: ?[]const u8 = null,
};

/// eyecite MAX_MATCH_CHARS: the post-citation scan window.
const MAX_MATCH_CHARS = 300;

const MONTHS = [_][]const u8{
    "January",   "Jan.", "February", "Feb.",  "March",    "Mar.",
    "April",     "Apr.", "May",      "June",  "Jun.",     "July",
    "Jul.",      "August", "Aug.",   "September", "Sept.", "Sep.",
    "October",   "Oct.", "November", "Nov.",  "December", "Dec.",
};

/// Scans forward from the end of a citation, mirroring eyecite's
/// POST_FULL_CITATION_REGEX two branches: `pin_cite? ,? extra [\(\[] court?
/// month? day? YEAR [\)\]]` preferred; bare `pin_cite` as the fallback when
/// no valid court/date paren follows. The court is everything in the paren
/// before the whitespace that precedes a month or the year (Python's lazy
/// `.*?` + lookahead); the paren must close right after the year or the
/// whole branch fails.
fn parsePostCitation(text: []const u8, start: usize) PostCitation {
    // window: tokens accumulate to the next paragraph break, max 300 chars
    const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const win = text[0..@min(nl, start + MAX_MATCH_CHARS)];

    const pin = parsePinCite(win, start);
    const pin_only: PostCitation = .{ .pin_cite = if (pin) |p| p.cleaned else null };
    const after_pin = if (pin) |p| p.end else start;

    // `,? ?` then `extra` window: [^(;]*
    var i = after_pin;
    if (i < win.len and win[i] == ',') i += 1;
    if (i < win.len and win[i] == ' ') i += 1;
    const extra_start = i;
    while (i < win.len) : (i += 1) {
        const c = win[i];
        if (c == '(' or c == '[') break;
        if (c == ';') return pin_only;
    }
    if (i >= win.len) return pin_only;
    const open = i;
    const close = blk: {
        var j = open + 1;
        while (j < win.len) : (j += 1) {
            const c = win[j];
            if (c == ')' or c == ']') break :blk j;
        }
        return pin_only;
    };
    const inner = win[open + 1 .. close];
    const extra_raw = std.mem.trim(u8, win[extra_start..open], &std.ascii.whitespace);
    const extra: ?[]const u8 = if (extra_raw.len == 0) null else extra_raw;

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
                    .pin_cite = pin_only.pin_cite,
                    .extra = extra,
                    .parenthetical = parseParenthetical(win, close + 1),
                };
            }
        }
        p += 1;
    }
    return pin_only;
}

/// PARENTHETICAL_REGEX + process_parenthetical: optional ` ?\(`, greedy
/// capture to the LAST `)` in the window, then trim at the first unbalanced
/// close paren; a capture starting with a 4-digit year is nulled.
fn parseParenthetical(win: []const u8, start: usize) ?[]const u8 {
    var r = start;
    if (r < win.len and win[r] == ' ') r += 1;
    if (r >= win.len or win[r] != '(') return null;
    var last: usize = win.len;
    while (last > r + 1) {
        last -= 1;
        if (win[last] == ')') break;
    } else return null;
    if (last <= r) return null;
    return processParenthetical(win[r + 1 .. last]);
}

fn processParenthetical(p: []const u8) ?[]const u8 {
    var depth: i32 = 0;
    for (p, 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') depth -= 1;
        if (depth < 0) {
            return if (i == 0) null else p[0..i];
        }
    }
    if (p.len >= 4 and isDigit(p[0]) and isDigit(p[1]) and isDigit(p[2]) and isDigit(p[3]))
        return null;
    return if (p.len == 0) null else p;
}

const PinCiteResult = struct {
    end: usize, // end offset of the raw pin capture in text
    cleaned: []const u8, // clean_pin_cite: raw stripped of ", " both ends
};

/// eyecite PIN_CITE_REGEX: `,? ?(at )? TOKEN (, ?TOKEN)*` with a trailing
/// lookahead requiring `,.;)]\`, ` ?[([`, or end of text. The star is
/// greedy with backtracking: trailing repetitions are dropped until the
/// lookahead holds (this is what stops a pin cite from eating the volume
/// of a following parallel citation).
fn parsePinCite(text: []const u8, start: usize) ?PinCiteResult {
    var p = start;
    if (p < text.len and text[p] == ',') p += 1;
    if (p < text.len and text[p] == ' ') p += 1;
    if (p + 3 <= text.len and std.mem.eql(u8, text[p .. p + 3], "at ")) p += 3;
    p = parsePinToken(text, p) orelse return null;

    var reps: [64]usize = undefined; // pre-rep positions for backtracking
    var n_reps: usize = 0;
    while (n_reps < reps.len) {
        var q = p;
        if (q >= text.len or text[q] != ',') break;
        q += 1;
        if (q < text.len and text[q] == ' ') q += 1;
        const t = parsePinToken(text, q) orelse break;
        reps[n_reps] = p;
        n_reps += 1;
        p = t;
    }
    while (!pinLookaheadOk(text, p)) {
        if (n_reps == 0) return null;
        n_reps -= 1;
        p = reps[n_reps];
    }
    const cleaned = std.mem.trim(u8, text[start..p], ", ");
    if (cleaned.len == 0) return null;
    return .{ .end = p, .cleaned = cleaned };
}

fn pinLookaheadOk(text: []const u8, p: usize) bool {
    if (p >= text.len) return true;
    return switch (text[p]) {
        ',', '.', ';', ')', ']', '\\', '(', '[' => true,
        ' ' => p + 1 < text.len and (text[p + 1] == '(' or text[p + 1] == '['),
        else => false,
    };
}

/// One pin-cite token: optional label + optional space, then
/// `\d+:\d+(-\d+(:\d+)?)?` (page:line) or `*?\d+(-\d+)?` (page range).
/// Python backtracks the optional label off when the number fails.
fn parsePinToken(text: []const u8, start: usize) ?usize {
    if (parsePinLabel(text, start)) |after_label| {
        var q = after_label;
        if (q < text.len and text[q] == ' ') q += 1;
        if (parsePinNumber(text, q)) |e| return e;
    }
    return parsePinNumber(text, start);
}

/// Labels, in eyecite's alternation order: (& )?note | (& )?nn?.? |
/// (& )?fn?.? | ¶{1,2} | §{1,2} | *{1,4} | pg.? | pp?.?
fn parsePinLabel(text: []const u8, start: usize) ?usize {
    const rest = text[start..];
    const amp: usize = if (std.mem.startsWith(u8, rest, "& ")) 2 else 0;
    const r = rest[amp..];
    if (std.mem.startsWith(u8, r, "note")) return start + amp + 4;
    if (r.len > 0 and (r[0] == 'n' or r[0] == 'f')) {
        var e: usize = 1;
        if (e < r.len and r[e] == 'n' and r[0] != 'f') e += 1;
        if (r[0] == 'f' and e < r.len and r[e] == 'n') e += 1;
        if (e < r.len and r[e] == '.') e += 1;
        return start + amp + e;
    }
    if (amp != 0) return null; // "& " requires note/n/f after it
    if (std.mem.startsWith(u8, rest, "\xc2\xb6")) { // ¶
        var e: usize = 2;
        if (std.mem.startsWith(u8, rest[e..], "\xc2\xb6")) e += 2;
        return start + e;
    }
    if (std.mem.startsWith(u8, rest, "\xc2\xa7")) { // §
        var e: usize = 2;
        if (std.mem.startsWith(u8, rest[e..], "\xc2\xa7")) e += 2;
        return start + e;
    }
    if (rest.len > 0 and rest[0] == '*') {
        var e: usize = 1;
        while (e < rest.len and e < 4 and rest[e] == '*') e += 1;
        return start + e;
    }
    if (std.mem.startsWith(u8, rest, "pg")) {
        var e: usize = 2;
        if (e < rest.len and rest[e] == '.') e += 1;
        return start + e;
    }
    if (rest.len > 0 and rest[0] == 'p') {
        var e: usize = 1;
        if (e < rest.len and rest[e] == 'p') e += 1;
        if (e < rest.len and rest[e] == '.') e += 1;
        return start + e;
    }
    return null;
}

/// Byte length of a pin-cite range separator at `i`: hyphen-minus (1) or
/// en-dash U+2013 / em-dash U+2014 (3), else 0. Real opinions use en/em-
/// dashes for page ranges ("241\u{2013}242"); eyecite's regex only accepts
/// hyphen-minus and silently drops these pins — incitez accepts all three
/// (a principled surpass; see docs/principled_divergences.md section 3).
fn pinDashLen(text: []const u8, i: usize) usize {
    if (i >= text.len) return 0;
    if (text[i] == '-') return 1;
    if (i + 3 <= text.len and text[i] == 0xe2 and text[i + 1] == 0x80 and
        (text[i + 2] == 0x93 or text[i + 2] == 0x94)) return 3;
    return 0;
}

fn digitRun(text: []const u8, start: usize) usize {
    var p = start;
    while (p < text.len and isDigit(text[p])) p += 1;
    return p;
}

fn parsePinNumber(text: []const u8, start: usize) ?usize {
    // page:line form first (eyecite alternation order): \d+:\d+(-\d+(:\d+)?)?
    const d1 = digitRun(text, start);
    if (d1 > start and d1 < text.len and text[d1] == ':') {
        const d2 = digitRun(text, d1 + 1);
        if (d2 > d1 + 1) {
            var e = d2;
            if (pinDashLen(text, e) > 0) {
                const dl = pinDashLen(text, e);
                const d3 = digitRun(text, e + dl);
                if (d3 > e + dl) {
                    e = d3;
                    if (e < text.len and text[e] == ':') {
                        const d4 = digitRun(text, e + 1);
                        if (d4 > e + 1) e = d4;
                    }
                }
            }
            return e;
        }
    }
    // page range: [*]?\d+(-\d+)?
    var q = start;
    if (q < text.len and text[q] == '*') q += 1;
    const e1 = digitRun(text, q);
    if (e1 == q) return null;
    var e = e1;
    const dl = pinDashLen(text, e);
    if (dl > 0) {
        const e2 = digitRun(text, e + dl);
        if (e2 > e + dl) e = e2;
    }
    return e;
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

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
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
                        if (prog.short) {
                            best.?.kind = .short_case;
                        } else best.?.kind = switch (edition.source) {
                            .reporters => .full_case,
                            .journals => .full_journal,
                            .laws => .full_law,
                        };
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
    defer freeCitations(testing.allocator, cites);
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
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(u32, 28), cites[0].span_start);
    try testing.expectEqual(@as(u32, 40), cites[0].span_end);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].page);
    try testing.expectEqualStrings("585", cites[0].volume.?);
}

test "citation requires non-alphanumeric boundaries (eyecite parity)" {
    const cites = try extract(testing.allocator, "foo1 U.S. 1, 1. U.S. 1foo");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "street addresses are not citations: page must end at a token boundary" {
    const a = try extract(testing.allocator, "lorem 111 S.W. 12th St.");
    defer freeCitations(testing.allocator, a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try extract(testing.allocator, "lorem 111 N. W. 12th St.");
    defer freeCitations(testing.allocator, b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "no citation in plain prose" {
    const cites = try extract(testing.allocator, "the 3 musketeers met 4 friends in 1982");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "volume must not be zero-led and reporter must be known" {
    const cites = try extract(testing.allocator, "0 U.S. 1 and 1 X.Y.Z. 2");
    defer freeCitations(testing.allocator, cites);
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
    defer freeCitations(testing.allocator, cites);
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
    defer freeCitations(testing.allocator, cites);
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
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 0), cites.len);
}

test "year from simple paren: (1982)" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("1982", cites[0].year_text.?);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].court_paren);
}

test "year and court from paren: (4th Cir. 1982)" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (4th Cir. 1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("4th Cir.", cites[0].court_paren.?);
}

test "year and court without space: (Pa.Super. 1982)" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (Pa.Super. 1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
    try testing.expectEqualStrings("Pa.Super.", cites[0].court_paren.?);
}

test "misformatted year yields no year: (198⁴)" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (198⁴)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "no paren yields no year" {
    const cites = try extract(testing.allocator, "1 U.S. 1");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "out-of-range year: text kept, numeric year null (eyecite get_year parity)" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1500)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
    try testing.expectEqualStrings("1500", cites[0].year_text.?);
}

test "year not at paren end is rejected: (1982 Pa.)" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1982 Pa.)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "court resolution: (4th Cir. 1982) -> ca4" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (4th Cir. 1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("ca4", cites[0].court.?);
}

test "court resolution without internal space: (Pa.Super. 1982) -> pasuperct" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (Pa.Super. 1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("pasuperct", cites[0].court.?);
}

test "court resolution exact: (Pa. 2017) -> pa" {
    const cites = try extract(testing.allocator, "Commonwealth v. Muniz, 164 A.3d 1189 (Pa. 2017)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("pa", cites[0].court.?);
}

test "scotus guessed from reporter without paren (guess_court parity)" {
    const cites = try extract(testing.allocator, "1 U.S. 1");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("scotus", cites[0].court.?);
}

test "non-scotus reporter without paren has no court" {
    const cites = try extract(testing.allocator, "1 F.2d 1");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].court);
}

test "pin cite: simple range before court paren" {
    const cites = try extract(testing.allocator, "bob Lissner v. Test 1 U.S. 12, 347-348 (4th Cir. 1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("347-348", cites[0].pin_cite.?);
    try testing.expectEqual(@as(?u16, 1982), cites[0].year);
}

test "pin cite stops before a following parallel citation" {
    const cites = try extract(testing.allocator, "Bob Lissner v. Test 1 U.S. 12, 347-348, 1 S. Ct. 2, 358 (4th Cir. 1982) (overruling foo)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("347-348", cites[0].pin_cite.?);
    try testing.expectEqualStrings("358", cites[1].pin_cite.?);
}

test "pin cite survives when the paren is not a court/date paren" {
    // (3 Atl. 33) has no 4-digit year: branch 1 fails, pin-only branch holds
    const cites = try extract(testing.allocator, "2 U.S. 3, 4-5 (3 Atl. 33)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("4-5", cites[0].pin_cite.?);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
}

test "pin cite terminated by period" {
    const cites = try extract(testing.allocator, "In re Foo 1 Mass. 12, 347-348. something something,");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("347-348", cites[0].pin_cite.?);
}

test "pin cite comma list" {
    const cites = try extract(testing.allocator, "1 U.S. 1, 2277, 2278, 2279 (1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("2277, 2278, 2279", cites[0].pin_cite.?);
}

test "no pin cite when nothing follows" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1982)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].pin_cite);
}

test "parenthetical comment and extra (parallel cite text)" {
    const cites = try extract(testing.allocator, "Bob Lissner v. Test 1 U.S. 12, 347-348, 1 S. Ct. 2, 358 (4th Cir. 1982) (overruling foo)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("overruling foo", cites[0].parenthetical.?);
    try testing.expectEqualStrings("1 S. Ct. 2, 358", cites[0].extra.?);
    try testing.expectEqualStrings("overruling foo", cites[1].parenthetical.?);
    try testing.expectEqual(@as(?[]const u8, null), cites[1].extra);
}

test "nested parenthetical kept whole" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (1982) (discussing abc (Holmes, J., concurring))");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("discussing abc (Holmes, J., concurring)", cites[0].parenthetical.?);
}

test "parenthetical trimmed at unbalanced close paren" {
    const cites = try extract(testing.allocator, "Lissner v. Test 1 U.S. 1 (1982) (discussing abc); blah (something).");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("discussing abc", cites[0].parenthetical.?);
}

test "year-shaped parenthetical is nulled (eyecite parity)" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (Pa. 1982) (1983)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].parenthetical);
}

test "no parenthetical when none follows" {
    const cites = try extract(testing.allocator, "1 U.S. 1 (1982) and more text");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].parenthetical);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].extra);
}

fn expectNames(text: []const u8, cite_idx: usize, plaintiff: ?[]const u8, defendant: ?[]const u8) !void {
    const cites = try extract(testing.allocator, text);
    defer freeCitations(testing.allocator, cites);
    try testing.expect(cites.len > cite_idx);
    const c = cites[cite_idx];
    if (plaintiff) |p| try testing.expectEqualStrings(p, c.plaintiff.?) else try testing.expectEqual(@as(?[]const u8, null), c.plaintiff);
    if (defendant) |d| try testing.expectEqualStrings(d, c.defendant.?) else try testing.expectEqual(@as(?[]const u8, null), c.defendant);
}

test "case name: simple v." {
    try expectNames("Lissner v. Test 1 U.S. 1", 0, "Lissner", "Test");
}

test "case name: lowercase word before plaintiff excluded" {
    try expectNames("bob Lissner v. Test 1 F.2d 1 (1982)", 0, "Lissner", "Test");
}

test "case name: structural newline is a hard walk-back stop (boundary-aware surpass)" {
    // docscan emits a lone \n only at a real structural boundary (heading /
    // paragraph break; it joins intra-paragraph wraps to spaces). The case-name
    // walk-back must STOP at that \n rather than swallow the preceding heading
    // into the party — the all-caps-heading bleed that eyecite ALSO gets wrong
    // (eyecite treats \n as \s and walks past). Additive: the marker-free
    // differential corpus has no \n, so 215/215 is untouched. Principled
    // divergence; see docs/principled_divergences.md.
    // no-"v" antecedent: the heading must not bleed past the boundary
    try expectNames("DISCUSSION\nSmith Co., 1 U.S. 1 (1980)", 0, null, "Smith Co.");
    // "v" case: heading excluded, both parties intact
    try expectNames("TABLE OF AUTHORITIES\nLissner v. Test, 1 U.S. 1", 0, "Lissner", "Test");
}

test "case name: leading Bluebook signals stripped, embedded ones kept (surpass)" {
    // eyecite filters See/Cf. but NOT Compare/Accord/Contra/Consider — it leaves
    // them in the plaintiff. incitez strips the full introductory-signal set,
    // LEADING-ONLY: a sentence-initial signal is removed, but the same word
    // embedded in a real name survives (capitalization + position as signal).
    // Principled surpass; see docs/exceeds_eyecite.md.
    try expectNames("Compare Gideon v. Wainwright, 372 U.S. 335 (1963)", 0, "Gideon", "Wainwright");
    try expectNames("Accord Foo v. Bar, 1 U.S. 1", 0, "Foo", "Bar");
    try expectNames("Contra Foo v. Bar, 1 U.S. 1", 0, "Foo", "Bar");
    try expectNames("Consider Foo v. Bar, 1 U.S. 1", 0, "Foo", "Bar");
    // embedded signal word must survive (eyecite drops it AND the leading "I")
    try expectNames("I See Deadpeople v. State of California, 1 U.S. 1", 0, "I See Deadpeople", "State of California");
    try expectNames("See I See Deadpeople v. State of California, 1 U.S. 1", 0, "I See Deadpeople", "State of California");
    // a litigant literally named a signal word, right before "v.", is NOT a
    // signal — keep it (the empty-guard)
    try expectNames("Accord v. Honda, 1 U.S. 1", 0, "Accord", "Honda");
}
test "case name: capitalized word joins plaintiff" {
    try expectNames("Bob Lissner v. Test 1 U.S. 12, 347-348, 1 S. Ct. 2, 358 (4th Cir. 1982)", 0, "Bob Lissner", "Test");
    try expectNames("Bob Lissner v. Test 1 U.S. 12, 347-348, 1 S. Ct. 2, 358 (4th Cir. 1982)", 1, "Bob Lissner", "Test");
}

test "case name: comma after defendant" {
    try expectNames("Lissner v. Test, 1 U.S. 1 (1982)", 0, "Lissner", "Test");
}

test "case name: multi-word defendant with lowercase 'of'" {
    try expectNames("(1963); Reece v. State of Washington, 310 F.2d 139 (1962)", 0, "Reece", "State of Washington");
}

test "case name: in re style has defendant only" {
    try expectNames("In re Foo 1 Mass. 12, 347-348. something something, in at we see that", 0, null, "Foo");
}

test "case name: bare v without period" {
    try expectNames("Rogers v Rogers (63 NY2d 582 [1984])", 0, "Rogers", "Rogers");
}

test "case name: across a placeholder citation" {
    try expectNames("Hurst v. Florida, — U.S. —, 136 S.Ct. 616, 193 L.Ed.2d 504 (2016)", 0, "Hurst", "Florida");
    try expectNames("Hurst v. Florida, — U.S. —, 136 S.Ct. 616, 193 L.Ed.2d 504 (2016)", 1, "Hurst", "Florida");
}

test "case name: abbreviation break after v keeps single plaintiff word" {
    try expectNames("speech.\xe2\x80\x9d Houston Cmty. Coll. Sys. v. Wilson, ---- U.S. ----, 142 S. Ct. 1253, 1259, ---- L. Ed. 2d ---- (2022)", 0, "Sys.", "Wilson");
}

test "case name: pre-citation year still applies with case name" {
    const cites = try extract(testing.allocator, "trial court\xe2\x80\x99s ruling. (See In re K.F. (2009) 1 U.S. 1 ");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?u16, 2009), cites[0].year);
}

test "short cite: bare '1 So.2d at 1'" {
    const cites = try extract(testing.allocator, "1 So.2d at 1");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(Kind.short_case, c.kind);
    try testing.expectEqual(@as(u32, 0), c.span_start);
    try testing.expectEqual(@as(u32, 12), c.span_end);
    try testing.expectEqualStrings("1", c.volume.?);
    try testing.expectEqualStrings("So.2d", c.reporter);
    try testing.expectEqualStrings("1", c.page.?);
    try testing.expectEqualStrings("1", c.pin_cite.?);
}

test "short cite: antecedent guess and pin range extends span" {
    const cites = try extract(testing.allocator, "before Foo, 1 U. S., at 20-25");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(Kind.short_case, c.kind);
    try testing.expectEqual(@as(u32, 12), c.span_start);
    try testing.expectEqual(@as(u32, 29), c.span_end);
    try testing.expectEqualStrings("20", c.page.?);
    try testing.expectEqualStrings("20-25", c.pin_cite.?);
    try testing.expectEqualStrings("Foo", c.antecedent_guess.?);
}

test "short cite: 'at p. 651' label form" {
    const cites = try extract(testing.allocator, "174 Cal.App.2d at p. 651");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(Kind.short_case, cites[0].kind);
    try testing.expectEqual(@as(u32, 24), cites[0].span_end);
    try testing.expectEqualStrings("651", cites[0].page.?);
    try testing.expectEqualStrings("651", cites[0].pin_cite.?);
}

test "short cite: terminal quote blocks antecedent" {
    const cites = try extract(testing.allocator, "before Foo,\xe2\x80\x9d 1 U. S., at 2");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].antecedent_guess);
}

test "short cite gets scotus guess and no year" {
    const cites = try extract(testing.allocator, "before Foo, 1 U. S., at 2 (overruling xyz)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("scotus", cites[0].court.?);
    try testing.expectEqual(@as(?u16, null), cites[0].year);
    try testing.expectEqualStrings("overruling xyz", cites[0].parenthetical.?);
}

test "id citation: Ibid. bare" {
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12. asdf. Ibid. foo bar lorem ipsum.");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqual(Kind.id, cites[1].kind);
    try testing.expectEqual(@as(u32, 28), cites[1].span_start);
    try testing.expectEqual(@as(u32, 33), cites[1].span_end);
    try testing.expectEqual(@as(?[]const u8, null), cites[1].pin_cite);
}

test "id citation: Id., at 123 with pin extending span" {
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12, 347-348. asdf. Id., at 123. foo bar");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqual(Kind.id, cites[1].kind);
    try testing.expectEqual(@as(u32, 37), cites[1].span_start);
    try testing.expectEqual(@as(u32, 48), cites[1].span_end);
    try testing.expectEqualStrings("at 123", cites[1].pin_cite.?);
}

test "id citation: paragraph-sign pin" {
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12, 347-348. asdf. Id. \xc2\xb6 34. foo bar");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("\xc2\xb6 34", cites[1].pin_cite.?);
}

test "id citation: comma-list pin with labels" {
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12, 347-348. asdf. Id. at pp. 45, 64. f");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("at pp. 45, 64", cites[1].pin_cite.?);
}

test "supra: antecedent and pin" {
    const cites = try extract(testing.allocator, "before asdf, supra, at 2");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(Kind.supra, cites[0].kind);
    try testing.expectEqual(@as(u32, 13), cites[0].span_start);
    try testing.expectEqual(@as(u32, 24), cites[0].span_end);
    try testing.expectEqualStrings("at 2", cites[0].pin_cite.?);
    try testing.expectEqualStrings("asdf", cites[0].antecedent_guess.?);
}

test "supra: with volume before" {
    const cites = try extract(testing.allocator, "before asdf, 123 supra, at 2");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(u32, 17), cites[0].span_start);
    try testing.expectEqual(@as(u32, 28), cites[0].span_end);
    try testing.expectEqualStrings("asdf", cites[0].antecedent_guess.?);
}

test "supra: punctuation shell in token span, no pin" {
    const cites = try extract(testing.allocator, "before Asdf, supra. foo bar");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(u32, 13), cites[0].span_start);
    try testing.expectEqual(@as(u32, 19), cites[0].span_end);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].pin_cite);
    try testing.expectEqualStrings("Asdf", cites[0].antecedent_guess.?);
}

test "supra: parenthetical without pin" {
    const cites = try extract(testing.allocator, "Foo, supra (overruling ...) (ignore this)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(u32, 10), cites[0].span_end);
    try testing.expectEqualStrings("overruling ...", cites[0].parenthetical.?);
    try testing.expectEqualStrings("Foo", cites[0].antecedent_guess.?);
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
        defer freeCitations(testing.allocator, vm_cites);
        const p_cites = try extractWithEngine(testing.allocator, text, .pcre2);
        defer freeCitations(testing.allocator, p_cites);
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
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 2), cites.len);
    try testing.expectEqualStrings("U.S.", cites[0].reporter);
    try testing.expectEqualStrings("F.2d", cites[1].reporter);
}

test "journal citation: bare, pin, year, parenthetical" {
    const cites = try extract(testing.allocator, "1 Minn. L. Rev. 1, 2-3 (2007) (discussing ...) (ignore this)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(Kind.full_journal, c.kind);
    try testing.expectEqual(@as(u32, 0), c.span_start);
    try testing.expectEqual(@as(u32, 17), c.span_end);
    try testing.expectEqualStrings("1", c.volume.?);
    try testing.expectEqualStrings("Minn. L. Rev.", c.reporter);
    try testing.expectEqualStrings("1", c.page.?);
    try testing.expectEqualStrings("2-3", c.pin_cite.?);
    try testing.expectEqual(@as(?u16, 2007), c.year);
    try testing.expectEqualStrings("discussing ...", c.parenthetical.?);
    try testing.expectEqualStrings("Minn. L. Rev.", c.correctedReporter());
}

test "journal citation: year range paren" {
    const cites = try extract(testing.allocator, "77 Marq. L. Rev. 475 (1993-94)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(Kind.full_journal, cites[0].kind);
    try testing.expectEqual(@as(?u16, 1993), cites[0].year);
    try testing.expectEqual(@as(u32, 20), cites[0].span_end);
}

test "journal citation: no case names, no court" {
    const cites = try extract(testing.allocator, "see Smith v. Jones, 1 Minn. L. Rev. 1 (2007)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].plaintiff);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].defendant);
    try testing.expectEqual(@as(?[]const u8, null), cites[0].court);
}

test "section token becomes an unknown citation" {
    const cites = try extract(testing.allocator, "lorem ipsum see \xc2\xa799 of the U.S. code.");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqual(Kind.unknown, cites[0].kind);
    try testing.expectEqual(@as(u32, 16), cites[0].span_start);
    try testing.expectEqual(@as(u32, 20), cites[0].span_end);
}

test "law citation: statute with subsection pin, publisher year paren" {
    const cites = try extract(testing.allocator, "Ohio Rev. Code Ann. \xc2\xa7 5739.02(B)(7) (Lexis Supp. 2010)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    const c = cites[0];
    try testing.expectEqual(Kind.full_law, c.kind);
    try testing.expectEqual(@as(u32, 0), c.span_start);
    try testing.expectEqual(@as(u32, 30), c.span_end); // § is 2 bytes: char 29 -> byte 30
    try testing.expectEqualStrings("(B)(7)", c.pin_cite.?);
    try testing.expectEqual(@as(?u16, 2010), c.year);
    try testing.expectEqualStrings("Lexis Supp.", c.publisher.?);
}

test "law citation: et seq pin with West year" {
    const cites = try extract(testing.allocator, "Ariz. Rev. Stat. Ann. \xc2\xa7 36-3701 et seq. (West 2009)");
    defer freeCitations(testing.allocator, cites);
    try testing.expectEqual(@as(usize, 1), cites.len);
    try testing.expectEqualStrings("et seq.", cites[0].pin_cite.?);
    try testing.expectEqual(@as(?u16, 2009), cites[0].year);
    try testing.expectEqualStrings("West", cites[0].publisher.?);
}

test "law citation: and-subsection pin, double section, chapter form" {
    const a = try extract(testing.allocator, "Ark. Code Ann. \xc2\xa7 23-3-119(a)(2) and (d) (1987)");
    defer freeCitations(testing.allocator, a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("(a)(2) and (d)", a[0].pin_cite.?);
    try testing.expectEqual(@as(?u16, 1987), a[0].year);

    const b = try extract(testing.allocator, "Mass. Gen. Laws ch. 1, \xc2\xa7\xc2\xa7 2-3");
    defer freeCitations(testing.allocator, b);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqual(Kind.full_law, b[0].kind);

    const d = try extract(testing.allocator, "1 Stat. 2");
    defer freeCitations(testing.allocator, d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqual(Kind.full_law, d[0].kind);

    const e = try extract(testing.allocator, "Kan. Stat. Ann. \xc2\xa7 21-3516(a)(2) (repealed) (ignore this)");
    defer freeCitations(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.len);
    try testing.expectEqualStrings("(a)(2)", e[0].pin_cite.?);
    try testing.expectEqualStrings("repealed", e[0].parenthetical.?);
}

// ── Seam / adjacency characterization (documented intentional divergence) ──
// When citations with the SAME reporter are packed back-to-back separated by
// a SINGLE boundary char, finditer-style engines (eyecite, and our literal
// PCRE2 path) consume the trailing boundary of one match, starving the next
// match's leading boundary, and drop it. The VM resumes after the citation
// core, keeps the separator available, and finds ALL of them — arguably more
// correct (every one is a real citation). This only arises in synthetic
// concatenation; real prose separates citations with more than one char.
// These tests PIN that behavior so it is a tested invariant, not a surprise.
// See docs/architecture.md "Honest edges".

test "seam: VM finds all adjacent same-reporter cites; pcre2 drops the starved middle" {
    // three "1 Minn. L. Rev. 1" packed by single newlines
    const text = "1 Minn. L. Rev. 1\n1 Minn. L. Rev. 1, 2-3\n1 Minn. L. Rev. 1";
    const vm = try extractWithEngine(testing.allocator, text, .vm);
    defer freeCitations(testing.allocator, vm);
    const p2 = try extractWithEngine(testing.allocator, text, .pcre2);
    defer freeCitations(testing.allocator, p2);
    // VM recovers the boundary-starved middle citation; pcre2 (finditer) does not
    try testing.expectEqual(@as(usize, 3), vm.len);
    try testing.expectEqual(@as(usize, 2), p2.len);
    // all three VM hits are the same journal edition
    for (vm) |c| try testing.expectEqual(Kind.full_journal, c.kind);
}

test "seam: normal two-char separation — both engines agree (no divergence in real prose)" {
    const text = "1 Minn. L. Rev. 1; 1 Minn. L. Rev. 2; 1 Minn. L. Rev. 3";
    const vm = try extractWithEngine(testing.allocator, text, .vm);
    defer freeCitations(testing.allocator, vm);
    const p2 = try extractWithEngine(testing.allocator, text, .pcre2);
    defer freeCitations(testing.allocator, p2);
    try testing.expectEqual(@as(usize, 3), vm.len);
    try testing.expectEqual(vm.len, p2.len);
}

test "seam: different reporters never interfere (separate extractor passes)" {
    // distinct editions => distinct extractors => no shared-finditer starving
    const text = "1 U.S. 1\n2 F.2d 3";
    const vm = try extractWithEngine(testing.allocator, text, .vm);
    defer freeCitations(testing.allocator, vm);
    const p2 = try extractWithEngine(testing.allocator, text, .pcre2);
    defer freeCitations(testing.allocator, p2);
    try testing.expectEqual(@as(usize, 2), vm.len);
    try testing.expectEqual(@as(usize, 2), p2.len);
}

test "reference: plaintiff name + pin after a full case cite" {
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12, 347-348. something something, In Foo at 62, we see that");
    defer freeCitations(testing.allocator, cites);
    var refs: usize = 0;
    for (cites) |c| {
        if (c.kind != .reference) continue;
        refs += 1;
        try testing.expectEqual(@as(u32, 55), c.span_start);
        try testing.expectEqual(@as(u32, 64), c.span_end);
        try testing.expectEqualStrings("Foo", c.plaintiff.?);
        try testing.expectEqual(@as(?[]const u8, null), c.defendant);
    }
    try testing.expectEqual(@as(usize, 1), refs);
}

test "reference: defendant name (in re) + pin" {
    const cites = try extract(testing.allocator, "In re Foo 1 Mass. 12, 347-348. something something, in Foo at 62, we see that, ");
    defer freeCitations(testing.allocator, cites);
    var refs: usize = 0;
    for (cites) |c| {
        if (c.kind != .reference) continue;
        refs += 1;
        try testing.expectEqualStrings("Foo", c.defendant.?);
        try testing.expectEqual(@as(?[]const u8, null), c.plaintiff);
    }
    try testing.expectEqual(@as(usize, 1), refs);
}

test "reference: disallowed name (United States) excluded; valid one kept" {
    const cites = try extract(testing.allocator, "Foo v. United States 1 U.S. 12, 347-348. something something ... the United States at 1776 we see that and Foo at 62");
    defer freeCitations(testing.allocator, cites);
    var refs: usize = 0;
    for (cites) |c| {
        if (c.kind != .reference) continue;
        refs += 1;
        try testing.expectEqualStrings("Foo", c.plaintiff.?);
    }
    try testing.expectEqual(@as(usize, 1), refs); // "United States at 1776" excluded
}

test "reference: only fires after the full cite, requires a pin" {
    // no pin after the name => no reference
    const cites = try extract(testing.allocator, "Foo v. Bar 1 U.S. 12, 347-348. Later Foo did something.");
    defer freeCitations(testing.allocator, cites);
    for (cites) |c| try testing.expect(c.kind != .reference);
}

test "pin cite: en-dash and em-dash ranges (surpass — eyecite accepts only hyphen)" {
    // real opinions use en-dashes for page ranges; eyecite drops these pins
    const a = try extract(testing.allocator, "Harris Trust v. Salomon, 530 U. S. 238, 241\xe2\x80\x93242 (2000)");
    defer freeCitations(testing.allocator, a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("241\xe2\x80\x93242", a[0].pin_cite.?);
    // em-dash too
    const b = try extract(testing.allocator, "1 U.S. 37, 44\xe2\x80\x9445 (1948)");
    defer freeCitations(testing.allocator, b);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqualStrings("44\xe2\x80\x9445", b[0].pin_cite.?);
    // plain hyphen still works (no regression)
    const c = try extract(testing.allocator, "1 U.S. 12, 347-348 (1982)");
    defer freeCitations(testing.allocator, c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqualStrings("347-348", c[0].pin_cite.?);
}
