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
const RATCHET_EXPECTED_PASSES: usize = 64;

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
        if (!std.mem.eql(u8, t, "FullCaseCitation")) return false;
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

fn citeMatches(text: []const u8, expected: std.json.ObjectMap, actual: incitez.extraction.Citation) bool {
    // span
    const span = expected.get("span").?.array.items;
    const exp_bytes = charSpanToBytes(text, span[0].integer, span[1].integer);
    if (actual.span_start != exp_bytes[0] or actual.span_end != exp_bytes[1]) return false;
    // groups: volume, reporter, page (may be null/absent)
    const groups = expected.get("groups").?.object;
    if (!optFieldMatches(groups.get("volume"), actual.volume)) return false;
    if (!optFieldMatches(groups.get("reporter"), actual.reporter)) return false;
    if (!optFieldMatches(groups.get("page"), actual.page)) return false;
    // corrected reporter
    if (expected.get("corrected_reporter")) |cr| {
        if (jsonStr(cr)) |s| {
            if (!std.mem.eql(u8, s, actual.correctedReporter())) return false;
        }
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

test "acceptance ratchet: full case citations vs eyecite corpus" {
    const allocator = std.testing.allocator;
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

            const actual = try incitez.extraction.extract(allocator, text);
            defer allocator.free(actual);

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

    if (result.passed != RATCHET_EXPECTED_PASSES) {
        std.debug.print(
            "\nacceptance ratchet: {d}/{d} eligible cases pass (ratchet expects exactly {d})\n",
            .{ result.passed, result.attempted, RATCHET_EXPECTED_PASSES },
        );
        if (result.passed < RATCHET_EXPECTED_PASSES) {
            std.debug.print("REGRESSION — failing cases:\n", .{});
            for (result.failures.items) |f| std.debug.print("  {s}\n", .{f});
        } else {
            std.debug.print(
                "progress! bump RATCHET_EXPECTED_PASSES to {d} after reviewing\n",
                .{result.passed},
            );
        }
        return error.RatchetMismatch;
    }
}
