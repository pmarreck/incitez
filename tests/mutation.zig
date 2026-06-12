//! Mutation suite (citation-domain shotgun test): corrupt known-good
//! citations and assert extraction degrades PREDICTABLY.
//!
//! Members:
//!  - kill-class operators (reporter corruption) must make the original
//!    citation disappear — must-detect bits;
//!  - perturbation operators (volume/page digit edits) must never leave the
//!    original citation intact at the same span;
//!  - the specificity arm: unmutated texts must keep extracting (a
//!    reject-everything extractor scores zero here);
//!  - every mutant must produce IDENTICAL results from both engines —
//!    independent implementations agreeing on garbage inputs is the
//!    strongest cheap check we have against engine-specific crashes.
//! Counts are exact (seeded PRNG): regressions AND silent behavior shifts
//! both trip the two-sided tallies.
const std = @import("std");
const incitez = @import("incitez");

const corpus_json = @embedFile("corpus/eyecite_corpus.json");

const SEED: u64 = 0x1ec17e5_2026;

/// Two-sided expected tallies — bump consciously when behavior changes.
const EXPECTED_TEXTS: usize = 179;
const EXPECTED_REPORTER_KILLS: usize = 176; // 3 survivors: section-token words immune to letter corruption (predictable)

fn engineAgree(allocator: std.mem.Allocator, text: []const u8) !bool {
    const a = try incitez.extraction.extractWithEngine(allocator, text, .vm);
    defer incitez.extraction.freeCitations(allocator, a);
    const b = try incitez.extraction.extractWithEngine(allocator, text, .pcre2);
    defer incitez.extraction.freeCitations(allocator, b);
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.span_start != y.span_start or x.span_end != y.span_end or
            x.kind != y.kind or x.edition != y.edition) return false;
    }
    return true;
}

test "mutation suite: predictable degradation + cross-engine agreement on mutants" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, corpus_json, .{});
    defer parsed.deinit();

    var prng = std.Random.DefaultPrng.init(SEED);
    const rand = prng.random();

    var texts: usize = 0;
    var reporter_kills: usize = 0;
    var reporter_mutants: usize = 0;
    var digit_mutants: usize = 0;
    var digit_survivors: usize = 0;
    var engine_disagreements: usize = 0;

    var buf: [4096]u8 = undefined;

    var methods_it = parsed.value.object.get("methods").?.object.iterator();
    while (methods_it.next()) |method| {
        for (method.value_ptr.array.items) |case_val| {
            const text = switch (case_val.object.get("text").?) {
                .string => |s| s,
                else => continue,
            };
            if (text.len == 0 or text.len > buf.len) continue;

            // control arm: the original must extract at least one citation
            const orig = try incitez.extraction.extract(allocator, text);
            defer incitez.extraction.freeCitations(allocator, orig);
            if (orig.len == 0) continue;
            texts += 1;
            const c0 = orig[0];

            // operator 1: corrupt one alpha char inside the reporter slice
            {
                @memcpy(buf[0..text.len], text);
                const rep_off = @intFromPtr(c0.reporter.ptr) - @intFromPtr(text.ptr);
                var corrupted = false;
                for (buf[rep_off .. rep_off + c0.reporter.len]) |*ch| {
                    if (std.ascii.isAlphabetic(ch.*)) {
                        ch.* = if (ch.* == 'q') 'x' else 'q';
                        corrupted = true;
                        break;
                    }
                }
                if (corrupted) {
                    reporter_mutants += 1;
                    const mutant = buf[0..text.len];
                    if (!try engineAgree(allocator, mutant)) engine_disagreements += 1;
                    const after = try incitez.extraction.extract(allocator, mutant);
                    defer incitez.extraction.freeCitations(allocator, after);
                    var original_survives = false;
                    for (after) |c| {
                        if (c.span_start == c0.span_start and c.span_end == c0.span_end and
                            c.edition == c0.edition) original_survives = true;
                    }
                    if (!original_survives) reporter_kills += 1;
                }
            }

            // operator 2: perturb one digit of the volume or page
            {
                @memcpy(buf[0..text.len], text);
                const target: ?[]const u8 = c0.volume orelse c0.page;
                if (target) |t| {
                    const off = @intFromPtr(t.ptr) - @intFromPtr(text.ptr);
                    const idx = off + rand.uintLessThan(usize, t.len);
                    if (std.ascii.isDigit(buf[idx])) {
                        buf[idx] = if (buf[idx] == '9') '3' else buf[idx] + 1;
                        digit_mutants += 1;
                        const mutant = buf[0..text.len];
                        if (!try engineAgree(allocator, mutant)) engine_disagreements += 1;
                        const after = try incitez.extraction.extract(allocator, mutant);
                        defer incitez.extraction.freeCitations(allocator, after);
                        for (after) |c| {
                            // the ORIGINAL volume+page combination must not
                            // reappear at the original span
                            if (c.span_start == c0.span_start and c.span_end == c0.span_end and
                                eqOpt(c.volume, c0.volume) and eqOpt(c.page, c0.page))
                            {
                                digit_survivors += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // hard invariants
    if (engine_disagreements != 0) {
        std.debug.print("\nmutation: {d} cross-engine disagreements on mutants\n", .{engine_disagreements});
        return error.EngineDisagreementOnMutants;
    }
    if (digit_survivors != 0) {
        std.debug.print("\nmutation: {d} digit mutants left the original citation intact\n", .{digit_survivors});
        return error.UndetectedDigitMutation;
    }
    // two-sided tallies
    if (texts != EXPECTED_TEXTS or reporter_kills != EXPECTED_REPORTER_KILLS) {
        std.debug.print(
            "\nmutation tallies: texts={d} (exp {d}), reporter kills={d}/{d} (exp {d})\n",
            .{ texts, EXPECTED_TEXTS, reporter_kills, reporter_mutants, EXPECTED_REPORTER_KILLS },
        );
        return error.RatchetMismatch;
    }
}

fn eqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}
