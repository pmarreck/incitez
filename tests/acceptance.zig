//! Acceptance driver: runs incitez extraction over the oracle-verified
//! eyecite corpus (tests/corpus/eyecite_corpus.json) and ratchets progress.
//!
//! Comparison is per-FIELD: only fields incitez implements are asserted
//! (span, groups, corrected reporter so far); metadata fields activate as
//! features land. The pass count is a TWO-SIDED ratchet: regressions fail,
//! and unbumped progress also fails (forcing a conscious ratchet bump).
const std = @import("std");
const incitez = @import("incitez");

const corpus_json = @embedFile("corpus/eyecite_corpus.json");

/// Bump this consciously as matcher features land.
const RATCHET_EXPECTED_PASSES: usize = 136;
const RATCHET_PCRE2_EXPECTED_PASSES: usize = 136;
/// Eligible-case count must ALSO match exactly — without this, newly
/// eligible cases that all fail leave the pass count unchanged and slip by.
const RATCHET_EXPECTED_ATTEMPTED: usize = 136;
const EXPECTED_ENGINE_DIVERGENCES: usize = 0;

const CaseResult = struct {
    passed: usize = 0,
    attempted: usize = 0,
    failures: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn jsonStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Eligible for the current slice: no clean steps, no kwargs, and every
/// expected citation is a FullCaseCitation.
fn caseEligible(case: std.json.ObjectMap) bool {
    if (case.get("clean_steps").?.array.items.len != 0) return false;
    if (case.get("kwargs").?.object.count() != 0) return false;
    const cites = case.get("cites").?.array.items;
    for (cites) |cite| {
        const t = jsonStr(cite.object.get("type").?).?;
        const supported = std.mem.eql(u8, t, "FullCaseCitation") or
            std.mem.eql(u8, t, "ShortCaseCitation") or
            std.mem.eql(u8, t, "SupraCitation") or
            std.mem.eql(u8, t, "IdCitation") or
            std.mem.eql(u8, t, "FullJournalCitation") or
            std.mem.eql(u8, t, "UnknownCitation") or
            std.mem.eql(u8, t, "FullLawCitation") or
            std.mem.eql(u8, t, "ReferenceCitation");
        if (!supported) return false;
    }
    return true;
}

/// eyecite spans count Python str code points; incitez spans count bytes
/// (deliberate: byte offsets are what C/FFI consumers index with). Convert
/// an expected code-point span to byte offsets for comparison.
fn charSpanToBytes(text: []const u8, char_start: i64, char_end: i64) [2]u32 {
    var out: [2]u32 = .{ @intCast(text.len), @intCast(text.len) };
    var byte_i: usize = 0;
    var char_i: i64 = 0;
    while (byte_i < text.len) {
        if (char_i == char_start) out[0] = @intCast(byte_i);
        if (char_i == char_end) {
            out[1] = @intCast(byte_i);
            break;
        }
        byte_i += std.unicode.utf8ByteSequenceLength(text[byte_i]) catch 1;
        char_i += 1;
    }
    return out;
}

fn kindMatches(type_name: []const u8, kind: incitez.extraction.Kind) bool {
    const expected_kind: incitez.extraction.Kind =
        if (std.mem.eql(u8, type_name, "FullCaseCitation")) .full_case
        else if (std.mem.eql(u8, type_name, "ShortCaseCitation")) .short_case
        else if (std.mem.eql(u8, type_name, "SupraCitation")) .supra
        else if (std.mem.eql(u8, type_name, "IdCitation")) .id
        else if (std.mem.eql(u8, type_name, "FullJournalCitation")) .full_journal
        else if (std.mem.eql(u8, type_name, "UnknownCitation")) .unknown
        else if (std.mem.eql(u8, type_name, "FullLawCitation")) .full_law
        else if (std.mem.eql(u8, type_name, "ReferenceCitation")) .reference
        else return false;
    return kind == expected_kind;
}

fn citeMatches(text: []const u8, expected: std.json.ObjectMap, actual: incitez.extraction.Citation) bool {
    if (!kindMatches(jsonStr(expected.get("type").?).?, actual.kind)) return false;
    // span
    const span = expected.get("span").?.array.items;
    const exp_bytes = charSpanToBytes(text, span[0].integer, span[1].integer);
    if (actual.span_start != exp_bytes[0] or actual.span_end != exp_bytes[1]) return false;
    // groups: volume, reporter, page (may be null/absent)
    const groups = expected.get("groups").?.object;
    const is_token = actual.kind == .supra or actual.kind == .id or actual.kind == .unknown or actual.kind == .reference;
    const actual_reporter: ?[]const u8 = if (is_token) null else actual.reporter;
    if (!optFieldMatches(groups.get("volume"), actual.volume)) return false;
    if (!optFieldMatches(groups.get("reporter"), actual_reporter)) return false;
    if (!optFieldMatches(groups.get("page"), actual.page)) return false;
    // corrected reporter
    if (expected.get("corrected_reporter")) |cr| {
        if (jsonStr(cr)) |s| {
            if (!std.mem.eql(u8, s, actual.correctedReporter())) return false;
        }
    }
    // court (resolved courts-db id, or guessed scotus)
    if (expected.get("metadata")) |md| {
        if (!optFieldMatches(md.object.get("court"), actual.court)) return false;
        if (!optFieldMatches(md.object.get("pin_cite"), actual.pin_cite)) return false;
        if (!optFieldMatches(md.object.get("parenthetical"), actual.parenthetical)) return false;
        if (!optFieldMatches(md.object.get("extra"), actual.extra)) return false;
        if (!optFieldMatches(md.object.get("plaintiff"), actual.plaintiff)) return false;
        if (!optFieldMatches(md.object.get("defendant"), actual.defendant)) return false;
        if (!optFieldMatches(md.object.get("antecedent_guess"), actual.antecedent_guess)) return false;
    }
    // year (validated integer; null when absent or out of range)
    if (expected.get("year")) |y| {
        const exp_year: ?u16 = switch (y) {
            .integer => |n| @intCast(n),
            else => null,
        };
        if (exp_year != actual.year) return false;
    }
    return true;
}

fn optFieldMatches(expected: ?std.json.Value, actual: ?[]const u8) bool {
    const exp_str = if (expected) |e| jsonStr(e) else null;
    if (exp_str == null and actual == null) return true;
    if (exp_str == null or actual == null) return false;
    return std.mem.eql(u8, exp_str.?, actual.?);
}

fn runCorpus(
    allocator: std.mem.Allocator,
    engine: incitez.extraction.Engine,
    ratchet: usize,
    label: []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, corpus_json, .{});
    defer parsed.deinit();

    var result: CaseResult = .{};
    defer {
        for (result.failures.items) |f| allocator.free(f);
        result.failures.deinit(allocator);
    }

    var methods_it = parsed.value.object.get("methods").?.object.iterator();
    while (methods_it.next()) |method| {
        for (method.value_ptr.array.items) |case_val| {
            const case = case_val.object;
            if (!caseEligible(case)) continue;
            result.attempted += 1;

            const text = jsonStr(case.get("text").?).?;
            const expected_cites = case.get("cites").?.array.items;

            const actual = try incitez.extraction.extractWithEngine(allocator, text, engine);
            defer incitez.extraction.freeCitations(allocator, actual);

            var ok = actual.len == expected_cites.len;
            if (ok) {
                for (expected_cites, actual) |exp, act| {
                    if (!citeMatches(text, exp.object, act)) {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok) {
                result.passed += 1;
            } else {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "[{s}] {s} (expected {d} cites, got {d})",
                    .{ method.key_ptr.*, text, expected_cites.len, actual.len },
                );
                try result.failures.append(allocator, msg);
            }
        }
    }

    if (result.attempted != RATCHET_EXPECTED_ATTEMPTED) {
        std.debug.print(
            "\n{s}: {d} eligible cases attempted (expected exactly {d})\n",
            .{ label, result.attempted, RATCHET_EXPECTED_ATTEMPTED },
        );
        return error.RatchetMismatch;
    }
    if (result.passed != ratchet) {
        std.debug.print(
            "\n{s} ratchet: {d}/{d} eligible cases pass (ratchet expects exactly {d})\n",
            .{ label, result.passed, result.attempted, ratchet },
        );
        if (result.passed < ratchet) {
            std.debug.print("REGRESSION — failing cases:\n", .{});
            for (result.failures.items) |f| std.debug.print("  {s}\n", .{f});
        } else {
            std.debug.print("progress! bump the {s} ratchet to {d} after reviewing\n", .{ label, result.passed });
        }
        return error.RatchetMismatch;
    }
}

test "acceptance ratchet (vm): full case citations vs eyecite corpus" {
    try runCorpus(std.testing.allocator, .vm, RATCHET_EXPECTED_PASSES, "vm");
}

test "acceptance ratchet (pcre2): full case citations vs eyecite corpus" {
    try runCorpus(std.testing.allocator, .pcre2, RATCHET_PCRE2_EXPECTED_PASSES, "pcre2");
}

// Cross-engine differential: both engines over EVERY corpus text (all
// methods, eligibility ignored — divergences on unsupported shapes are
// data, not noise). Two-sided: the divergence count must equal the
// constant exactly.
test "cross-engine differential: vm vs pcre2 over all corpus texts" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, corpus_json, .{});
    defer parsed.deinit();

    var diverged: usize = 0;
    var total: usize = 0;
    var methods_it = parsed.value.object.get("methods").?.object.iterator();
    while (methods_it.next()) |method| {
        for (method.value_ptr.array.items) |case_val| {
            const text = jsonStr(case_val.object.get("text").?).?;
            total += 1;

            const a = try incitez.extraction.extractWithEngine(allocator, text, .vm);
            defer incitez.extraction.freeCitations(allocator, a);
            const b = try incitez.extraction.extractWithEngine(allocator, text, .pcre2);
            defer incitez.extraction.freeCitations(allocator, b);

            var same = a.len == b.len;
            if (same) {
                for (a, b) |x, y| {
                    if (x.span_start != y.span_start or x.span_end != y.span_end or
                        x.edition != y.edition or x.year != y.year or
                        !optEq(x.volume, y.volume) or !optEq(x.page, y.page) or
                        !optEq(x.court, y.court))
                    {
                        same = false;
                        break;
                    }
                }
            }
            if (!same) {
                diverged += 1;
                std.debug.print("ENGINE DIVERGENCE [{s}]: {s} (vm {d} cites, pcre2 {d})\n", .{
                    method.key_ptr.*, text, a.len, b.len,
                });
            }
        }
    }

    if (diverged != EXPECTED_ENGINE_DIVERGENCES) {
        std.debug.print(
            "\ncross-engine: {d}/{d} texts diverge (expected exactly {d})\n",
            .{ diverged, total, EXPECTED_ENGINE_DIVERGENCES },
        );
        return error.RatchetMismatch;
    }
}

fn optEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

const resolve_corpus_json = @embedFile("corpus/eyecite_resolve_corpus.json");

/// Resolution-corpus ratchets (cases replicate eyecite checkResolution:
/// one cite per row text, combined list resolved, cluster indices compared).
const RESOLVE_EXPECTED_ATTEMPTED: usize = 23;
const RESOLVE_EXPECTED_PASSES: usize = 23; // full ResolveTest parity

test "resolution corpus: cluster assignments vs eyecite ResolveTest" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resolve_corpus_json, .{});
    defer parsed.deinit();

    var attempted: usize = 0;
    var passed: usize = 0;
    var methods_it = parsed.value.object.get("methods").?.object.iterator();
    while (methods_it.next()) |method| {
        for (method.value_ptr.array.items) |case_val| {
            attempted += 1;
            const rows = case_val.object.get("rows").?.array.items;

            var cites: std.ArrayListUnmanaged(incitez.extraction.Citation) = .empty;
            defer {
                for (cites.items) |*c| {
                    if (c.plaintiff) |p| allocator.free(p);
                    if (c.defendant) |d| allocator.free(d);
                    if (c.antecedent_guess) |a| allocator.free(a);
                }
                cites.deinit(allocator);
            }
            var extraction_ok = true;
            for (rows) |row| {
                const text = jsonStr(row.array.items[1]).?;
                const found = try incitez.extraction.extract(allocator, text);
                defer allocator.free(found);
                if (found.len != 1) {
                    extraction_ok = false;
                    for (found) |*c| {
                        if (c.plaintiff) |p| allocator.free(p);
                        if (c.defendant) |d| allocator.free(d);
                        if (c.antecedent_guess) |a| allocator.free(a);
                    }
                    break;
                }
                try cites.append(allocator, found[0]);
            }
            if (!extraction_ok) continue; // known gaps (law/journal/section)

            const assignment = try incitez.resolution.resolve(allocator, cites.items);
            defer allocator.free(assignment);

            // expected cluster index -> anchor citation index
            var anchors: [32]?u32 = @splat(null);
            var ok = true;
            for (rows, 0..) |row, i| {
                const exp = row.array.items[0];
                const want: ?u32 = switch (exp) {
                    .integer => |n| blk: {
                        const cl: usize = @intCast(n);
                        if (anchors[cl] == null) anchors[cl] = @intCast(i);
                        break :blk anchors[cl];
                    },
                    else => null,
                };
                if (want != assignment[i]) {
                    if (ok) std.debug.print(
                        "RESOLVE MISMATCH [{s}] row {d}: want={?d} got={?d}\n",
                        .{ method.key_ptr.*, i, want, assignment[i] },
                    );
                    ok = false;
                }
            }
            if (ok) passed += 1;
        }
    }

    if (attempted != RESOLVE_EXPECTED_ATTEMPTED or passed != RESOLVE_EXPECTED_PASSES) {
        std.debug.print(
            "\nresolution corpus: {d}/{d} pass (ratchet expects {d}/{d})\n",
            .{ passed, attempted, RESOLVE_EXPECTED_PASSES, RESOLVE_EXPECTED_ATTEMPTED },
        );
        return error.RatchetMismatch;
    }
}
