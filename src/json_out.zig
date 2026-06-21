//! Single source of truth for the `--json` citation schema. Both the C CLI
//! (via the FFI) and the WASM export serialize through this, so their output
//! is byte-identical by construction — which makes incitez_web's
//! `wasm.process(x) == CLI --json(x)` differential gate trivially sound.
const std = @import("std");
const extraction = @import("extract.zig");
const Citation = extraction.Citation;

pub fn kindName(kind: extraction.Kind) []const u8 {
    return switch (kind) {
        .full_case => "FullCaseCitation",
        .short_case => "ShortCaseCitation",
        .supra => "SupraCitation",
        .id => "IdCitation",
        .reference => "ReferenceCitation",
        .unknown => "UnknownCitation",
        .full_law => "FullLawCitation",
        .short_law => "ShortLawCitation",
        .full_journal => "FullJournalCitation",
    };
}

/// Writes the citation array as JSON to `w`, exactly mirroring the legacy C
/// CLI byte layout (spacing, field order, null handling).
pub fn writeJson(
    w: *std.Io.Writer,
    cites: []const Citation,
    assignment: []const ?u32,
) !void {
    try w.writeAll("[");
    for (cites, assignment, 0..) |c, res, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n {\"kind\": ");
        try jsonString(w, kindName(c.kind));
        try w.print(
            ", \"span\": [{d}, {d}], \"full_span\": [{d}, {d}]",
            .{ c.span_start, c.span_end, c.full_span_start, c.full_span_end },
        );
        const is_token = c.kind == .supra or c.kind == .id or
            c.kind == .unknown or c.kind == .reference;
        try jsonField(w, "volume", c.volume);
        try jsonField(w, "reporter", if (is_token) null else c.reporter);
        try jsonField(w, "page", c.page);
        try jsonField(w, "title", c.title);
        try jsonField(w, "section", c.section);
        try jsonField(w, "corrected_reporter", if (is_token) null else c.correctedReporter());
        try jsonField(w, "pin_cite", c.pin_cite);
        try jsonField(w, "court", c.court);
        if (c.year) |y| try w.print(", \"year\": {d}", .{y}) else try w.writeAll(", \"year\": null");
        try jsonField(w, "parenthetical", c.parenthetical);
        try jsonField(w, "extra", c.extra);
        try jsonField(w, "plaintiff", c.plaintiff);
        try jsonField(w, "defendant", c.defendant);
        try jsonField(w, "antecedent_guess", c.antecedent_guess);
        if (res) |r| try w.print(", \"resolution\": {d}", .{r}) else try w.writeAll(", \"resolution\": null");
        try w.writeAll("}");
    }
    try w.writeAll("\n]\n");
}

fn jsonField(w: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    try w.print(", \"{s}\": ", .{name});
    if (value) |v| try jsonString(w, v) else try w.writeAll("null");
}

fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
