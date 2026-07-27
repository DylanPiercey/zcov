//! Resolves per-source coverage for one bundle: parse with yuku, walk the flat
//! node array for probes, map each through the source map, score against V8.
const std = @import("std");
const yuku = @import("parser");

pub const Hit = extern struct { source: i32, line: i32, count: i32 };

/// Marks a branch V8 cannot speak to, so it is left out of the report entirely
/// rather than counted as taken or as missed.
pub const unknown_branch: i32 = std.math.minInt(i32);

pub const BranchType = enum(u8) {
    @"if",
    binary_expr,
    cond_expr,
    @"switch",
    default_arg,

    pub fn label(self: BranchType) []const u8 {
        return switch (self) {
            .@"if" => "if",
            .binary_expr => "binary-expr",
            .cond_expr => "cond-expr",
            .@"switch" => "switch",
            .default_arg => "default-arg",
        };
    }
};

/// A function or branch to score: `probe` is where the V8 count is read, `loc`
/// what identifies it in source. For a function those are rarely the same place.
pub const Item = struct {
    probe: u32,
    loc: u32,
    is_branch: bool,
    /// Reads a block branch one character in, so the count comes from the body
    /// rather than the block. Applied in UTF-16 space, where V8 offsets live.
    bias: u8 = 0,
    btype: BranchType = .@"if",
    slot: u16 = 0,
    /// An `if` with no `else` still has two branches; the implicit one ran
    /// however many times the `if` did minus the times the body did.
    implicit: bool = false,
    name_start: u32 = 0,
    name_len: u32 = 0,
    /// V8 says nothing about a default parameter, so its probe reads whatever
    /// encloses it. The only signal is a range *inside* the expression.
    unevidenced: bool = false,
    /// End of the expression `unevidenced` searches, in bytes.
    end: u32 = 0,
    /// End of the branch group's node, in bytes. Orders two groups starting in
    /// the same place: istanbul numbers them pre-order, outermost first.
    span_end: u32 = 0,
};

/// A scored function or branch, positioned in the original source.
pub const ItemHit = struct {
    source: i32,
    line: i32,
    col: i32,
    count: i32,
    is_branch: bool,
    btype: BranchType,
    slot: u16,
    name_start: u32,
    name_len: u32,
    /// See `Item.span_end`. Kept in generated-code bytes: it only ever breaks a
    /// tie between two groups at the same mapped position.
    span_end: u32 = 0,
};

/// V8 offsets are UTF-16 code units; yuku's AST spans are bytes. Any non-ASCII
/// source drifts between the two, so they are translated rather than compared.
pub const Offsets = struct {
    line_b: []const u32,
    line_u16: []const u32,
    code: []const u8,

    pub fn init(gpa: std.mem.Allocator, code: []const u8) !Offsets {
        var line_b: std.ArrayList(u32) = .empty;
        var line_u16: std.ArrayList(u32) = .empty;
        try line_b.append(gpa, 0);
        try line_u16.append(gpa, 0);
        var b: u32 = 0;
        var u: u32 = 0;
        while (b < code.len) {
            const len = std.unicode.utf8ByteSequenceLength(code[b]) catch 1;
            if (code[b] == '\n') {
                try line_b.append(gpa, b + 1);
                try line_u16.append(gpa, u + 1);
            }
            u += if (len == 4) 2 else 1;
            b += len;
        }
        return .{
            .line_b = try line_b.toOwnedSlice(gpa),
            .line_u16 = try line_u16.toOwnedSlice(gpa),
            .code = code,
        };
    }

    /// 1-based line for a byte offset.
    pub fn line(self: Offsets, byte_off: u32) i32 {
        return @intCast(upperBound(self.line_b, byte_off));
    }

    /// Byte offset -> UTF-16 offset, which is the space V8 ranges live in.
    pub fn toU16(self: Offsets, byte_off: u32) u32 {
        const idx = upperBound(self.line_b, byte_off) - 1;
        var b = self.line_b[idx];
        var u = self.line_u16[idx];
        while (b < byte_off and b < self.code.len) {
            const len = std.unicode.utf8ByteSequenceLength(self.code[b]) catch 1;
            u += if (len == 4) 2 else 1;
            b += len;
        }
        return u;
    }

    /// UTF-16 column within the line holding `byte_off`.
    pub fn columnU16(self: Offsets, byte_off: u32) u32 {
        const idx = upperBound(self.line_b, byte_off) - 1;
        return self.toU16(byte_off) - self.line_u16[idx];
    }
};

/// Everything one bundle's scan produced, positioned in the original sources.
pub const Result = struct {
    sources: []const []const u8,
    hits: []Hit,
    /// Lines proved live by any mapping segment landing in executed code. Only
    /// lifts statements that already exist; never invents a line.
    resolved: []Hit,
    /// Functions and branches, positioned in the original source.
    items: []ItemHit,
    /// The generated code, which `ItemHit.name_start/len` index into.
    code: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

const Segment = struct { gen_line: u32, gen_col: u32, source: i32, src_line: i32, src_col: i32 };
pub const Range = struct { start: u32, end: u32, count: i32, fn_root: bool };

fn decodeVlq(s: []const u8, i: *usize) ?i32 {
    var result: i64 = 0;
    // Wider than the shift it feeds, so an over-long VLQ is rejected by the
    // guard below rather than wrapping the counter on the way there.
    var shift: u32 = 0;
    while (i.* < s.len) {
        const c = s[i.*];
        const digit: i64 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => return null,
        };
        i.* += 1;
        // Checked before the shift, so an over-long VLQ is rejected rather than
        // wrapping. Column deltas in a big bundle legitimately reach 7 digits.
        if (shift > 60) return null;
        result += (digit & 31) << @as(u6, @intCast(shift));
        if (digit & 32 == 0) {
            const negative = result & 1 == 1;
            result >>= 1;
            // A map can spell a value no offset could hold; refuse it rather
            // than narrowing into a wrapped one.
            return std.math.cast(i32, if (negative) -result else result);
        }
        shift += 5;
    }
    return null;
}

fn decodeMappings(gpa: std.mem.Allocator, mappings: []const u8) ![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    var gen_line: u32 = 0;
    var gen_col: i32 = 0;
    var source: i32 = 0;
    var src_line: i32 = 0;
    var src_col: i32 = 0;
    var i: usize = 0;
    while (i < mappings.len) {
        const c = mappings[i];
        if (c == ';') {
            gen_line += 1;
            gen_col = 0;
            i += 1;
            continue;
        }
        if (c == ',') {
            i += 1;
            continue;
        }
        const d0 = decodeVlq(mappings, &i) orelse break;
        gen_col += d0;
        // A one-field segment carries no source; skip it.
        if (i >= mappings.len or mappings[i] == ',' or mappings[i] == ';') continue;
        source += decodeVlq(mappings, &i) orelse break;
        src_line += decodeVlq(mappings, &i) orelse break;
        src_col += decodeVlq(mappings, &i) orelse break;
        // An optional name index may follow.
        if (i < mappings.len and mappings[i] != ',' and mappings[i] != ';') {
            _ = decodeVlq(mappings, &i) orelse break;
        }
        try out.append(gpa, .{
            .gen_line = gen_line,
            .gen_col = @intCast(@max(0, gen_col)),
            .source = source,
            .src_line = src_line,
            .src_col = src_col,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// A hand-written or truncated map can decode to a source index that is
/// negative or past the end of `sources`; packing that into a key would fault.
fn validSegment(seg: Segment, source_count: usize) bool {
    if (seg.source < 0 or seg.source >= source_count) return false;
    if (seg.src_line < 0 or seg.src_line == std.math.maxInt(i32)) return false;
    return true;
}

fn lessSegment(_: void, a: Segment, b: Segment) bool {
    if (a.gen_line != b.gen_line) return a.gen_line < b.gen_line;
    return a.gen_col < b.gen_col;
}

pub fn lessRange(_: void, a: Range, b: Range) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

/// Innermost range containing `offset`, using a stack sweep over sorted ranges.
pub fn scoreOffsets(gpa: std.mem.Allocator, offsets: []const u32, ranges: []Range) ![]i32 {
    return scoreOffsetsOpt(gpa, offsets, ranges, true);
}

/// `skip_fn_roots` is the statement rule below. Functions and branches want the
/// plain innermost range: a function's count *is* the count of its own range.
pub fn scoreOffsetsOpt(
    gpa: std.mem.Allocator,
    offsets: []const u32,
    ranges: []Range,
    skip_fn_roots: bool,
) ![]i32 {
    return scoreOffsetsSkip(gpa, offsets, ranges, skip_fn_roots, null);
}

pub fn scoreOffsetsSkip(
    gpa: std.mem.Allocator,
    offsets: []const u32,
    ranges: []Range,
    skip_fn_roots: bool,
    skip_own: ?[]const bool,
) ![]i32 {
    const counts = try gpa.alloc(i32, offsets.len);
    @memset(counts, 0);
    var open: std.ArrayList(Range) = .empty;
    defer open.deinit(gpa);
    var next: usize = 0;
    for (offsets, 0..) |offset, idx| {
        while (next < ranges.len and ranges[next].start <= offset) {
            try open.append(gpa, ranges[next]);
            next += 1;
        }
        while (open.items.len > 0 and open.items[open.items.len - 1].end <= offset) {
            _ = open.pop();
        }
        // A statement that *is* a function sits on that function's own range, so
        // prefer the enclosing count -- but fall back to it at a module's start.
        var fallback: ?i32 = null;
        var i = open.items.len;
        counts[idx] = 0;
        while (i > 0) {
            i -= 1;
            const r = open.items[i];
            // Only the top of the stack is popped, so an entry below it may have
            // already ended; a finished sibling must not lend out its count.
            if (r.end <= offset) continue;
            const own = skip_own != null and skip_own.?[idx];
            if ((skip_fn_roots and r.fn_root and r.start == offset) or (own and r.start == offset)) {
                if (fallback == null) fallback = r.count;
                continue;
            }
            counts[idx] = r.count;
            fallback = null;
            break;
        }
        if (fallback) |c| counts[idx] = c;
    }
    return counts;
}

/// The node kinds that count as statements: no blocks, no declarations, and
/// each `variable_declarator` counted individually.
fn isStatement(tag: anytype) bool {
    return switch (tag) {
        .expression_statement,
        .break_statement,
        .continue_statement,
        .debugger_statement,
        .do_while_statement,
        .for_in_statement,
        .for_of_statement,
        .for_statement,
        .if_statement,
        .labeled_statement,
        .return_statement,
        .switch_statement,
        .throw_statement,
        .try_statement,
        .while_statement,
        .with_statement,
        .variable_declarator,
        .property_definition,
        => true,
        else => false,
    };
}

/// Constructs whose V8 range starts at the body, so the count on the header is
/// inherited from whatever encloses it and says nothing about being reached.
fn hasInnerRange(tag: anytype) bool {
    return switch (tag) {
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .while_statement,
        .do_while_statement,
        .switch_statement,
        => true,
        else => false,
    };
}

pub const Span2 = struct {
    start: u32,
    end: u32,
    /// Owning statement list and position in it. Control flows top to bottom, so
    /// a statement runs at least as often as anything after it in the list.
    group: u32 = 0,
    order: u32 = 0,
    /// V8 starts a loop or switch range at the body brace, so the header falls
    /// in a gap and inherits the enclosing count whether or not it was reached.
    is_loop: bool = false,
};

/// One statement probe: `probe` is where the count is read, `loc` where the
/// statement is reported. A declarator counts at itself, reports at its init.
pub const Probe = struct {
    probe: u32,
    loc: u32,
    /// A loop's own range counts *iterations*, but what matters is how often the
    /// statement was reached, which is the count of the enclosing range.
    skip_own: bool = false,
};

/// Start and end offsets of every statement, for containment repair.
pub fn statementSpans(
    gpa: std.mem.Allocator,
    tree: *const yuku.ast.Tree,
    ignore: Ignore,
    out: *std.ArrayList(Span2),
) !void {
    if (ignore.whole_file) return;
    const data = tree.nodes.items(.data);
    const spans = tree.nodes.items(.span);

    // Statement-list membership, resolved once: node index -> (list, position).
    const group = try gpa.alloc(u32, data.len);
    defer gpa.free(group);
    const order = try gpa.alloc(u32, data.len);
    defer gpa.free(order);
    @memset(group, 0);
    @memset(order, 0);
    for (data, 0..) |d, i| {
        const body: yuku.ast.IndexRange = switch (d) {
            .program => |n| n.body,
            .block_statement => |n| n.body,
            .function_body => |n| n.body,
            .static_block => |n| n.body,
            .switch_case => |n| n.consequent,
            else => continue,
        };
        for (tree.extra(body), 0..) |child, k| {
            const ci = @intFromEnum(child);
            group[ci] = @intCast(i + 1);
            order[ci] = @intCast(k);
            // A declaration is not itself a statement; its declarators are, and
            // they inherit its place in the list.
            if (data[ci] == .variable_declaration) {
                for (tree.extra(data[ci].variable_declaration.declarators)) |dec| {
                    group[@intFromEnum(dec)] = @intCast(i + 1);
                    order[@intFromEnum(dec)] = @intCast(k);
                }
            }
        }
    }

    // One walk: a line's count is the max over its spans, so order is free.
    for (data, spans, 0..) |d, s, idx| {
        const tag = std.meta.activeTag(d);
        // Keeps the denominator in step with the probes: a bodyless arrow's
        // implicit return is a statement located at the body.
        if (tag == .arrow_function_expression) {
            const arrow = d.arrow_function_expression;
            if (!arrow.expression or arrow.body == .null) continue;
            if (ignore.covers(s.start)) continue;
            const body = unwrapParensIdx(data, @intFromEnum(arrow.body));
            try out.append(gpa, .{ .start = spans[body].start, .end = spans[body].end });
            continue;
        }
        if (!isStatement(tag)) continue;
        if (ignore.covers(s.start)) continue;
        // Located at what they assign rather than at the name: istanbul's
        // statement for `const x =\n  expr` is `expr`. Still counted at the name.
        var at = s;
        if (tag == .variable_declarator) {
            const init = d.variable_declarator.init;
            if (init == .null) continue;
            at = spans[@intFromEnum(init)];
        }
        if (tag == .property_definition) {
            const value = d.property_definition.value;
            if (value == .null) continue;
            at = spans[@intFromEnum(value)];
        }
        try out.append(gpa, .{ .start = at.start, .end = at.end, .group = group[idx], .order = order[idx], .is_loop = hasInnerRange(tag) });
    }
}

/// Start offsets of everything that counts as a statement.
pub fn statementOffsets(
    gpa: std.mem.Allocator,
    tree: *const yuku.ast.Tree,
    ignore: Ignore,
    out: *std.ArrayList(Probe),
) !void {
    if (ignore.whole_file) return;
    const data = tree.nodes.items(.data);
    const spans = tree.nodes.items(.span);
    // One walk: probes are sorted by the caller, so append order is free.
    for (data, spans) |d, s| {
        const tag = std.meta.activeTag(d);
        // A bodyless arrow's expression is its implicit return, counted at the
        // body where the enclosing range is the arrow's own count of calls.
        if (tag == .arrow_function_expression) {
            const arrow = d.arrow_function_expression;
            if (!arrow.expression or arrow.body == .null) continue;
            if (ignore.covers(s.start)) continue;
            const body = unwrapParensIdx(data, @intFromEnum(arrow.body));
            try out.append(gpa, .{ .probe = spans[body].start, .loc = spans[body].start });
            continue;
        }
        if (!isStatement(tag)) continue;
        if (ignore.covers(s.start)) continue;
        if (tag == .variable_declarator) {
            const init = d.variable_declarator.init;
            if (init == .null) continue;
            // Counted at the declarator so a folded-away initializer still has a
            // count to read; located at the init, where istanbul puts it.
            try out.append(gpa, .{ .probe = s.start, .loc = spans[@intFromEnum(init)].start });
            continue;
        }
        if (tag == .property_definition) {
            const value = d.property_definition.value;
            if (value == .null) continue;
            try out.append(gpa, .{ .probe = spans[@intFromEnum(value)].start, .loc = spans[@intFromEnum(value)].start });
            continue;
        }
        try out.append(gpa, .{ .probe = s.start, .loc = s.start, .skip_own = false });
    }
}

/// How far a continuation counter at a given position really reaches, keyed in
/// the UTF-16 offsets the ranges use. Derived from the parse, so it is built
/// once per script rather than once per process that ran it.
pub const ReachMap = std.AutoHashMapUnmanaged(u32, Reach);
pub const Reach = struct { list_end: u32, min_end: u32 };

/// Restores V8's truncated *continuation* counters: a range starting where a
/// statement ends really holds to the end of the enclosing statement list.
pub fn continuationReach(
    gpa: std.mem.Allocator,
    tree: *const yuku.ast.Tree,
    off: Offsets,
) !ReachMap {
    var reach_from: ReachMap = .empty;
    const data = tree.nodes.items(.data);
    const spans = tree.nodes.items(.span);

    // {position, end of the list to reach, how far the range must already
    // reach for that to be allowed}, in byte offsets.
    var pairs: std.ArrayList([3]u32) = .empty;
    defer pairs.deinit(gpa);
    for (data, spans) |d, s| {
        const body: yuku.ast.IndexRange = switch (d) {
            .program => |n| n.body,
            .block_statement => |n| n.body,
            .function_body => |n| n.body,
            .static_block => |n| n.body,
            // A case falls through, so a continuation inside one stops at its
            // end: the next case is still reachable by dispatch.
            .switch_case => |n| n.consequent,
            else => continue,
        };
        for (tree.extra(body)) |child| {
            const end = spans[@intFromEnum(child)].end;
            if (end < s.end) try pairs.append(gpa, .{ end, s.end, 0 });
            // A `try` carries a counter at its `catch` end too, but stretching
            // that is sound only once it already reaches past the `finally`.
            var inner = child;
            while (data[@intFromEnum(inner)] == .labeled_statement) {
                inner = data[@intFromEnum(inner)].labeled_statement.body;
            }
            if (data[@intFromEnum(inner)] != .try_statement) continue;
            const t = data[@intFromEnum(inner)].try_statement;
            if (t.handler == .null or t.finalizer == .null) continue;
            const handler_end = spans[@intFromEnum(t.handler)].end;
            const finalizer_end = spans[@intFromEnum(t.finalizer)].end;
            if (handler_end < s.end) try pairs.append(gpa, .{ handler_end, s.end, finalizer_end });
        }
    }
    if (pairs.items.len == 0) return reach_from;

    // One walk over the code rather than one per offset: `toU16` starts at the
    // line start, and a minified bundle is a single very long line.
    const needed = try gpa.alloc(u32, pairs.items.len * 3);
    defer gpa.free(needed);
    for (pairs.items, 0..) |p, i| {
        needed[i * 3] = p[0];
        needed[i * 3 + 1] = p[1];
        needed[i * 3 + 2] = p[2];
    }
    std.sort.pdq(u32, needed, {}, std.sort.asc(u32));
    var as_u16 = std.AutoHashMap(u32, u32).init(gpa);
    defer as_u16.deinit();
    {
        var b: u32 = 0;
        var u: u32 = 0;
        for (needed) |target| {
            while (b < target and b < off.code.len) {
                const len = std.unicode.utf8ByteSequenceLength(off.code[b]) catch 1;
                u += if (len == 4) 2 else 1;
                b += len;
            }
            try as_u16.put(target, u);
        }
    }

    for (pairs.items) |p| {
        const list_end = as_u16.get(p[1]) orelse continue;
        const min_end = as_u16.get(p[2]) orelse continue;
        const g = try reach_from.getOrPut(gpa, as_u16.get(p[0]) orelse continue);
        // Two lists can only end a statement at the same offset in code written
        // without separators; the shorter reach is the safer read.
        if (!g.found_existing or g.value_ptr.list_end > list_end) {
            g.value_ptr.* = .{ .list_end = list_end, .min_end = min_end };
        }
    }
    return reach_from;
}

/// Widens this process's ranges to the extent `continuationReach` recovered.
pub fn applyContinuations(reach_from: ReachMap, ranges: []Range) void {
    if (reach_from.size == 0) return;
    var grew = false;
    for (ranges) |*r| {
        const reach = reach_from.get(r.start) orelse continue;
        if (r.end < reach.min_end or reach.list_end <= r.end) continue;
        r.end = reach.list_end;
        grew = true;
    }
    // Starts are untouched, so the array is still ordered by start; only the
    // widest-first tie-break among equal starts can have been disturbed.
    if (grew) std.sort.pdq(Range, ranges, {}, lessRange);
}

/// `/* c8 ignore next */` and friends: anything inside one is left out of both
/// numerator and denominator. Read from whichever code is being scanned.
pub const Ignore = struct {
    ranges: []const Span2 = &.{},
    /// `ignore if` / `ignore else`: offsets of the if-statements whose
    /// consequent or alternate is dropped from the branch group.
    no_consequent: []const u32 = &.{},
    no_alternate: []const u32 = &.{},
    whole_file: bool = false,

    pub const none: Ignore = .{};

    pub fn covers(self: Ignore, offset: u32) bool {
        for (self.ranges) |r| {
            if (offset >= r.start and offset < r.end) return true;
        }
        return false;
    }

    fn has(list: []const u32, offset: u32) bool {
        for (list) |o| if (o == offset) return true;
        return false;
    }
};

const IGNORE_PREFIXES = [_][]const u8{ "istanbul", "c8", "v8", "node:coverage" };
const IGNORE_KINDS = [_][]const u8{ "if", "else", "next", "file" };
const IGNORE_SPANS = [_][]const u8{ "start", "stop" };

/// `<tool> ignore start|stop` anywhere on a line. A plain text search rather
/// than a comment scan, so it works in Vue and Svelte files too.
fn ignoreSpanKind(line: []const u8) ?usize {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, "ignore")) |i| {
        at = i + 1;
        const before = std.mem.trimEnd(u8, line[0..i], " \t");
        var matched = false;
        for (IGNORE_PREFIXES) |p| {
            if (std.mem.endsWith(u8, before, p)) matched = true;
        }
        if (!matched or before.len == line[0..i].len) continue;
        var rest = line[i + "ignore".len ..];
        const n = rest.len;
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == n) continue;
        for (IGNORE_SPANS, 0..) |k, idx| {
            if (!std.mem.startsWith(u8, rest, k)) continue;
            const after = rest[k.len..];
            if (after.len == 0 or !isWordChar(after[0])) return idx;
        }
    }
    return null;
}

/// Offset ranges for every `ignore start` .. `ignore stop` block. An unclosed
/// `start` runs to the end of the file, and a `stop` with no `start` is dropped.
fn ignoreSpanRanges(gpa: std.mem.Allocator, code: []const u8, out: *std.ArrayList(Span2)) !void {
    var open: ?u32 = null;
    var at: usize = 0;
    while (at <= code.len) {
        const nl = std.mem.indexOfScalarPos(u8, code, at, '\n') orelse code.len;
        const line = std.mem.trimEnd(u8, code[at..nl], "\r");
        if (ignoreSpanKind(line)) |kind| {
            if (kind == 0) {
                if (open == null) open = @intCast(at);
            } else if (open) |start| {
                try out.append(gpa, .{ .start = start, .end = @intCast(nl) });
                open = null;
            }
        }
        if (nl == code.len) break;
        at = nl + 1;
    }
    if (open) |start| try out.append(gpa, .{ .start = start, .end = @intCast(code.len) });
}

/// `<tool> ignore <kind>` with arbitrary surrounding whitespace, matching the
/// reference's regex without pulling in a regex engine.
fn ignoreKind(text: []const u8) ?usize {
    var rest = std.mem.trimStart(u8, text, " \t*");
    var matched = false;
    for (IGNORE_PREFIXES) |p| {
        if (std.mem.startsWith(u8, rest, p)) {
            rest = rest[p.len..];
            matched = true;
            break;
        }
    }
    if (!matched) return null;
    const before = rest.len;
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len == before) return null;
    if (!std.mem.startsWith(u8, rest, "ignore")) return null;
    rest = rest["ignore".len..];
    const before2 = rest.len;
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len == before2) return null;
    for (IGNORE_KINDS, 0..) |k, i| {
        if (!std.mem.startsWith(u8, rest, k)) continue;
        const after = rest[k.len..];
        if (after.len == 0 or !isWordChar(after[0])) return i;
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// Comment hints attach to whatever node starts next and cover its whole
/// subtree, which for a flat node array is just an offset range.
pub fn ignoreRanges(gpa: std.mem.Allocator, tree: *const yuku.ast.Tree, code: []const u8) !Ignore {
    var span_ranges: std.ArrayList(Span2) = .empty;
    if (std.mem.indexOf(u8, code, "ignore ") != null) {
        try ignoreSpanRanges(gpa, code, &span_ranges);
    }
    if (tree.comments.len == 0) {
        return .{ .ranges = try span_ranges.toOwnedSlice(gpa) };
    }

    // Every hint resolved to its offset first, so the node array is walked once
    // for all of them: a bundle carries tens of thousands of comments.
    const Hint = struct { at: u32, kind: usize };
    var hints: std.ArrayList(Hint) = .empty;
    defer hints.deinit(gpa);
    for (tree.comments) |c| {
        const kind = ignoreKind(tree.strings.get(c.value)) orelse continue;
        if (kind == 3) return .{ .whole_file = true };
        var at: u32 = c.span.end;
        while (at < code.len and std.ascii.isWhitespace(code[at])) at += 1;
        try hints.append(gpa, .{ .at = at, .kind = kind });
    }
    if (hints.items.len == 0) {
        return .{ .ranges = try span_ranges.toOwnedSlice(gpa) };
    }
    std.sort.pdq(Hint, hints.items, {}, struct {
        fn lt(_: void, x: Hint, y: Hint) bool {
            return x.at < y.at;
        }
    }.lt);

    const data = tree.nodes.items(.data);
    const spans = tree.nodes.items(.span);
    // Widest node starting at each hint offset -- the walker reaches the
    // outermost first, and that is the subtree it suppresses.
    const targets = try gpa.alloc(Span2, hints.items.len);
    defer gpa.free(targets);
    @memset(targets, .{ .start = 0, .end = 0 });
    const arms = try gpa.alloc(Span2, hints.items.len);
    defer gpa.free(arms);
    @memset(arms, .{ .start = 0, .end = 0 });

    for (data, spans) |d, s| {
        const h = findHint(hints.items, s.start) orelse continue;
        const t = &targets[h];
        if (t.end == 0 or s.end > t.end) t.* = .{ .start = s.start, .end = s.end };
        if (hints.items[h].kind <= 1 and d == .if_statement) {
            const arm = if (hints.items[h].kind == 0) d.if_statement.consequent else d.if_statement.alternate;
            if (arm != .null) arms[h] = .{ .start = spans[@intFromEnum(arm)].start, .end = spans[@intFromEnum(arm)].end };
        }
    }

    var ranges: std.ArrayList(Span2) = span_ranges;
    var no_consequent: std.ArrayList(u32) = .empty;
    var no_alternate: std.ArrayList(u32) = .empty;
    for (hints.items, targets, arms) |h, target, arm| {
        if (target.end == 0) continue;
        switch (h.kind) {
            0 => try no_consequent.append(gpa, target.start),
            1 => try no_alternate.append(gpa, target.start),
            else => try ranges.append(gpa, target),
        }
        // `ignore if` / `ignore else` also suppress the arm they drop.
        if (h.kind <= 1 and arm.end != 0) try ranges.append(gpa, arm);
    }
    return .{
        .ranges = try ranges.toOwnedSlice(gpa),
        .no_consequent = try no_consequent.toOwnedSlice(gpa),
        .no_alternate = try no_alternate.toOwnedSlice(gpa),
    };
}

fn findHint(hints: anytype, offset: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = hints.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (hints[mid].at < offset) lo = mid + 1 else hi = mid;
    }
    if (lo < hints.len and hints[lo].at == offset) return lo;
    return null;
}

/// Every function and branch, in AST order. Statements go through
/// `statementOffsets` instead: only they get a source-parsed denominator.
pub fn collectItems(
    gpa: std.mem.Allocator,
    tree: *const yuku.ast.Tree,
    ignore: Ignore,
    out: *std.ArrayList(Item),
) !void {
    if (ignore.whole_file) return;
    const data = tree.nodes.items(.data);
    const spans = tree.nodes.items(.span);

    // A method's function is reported at the method, so the inner one is
    // skipped; a nested logical folds into the outermost parent owning it.
    const skip_fn = try gpa.alloc(bool, data.len);
    defer gpa.free(skip_fn);
    @memset(skip_fn, false);
    const nested_logical = try gpa.alloc(bool, data.len);
    defer gpa.free(nested_logical);
    @memset(nested_logical, false);
    for (data) |d| {
        switch (d) {
            .method_definition => |m| {
                if (m.value != .null and isPlainFunction(data, m.value)) skip_fn[@intFromEnum(m.value)] = true;
            },
            .object_property => |p| {
                if (p.value != .null and isPlainFunction(data, p.value)) skip_fn[@intFromEnum(p.value)] = true;
            },
            .logical_expression => |l| {
                if (l.left != .null and data[@intFromEnum(l.left)] == .logical_expression)
                    nested_logical[@intFromEnum(l.left)] = true;
                if (l.right != .null and data[@intFromEnum(l.right)] == .logical_expression)
                    nested_logical[@intFromEnum(l.right)] = true;
            },
            else => {},
        }
    }

    for (data, spans, 0..) |d, s, i| switch (d) {
        // --- functions ----------------------------------------------------
        .function => |f| {
            if (skip_fn[i] or ignore.covers(s.start)) continue;
            if (f.type != .function_declaration and f.type != .function_expression) continue;
            var it: Item = .{ .probe = s.start, .loc = s.start, .is_branch = false };
            if (f.id != .null) {
                const id = spans[@intFromEnum(f.id)];
                it.loc = id.start;
                it.name_start = id.start;
                it.name_len = id.end - id.start;
            }
            try out.append(gpa, it);
        },
        .arrow_function_expression => {
            if (ignore.covers(s.start)) continue;
            try out.append(gpa, .{ .probe = s.start, .loc = s.start, .is_branch = false });
        },
        .method_definition => |m| {
            if (ignore.covers(s.start)) continue;
            try out.append(gpa, methodItem(data, spans, s, m.key, m.value));
        },
        .object_property => |p| {
            if (ignore.covers(s.start)) continue;
            if (p.value == .null or !isPlainFunction(data, p.value)) continue;
            try out.append(gpa, methodItem(data, spans, s, p.key, p.value));
        },

        // --- branches -----------------------------------------------------
        .if_statement => |n| {
            if (ignore.covers(s.start)) continue;
            // `ignore if` drops the whole group: with its only remaining arm
            // gone there is no branch left to record.
            if (Ignore.has(ignore.no_consequent, s.start)) continue;
            // A bodyless consequent behaves as a block, so both arms
            // read one character in regardless of how they were written.
            try out.append(gpa, branchItem(spans, s, n.consequent, .@"if", 0, 1));
            if (Ignore.has(ignore.no_alternate, s.start)) continue;
            if (n.alternate != .null) {
                try out.append(gpa, branchItem(spans, s, n.alternate, .@"if", 1, 1));
            } else {
                try out.append(gpa, .{
                    .probe = s.start,
                    .loc = s.start,
                    .span_end = s.end,
                    .is_branch = true,
                    .btype = .@"if",
                    .slot = 1,
                    .implicit = true,
                });
            }
        },
        .conditional_expression => |n| {
            if (ignore.covers(s.start)) continue;
            try out.append(gpa, branchItem(spans, s, unwrapParens(data, n.consequent), .cond_expr, 0, 0));
            try out.append(gpa, branchItem(spans, s, unwrapParens(data, n.alternate), .cond_expr, 1, 0));
        },
        .logical_expression => {
            if (nested_logical[i] or ignore.covers(s.start)) continue;
            var slot: u16 = 0;
            const self_idx: @TypeOf(d.logical_expression.left) = @enumFromInt(i);
            try flattenLogical(gpa, data, spans, self_idx, s, &slot, out);
        },
        .switch_statement => |n| {
            if (ignore.covers(s.start)) continue;
            for (tree.extra(n.cases), 0..) |c, k| {
                try out.append(gpa, branchItem(spans, s, c, .@"switch", @intCast(k), 0));
            }
        },
        .assignment_pattern => |n| {
            if (n.right == .null or ignore.covers(s.start)) continue;
            // V8 emits no range for a default parameter, so the probe would read
            // whatever encloses it; `unevidenced` looks inside instead.
            var it = branchItem(spans, s, n.right, .default_arg, 0, 0);
            it.unevidenced = true;
            it.end = spans[@intFromEnum(n.right)].end;
            try out.append(gpa, it);
        },
        else => {},
    };
}

fn isPlainFunction(data: anytype, idx: anytype) bool {
    return data[@intFromEnum(idx)] == .function;
}

fn methodItem(data: anytype, spans: anytype, s: anytype, key: anytype, value: anytype) Item {
    var it: Item = .{ .probe = s.start, .loc = s.start, .is_branch = false };
    // Read where *V8* thinks the function starts, the value rather than the
    // member: `static m() {}` is measured from `m`, not from `static`.
    if (value != .null) it.probe = spans[@intFromEnum(value)].start;
    if (key == .null) return it;
    const k = spans[@intFromEnum(key)];
    it.loc = k.start;
    // `#priv` included, matching what V8 and c8 name it. A computed key stays
    // anonymous: its text is an expression rather than a name.
    switch (data[@intFromEnum(key)]) {
        .private_identifier,
        .identifier_name,
        .identifier_reference,
        .binding_identifier,
        .label_identifier,
        => {
            it.name_start = k.start;
            it.name_len = k.end - k.start;
        },
        else => {},
    }
    return it;
}

fn branchItem(spans: anytype, at: anytype, node: anytype, btype: BranchType, slot: u16, bias: u8) Item {
    return .{
        .probe = spans[@intFromEnum(node)].start,
        .loc = at.start,
        .span_end = at.end,
        .is_branch = true,
        .btype = btype,
        .slot = slot,
        .bias = bias,
    };
}

/// Parentheses are preserved by the parser; coverage looks through them.
fn unwrapParensIdx(data: anytype, start: usize) usize {
    var i = start;
    while (std.meta.activeTag(data[i]) == .parenthesized_expression) {
        const inner = data[i].parenthesized_expression.expression;
        if (inner == .null) break;
        i = @intFromEnum(inner);
    }
    return i;
}

fn unwrapParens(data: anytype, node: anytype) @TypeOf(node) {
    var n = node;
    while (data[@intFromEnum(n)] == .parenthesized_expression) {
        const inner = data[@intFromEnum(n)].parenthesized_expression.expression;
        if (inner == .null) break;
        n = inner;
    }
    return n;
}

/// `a || b || c` is one branch with three leaves, not two nested branches.
fn flattenLogical(
    gpa: std.mem.Allocator,
    data: anytype,
    spans: anytype,
    node: anytype,
    at: anytype,
    slot: *u16,
    out: *std.ArrayList(Item),
) !void {
    const d = data[@intFromEnum(node)];
    if (d == .logical_expression) {
        const l = d.logical_expression;
        try flattenLogical(gpa, data, spans, l.left, at, slot, out);
        try flattenLogical(gpa, data, spans, l.right, at, slot, out);
        return;
    }
    try out.append(gpa, branchItem(spans, at, node, .binary_expr, slot.*, 0));
    slot.* += 1;
}

/// Scores items that are not in probe order, returning counts in the order the
/// items were collected so the implicit-else subtraction still lines up.
pub fn scoreItems(
    gpa: std.mem.Allocator,
    items: []const Item,
    off: Offsets,
    ranges: []Range,
) ![]i32 {
    const probes = try gpa.alloc(u32, items.len);
    for (items, 0..) |it, i| probes[i] = off.toU16(it.probe) + it.bias;
    const order = try gpa.alloc(u32, items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.sort.pdq(u32, order, probes, struct {
        fn lt(p: []const u32, x: u32, y: u32) bool {
            return p[x] < p[y];
        }
    }.lt);

    const sorted = try gpa.alloc(u32, items.len);
    for (order, 0..) |o, i| sorted[i] = probes[o];
    const scored = try scoreOffsetsOpt(gpa, sorted, ranges, false);

    const counts = try gpa.alloc(i32, items.len);
    for (order, 0..) |o, i| counts[o] = scored[i];

    // Most scripts have a few default parameters and answer them by scanning
    // the ranges below. One with thousands would make that quadratic, so once
    // the scanning has cost more than the index would, the index gets built.
    var zero_reach: []u32 = &.{};
    var scanned: usize = 0;

    // An implicit else ran however many times its `if` did that its body did not.
    for (items, 0..) |it, i| {
        // Clamped: an overshooting zero range can swallow the `if` but not its
        // body, and a branch cannot be taken fewer than no times.
        if (it.implicit and i > 0) counts[i] = @max(0, counts[i] - counts[i - 1]);
        if (!it.unevidenced) continue;
        // V8 emits ranges only for code that did *not* run, so a zero range over
        // the expression proves the default was skipped. Otherwise it is unknown.
        const lo = off.toU16(it.probe);
        const hi = off.toU16(it.end);
        counts[i] = unknown_branch;
        if (zero_reach.len == 0) {
            for (ranges) |r| {
                if (r.start > lo) break;
                scanned += 1;
                if (r.count == 0 and r.end >= hi) counts[i] = 0;
            }
            if (scanned > 2 * ranges.len) zero_reach = try zeroReach(gpa, ranges);
            continue;
        }
        const upto = rangesStartingAtOrBefore(ranges, lo);
        if (upto > 0 and zero_reach[upto - 1] >= hi) counts[i] = 0;
    }
    return counts;
}

/// The furthest any zero range starting at or before each index reaches, so a
/// default parameter can be decided by one binary search and one lookup.
fn zeroReach(gpa: std.mem.Allocator, ranges: []const Range) ![]u32 {
    const out = try gpa.alloc(u32, ranges.len);
    var far: u32 = 0;
    for (ranges, out) |r, *slot| {
        if (r.count == 0 and r.end > far) far = r.end;
        slot.* = far;
    }
    return out;
}

/// How many of the sorted ranges start at or before `offset`.
fn rangesStartingAtOrBefore(ranges: []const Range, offset: u32) usize {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid].start <= offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Comments are read for one thing only, so a source with no `ignore` anywhere
/// in it has none worth collecting. A bundle carries tens of thousands.
pub fn parseOptions(code: []const u8, lang: yuku.ast.Lang) yuku.Options {
    return .{
        .lang = lang,
        .comments = if (std.mem.indexOf(u8, code, "ignore") == null) .none else .flat,
    };
}

pub fn lessProbe(_: void, a: Probe, b: Probe) bool {
    return a.probe < b.probe;
}

/// A script's parse, and everything else that does not depend on the V8 ranges.
/// A script that ran in sixteen processes has sixteen range sets and one of
/// these, rather than sixteen identical parses.
pub const Prepared = struct {
    off: Offsets,
    probes: []Probe,
    items: []Item,
    reach: ReachMap,
    /// Whether a map was found, which is not the same as it decoding to any
    /// segments: an empty `mappings` still means the file is generated code.
    mapped: bool,
    /// The line denominator, for a script that is its own source. Saves the
    /// report walk parsing the same file a second time.
    spans: []Span2,
    segments: []Segment,
    seg_probes: []u32,
    sources: []const []const u8,
    code: []const u8,
};

/// Allocates entirely from `a`, which the caller owns and frees; nothing here
/// outlives the script it describes.
pub fn prepare(
    a: std.mem.Allocator,
    code: []const u8,
    map_json: ?[]const u8,
    lang: yuku.ast.Lang,
) !Prepared {
    var sources: std.ArrayList([]const u8) = .empty;
    var segments: []Segment = &.{};
    if (map_json) |mj| {
        // Every field is checked before it is read: a half-written or hand-made
        // `.map` should cost one script, not the whole run.
        const map = try std.json.parseFromSlice(std.json.Value, a, mj, .{});
        if (map.value != .object) return error.BadSourceMap;
        const sources_val = map.value.object.get("sources") orelse return error.NoSources;
        if (sources_val != .array) return error.BadSourceMap;
        // `sourceRoot` prefixes every entry in `sources`; webpack and rollup both
        // set it, and ignoring it puts every hit under a path that does not exist.
        var root: []const u8 = "";
        if (map.value.object.get("sourceRoot")) |r| {
            if (r == .string) root = r.string;
        }
        for (sources_val.array.items) |s| {
            const raw = if (s == .string) s.string else "";
            if (root.len == 0 or raw.len == 0 or std.fs.path.isAbsolute(raw)) {
                try sources.append(a, raw);
            } else if (root[root.len - 1] == '/') {
                try sources.append(a, try std.mem.concat(a, u8, &.{ root, raw }));
            } else {
                try sources.append(a, try std.mem.concat(a, u8, &.{ root, "/", raw }));
            }
        }
        const mappings_val = map.value.object.get("mappings") orelse return error.NoMappings;
        if (mappings_val != .string) return error.BadSourceMap;
        segments = try decodeMappings(a, mappings_val.string);
        std.sort.pdq(Segment, segments, {}, lessSegment);
    }

    var tree = yuku.parse(a, code, parseOptions(code, lang)) catch return error.ParseFailed;
    const ignore = try ignoreRanges(a, &tree, code);
    var offsets: std.ArrayList(Probe) = .empty;
    try statementOffsets(a, &tree, ignore, &offsets);
    std.sort.pdq(Probe, offsets.items, {}, lessProbe);
    var raw_items: std.ArrayList(Item) = .empty;
    try collectItems(a, &tree, ignore, &raw_items);

    // A bundle's sources are other files, so only a script V8 ran directly can
    // hand its denominator to the report.
    var spans: std.ArrayList(Span2) = .empty;
    if (map_json == null) try statementSpans(a, &tree, ignore, &spans);

    const off = try Offsets.init(a, code);
    const reach = try continuationReach(a, &tree, off);

    // Where each mapping segment lands in the generated code, which the ranges
    // are then swept for. The segments do not move between sets.
    //
    // A stale map can name a line or column the generated file does not have.
    // Those get an offset past every range rather than being folded to zero,
    // which used to score them against whatever was live at the file's start.
    const end_u = off.toU16(@intCast(off.code.len));
    const seg_probes = try a.alloc(u32, segments.len);
    for (segments, 0..) |seg, i| {
        const line_idx: usize = @intCast(seg.gen_line);
        if (line_idx >= off.line_u16.len) {
            seg_probes[i] = std.math.maxInt(u32);
            continue;
        }
        const line_end = if (line_idx + 1 < off.line_u16.len) off.line_u16[line_idx + 1] else end_u;
        const at = @as(u64, off.line_u16[line_idx]) + seg.gen_col;
        seg_probes[i] = if (at > line_end) std.math.maxInt(u32) else @intCast(at);
    }

    return .{
        .off = off,
        .mapped = map_json != null,
        .probes = try offsets.toOwnedSlice(a),
        .items = try raw_items.toOwnedSlice(a),
        .reach = reach,
        .spans = try spans.toOwnedSlice(a),
        .segments = segments,
        .seg_probes = seg_probes,
        .sources = try sources.toOwnedSlice(a),
        .code = code,
    };
}

/// Scores one process's ranges against an already-prepared script. `scratch` is
/// per-set working memory; the results are appended with `gpa`.
pub fn scoreSet(
    scratch: std.mem.Allocator,
    gpa: std.mem.Allocator,
    prep: *const Prepared,
    ranges: []Range,
    hits: *std.ArrayList(Hit),
    resolved: *std.ArrayList(Hit),
    items_out: *std.ArrayList(ItemHit),
) !void {
    const a = scratch;
    const off = prep.off;
    const mapped = prep.mapped;
    applyContinuations(prep.reach, ranges);

    const probes = try a.alloc(u32, prep.probes.len);
    const skip_own = try a.alloc(bool, prep.probes.len);
    for (prep.probes, 0..) |o, i| {
        probes[i] = off.toU16(o.probe);
        skip_own[i] = o.skip_own;
    }
    const counts = try scoreOffsetsSkip(a, probes, ranges, true, skip_own);

    if (!mapped) {
        for (prep.probes, counts) |o, count| {
            try hits.append(gpa, .{ .source = -1, .line = off.line(o.loc), .count = count });
        }
    } else {
        // --- offsets -> generated line/col -> source line ------------------
        var acc = std.AutoHashMap(u64, i32).init(a);
        for (prep.probes, counts) |o, count| {
            const gl: u32 = @intCast(off.line(o.loc) - 1);
            // Source map columns are UTF-16 units too.
            const gc: u32 = off.columnU16(o.loc);
            const seg = findSegment(prep.segments, gl, gc) orelse continue;
            if (!validSegment(seg, prep.sources.len)) continue;
            // Source-map lines are 0-based; coverage reports 1-based.
            const key = (@as(u64, @intCast(seg.source)) << 32) | @as(u64, @intCast(seg.src_line + 1));
            const g = try acc.getOrPut(key);
            if (!g.found_existing or g.value_ptr.* < count) g.value_ptr.* = count;
        }
        var it = acc.iterator();
        while (it.next()) |e| {
            try hits.append(gpa, .{
                .source = @intCast(e.key_ptr.* >> 32),
                .line = @intCast(e.key_ptr.* & 0xffffffff),
                .count = e.value_ptr.*,
            });
        }

        // Second pass over every segment, not just the ones a statement sits on:
        // a bundler inlines code whose statements never anchor anywhere.
        var seg_acc = std.AutoHashMap(u64, i32).init(a);
        const seg_counts = try scoreOffsets(a, prep.seg_probes, ranges);
        for (prep.segments, seg_counts) |seg, count| {
            if (count == 0) continue;
            if (!validSegment(seg, prep.sources.len)) continue;
            const key = (@as(u64, @intCast(seg.source)) << 32) | @as(u64, @intCast(seg.src_line + 1));
            const prev = seg_acc.get(key) orelse 0;
            if (count > prev) try seg_acc.put(key, count);
        }
        var ri = seg_acc.iterator();
        while (ri.next()) |e| {
            try resolved.append(gpa, .{
                .source = @intCast(e.key_ptr.* >> 32),
                .line = @intCast(e.key_ptr.* & 0xffffffff),
                .count = e.value_ptr.*,
            });
        }
    }

    // --- functions and branches -------------------------------------------
    const item_counts = try scoreItems(a, prep.items, off, ranges);
    // `unknown_branch` travels to the merge rather than being dropped here: one
    // appearance proving a default skipped must not outvote one that could not tell.
    for (prep.items, item_counts) |item, count| {
        if (!mapped) {
            try items_out.append(gpa, .{
                .source = -1,
                .line = off.line(item.loc),
                .col = @intCast(off.columnU16(item.loc)),
                .count = count,
                .is_branch = item.is_branch,
                .btype = item.btype,
                .slot = item.slot,
                .span_end = item.span_end,
                .name_start = item.name_start,
                .name_len = item.name_len,
            });
            continue;
        }
        const gl: u32 = @intCast(off.line(item.loc) - 1);
        const gc: u32 = off.columnU16(item.loc);
        const seg = findSegment(prep.segments, gl, gc) orelse continue;
        if (!validSegment(seg, prep.sources.len)) continue;
        try items_out.append(gpa, .{
            .source = seg.source,
            .line = seg.src_line + 1,
            .col = seg.src_col,
            .count = count,
            .is_branch = item.is_branch,
            .btype = item.btype,
            .slot = item.slot,
            .span_end = item.span_end,
            .name_start = item.name_start,
            .name_len = item.name_len,
        });
    }
}

fn upperBound(items: []const u32, value: u32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Last segment at or before (line, col) on the same generated line.
fn findSegment(segments: []const Segment, line: u32, col: u32) ?Segment {
    var lo: usize = 0;
    var hi: usize = segments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const s = segments[mid];
        if (s.gen_line < line or (s.gen_line == line and s.gen_col <= col)) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const s = segments[lo - 1];
    if (s.gen_line != line) return null;
    return s;
}
