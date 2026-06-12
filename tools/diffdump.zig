//! Differential-gate dump tool: reads a JSON array of texts, extracts
//! citations from each (VM engine), writes JSON results to stdout. The
//! Python comparator diffs this against the live eyecite oracle.
//! Spans are BYTE offsets (the comparator converts the oracle's char spans).
const std = @import("std");
const incitez = @import("incitez");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <texts.json>\n", .{args[0]});
        return error.BadArgs;
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("[\n");
    for (parsed.value.array.items, 0..) |item, i| {
        const text = item.string;
        const cites = try incitez.extraction.extractWithEngine(arena, text, .vm);
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll(" {\"cites\": [");
        for (cites, 0..) |c, ci| {
            if (ci > 0) try w.writeAll(", ");
            try w.writeAll("{");
            try w.print("\"type\": \"{s}\"", .{typeName(c.kind)});
            try w.print(", \"span\": [{d}, {d}]", .{ c.span_start, c.span_end });
            try jsonField(w, "volume", c.volume);
            try jsonField(w, "reporter", if (c.kind == .supra or c.kind == .id or c.kind == .unknown) null else c.reporter);
            try jsonField(w, "page", c.page);
            try jsonField(w, "pin_cite", c.pin_cite);
            try jsonField(w, "court", c.court);
            try jsonField(w, "parenthetical", c.parenthetical);
            try jsonField(w, "extra", c.extra);
            try jsonField(w, "plaintiff", c.plaintiff);
            try jsonField(w, "defendant", c.defendant);
            try jsonField(w, "antecedent_guess", c.antecedent_guess);
            if (c.kind == .full_case or c.kind == .short_case or c.kind == .full_journal or c.kind == .full_law) {
                try w.writeAll(", \"corrected_reporter\": ");
                try jsonString(w, c.correctedReporter());
            }
            if (c.year) |y| try w.print(", \"year\": {d}", .{y}) else try w.writeAll(", \"year\": null");
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("\n]\n");

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll(aw.written());
    try out.interface.flush();
}

fn typeName(kind: incitez.extraction.Kind) []const u8 {
    return switch (kind) {
        .full_case => "FullCaseCitation",
        .short_case => "ShortCaseCitation",
        .supra => "SupraCitation",
        .id => "IdCitation",
        .reference => "ReferenceCitation",
        .unknown => "UnknownCitation",
        .full_law => "FullLawCitation",
        .full_journal => "FullJournalCitation",
    };
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
        else => if (c < 0x20)
            try w.print("\\u{x:0>4}", .{c})
        else
            try w.writeByte(c),
    };
    try w.writeByte('"');
}
