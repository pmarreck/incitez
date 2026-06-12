//! PCRE2 engine path: runs the eyecite-literal extractor regexes verbatim
//! over the whole text (architecturally what eyecite's Python `re`/hyperscan
//! tokenizer does), rather than incitez's anchored pattern VM. This is a
//! deliberately independent second implementation — the dual-engine harness
//! compares both against each other and against the Python oracle corpus,
//! measuring error rates and performance per engine.
const std = @import("std");
const tables = @import("reporters_tables");

// ── PCRE2 C API (8-bit code units) ───────────────────────────────────

const pcre2_code = opaque {};
const pcre2_match_data = opaque {};

extern fn pcre2_compile_8(
    pattern: [*]const u8,
    length: usize,
    options: u32,
    errorcode: *c_int,
    erroroffset: *usize,
    ccontext: ?*anyopaque,
) ?*pcre2_code;
extern fn pcre2_jit_compile_8(code: *pcre2_code, options: u32) c_int;
extern fn pcre2_match_8(
    code: *const pcre2_code,
    subject: [*]const u8,
    length: usize,
    startoffset: usize,
    options: u32,
    match_data: *pcre2_match_data,
    mcontext: ?*anyopaque,
) c_int;
extern fn pcre2_match_data_create_from_pattern_8(
    code: *const pcre2_code,
    gcontext: ?*anyopaque,
) ?*pcre2_match_data;
extern fn pcre2_match_data_free_8(md: *pcre2_match_data) void;
extern fn pcre2_get_ovector_pointer_8(md: *pcre2_match_data) [*]usize;
extern fn pcre2_substring_number_from_name_8(
    code: *const pcre2_code,
    name: [*:0]const u8,
) c_int;

const PCRE2_JIT_COMPLETE: u32 = 0x00000001;
const PCRE2_UNSET = std.math.maxInt(usize);
const PCRE2_ERROR_NOMATCH: c_int = -1;

const Extractor = struct {
    code: *pcre2_code,
    volume: c_int, // named-group numbers; < 0 when the pattern lacks them
    reporter: c_int,
    page: c_int,
    edition: u32,
    is_variant: bool,
    short: bool,
};

// One-shot lazy init (std.once is gone in 0.16; 3-state atomic instead).
// Compiled codes live for the process lifetime by design.
var init_state: std.atomic.Value(u8) = .init(0); // 0=uninit 1=busy 2=ready
var extractors: [tables.pcre2_extractors.len]Extractor = undefined;

fn ensureInit() void {
    if (init_state.load(.acquire) == 2) return;
    if (init_state.cmpxchgStrong(0, 1, .acquire, .acquire) != null) {
        while (init_state.load(.acquire) != 2) std.atomic.spinLoopHint();
        return;
    }
    defer init_state.store(2, .release);
    for (tables.pcre2_extractors, 0..) |ex, i| {
        var errcode: c_int = 0;
        var erroff: usize = 0;
        const code = pcre2_compile_8(ex.regex.ptr, ex.regex.len, 0, &errcode, &erroff, null) orelse {
            std.debug.panic(
                "pcre2_compile failed (err {d} at byte {d}) for: {s}",
                .{ errcode, erroff, ex.regex },
            );
        };
        // best-effort: falls back to the interpreter where JIT is unavailable
        _ = pcre2_jit_compile_8(code, PCRE2_JIT_COMPLETE);
        extractors[i] = .{
            .code = code,
            .volume = pcre2_substring_number_from_name_8(code, "volume"),
            .reporter = pcre2_substring_number_from_name_8(code, "reporter"),
            .page = pcre2_substring_number_from_name_8(code, "page"),
            .edition = ex.edition,
            .is_variant = ex.is_variant,
            .short = ex.short,
        };
    }
}

pub const Candidate = struct {
    start: u32,
    end: u32,
    volume: ?[]const u8,
    reporter: []const u8,
    page: ?[]const u8,
    edition: u32,
    is_variant: bool,
    short: bool,
};

/// Runs every extractor over the text (finditer semantics: scan resumes at
/// the end of the WHOLE match, trailing boundary char included), then merges
/// candidates non-overlapping: earliest start wins, ties to the longest.
pub fn scan(allocator: std.mem.Allocator, text: []const u8) ![]Candidate {
    ensureInit();
    var all: std.ArrayListUnmanaged(Candidate) = .empty;
    defer all.deinit(allocator);

    for (&extractors) |*ex| {
        const md = pcre2_match_data_create_from_pattern_8(ex.code, null) orelse
            return error.OutOfMemory;
        defer pcre2_match_data_free_8(md);
        var offset: usize = 0;
        while (offset <= text.len) {
            const rc = pcre2_match_8(ex.code, text.ptr, text.len, offset, 0, md, null);
            if (rc == PCRE2_ERROR_NOMATCH) break;
            if (rc < 0) return error.Pcre2MatchError;
            const ov = pcre2_get_ovector_pointer_8(md);
            const next_offset = if (ov[1] > offset) ov[1] else offset + 1;
            // group 1 = the citation body inside the boundary wrapper
            if (groupSlice(text, ov, ex.reporter)) |rep| {
                try all.append(allocator, .{
                    .start = @intCast(ov[2]),
                    .end = @intCast(ov[3]),
                    .volume = groupSlice(text, ov, ex.volume),
                    .reporter = rep,
                    .page = groupSlice(text, ov, ex.page),
                    .edition = ex.edition,
                    .is_variant = ex.is_variant,
                    .short = ex.short,
                });
            }
            offset = next_offset;
        }
    }

    std.mem.sort(Candidate, all.items, {}, candidateLessThan);
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer out.deinit(allocator);
    var last_end: u32 = 0;
    for (all.items) |cand| {
        if (out.items.len == 0 or cand.start >= last_end) {
            try out.append(allocator, cand);
            last_end = cand.end;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

fn groupSlice(text: []const u8, ov: [*]usize, group: c_int) ?[]const u8 {
    if (group < 0) return null;
    const g: usize = @intCast(group);
    const s = ov[2 * g];
    if (s == PCRE2_UNSET) return null;
    return text[s..ov[2 * g + 1]];
}
