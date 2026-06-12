//! Case-name extraction: a faithful port of eyecite's find_case_name
//! (_scan_for_case_boundaries + _process_case_name + strip_stop_words).
//!
//! eyecite walks a token list (words, single-space separators, citation/
//! placeholder/stop-word tokens) backward from the citation. This port
//! reconstructs the same elements directly from the text: contiguous byte
//! ranges classified on the fly, so candidate case names are plain slices
//! until the cleaning passes require allocation.
const std = @import("std");
const reporters = @import("reporters.zig");

pub const CaseName = struct {
    plaintiff: ?[]u8 = null, // allocated; null when absent/empty
    defendant: ?[]u8 = null, // allocated
    antecedent: ?[]u8 = null, // allocated; short-form citations only
    year_text: ?[]const u8 = null, // pre-citation "(YYYY)" year, slice
    full_span_start: ?u32 = null,
};

pub const CiteSpan = struct { start: u32, end: u32 };

const BACKWARD_SEEK = 28; // eyecite: median case name length in tokens

const STOP_WORDS = [_][]const u8{
    "v",      "in re",   "re",       "quoting", "e.g.",    "parte",
    "denied", "citing",  "aff'd",    "affirmed", "remanded", "see also",
    "see",    "granted", "dismissed", "Cf",
};

const ElementKind = enum { word, space, citation, placeholder, stop_word, supra, paragraph };

const Element = struct {
    kind: ElementKind,
    start: usize,
    end: usize,
    is_v: bool = false,
};

pub const TokenSpan = struct { start: usize, end: usize, kind: ElementKind };

const Walker = struct {
    text: []const u8,
    tokens: []const TokenSpan, // other citations + placeholder tokens

    /// The element ending at byte offset `pos` (exclusive), or null at 0.
    fn prev(w: *const Walker, pos: usize) ?Element {
        if (pos == 0) return null;
        for (w.tokens) |s| {
            if (s.end == pos) return .{ .kind = s.kind, .start = s.start, .end = pos };
        }
        if (w.text[pos - 1] == ' ') return .{ .kind = .space, .start = pos - 1, .end = pos };
        if (w.text[pos - 1] == '\n') return .{ .kind = .paragraph, .start = pos - 1, .end = pos };
        var start = pos;
        while (start > 0 and w.text[start - 1] != ' ' and w.text[start - 1] != '\n') {
            var crosses = false;
            for (w.tokens) |s| {
                if (s.end == start) crosses = true;
            }
            if (crosses) break;
            start -= 1;
        }
        const word = w.text[start..pos];

        const c = core(word);
        if (std.ascii.eqlIgnoreCase(c, "supra")) {
            return .{ .kind = .supra, .start = start, .end = pos };
        }
        // two-word stop tokens ("in re", "see also") — match the tokenizer,
        // which extracts them as single tokens
        if (std.mem.eql(u8, c, "re") or std.mem.eql(u8, c, "also")) {
            const first: []const u8 = if (c[0] == 'r') "in" else "see";
            if (start >= 2 and w.text[start - 1] == ' ') {
                var ps = start - 1;
                while (ps > 0 and w.text[ps - 1] != ' ' and w.text[ps - 1] != '\n') ps -= 1;
                if (std.mem.eql(u8, core(w.text[ps .. start - 1]), first)) {
                    return .{ .kind = .stop_word, .start = ps, .end = pos };
                }
            }
        }
        for (STOP_WORDS) |sw| {
            if (std.mem.eql(u8, c, sw)) {
                return .{
                    .kind = .stop_word,
                    .start = start,
                    .end = pos,
                    .is_v = std.mem.eql(u8, c, "v"),
                };
            }
        }
        return .{ .kind = .word, .start = start, .end = pos };
    }

};

fn isDashRun(word: []const u8) bool {
    if (word.len == 0) return false;
    var i: usize = 0;
    while (i < word.len) {
        if (word[i] == '-' or word[i] == '_') {
            i += 1;
        } else if (i + 3 <= word.len and word[i] == 0xe2 and word[i + 1] == 0x80 and
            (word[i + 2] == 0x93 or word[i + 2] == 0x94))
        { // – —
            i += 3;
        } else return false;
    }
    return true;
}

/// Forward scan for PLACEHOLDER_CITATIONS tokens (`dashes \\s reporter
/// \\s dashes`) in the window before the citation — these are cut out of
/// the word stream exactly like the tokenizer does. Reporter resolution
/// uses the match table (a superset of upstream's fixed placeholder list).
fn scanPlaceholders(text: []const u8, before: usize, out: []TokenSpan) usize {
    var n: usize = 0;
    const window_start = before -| 400;
    var i = window_start;
    while (i < before and n < out.len) {
        if (!isDashChar(text, i)) {
            i += 1;
            continue;
        }
        const d1_start = i;
        var j = i;
        while (j < before and isDashChar(text, j)) j += dashCharLen(text, j);
        if (j >= before or text[j] != ' ') {
            i = j + 1;
            continue;
        }
        const rep_start = j + 1;
        if (reporters.longestMatch(text[rep_start..])) |m| {
            const rep_end = rep_start + m.key_len;
            if (rep_end < before and text[rep_end] == ' ' and rep_end + 1 < before and
                isDashChar(text, rep_end + 1))
            {
                var k = rep_end + 1;
                while (k < text.len and isDashChar(text, k)) k += dashCharLen(text, k);
                out[n] = .{ .start = d1_start, .end = k, .kind = .placeholder };
                n += 1;
                i = k;
                continue;
            }
        }
        i = j + 1;
    }
    return n;
}

fn isDashChar(text: []const u8, i: usize) bool {
    if (text[i] == '-' or text[i] == '_') return true;
    return i + 3 <= text.len and text[i] == 0xe2 and text[i + 1] == 0x80 and
        (text[i + 2] == 0x93 or text[i + 2] == 0x94);
}

fn dashCharLen(text: []const u8, i: usize) usize {
    return if (text[i] == '-' or text[i] == '_') 1 else 3;
}

/// Outer-punctuation-stripped view of a word (the tokenizer's
/// strip_punctuation_re: `[^\s a-zA-Z0-9]*` shells around stop words).
fn core(word: []const u8) []const u8 {
    var s: usize = 0;
    var e: usize = word.len;
    while (s < e and !std.ascii.isAlphanumeric(word[s]) and word[s] != '\'') s += 1;
    while (e > s and !std.ascii.isAlphanumeric(word[e - 1])) {
        // keep "e.g." / "aff'd" inner punctuation by only trimming the shell
        if (word[e - 1] == '.' and e >= 2 and std.ascii.isAlphanumeric(word[e - 2]) and
            (std.mem.indexOfScalar(u8, word[s..e], ' ') == null) and isKnownDotted(word[s..e]))
            break;
        e -= 1;
    }
    return word[s..e];
}

fn isKnownDotted(w: []const u8) bool {
    return std.ascii.eqlIgnoreCase(w, "e.g.") or std.ascii.eqlIgnoreCase(w, "rel.");
}

fn startsUpper(word: []const u8) bool {
    return word.len > 0 and word[0] >= 'A' and word[0] <= 'Z';
}

fn isArticle(word: []const u8) bool {
    for ([_][]const u8{ "of", "the", "an", "and" }) |a| {
        if (std.mem.eql(u8, word, a)) return true;
    }
    return false;
}

/// Port of _scan_for_case_boundaries + _process_case_name.
pub fn findCaseName(
    alloc: std.mem.Allocator,
    text: []const u8,
    self_span: CiteSpan,
    other_spans: []const CiteSpan,
    short: bool,
) !CaseName {
    var tokens_buf: [48]TokenSpan = undefined;
    var n_tokens: usize = 0;
    for (other_spans) |s| {
        if (n_tokens == tokens_buf.len) break;
        tokens_buf[n_tokens] = .{ .start = s.start, .end = s.end, .kind = .citation };
        n_tokens += 1;
    }
    n_tokens += scanPlaceholders(text, self_span.start, tokens_buf[n_tokens..]);
    const w: Walker = .{ .text = text, .tokens = tokens_buf[0..n_tokens] };

    var pos: usize = self_span.start;
    // title_starting_index = citation.index - 1: the candidate excludes the
    // single element immediately before the citation, whatever it is
    var title_end: usize = self_span.start;
    if (w.prev(self_span.start)) |e| title_end = e.start;

    const title_end0 = title_end;
    var v_seen = false;
    var start_byte: ?usize = null;
    var elem_start_byte: ?usize = null; // pre-trim element start (full_span)
    var has_candidate = false;
    var pre_cite_year: ?[]const u8 = null;
    var case_name_length: usize = 0;
    var plaintiff_length: usize = 0;
    var iterations: usize = 0;

    while (iterations < BACKWARD_SEEK) : (iterations += 1) {
        const elem = w.prev(pos) orelse break;
        const word = text[elem.start..elem.end];
        defer pos = elem.start;

        // skip bare commas
        if (std.mem.eql(u8, word, ",")) continue;

        case_name_length += 1;
        if (v_seen and elem.kind != .space) plaintiff_length += 1;

        switch (elem.kind) {
            .citation => {
                title_end = if (w.prev(elem.start)) |e| e.start else elem.start;
                continue;
            },
            .space => {
                if (elem.start == 0) break;
                continue;
            },
            else => {},
        }

        // terminal punctuation
        if (std.mem.endsWith(u8, word, ";") or std.mem.endsWith(u8, word, "\"") or
            std.mem.endsWith(u8, word, "\xe2\x80\x9d")) // ”
        {
            start_byte = afterElement(text, elem.end);
            has_candidate = true;
            break;
        }

        // pre-citation year "(YYYY)..."
        if (word.len >= 6 and word[0] == '(' and word[5] == ')' and allDigits(word[1..5])) {
            title_end = if (w.prev(elem.start)) |e| e.start else elem.start;
            pre_cite_year = word[1..5];
            continue;
        }

        // opening paren after the first few words
        if (word[0] == '(' and case_name_length > 3) {
            start_byte = elem.start;
            if (word.len == 1 or (word.len > 1 and word[1] >= 'a' and word[1] <= 'z')) {
                start_byte = afterElement(text, elem.end);
            }
            elem_start_byte = start_byte;
            has_candidate = true;
            break;
        }

        // lowercase word after "v"
        if (v_seen and !startsUpper(word) and !isArticle(word)) {
            start_byte = afterElement(text, elem.end);
            elem_start_byte = start_byte;
            has_candidate = true;
            // strip leading article + space from the candidate (name only)
            start_byte = stripLeadingArticle(text, start_byte.?, title_end, true);
            break;
        }

        if (elem.kind == .placeholder) {
            title_end = if (w.prev(elem.start)) |e| e.start else elem.start;
            continue;
        }

        if (elem.kind == .stop_word and elem.is_v) {
            v_seen = true;
            start_byte = twoElementsBack(&w, elem.start);
            elem_start_byte = start_byte;
            has_candidate = start_byte != null;
            continue;
        }

        // likely new sentence (capitalized abbreviation) or stop word
        const cap_abbrev = v_seen and startsUpper(word) and word.len > 4 and
            std.mem.endsWith(u8, word, ".") and plaintiff_length > 1;
        if (cap_abbrev or elem.kind == .stop_word) {
            start_byte = afterElement(text, elem.end);
            elem_start_byte = start_byte;
            has_candidate = true;
            break;
        }

        // lowercase word without "v"
        if (!v_seen and !startsUpper(word) and word.len > 0 and
            std.ascii.isAlphabetic(word[0]) and !isArticle(word))
        {
            if (std.mem.eql(u8, word, "ex") or std.mem.eql(u8, word, "rel.")) continue;
            if (elem.kind == .supra) {
                title_end = if (w.prev(elem.start)) |e| e.start else elem.start;
                continue;
            }
            const sb = afterElement(text, elem.end);
            elem_start_byte = sb;
            // keep from the first capitalized word, else no candidate
            if (firstCapitalAt(text, sb, title_end)) |cap_at| {
                start_byte = cap_at;
                has_candidate = true;
            } else {
                has_candidate = false;
            }
            break;
        }

        if (elem.start == 0) {
            start_byte = stripLeadingArticle(text, 0, title_end, false);
            elem_start_byte = 0;
            has_candidate = true;
            // drop if the candidate ends in a standalone number
            if (endsWithBareNumber(text[start_byte.?..title_end])) has_candidate = false;
            break;
        }
    }

    if (!has_candidate or start_byte == null or start_byte.? >= title_end) return .{};
    const candidate = text[start_byte.?..title_end];

    var result: CaseName = .{};
    var defendant_part: []const u8 = candidate;

    if (v_seen) {
        const split = splitOnV(candidate);
        var plaintiff_part: []const u8 = "";
        if (split) |sp| {
            plaintiff_part = candidate[0..sp.before_end];
            defendant_part = candidate[sp.after_start..];
        }
        if (!short) {
            const plaintiff_trimmed = std.mem.trim(u8, plaintiff_part, " \t\r\n,(");
            const no_lower = try removeLowercaseWords(alloc, plaintiff_trimmed);
            defer alloc.free(no_lower);
            const p = try stripStopWords(alloc, no_lower);
            if (p.len > 0) result.plaintiff = p else alloc.free(p);
        }
    }

    const d = try stripStopWords(alloc, defendant_part);
    if (d.len > 0) {
        if (short) result.antecedent = d else result.defendant = d;
        // offset = len(join(words[start_index : index-1])) + 1, from the
        // RAW element start (candidate trimming does not move full_span)
        const es = elem_start_byte orelse start_byte.?;
        const join_len = title_end0 -| es;
        result.full_span_start = @intCast(self_span.start -| (join_len + 1));
    } else {
        alloc.free(d);
    }

    if (pre_cite_year) |y| result.year_text = y;
    return result;
}

/// `start_index = index + 2`: the element after the space after this one.
fn afterElement(text: []const u8, elem_end: usize) usize {
    if (elem_end < text.len and text[elem_end] == ' ') return elem_end + 1;
    return elem_end;
}

/// `start_index = index - 2` at the v token: one word further back. When
/// the v token is at (or one element from) the text start, eyecite's index
/// goes negative and Python's negative slicing yields an EMPTY candidate -
/// mirrored here as null.
fn twoElementsBack(w: *const Walker, elem_start: usize) ?usize {
    const sp = w.prev(elem_start) orelse return null;
    const word = w.prev(sp.start) orelse return null;
    return word.start;
}

fn stripLeadingArticle(text: []const u8, start: usize, end: usize, require_space: bool) usize {
    const slice = text[start..end];
    for ([_][]const u8{ "of", "the", "an", "and" }) |a| {
        if (slice.len < a.len) continue;
        const head_matches = if (require_space)
            std.mem.startsWith(u8, slice, a)
        else
            std.ascii.startsWithIgnoreCase(slice, a);
        if (!head_matches) continue;
        const after = slice[a.len..];
        if (require_space) {
            // ^(of|the|an|and)\s+ - whitespace required
            if (after.len > 0 and after[0] == ' ') {
                var k = a.len;
                while (k < slice.len and slice[k] == ' ') k += 1;
                return start + k;
            }
        } else {
            // ^(of|the|an|and)\b - word boundary also matches end-of-string
            if (after.len == 0 or !isWordChar(after[0])) {
                return start + a.len;
            }
        }
    }
    return start;
}

fn firstCapitalAt(text: []const u8, start: usize, end: usize) ?usize {
    var i = start;
    while (i < end) : (i += 1) {
        const c = text[i];
        if (c >= 'A' and c <= 'Z') {
            if (i == 0 or !isWordChar(text[i - 1])) return i;
        }
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn endsWithBareNumber(s: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, s, " ");
    if (trimmed.len == 0) return false;
    var i = trimmed.len;
    while (i > 0 and isDigit(trimmed[i - 1])) i -= 1;
    if (i == trimmed.len) return false;
    return i == 0 or !isWordChar(trimmed[i - 1]);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

const VSplit = struct { before_end: usize, after_start: usize };

/// First `\s+v\.?\s+` in the candidate.
fn splitOnV(s: []const u8) ?VSplit {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != ' ') continue;
        var j = i;
        while (j < s.len and s[j] == ' ') j += 1;
        if (j >= s.len or s[j] != 'v') continue;
        var k = j + 1;
        if (k < s.len and s[k] == '.') k += 1;
        if (k >= s.len or s[k] != ' ') continue;
        while (k < s.len and s[k] == ' ') k += 1;
        return .{ .before_end = i, .after_start = k };
    }
    return null;
}

/// re.sub(r"\b[a-z]\w*\b", "", s): remove words starting with a lowercase
/// ASCII letter (their characters only; surrounding spaces remain).
fn removeLowercaseWords(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 'a' and c <= 'z' and (i == 0 or !isWordChar(s[i - 1]))) {
            var j = i;
            while (j < s.len and isWordChar(s[j])) j += 1;
            i = j;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Port of eyecite strip_stop_words: two stop-word removal passes
/// (case-sensitive→space, then case-insensitive→empty), leading "In "
/// strip, paren shell trim, ';' tail selection, ", " trims.
pub fn stripStopWords(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const pass1 = try subStopWords(alloc, input, false);
    defer alloc.free(pass1);

    var t: []const u8 = pass1;
    // ^(?i)In\s+
    if (t.len > 2 and std.ascii.eqlIgnoreCase(t[0..2], "in") and std.ascii.isWhitespace(t[2])) {
        var k: usize = 2;
        while (k < t.len and std.ascii.isWhitespace(t[k])) k += 1;
        t = t[k..];
    }
    t = std.mem.trim(u8, t, " \t\r\n");
    t = std.mem.trimStart(u8, t, "(");
    t = std.mem.trimEnd(u8, t, ")");
    if (std.mem.indexOfScalar(u8, t, ';')) |semi| {
        const rest = t[semi + 1 ..];
        t = if (std.mem.indexOfScalar(u8, rest, ';')) |s2| rest[0..s2] else rest;
    }

    const pre = std.mem.trim(u8, t, ", ");
    const pass2 = try subStopWords(alloc, pre, true);
    defer alloc.free(pass2);
    const final = std.mem.trim(u8, std.mem.trim(u8, pass2, ", "), " \t\r\n");
    return alloc.dupe(u8, final);
}

/// One STOP_WORD_REGEX substitution pass at word granularity. A matched
/// stop word consumes its trailing space, so an immediately following stop
/// word lacks its leading boundary and survives (Python quirk, mirrored).
fn subStopWords(alloc: std.mem.Allocator, s: []const u8, case_insensitive: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var prev_was_stop = false;
    var first = true;
    while (i < s.len) {
        if (s[i] == ' ') {
            try out.append(alloc, ' ');
            i += 1;
            continue;
        }
        var j = i;
        while (j < s.len and s[j] != ' ') j += 1;
        var consumed = j;
        var is_stop = false;
        if (!prev_was_stop) {
            const c1 = core(s[i..j]);
            // two-word stops first
            if (matchWord(c1, "in", case_insensitive) or matchWord(c1, "see", case_insensitive)) {
                var j2 = j;
                while (j2 < s.len and s[j2] == ' ') j2 += 1;
                var j3 = j2;
                while (j3 < s.len and s[j3] != ' ') j3 += 1;
                const c2 = core(s[j2..j3]);
                const two_ok = (matchWord(c1, "in", case_insensitive) and matchWord(c2, "re", case_insensitive)) or
                    (matchWord(c1, "see", case_insensitive) and matchWord(c2, "also", case_insensitive));
                if (two_ok) {
                    is_stop = true;
                    consumed = j3;
                }
            }
            if (!is_stop) {
                for (STOP_WORDS) |sw| {
                    if (std.mem.indexOfScalar(u8, sw, ' ') != null) continue;
                    if (matchWord(c1, sw, case_insensitive)) {
                        is_stop = true;
                        break;
                    }
                }
            }
        }
        if (is_stop) {
            // the match consumes the trailing space; emit one space in pass1
            // style (replacement collapses), nothing extra otherwise
            if (consumed < s.len and s[consumed] == ' ') consumed += 1;
            if (!first and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(alloc, ' ');
            }
            prev_was_stop = true;
            i = consumed;
        } else {
            try out.appendSlice(alloc, s[i..consumed]);
            prev_was_stop = false;
            i = consumed;
        }
        first = false;
    }
    return out.toOwnedSlice(alloc);
}

fn matchWord(a: []const u8, b: []const u8, case_insensitive: bool) bool {
    if (case_insensitive) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

/// match_on_tokens(..., forward=False, strings_only=True) window: the text
/// region before the citation bounded by the nearest token (citation,
/// placeholder, stop word, supra, paragraph break) or MAX_MATCH_CHARS.
pub fn preCiteWindowStart(
    text: []const u8,
    self_span: CiteSpan,
    other_spans: []const CiteSpan,
) usize {
    var tokens_buf: [48]TokenSpan = undefined;
    var n_tokens: usize = 0;
    for (other_spans) |s| {
        if (n_tokens == tokens_buf.len) break;
        tokens_buf[n_tokens] = .{ .start = s.start, .end = s.end, .kind = .citation };
        n_tokens += 1;
    }
    n_tokens += scanPlaceholders(text, self_span.start, tokens_buf[n_tokens..]);
    const w: Walker = .{ .text = text, .tokens = tokens_buf[0..n_tokens] };

    const floor = self_span.start -| 300;
    var pos: usize = self_span.start;
    while (pos > floor) {
        const elem = w.prev(pos) orelse break;
        switch (elem.kind) {
            .word, .space => pos = elem.start,
            else => return elem.end,
        }
    }
    return @max(pos, floor);
}
