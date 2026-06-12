//! Build-time codegen: reporters-db JSON → Zig lookup tables + citation
//! pattern programs.
//!
//! Mirrors eyecite's extractor construction: regexes.json variables are
//! flattened/expanded exactly like reporters_db.utils.process_variables
//! (incl. the `_optional` = "(?:X ?)?" rule and eyecite's $page override),
//! then each edition's regex templates (default ["$full_cite"]) are compiled
//! into PRE/POST instruction programs split at the $edition anchor.
//!
//! Strict by design: unknown cite_types, dangling variations, unresolved
//! $variables, or regex constructs outside the closed reporters-db
//! vocabulary ABORT THE BUILD — upstream drift must be loud, never silent.
const std = @import("std");

// eyecite tokenizers.py overrides (verbatim):
const PAGE_OVERRIDE =
    "(?P<page>\\d+|c?(?:xc|xl|l?x{1,3})(?:ix|iv|v?i{0,3})|(?:c?l?)(?:ix|iv|v?i{1,3})|(?:lv|cv|cl|clv)|_+)";
const FULL_CITE_OVERRIDE = "$volume $reporter,? $page";

const GROUP_NAMES = [_][]const u8{
    "volume",             "page",     "year", "date_filed",
    "volume_nominative",  "reporter_nominative", "supp", "jurisdiction",
};

const cite_types = [_][]const u8{
    "federal",         "neutral",        "scotus_early", "specialty",
    "specialty_lexis", "specialty_west", "state",        "state_regional",
};

const Ed = struct {
    abbrev: []const u8,
    name: []const u8,
    cite_type: []const u8,
    program_ids: []const u32,
};

const Match = struct {
    key: []const u8,
    edition: u32,
    is_variant: bool,
};

// ── Regex AST ────────────────────────────────────────────────────────

const Node = union(enum) {
    lit: []const u8,
    class: Class,
    seq: []Node,
    alt: []Node, // each branch a node (usually seq)
    opt: *Node,
    group: Group,
    anchor, // (?P<reporter>$edition)

    const Class = struct { bits: [4]u64, min: u32, max: u32 };
    const Group = struct { name: ?[]const u8, body: *Node };
};

const ParseError = error{ UnsupportedRegex, OutOfMemory };

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    /// Set when (?P<reporter>...) wraps a pattern instead of the $edition
    /// anchor (one known case: the S.W. fuzzy regex) — such programs cannot
    /// be reporter-anchored and are tracked as unanchored.
    unanchorable: bool = false,

    fn fail(p: *Parser, comptime why: []const u8) ParseError {
        std.debug.print(
            "regex compile error ({s}) at byte {d} in:\n  {s}\n  ",
            .{ why, p.pos, p.src },
        );
        for (0..p.pos + 2) |_| std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
        return error.UnsupportedRegex;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn parseAlternation(p: *Parser) ParseError!Node {
        var branches: std.ArrayListUnmanaged(Node) = .empty;
        try branches.append(p.arena, try p.parseSequence());
        while (p.peek() == @as(u8, '|')) {
            p.pos += 1;
            try branches.append(p.arena, try p.parseSequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn parseSequence(p: *Parser) ParseError!Node {
        var nodes: std.ArrayListUnmanaged(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try p.parseAtom();
            const quantified = try p.applyQuantifier(atom);
            // merge adjacent unquantified literals for compactness
            if (quantified == .lit and nodes.items.len > 0 and
                nodes.items[nodes.items.len - 1] == .lit)
            {
                const prev = nodes.items[nodes.items.len - 1].lit;
                const merged = try std.mem.concat(p.arena, u8, &.{ prev, quantified.lit });
                nodes.items[nodes.items.len - 1] = .{ .lit = merged };
                continue;
            }
            try nodes.append(p.arena, quantified);
        }
        if (nodes.items.len == 1) return nodes.items[0];
        return .{ .seq = nodes.items };
    }

    fn parseAtom(p: *Parser) ParseError!Node {
        const c = p.peek() orelse return p.fail("unexpected end");
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => return p.parseClass(),
            '\\' => {
                p.pos += 1;
                const e = p.peek() orelse return p.fail("dangling backslash");
                p.pos += 1;
                switch (e) {
                    'd' => return .{ .class = .{ .bits = digitBits(), .min = 1, .max = 1 } },
                    's' => return .{ .class = .{ .bits = spaceBits(), .min = 1, .max = 1 } },
                    'w' => return .{ .class = .{ .bits = wordBits(), .min = 1, .max = 1 } },
                    else => {
                        if (std.ascii.isAlphanumeric(e)) return p.fail("unsupported escape");
                        return .{ .lit = p.src[p.pos - 1 .. p.pos] };
                    },
                }
            },
            '$' => {
                // only the $edition anchor may remain unresolved
                if (std.mem.startsWith(u8, p.src[p.pos..], "$edition")) {
                    p.pos += "$edition".len;
                    return .anchor;
                }
                return p.fail("unresolved $variable");
            },
            '.' => {
                // Python re: any char except newline (yes, even inside
                // " p. " — upstream regexes really do use a bare dot there)
                p.pos += 1;
                return .{ .class = .{ .bits = anyBits(), .min = 1, .max = 1 } };
            },
            '^', '*', '+', '?', '{', '}' => return p.fail("unsupported metachar"),
            else => {
                p.pos += 1;
                return .{ .lit = p.src[p.pos - 1 .. p.pos] };
            },
        }
    }

    fn parseGroup(p: *Parser) ParseError!Node {
        p.pos += 1; // consume '('
        var name: ?[]const u8 = null;
        if (std.mem.startsWith(u8, p.src[p.pos..], "?:")) {
            p.pos += 2;
        } else if (std.mem.startsWith(u8, p.src[p.pos..], "?P<")) {
            p.pos += 3;
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '>') orelse
                return p.fail("unterminated group name");
            name = p.src[p.pos..end];
            p.pos = end + 1;
        }
        const body = try p.parseAlternation();
        if (p.peek() != @as(u8, ')')) return p.fail("unterminated group");
        p.pos += 1;

        if (name) |n| {
            if (std.mem.eql(u8, n, "reporter")) {
                if (body == .anchor) return .anchor;
                p.unanchorable = true;
                return body;
            }
            var known = false;
            for (GROUP_NAMES) |g| {
                if (std.mem.eql(u8, g, n)) known = true;
            }
            if (!known) return p.fail("unknown group name");
            const boxed = try p.arena.create(Node);
            boxed.* = body;
            return .{ .group = .{ .name = n, .body = boxed } };
        }
        // unnamed/non-capturing: plain grouping either way
        return body;
    }

    fn parseClass(p: *Parser) ParseError!Node {
        p.pos += 1; // consume '['
        if (p.peek() == @as(u8, '^')) return p.fail("negated class");
        var bits: [4]u64 = .{ 0, 0, 0, 0 };
        var prev: ?u8 = null;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated class");
            p.pos += 1;
            if (c == ']') break;
            if (c == '-' and prev != null and p.peek() != @as(u8, ']')) {
                const hi = p.src[p.pos];
                p.pos += 1;
                var ch = prev.?;
                while (ch <= hi) : (ch += 1) setBit(&bits, ch);
                prev = null;
                continue;
            }
            var ch = c;
            if (c == '\\') {
                const e = p.peek() orelse return p.fail("dangling class escape");
                p.pos += 1;
                switch (e) {
                    'd' => {
                        orBits(&bits, digitBits());
                        prev = null;
                        continue;
                    },
                    's' => {
                        orBits(&bits, spaceBits());
                        prev = null;
                        continue;
                    },
                    else => ch = e,
                }
            }
            setBit(&bits, ch);
            prev = ch;
        }
        return .{ .class = .{ .bits = bits, .min = 1, .max = 1 } };
    }

    fn applyQuantifier(p: *Parser, atom: Node) ParseError!Node {
        const c = p.peek() orelse return atom;
        var min: u32 = 0;
        var max: u32 = 0;
        switch (c) {
            '?' => {
                p.pos += 1;
                min = 0;
                max = 1;
            },
            '*' => {
                p.pos += 1;
                min = 0;
                max = std.math.maxInt(u16);
            },
            '+' => {
                p.pos += 1;
                min = 1;
                max = std.math.maxInt(u16);
            },
            '{' => {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse
                    return p.fail("unterminated counted quantifier");
                const spec = p.src[p.pos + 1 .. end];
                p.pos = end + 1;
                if (std.mem.indexOfScalar(u8, spec, ',')) |comma| {
                    min = std.fmt.parseInt(u32, spec[0..comma], 10) catch
                        return p.fail("bad quantifier min");
                    max = if (comma + 1 == spec.len)
                        std.math.maxInt(u16)
                    else
                        std.fmt.parseInt(u32, spec[comma + 1 ..], 10) catch
                            return p.fail("bad quantifier max");
                } else {
                    min = std.fmt.parseInt(u32, spec, 10) catch
                        return p.fail("bad quantifier count");
                    max = min;
                }
            },
            else => return atom,
        }
        // quantifier applies to the last single char of a merged literal
        switch (atom) {
            .class => |cl| {
                if (cl.min == 1 and cl.max == 1)
                    return .{ .class = .{ .bits = cl.bits, .min = min, .max = max } };
                return p.fail("double quantifier");
            },
            .lit => |l| {
                var bits: [4]u64 = .{ 0, 0, 0, 0 };
                setBit(&bits, l[l.len - 1]);
                const quant: Node = .{ .class = .{ .bits = bits, .min = min, .max = max } };
                if (l.len == 1) return quant;
                const head: Node = .{ .lit = l[0 .. l.len - 1] };
                const pair = try p.arena.alloc(Node, 2);
                pair[0] = head;
                pair[1] = quant;
                return .{ .seq = pair };
            },
            else => {
                if (min == 0 and max == 1) {
                    const boxed = try p.arena.create(Node);
                    boxed.* = atom;
                    return .{ .opt = boxed };
                }
                return p.fail("unsupported group quantifier");
            },
        }
    }
};

fn setBit(bits: *[4]u64, c: u8) void {
    bits[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
}

fn orBits(dst: *[4]u64, src: [4]u64) void {
    for (dst, src) |*d, s| d.* |= s;
}

fn anyBits() [4]u64 {
    var b: [4]u64 = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) };
    b['\n' >> 6] &= ~(@as(u64, 1) << ('\n' & 63));
    return b;
}

fn digitBits() [4]u64 {
    var b: [4]u64 = .{ 0, 0, 0, 0 };
    for ('0'..'9' + 1) |c| setBit(&b, @intCast(c));
    return b;
}

fn spaceBits() [4]u64 {
    var b: [4]u64 = .{ 0, 0, 0, 0 };
    for ([_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c }) |c| setBit(&b, c);
    return b;
}

fn wordBits() [4]u64 {
    var b: [4]u64 = .{ 0, 0, 0, 0 };
    for ('a'..'z' + 1) |c| setBit(&b, @intCast(c));
    for ('A'..'Z' + 1) |c| setBit(&b, @intCast(c));
    for ('0'..'9' + 1) |c| setBit(&b, @intCast(c));
    setBit(&b, '_');
    return b;
}

// ── Template variable expansion (mirrors reporters_db.utils) ─────────

fn flattenVars(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    prefix: []const u8,
    out: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.endsWith(u8, k, "#")) continue;
        const new_key = if (prefix.len == 0)
            k
        else if (k.len == 0)
            prefix
        else
            try std.mem.join(arena, "_", &.{ prefix, k });
        switch (e.value_ptr.*) {
            .object => |o| try flattenVars(arena, o, new_key, out),
            .string => |s| try out.put(arena, new_key, s),
            else => return error.BadVariablesJson,
        }
    }
}

/// Python string.Template.safe_substitute for $name / ${name}.
fn safeSubstitute(
    arena: std.mem.Allocator,
    template: []const u8,
    vars: *const std.StringArrayHashMapUnmanaged([]const u8),
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '$') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 < template.len and template[i + 1] == '$') {
            try out.append(arena, '$');
            i += 2;
            continue;
        }
        var j = i + 1;
        var braced = false;
        if (j < template.len and template[j] == '{') {
            braced = true;
            j += 1;
        }
        const name_start = j;
        while (j < template.len and (template[j] == '_' or std.ascii.isAlphanumeric(template[j]))) j += 1;
        const name = template[name_start..j];
        if (braced) {
            if (j < template.len and template[j] == '}') j += 1 else {
                try out.append(arena, c);
                i += 1;
                continue;
            }
        }
        if (name.len > 0) {
            if (vars.get(name)) |v| {
                try out.appendSlice(arena, v);
                i = j;
                continue;
            }
        }
        try out.appendSlice(arena, template[i..j]);
        i = j;
    }
    return out.items;
}

fn recursiveSubstitute(
    arena: std.mem.Allocator,
    template: []const u8,
    vars: *const std.StringArrayHashMapUnmanaged([]const u8),
) ![]const u8 {
    var old = template;
    for (0..100) |_| {
        const new = try safeSubstitute(arena, old, vars);
        if (std.mem.eql(u8, new, old)) return new;
        old = new;
    }
    std.debug.print("max substitution depth for template '{s}'\n", .{template});
    return error.MaxDepthExceeded;
}

// ── Program compilation ──────────────────────────────────────────────

const Compiled = struct {
    pre: []Insn,
    post: []Insn,
    pre_min: u32,
    pre_max: u32,
    anchored: bool,
    short: bool = false,
};

/// eyecite short_cite_re: turn a full-cite regex into its short form by
/// prefixing the page group with `at ?(p(.|age)?)? `. Null when the regex
/// has no page group.
fn shortify(arena: std.mem.Allocator, expanded: []const u8) !?[]const u8 {
    const needle = "(?P<page>";
    if (std.mem.indexOf(u8, expanded, needle) == null) return null;
    const replacement = "at\\s?(p(\\.|age)?)? (?P<page>";
    const n = std.mem.replacementSize(u8, expanded, needle, replacement);
    const out = try arena.alloc(u8, n);
    _ = std.mem.replace(u8, expanded, needle, replacement, out);
    return out;
}

const Insn = union(enum) {
    lit: []const u8,
    class: Node.Class,
    open: usize, // group index
    close: usize,
    alt: [][]Insn,
    opt: []Insn,
};

fn lowerInto(arena: std.mem.Allocator, node: Node, out: *std.ArrayListUnmanaged(Insn)) !void {
    switch (node) {
        .lit => |l| try out.append(arena, .{ .lit = l }),
        .class => |c| try out.append(arena, .{ .class = c }),
        .seq => |children| for (children) |ch| try lowerInto(arena, ch, out),
        .alt => |branches| {
            var lowered: std.ArrayListUnmanaged([]Insn) = .empty;
            for (branches) |b| {
                var seq: std.ArrayListUnmanaged(Insn) = .empty;
                try lowerInto(arena, b, &seq);
                try lowered.append(arena, seq.items);
            }
            try out.append(arena, .{ .alt = lowered.items });
        },
        .opt => |body| {
            var seq: std.ArrayListUnmanaged(Insn) = .empty;
            try lowerInto(arena, body.*, &seq);
            try out.append(arena, .{ .opt = seq.items });
        },
        .group => |g| {
            const idx = groupIndex(g.name.?);
            try out.append(arena, .{ .open = idx });
            try lowerInto(arena, g.body.*, out);
            try out.append(arena, .{ .close = idx });
        },
        .anchor => return error.AnchorNotTopLevel,
    }
}

fn groupIndex(name: []const u8) usize {
    for (GROUP_NAMES, 0..) |g, i| {
        if (std.mem.eql(u8, g, name)) return i;
    }
    unreachable; // validated at parse time
}

fn seqWidth(insns: []const Insn) [2]u32 {
    var min: u32 = 0;
    var max: u32 = 0;
    for (insns) |insn| {
        const w = insnWidth(insn);
        min += w[0];
        max +|= w[1];
    }
    return .{ min, max };
}

fn insnWidth(insn: Insn) [2]u32 {
    return switch (insn) {
        .lit => |l| .{ @intCast(l.len), @intCast(l.len) },
        .class => |c| .{ c.min, c.max },
        .open, .close => .{ 0, 0 },
        .opt => |body| .{ 0, seqWidth(body)[1] },
        .alt => |branches| blk: {
            var min: u32 = std.math.maxInt(u32);
            var max: u32 = 0;
            for (branches) |b| {
                const w = seqWidth(b);
                min = @min(min, w[0]);
                max = @max(max, w[1]);
            }
            break :blk .{ min, max };
        },
    };
}

fn compileRegex(arena: std.mem.Allocator, regex: []const u8) !Compiled {
    var p: Parser = .{ .src = regex, .pos = 0, .arena = arena };
    const root = try p.parseAlternation();
    if (p.pos != regex.len) return p.fail("trailing garbage");
    if (p.unanchorable) {
        return .{ .pre = &.{}, .post = &.{}, .pre_min = 0, .pre_max = 0, .anchored = false };
    }

    // split top-level sequence at the anchor
    const children: []Node = switch (root) {
        .seq => |s| s,
        else => blk: {
            const one = try arena.alloc(Node, 1);
            one[0] = root;
            break :blk one;
        },
    };
    var anchor_idx: ?usize = null;
    for (children, 0..) |ch, i| {
        if (ch == .anchor) {
            if (anchor_idx != null) return error.MultipleAnchors;
            anchor_idx = i;
        }
    }
    if (anchor_idx == null) {
        // unanchored program (e.g. the S.W. fuzzy regex): tracked, not compiled
        return .{ .pre = &.{}, .post = &.{}, .pre_min = 0, .pre_max = 0, .anchored = false };
    }

    var pre: std.ArrayListUnmanaged(Insn) = .empty;
    for (children[0..anchor_idx.?]) |ch| try lowerInto(arena, ch, &pre);
    var post: std.ArrayListUnmanaged(Insn) = .empty;
    for (children[anchor_idx.? + 1 ..]) |ch| try lowerInto(arena, ch, &post);

    const w = seqWidth(pre.items);
    // Unbounded atoms (e.g. the standard volume `[1-9]\d*`) make the formal
    // max infinite; clamp the anchor-backscan window — no legitimate
    // citation has >64 bytes between its start and its reporter.
    const pre_max = @min(w[1], 64);
    return .{ .pre = pre.items, .post = post.items, .pre_min = w[0], .pre_max = pre_max, .anchored = true };
}

// ── Emission ─────────────────────────────────────────────────────────

const Emitter = struct {
    w: *std.Io.Writer,
    seq_counter: usize = 0,

    fn emitSeqDefs(e: *Emitter, insns: []const Insn, name: []const u8) !void {
        // depth-first: define child sequences before the referencing array
        var child_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer child_names.deinit(std.heap.page_allocator);
        _ = &child_names;
        for (insns, 0..) |insn, i| {
            switch (insn) {
                .alt => |branches| {
                    for (branches, 0..) |b, bi| {
                        var buf: [64]u8 = undefined;
                        const child = try std.fmt.bufPrint(&buf, "{s}_i{d}b{d}", .{ name, i, bi });
                        try e.emitSeqDefs(b, child);
                    }
                },
                .opt => |body| {
                    var buf: [64]u8 = undefined;
                    const child = try std.fmt.bufPrint(&buf, "{s}_i{d}o", .{ name, i });
                    try e.emitSeqDefs(body, child);
                },
                else => {},
            }
        }
        try e.w.print("const {s} = [_]Insn{{\n", .{name});
        for (insns, 0..) |insn, i| {
            switch (insn) {
                .lit => |l| {
                    try e.w.writeAll("    .{ .lit = ");
                    try writeZigString(e.w, l);
                    try e.w.writeAll(" },\n");
                },
                .class => |c| try e.w.print(
                    "    .{{ .class = .{{ .bits = .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }}, .min = {d}, .max = {d} }} }},\n",
                    .{ c.bits[0], c.bits[1], c.bits[2], c.bits[3], c.min, c.max },
                ),
                .open => |g| try e.w.print("    .{{ .open = {d} }},\n", .{g}),
                .close => |g| try e.w.print("    .{{ .close = {d} }},\n", .{g}),
                .alt => |branches| {
                    try e.w.writeAll("    .{ .alt = &.{ ");
                    for (branches, 0..) |_, bi| {
                        if (bi > 0) try e.w.writeAll(", ");
                        try e.w.print("&{s}_i{d}b{d}", .{ name, i, bi });
                    }
                    try e.w.writeAll(" } },\n");
                },
                .opt => try e.w.print("    .{{ .opt = &{s}_i{d}o }},\n", .{ name, i }),
            }
        }
        try e.w.writeAll("};\n");
    }
};

fn writeZigString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => if (c >= 0x20 and c < 0x7f)
            try w.writeByte(c)
        else
            try w.print("\\x{x:0>2}", .{c}),
    };
    try w.writeByte('"');
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: {s} <reporters.json> <regexes.json> <out.zig>\n", .{args[0]});
        return error.BadArgs;
    }

    // ---- variables (regexes.json) ----
    const regexes_data = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
    const regexes_parsed = try std.json.parseFromSlice(std.json.Value, arena, regexes_data, .{});
    var vars: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try flattenVars(arena, regexes_parsed.value.object, "", &vars);
    // eyecite overrides
    try vars.put(arena, "full_cite", FULL_CITE_OVERRIDE);
    try vars.put(arena, "page", PAGE_OVERRIDE);
    // _optional variants (over the pre-override key set, like eyecite does
    // after its overrides — order matches _populate_reporter_extractors)
    {
        var base_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        for (vars.keys()) |k| try base_keys.append(arena, k);
        for (base_keys.items) |k| {
            const v = vars.get(k).?;
            const opt_key = try std.mem.concat(arena, u8, &.{ k, "_optional" });
            const opt_val = try std.fmt.allocPrint(arena, "(?:{s} ?)?", .{v});
            try vars.put(arena, opt_key, opt_val);
        }
    }
    // fixpoint-resolve references among variables
    {
        var i: usize = 0;
        while (i < vars.count()) : (i += 1) {
            const k = vars.keys()[i];
            const resolved = try recursiveSubstitute(arena, vars.get(k).?, &vars);
            try vars.put(arena, k, resolved);
        }
    }

    // ---- reporters.json → editions, match table, programs ----
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    const root = parsed.value.object;

    var editions: std.ArrayListUnmanaged(Ed) = .empty;
    var matches: std.ArrayListUnmanaged(Match) = .empty;
    var programs: std.ArrayListUnmanaged(Compiled) = .empty;
    var program_ids: std.StringArrayHashMapUnmanaged(u32) = .empty; // expanded regex → id
    var unanchored_count: usize = 0;
    var pcre2_extractors: std.ArrayListUnmanaged(Pcre2Extractor) = .empty;
    var pcre2_seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    const EntryEd = struct {
        local: u32,
        abbrev: []const u8,
        expanded: []const []const u8,
    };

    var series_it = root.iterator();
    while (series_it.next()) |series| {
        for (series.value_ptr.array.items) |entry_val| {
            const entry = entry_val.object;
            const name = entry.get("name").?.string;
            const cite_type = entry.get("cite_type").?.string;

            const known = for (cite_types) |ct| {
                if (std.mem.eql(u8, ct, cite_type)) break true;
            } else false;
            if (!known) {
                std.debug.print("unknown cite_type '{s}' for '{s}'\n", .{ cite_type, name });
                return error.UnknownCiteType;
            }

            var local: std.StringHashMapUnmanaged(u32) = .empty;
            var entry_eds: std.ArrayListUnmanaged(EntryEd) = .empty;
            var ed_it = entry.get("editions").?.object.iterator();
            while (ed_it.next()) |ed| {
                const idx: u32 = @intCast(editions.items.len);

                // compile this edition's regex templates (default $full_cite)
                var ids: std.ArrayListUnmanaged(u32) = .empty;
                var expanded_list: std.ArrayListUnmanaged([]const u8) = .empty;
                const templates: []const std.json.Value = blk: {
                    if (ed.value_ptr.object.get("regexes")) |r| {
                        if (r == .array) break :blk r.array.items;
                    }
                    break :blk &.{};
                };
                const raw_templates: []const []const u8 = if (templates.len == 0)
                    &.{"$full_cite"}
                else blk: {
                    var list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (templates) |t| try list.append(arena, t.string);
                    break :blk list.items;
                };
                for (raw_templates) |t| {
                    const expanded = try recursiveSubstitute(arena, t, &vars);
                    try expanded_list.append(arena, expanded);
                    try ids.append(arena, try internProgram(
                        arena,
                        expanded,
                        false,
                        &programs,
                        &program_ids,
                        &unanchored_count,
                    ));
                    // derived short form (eyecite short_cite_re)
                    if (try shortify(arena, expanded)) |short_rx| {
                        try ids.append(arena, try internProgram(
                            arena,
                            short_rx,
                            true,
                            &programs,
                            &program_ids,
                            &unanchored_count,
                        ));
                    }
                }

                try editions.append(arena, .{
                    .abbrev = ed.key_ptr.*,
                    .name = name,
                    .cite_type = cite_type,
                    .program_ids = ids.items,
                });
                try local.put(arena, ed.key_ptr.*, idx);
                try entry_eds.append(arena, .{
                    .local = idx,
                    .abbrev = ed.key_ptr.*,
                    .expanded = expanded_list.items,
                });
                try matches.append(arena, .{ .key = ed.key_ptr.*, .edition = idx, .is_variant = false });
            }

            // per-edition variation keys (needed for pcre2 alternations)
            var var_keys: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;
            if (entry.get("variations")) |variations| {
                var var_it = variations.object.iterator();
                while (var_it.next()) |v| {
                    const target = v.value_ptr.string;
                    const idx = local.get(target) orelse {
                        std.debug.print(
                            "variation '{s}' -> '{s}' has no such edition in entry '{s}'\n",
                            .{ v.key_ptr.*, target, name },
                        );
                        return error.DanglingVariation;
                    };
                    try matches.append(arena, .{ .key = v.key_ptr.*, .edition = idx, .is_variant = true });
                    const gop = try var_keys.getOrPut(arena, idx);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(arena, v.key_ptr.*);
                }
            }

            // eyecite-literal extractors for the PCRE2 path: per template,
            // one regex with the exact edition name and one with all its
            // variations (mirrors eyecite _add_regexes)
            for (entry_eds.items) |ee| {
                for (ee.expanded) |expanded| {
                    const short_rx = try shortify(arena, expanded);
                    try internPcre2Extractor(
                        arena,
                        expanded,
                        &.{ee.abbrev},
                        ee.local,
                        false,
                        false,
                        &pcre2_extractors,
                        &pcre2_seen,
                    );
                    if (short_rx) |srx| {
                        try internPcre2Extractor(
                            arena,
                            srx,
                            &.{ee.abbrev},
                            ee.local,
                            false,
                            true,
                            &pcre2_extractors,
                            &pcre2_seen,
                        );
                    }
                    if (var_keys.get(ee.local)) |vk| {
                        try internPcre2Extractor(
                            arena,
                            expanded,
                            vk.items,
                            ee.local,
                            true,
                            false,
                            &pcre2_extractors,
                            &pcre2_seen,
                        );
                        if (short_rx) |srx| {
                            try internPcre2Extractor(
                                arena,
                                srx,
                                vk.items,
                                ee.local,
                                true,
                                true,
                                &pcre2_extractors,
                                &pcre2_seen,
                            );
                        }
                    }
                }
            }
        }
    }

    std.mem.sort(Match, matches.items, {}, matchLessThan);

    // ---- emit ----
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll(
        \\// Generated by tools/gen_tables.zig from reporters-db — DO NOT EDIT.
        \\pub const CiteType = enum {
        \\
    );
    for (cite_types) |ct| try w.print("    {s},\n", .{ct});
    try w.writeAll(
        \\};
        \\
        \\pub const Group = enum(u8) {
        \\
    );
    for (GROUP_NAMES) |g| try w.print("    {s},\n", .{g});
    try w.print(
        \\}};
        \\pub const group_count: usize = {d};
        \\
        \\pub const Class = struct {{
        \\    bits: [4]u64,
        \\    min: u32,
        \\    max: u32,
        \\}};
        \\
        \\pub const Insn = union(enum) {{
        \\    lit: []const u8,
        \\    class: Class,
        \\    open: u8,
        \\    close: u8,
        \\    alt: []const []const Insn,
        \\    opt: []const Insn,
        \\}};
        \\
        \\pub const Program = struct {{
        \\    pre: []const Insn,
        \\    post: []const Insn,
        \\    pre_min: u32,
        \\    pre_max: u32,
        \\    /// derived short-cite form ("at page") — eyecite short_cite_re
        \\    short: bool,
        \\}};
        \\
        \\pub const Edition = struct {{
        \\    abbrev: []const u8,
        \\    reporter_name: []const u8,
        \\    cite_type: CiteType,
        \\    programs: []const u16,
        \\    /// eyecite Reporter.is_scotus: federal + "supreme" in name, or
        \\    /// a scotus_early cite_type (drives guess_court).
        \\    is_scotus: bool,
        \\}};
        \\
        \\pub const MatchEntry = struct {{
        \\    key: []const u8,
        \\    edition: u32,
        \\    is_variant: bool,
        \\}};
        \\
        \\
    , .{GROUP_NAMES.len});

    // program instruction arrays
    var emitter: Emitter = .{ .w = w };
    for (programs.items, 0..) |prog, pi| {
        if (!prog.anchored) continue;
        var buf: [32]u8 = undefined;
        const pre_name = try std.fmt.bufPrint(&buf, "p{d}_pre", .{pi});
        try emitter.emitSeqDefs(prog.pre, pre_name);
        var buf2: [32]u8 = undefined;
        const post_name = try std.fmt.bufPrint(&buf2, "p{d}_post", .{pi});
        try emitter.emitSeqDefs(prog.post, post_name);
    }
    try w.writeAll("\npub const programs = [_]Program{\n");
    for (programs.items, 0..) |prog, pi| {
        if (prog.anchored) {
            try w.print(
                "    .{{ .pre = &p{d}_pre, .post = &p{d}_post, .pre_min = {d}, .pre_max = {d}, .short = {} }},\n",
                .{ pi, pi, prog.pre_min, prog.pre_max, prog.short },
            );
        } else {
            // placeholder keeps ids stable; runtime never executes it
            try w.writeAll("    .{ .pre = &.{}, .post = &.{}, .pre_min = 1, .pre_max = 0, .short = false },\n");
        }
    }
    try w.print(
        "}};\n\npub const unanchored_program_count: usize = {d};\n\n",
        .{unanchored_count},
    );

    // per-edition program id lists
    for (editions.items, 0..) |ed, i| {
        try w.print("const ed{d}_progs = [_]u16{{", .{i});
        for (ed.program_ids, 0..) |id, k| {
            if (k > 0) try w.writeAll(", ");
            try w.print("{d}", .{id});
        }
        try w.writeAll("};\n");
    }

    try w.writeAll("\npub const editions: []const Edition = &.{\n");
    for (editions.items, 0..) |ed, i| {
        const is_scotus = (std.mem.eql(u8, ed.cite_type, "federal") and
            containsSupreme(ed.name)) or
            std.mem.indexOf(u8, ed.cite_type, "scotus") != null;
        try w.writeAll("    .{ .abbrev = ");
        try writeZigString(w, ed.abbrev);
        try w.writeAll(", .reporter_name = ");
        try writeZigString(w, ed.name);
        try w.print(
            ", .cite_type = .{s}, .programs = &ed{d}_progs, .is_scotus = {} }},\n",
            .{ ed.cite_type, i, is_scotus },
        );
    }
    try w.writeAll(
        \\};
        \\
        \\pub const match_table: []const MatchEntry = &.{
        \\
    );
    var prev: ?Match = null;
    var max_key_len: usize = 0;
    var first_bytes: [4]u64 = .{ 0, 0, 0, 0 };
    for (matches.items) |m| {
        if (prev) |pm| {
            if (std.mem.eql(u8, pm.key, m.key) and pm.edition == m.edition) continue;
        }
        prev = m;
        max_key_len = @max(max_key_len, m.key.len);
        setBit(&first_bytes, m.key[0]);
        try w.writeAll("    .{ .key = ");
        try writeZigString(w, m.key);
        try w.print(", .edition = {d}, .is_variant = {} }},\n", .{ m.edition, m.is_variant });
    }
    try w.print(
        \\}};
        \\
        \\pub const max_key_len: usize = {d};
        \\pub const key_first_bytes = [4]u64{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }};
        \\
    , .{ max_key_len, first_bytes[0], first_bytes[1], first_bytes[2], first_bytes[3] });

    // eyecite-literal extractor regexes for the PCRE2 engine path
    try w.writeAll(
        \\
        \\/// Full eyecite extractor regexes (edition alternations substituted,
        \\/// nonalphanum-boundary wrapped, citation = group 1) for the PCRE2
        \\/// engine path. The owner edition resolves matches to the edition
        \\/// whose template fired. Regexes sentinel-terminated for the C API.
        \\pub const Pcre2Extractor = struct {
        \\    regex: [:0]const u8,
        \\    edition: u32,
        \\    is_variant: bool,
        \\    short: bool,
        \\};
        \\
        \\pub const pcre2_extractors: []const Pcre2Extractor = &.{
        \\
    );
    for (pcre2_extractors.items) |ex| {
        try w.writeAll("    .{ .regex = ");
        try writeZigString(w, ex.regex);
        try w.print(
            ", .edition = {d}, .is_variant = {}, .short = {} }},\n",
            .{ ex.edition, ex.is_variant, ex.short },
        );
    }
    try w.writeAll("};\n");

    const out = try std.Io.Dir.cwd().createFile(io, args[3], .{});
    defer out.close(io);
    try out.writeStreamingAll(io, aw.written());
}

fn internProgram(
    arena: std.mem.Allocator,
    expanded: []const u8,
    short: bool,
    programs: *std.ArrayListUnmanaged(Compiled),
    program_ids: *std.StringArrayHashMapUnmanaged(u32),
    unanchored_count: *usize,
) !u32 {
    if (program_ids.get(expanded)) |id| return id;
    var compiled = try compileRegex(arena, expanded);
    compiled.short = short;
    if (!compiled.anchored) unanchored_count.* += 1;
    const id: u32 = @intCast(programs.items.len);
    try programs.append(arena, compiled);
    try program_ids.put(arena, expanded, id);
    return id;
}

/// Python re.escape (3.7+ semantics): escape regex specials only.
fn escapePython(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        const special = switch (c) {
            '(', ')', '[', ']', '{', '}', '?', '*', '+', '-', '|', '^', '$',
            '\\', '.', '&', '~', '#', ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
            else => false,
        };
        if (special) try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.items;
}

const Pcre2Extractor = struct {
    regex: []const u8,
    edition: u32,
    is_variant: bool,
    short: bool,
};

/// eyecite-literal extractor regex: $edition replaced by an alternation of
/// escaped reporter strings, wrapped in nonalphanum boundaries with the
/// citation as group 1. These feed the PCRE2 engine path verbatim. The
/// owner edition travels with the regex so matches resolve to the edition
/// whose template actually fired (duplicate abbrevs like "Ohio" exist).
fn internPcre2Extractor(
    arena: std.mem.Allocator,
    expanded: []const u8,
    names: []const []const u8,
    edition: u32,
    is_variant: bool,
    short: bool,
    extractors: *std.ArrayListUnmanaged(Pcre2Extractor),
    seen: *std.StringArrayHashMapUnmanaged(void),
) !void {
    var alternation: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try alternation.append(arena, '|');
        try alternation.appendSlice(arena, try escapePython(arena, n));
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < expanded.len) {
        if (std.mem.startsWith(u8, expanded[i..], "$edition")) {
            try body.appendSlice(arena, alternation.items);
            i += "$edition".len;
        } else {
            try body.append(arena, expanded[i]);
            i += 1;
        }
    }

    const wrapped = try std.mem.concat(arena, u8, &.{
        "(?:^|[^a-zA-Z0-9])(", body.items, ")(?:[^a-zA-Z0-9]|$)",
    });
    if (seen.contains(wrapped)) return;
    try seen.put(arena, wrapped, {});
    try extractors.append(arena, .{
        .regex = wrapped,
        .edition = edition,
        .is_variant = is_variant,
        .short = short,
    });
}

fn containsSupreme(name: []const u8) bool {
    if (name.len < 7) return false;
    for (0..name.len - 6) |i| {
        var eq = true;
        for ("supreme", 0..) |c, k| {
            if (std.ascii.toLower(name[i + k]) != c) {
                eq = false;
                break;
            }
        }
        if (eq) return true;
    }
    return false;
}

fn matchLessThan(_: void, a: Match, b: Match) bool {
    switch (std.mem.order(u8, a.key, b.key)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.edition != b.edition) return a.edition < b.edition;
    return @intFromBool(a.is_variant) < @intFromBool(b.is_variant);
}
