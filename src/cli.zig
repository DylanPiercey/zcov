//! zcov: run a command under NODE_V8_COVERAGE, remap every script it loaded
//! through its source map, and report. Dumps and scans both run in parallel.
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const build_options = @import("build_options");
const scan = @import("scan.zig");
const yuku = @import("parser");

/// Past this a thread is pure overhead, and it keeps a mistyped `--threads`
/// from asking the OS for a million of them.
const max_threads = 1024;

const usage =
    \\zcov - V8 coverage to lcov, natively
    \\
    \\  zcov [options] [--] <command> [args...]   run a command and report
    \\  zcov report [options]                     report an existing dump directory
    \\
    \\Options:
    \\  -r, --reporter <name>   text, text-summary, lcov, json, html (repeatable, default: text)
    \\  -o, --report-dir <dir>  where to write lcov (default: coverage)
    \\  -d, --coverage-dir <d>  V8 dump directory (default: coverage-v8)
    \\  -n, --include <glob>    files to report on (repeatable, default: everything)
    \\  -x, --exclude <glob>    files to leave out (repeatable, adds to the defaults)
    \\      --cwd <dir>         project root (default: the working directory)
    \\      --threads <n>       default: one per core, capped at 8
    \\      --no-all            only report files the run actually loaded
    \\      --no-clean          keep any dumps already in the coverage directory
    \\      --extension <.ext>  also discover this extension when walking
    \\  -h, --help              show this message
    \\  -V, --version           print the version
    \\
    \\Thresholds (any of these implies --check-coverage):
    \\      --check-coverage    enforce thresholds; alone it means --lines 90
    \\      --lines <n>         minimum line coverage
    \\      --functions <n>     minimum function coverage
    \\      --branches <n>      minimum branch coverage
    \\      --statements <n>    minimum statement coverage
    \\
;

/// Conventional defaults, minus the ones that only make sense in a config file.
const default_excludes = [_][]const u8{
    "**/node_modules/**",
    "**/__tests__/**",
    "**/test/**",
    "**/tests/**",
    "**/*.test.*",
    "**/*.spec.*",
    "**/dist/**",
    "**/build/**",
    "**/coverage/**",
    "**/*.d.ts",
};

/// Extensions worth walking for when discovering files a run never loaded. What
/// a source map names is reported whatever its extension, so this is no gate.
const source_exts = [_][]const u8{
    ".ts",  ".mts",    ".cts",   ".js",
    ".mjs", ".cjs",    ".jsx",   ".tsx",
    ".vue", ".svelte", ".astro", ".marko",
};

const Config = struct {
    coverage_dir: []const u8 = "coverage-v8",
    report_dir: []const u8 = "coverage",
    root: []const u8 = ".",
    threads: usize = 0,
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    text: bool = false,
    text_summary: bool = false,
    lcov: bool = false,
    json: bool = false,
    html: bool = false,
    all: bool = true,
    clean: bool = true,
    check: bool = false,
    min_lines: f64 = 0,
    min_functions: f64 = 0,
    min_branches: f64 = 0,
    min_statements: f64 = 0,
    extensions: []const []const u8 = &.{},
    command: []const []const u8 = &.{},

    /// Should this file appear in the report? Bundles are whatever is left:
    /// scripts under the root that are not reported sources but carry a map.
    fn reports(self: Config, path: []const u8) bool {
        const ext = std.fs.path.extension(path);
        var known = false;
        inline for (source_exts) |e| {
            if (std.mem.eql(u8, ext, e)) known = true;
        }
        for (self.extensions) |e| {
            if (std.mem.eql(u8, ext, e)) known = true;
        }
        if (!known) return false;
        return self.included(path);
    }

    /// Include and exclude patterns only: a file a source map names is one
    /// somebody wrote, whatever it is called. A `.vue` component counts.
    fn included(self: Config, path: []const u8) bool {
        const rel = relativeTo(self.root, path);
        for (self.exclude) |p| if (matchGlob(p, rel)) return false;
        if (self.include.len == 0) return true;
        for (self.include) |p| if (matchGlob(p, rel)) return true;
        return false;
    }
};

/// Windows mixes separators and V8 reports `file:///C:/x/y.js`, so paths are
/// normalised to forward slashes, which its file APIs accept for I/O anyway.
fn normalizePath(a: std.mem.Allocator, path: []const u8) []const u8 {
    if (!is_windows) return path;
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const out = a.dupe(u8, path) catch return path;
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    // On a component boundary only, or a root of `/x/proj` would swallow
    // `/x/proj-tools/` and report a neighbouring project's files as its own.
    if (path.len > prefix.len and prefix.len > 0 and !isSep(path[prefix.len]) and
        !isSep(prefix[prefix.len - 1])) return false;
    // Windows paths are case-insensitive, and the drive letter's case in
    // particular differs between what V8 reports and what the shell gives us.
    if (is_windows) return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

fn relativeTo(root: []const u8, path: []const u8) []const u8 {
    if (!pathStartsWith(path, root)) return path;
    var rel = path[root.len..];
    while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
    return rel;
}

/// `*` and `?` stop at a separator, `**` does not. Enough for the include and
/// exclude patterns people actually write.
///
/// Recursive, because that exits early on the patterns real projects use, but
/// on a budget: several `**` can backtrack exponentially, and the table below
/// decides those in O(pattern x path) instead.
fn matchGlob(pattern: []const u8, path: []const u8) bool {
    var budget: usize = 4096;
    return matchGlobRec(pattern, path, path, &budget) orelse matchGlobTable(pattern, path);
}

/// `null` once the budget is spent, which is the caller's cue to use the table.
fn matchGlobRec(pattern: []const u8, path: []const u8, full: []const u8, budget: *usize) ?bool {
    if (budget.* == 0) return null;
    budget.* -= 1;
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*') {
        if (pattern.len > 1 and pattern[1] == '*') {
            var rest = pattern[2..];
            // `**/x` matches x at the start of a path component and nowhere
            // else, or `**/test/**` would swallow `contest/`.
            const bounded = rest.len > 0 and isSep(rest[0]);
            if (bounded) rest = rest[1..];
            var i: usize = 0;
            while (i <= path.len) : (i += 1) {
                // Measured against the whole path, so a `**/` reached partway
                // through a component still only resumes at a real boundary.
                const at = full.len - path.len + i;
                if (bounded and at > 0 and !isSep(full[at - 1])) continue;
                if (matchGlobRec(rest, path[i..], full, budget) orelse return null) return true;
            }
            return false;
        }
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (matchGlobRec(pattern[1..], path[i..], full, budget) orelse return null) return true;
            if (i < path.len and isSep(path[i])) break;
        }
        return false;
    }
    if (path.len == 0) return false;
    if (pattern[0] == '?') {
        if (isSep(path[0])) return false;
        return matchGlobRec(pattern[1..], path[1..], full, budget);
    }
    if (!sameChar(pattern[0], path[0])) return false;
    return matchGlobRec(pattern[1..], path[1..], full, budget);
}

/// The same match as `matchGlobRec`, decided in one pass over a table so that
/// no arrangement of `**` can make it backtrack.
fn matchGlobTable(pattern: []const u8, path: []const u8) bool {
    const n = pattern.len;
    const m = path.len;
    if (m + 1 > glob_row) return false;
    // `row[i][j]` is "pattern[i..] matches path[j..]". Only rows i+1..i+3 are
    // ever read, so four of them rotate rather than the whole table.
    var rows: [4][glob_row]bool = undefined;
    for (rows[n % 4][0 .. m + 1], 0..) |*cell, j| cell.* = j == m;

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const c = pattern[i];
        const dst = &rows[i % 4];
        if (c == '*' and i + 1 < n and pattern[i + 1] == '*') {
            // `**` crosses separators, so anything left may follow it -- but
            // `**/x` may only resume where a path component starts.
            var r = i + 2;
            const bounded = r < n and isSep(pattern[r]);
            if (bounded) r += 1;
            const src = &rows[r % 4];
            var seen = false;
            var j: usize = m + 1;
            while (j > 0) {
                j -= 1;
                const here = if (bounded and j > 0 and !isSep(path[j - 1])) false else src[j];
                seen = seen or here;
                dst[j] = seen;
            }
        } else if (c == '*') {
            const src = &rows[(i + 1) % 4];
            var seen = false;
            var j: usize = m + 1;
            while (j > 0) {
                j -= 1;
                // A single `*` may reach a separator but never past one.
                if (j < m and isSep(path[j])) seen = false;
                seen = seen or src[j];
                dst[j] = seen;
            }
        } else {
            const src = &rows[(i + 1) % 4];
            dst[m] = false;
            var j: usize = m;
            while (j > 0) {
                j -= 1;
                const ok = if (c == '?') !isSep(path[j]) else sameChar(c, path[j]);
                dst[j] = ok and src[j + 1];
            }
        }
    }
    return rows[0][0];
}

/// One more than the longest path any of these globs can be asked about.
const glob_row = std.fs.max_path_bytes + 1;

fn isSep(c: u8) bool {
    return c == '/' or (is_windows and c == '\\');
}

fn sameChar(a: u8, b: u8) bool {
    if (a == b) return true;
    // A pattern written with `/` should match a path that arrived with `\`.
    if (isSep(a) and isSep(b)) return true;
    if (is_windows) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return false;
}

// --- accumulators ---------------------------------------------------------

const Key = struct { file: []const u8, line: i32 };
const Row = struct { line: i32, count: i32 };

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.file);
        h.update(std.mem.asBytes(&k.line));
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.line == b.line and std.mem.eql(u8, a.file, b.file);
    }
};
const LineMap = std.HashMap(Key, i32, KeyContext, std.hash_map.default_max_load_percentage);

/// A function is identified by where its name sits in the original source, so
/// the same function inlined into a thousand bundles merges into one entry.
const FnKey = struct { file: []const u8, line: i32, col: i32 };
const FnVal = struct { count: i32, name: []const u8 };
const FnContext = struct {
    pub fn hash(_: FnContext, k: FnKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.file);
        h.update(std.mem.asBytes(&k.line));
        h.update(std.mem.asBytes(&k.col));
        return h.final();
    }
    pub fn eql(_: FnContext, a: FnKey, b: FnKey) bool {
        return a.line == b.line and a.col == b.col and std.mem.eql(u8, a.file, b.file);
    }
};
const FnMap = std.HashMap(FnKey, FnVal, FnContext, std.hash_map.default_max_load_percentage);

/// `a || b ? c : d` puts a logical and a conditional at the same offset, so the
/// branch type is part of the identity as well as the position.
const BrKey = struct { file: []const u8, line: i32, col: i32, btype: u8, slot: u16 };
const BrContext = struct {
    pub fn hash(_: BrContext, k: BrKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.file);
        h.update(std.mem.asBytes(&k.line));
        h.update(std.mem.asBytes(&k.col));
        h.update(std.mem.asBytes(&k.btype));
        h.update(std.mem.asBytes(&k.slot));
        return h.final();
    }
    pub fn eql(_: BrContext, a: BrKey, b: BrKey) bool {
        return a.line == b.line and a.col == b.col and a.btype == b.btype and
            a.slot == b.slot and std.mem.eql(u8, a.file, b.file);
    }
};
/// The count, plus the extent of the node the group belongs to -- see
/// `scan.Item.span_end`. Not part of the key: it must not split a group.
const BrVal = struct { count: i32, span_end: u32 };
const BrMap = std.HashMap(BrKey, BrVal, BrContext, std.hash_map.default_max_load_percentage);

/// Unknown wins over a count. A default parameter is only ever proven skipped
/// per process, so one that could not tell keeps the whole branch out of the
/// report rather than letting the other's zero read as a miss.
fn mergeBranch(a: i32, b: i32) i32 {
    if (a == scan.unknown_branch or b == scan.unknown_branch) return scan.unknown_branch;
    return a +| b;
}

// One range set per contributing process: sets from different processes do not
// nest, so they are scored apart and only the per-line results combined.
const Script = struct { direct: bool, sets: std.ArrayList(std.ArrayList(scan.Range)) };

const Job = struct {
    dumps: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
    cfg: *const Config,
    io: std.Io,
    gpa: std.mem.Allocator,
    scripts: std.StringHashMap(Script),
};

const Worker = struct {
    gpa: std.mem.Allocator,
    lines: LineMap,
    fns: FnMap,
    brs: BrMap,
    // Phase 1 accumulates here per thread, so no lock is needed; the maps are
    // merged once all dumps have been read.
    scripts: std.StringHashMap(Script),
    /// Segment-derived evidence, kept apart from statement hits so it can only
    /// lift lines that already carry a statement.
    resolved: LineMap,
    /// Generated files whose coverage was attributed to their sources instead.
    remapped: std.StringHashMap(void),
    /// Line denominators carried over from the scan, so a source V8 ran itself
    /// is not parsed a second time to count its statements.
    src_spans: std.StringHashMap([]LineSpan),
    /// Anything skipped, so a quietly-low number is visible rather than
    /// plausible. A script that fails to parse just disappears otherwise.
    unreadable: usize = 0,
    unparsed: usize = 0,
    bad_dumps: usize = 0,
    bundles: usize = 0,
    bytes: usize = 0,
};

fn run(job: *Job, w: *Worker) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.dumps.len) return;
        processDump(job, w, job.dumps[i]) catch {
            w.bad_dumps += 1;
            continue;
        };
    }
}

const ScanJob = struct {
    urls: []const []const u8,
    scripts: *std.StringHashMap(Script),
    next: std.atomic.Value(usize) = .init(0),
    io: std.Io,
    root: []const u8,
};

fn runScan(job: *ScanJob, w: *Worker) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.urls.len) return;
        scanOne(job, w, job.urls[i]) catch continue;
    }
}

fn scanOne(job: *ScanJob, w: *Worker, url: []const u8) !void {
    const entry = job.scripts.getPtr(url) orelse return;

    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const code = std.Io.Dir.cwd().readFileAlloc(job.io, url, a, .limited(1 << 28)) catch {
        w.unreadable += 1;
        return;
    };
    w.bundles += 1;
    w.bytes += code.len;

    // Anything carrying a source map is remapped even when it also looks
    // reportable: `tsc` output sits beside its sources and would score itself.
    const map_json = readSourceMap(job.io, a, url, code);

    const mapped = map_json != null;
    if (!mapped and !entry.direct) return;
    // Parsed once, then scored against each process's ranges. The parse is a
    // function of the source alone, and a CI run repeats a script per worker.
    var prep = scan.prepare(a, code, map_json, langOf(url)) catch {
        w.unparsed += 1;
        return;
    };
    // Report the sources it maps to, not the generated file.
    if (mapped) w.remapped.put(url, {}) catch {};
    const base = std.fs.path.dirname(url) orelse ".";
    if (!mapped and !w.src_spans.contains(url)) {
        const rows = try w.gpa.alloc(LineSpan, prep.spans.len);
        const end: u32 = @intCast(code.len);
        for (prep.spans, rows) |sp, *row| row.* = .{
            .line = prep.off.line(@min(sp.start, end)),
            .end_line = prep.off.line(@min(sp.end, end)),
            .group = sp.group,
            .order = sp.order,
            .is_loop = sp.is_loop,
        };
        try w.src_spans.put(try w.gpa.dupe(u8, url), rows);
    }

    // Within one process the highest count on a line wins; across processes the
    // counts add, because each process really did execute the line that often.
    // One scratch arena reset between sets, rather than a fresh mapping each.
    var set_arena = std.heap.ArenaAllocator.init(w.gpa);
    defer set_arena.deinit();
    for (entry.sets.items) |set| {
        _ = set_arena.reset(.retain_capacity);
        const sa = set_arena.allocator();

        var hits: std.ArrayList(scan.Hit) = .empty;
        var resolved: std.ArrayList(scan.Hit) = .empty;
        var items: std.ArrayList(scan.ItemHit) = .empty;
        scan.scoreSet(sa, sa, &prep, set.items, &hits, &resolved, &items) catch continue;

        if (!mapped) {
            var per_set = std.AutoHashMap(i32, i32).init(sa);
            for (hits.items) |h| {
                const g = try per_set.getOrPut(h.line);
                if (!g.found_existing or g.value_ptr.* < h.count) g.value_ptr.* = h.count;
            }
            var it = per_set.iterator();
            while (it.next()) |e| try record(w, url, e.key_ptr.*, e.value_ptr.*);
            for (items.items) |item| try recordItem(w, url, item, code);
            continue;
        }

        var per_set = std.StringHashMap(std.AutoHashMap(i32, i32)).init(sa);
        for (hits.items) |h| {
            const src = prep.sources[@intCast(h.source)];
            const abs = mappedSource(sa, base, src, job.root) orelse continue;
            const f = try per_set.getOrPut(abs);
            if (!f.found_existing) f.value_ptr.* = .init(sa);
            const g = try f.value_ptr.getOrPut(h.line);
            if (!g.found_existing or g.value_ptr.* < h.count) g.value_ptr.* = h.count;
        }
        var fi = per_set.iterator();
        while (fi.next()) |fe| {
            var li = fe.value_ptr.iterator();
            while (li.next()) |le| try record(w, fe.key_ptr.*, le.key_ptr.*, le.value_ptr.*);
        }
        for (resolved.items) |h| {
            const src = prep.sources[@intCast(h.source)];
            const abs = mappedSource(sa, base, src, job.root) orelse continue;
            const gop = try w.resolved.getOrPut(.{ .file = abs, .line = h.line });
            if (!gop.found_existing) {
                gop.key_ptr.file = try w.gpa.dupe(u8, abs);
                gop.value_ptr.* = h.count;
            } else if (gop.value_ptr.* < h.count) gop.value_ptr.* = h.count;
        }
        for (items.items) |item| {
            if (item.source < 0 or item.source >= prep.sources.len) continue;
            const src = prep.sources[@intCast(item.source)];
            const abs = mappedSource(sa, base, src, job.root) orelse continue;
            try recordItem(w, abs, item, code);
        }
    }
}

/// Where a source-map entry lands on disk, or null when that is outside the
/// project. A map names its own sources, so without this a crafted or careless
/// one reports files nobody asked about -- and the html reporter reads them.
fn mappedSource(a: std.mem.Allocator, base: []const u8, src: []const u8, root: []const u8) ?[]const u8 {
    const abs = normalizePath(a, std.fs.path.resolve(a, &.{ base, src }) catch return null);
    if (!pathStartsWith(abs, root)) return null;
    return abs;
}

/// A sibling `.map`, or an inline base64 map, which is what tsc and esbuild
/// emit by default.
fn readSourceMap(io: std.Io, a: std.mem.Allocator, url: []const u8, code: []const u8) ?[]const u8 {
    const map_path = std.mem.concat(a, u8, &.{ url, ".map" }) catch return null;
    if (std.Io.Dir.cwd().readFileAlloc(io, map_path, a, .limited(1 << 28))) |json| {
        return json;
    } else |_| {}

    const at = std.mem.lastIndexOf(u8, code, "sourceMappingURL=") orelse return null;
    var target = code[at + "sourceMappingURL=".len ..];
    if (std.mem.indexOfAny(u8, target, "\r\n")) |end| target = target[0..end];
    target = std.mem.trim(u8, target, " \t*/");

    // A plain path is resolved against the script's own directory, which is
    // what a build that writes its maps into a subdirectory produces.
    if (!std.mem.startsWith(u8, target, "data:")) {
        const dir = std.fs.path.dirname(url) orelse ".";
        const joined = std.fs.path.resolve(a, &.{ dir, target }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, joined, a, .limited(1 << 28)) catch null;
    }

    const b64_tag = "base64,";
    const b64_at = std.mem.indexOf(u8, target, b64_tag) orelse return null;
    const payload = target[b64_at + b64_tag.len ..];
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(payload) catch return null;
    const out = a.alloc(u8, len) catch return null;
    dec.decode(out, payload) catch return null;
    return out;
}

fn record(w: *Worker, file: []const u8, line: i32, count: i32) !void {
    const gop = try w.lines.getOrPut(.{ .file = file, .line = line });
    if (!gop.found_existing) {
        gop.key_ptr.file = try w.gpa.dupe(u8, file);
        gop.value_ptr.* = count;
    } else gop.value_ptr.* +|= count;
}

fn recordItem(w: *Worker, file: []const u8, item: scan.ItemHit, code: []const u8) !void {
    if (item.is_branch) {
        const gop = try w.brs.getOrPut(.{
            .file = file,
            .line = item.line,
            .col = item.col,
            .btype = @intFromEnum(item.btype),
            .slot = item.slot,
        });
        if (!gop.found_existing) {
            gop.key_ptr.file = try w.gpa.dupe(u8, file);
            gop.value_ptr.* = .{ .count = item.count, .span_end = item.span_end };
        } else {
            gop.value_ptr.count = mergeBranch(gop.value_ptr.count, item.count);
            if (item.span_end > gop.value_ptr.span_end) gop.value_ptr.span_end = item.span_end;
        }
        return;
    }
    var name: []const u8 = "";
    if (item.name_len > 0 and item.name_start + item.name_len <= code.len) {
        name = code[item.name_start..][0..item.name_len];
    }
    const gop = try w.fns.getOrPut(.{ .file = file, .line = item.line, .col = item.col });
    if (!gop.found_existing) {
        gop.key_ptr.file = try w.gpa.dupe(u8, file);
        gop.value_ptr.* = .{ .count = item.count, .name = try w.gpa.dupe(u8, name) };
        return;
    }
    gop.value_ptr.count +|= item.count;
    if (betterName(name, gop.value_ptr.name)) gop.value_ptr.name = try w.gpa.dupe(u8, name);
}

/// A bundler renames `NOOP` to `NOOP$1` wherever it collides, so the smallest
/// name wins: deterministic, and it prefers the un-suffixed original.
fn betterName(candidate: []const u8, current: []const u8) bool {
    if (candidate.len == 0) return false;
    if (current.len == 0) return true;
    return std.mem.order(u8, candidate, current) == .lt;
}

/// Streams a dump rather than building a `std.json.Value` for it: dumps reach
/// 22MB each, and only the URL and three numbers per range are ever needed.
fn processDump(job: *Job, w: *Worker, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = try std.Io.Dir.cwd().readFileAlloc(job.io, path, a, .limited(1 << 31));
    var scanner = std.json.Scanner.initCompleteInput(a, raw);
    defer scanner.deinit();

    // Ranges for the script being read. V8 writes `url` before `functions`, but
    // nothing guarantees it, so they are buffered and committed at script end.
    var pending: std.ArrayList(scan.Range) = .empty;
    defer pending.deinit(a);
    // Keyed on script id, not URL: one script listed twice merges, but a module
    // compiled once per context is a separate instance whose ranges must not.
    var seen = std.StringHashMap(SeenScript).init(a);
    defer seen.deinit();

    if (try scanner.next() != .object_begin) return;
    while (true) {
        switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
            .object_end, .end_of_document => return,
            .string, .allocated_string => |key| {
                if (!std.mem.eql(u8, key, "result")) {
                    try scanner.skipValue();
                    continue;
                }
                if (try scanner.next() != .array_begin) return;
                while (true) {
                    switch (try scanner.peekNextTokenType()) {
                        .array_end => {
                            _ = try scanner.next();
                            break;
                        },
                        .object_begin => {
                            _ = try scanner.next();
                            try readScript(job, w, a, &scanner, &pending, &seen);
                        },
                        else => return,
                    }
                }
            },
            else => return,
        }
    }
}

fn readScript(
    job: *Job,
    w: *Worker,
    a: std.mem.Allocator,
    scanner: *std.json.Scanner,
    pending: *std.ArrayList(scan.Range),
    seen: *std.StringHashMap(SeenScript),
) !void {
    pending.clearRetainingCapacity();
    var url: ?[]const u8 = null;
    var script_id: ?[]const u8 = null;

    while (true) {
        const key = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |k| k,
            else => return,
        };
        if (std.mem.eql(u8, key, "scriptId")) {
            script_id = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
                .string, .allocated_string => |v| v,
                .number, .allocated_number => |v| v,
                else => null,
            };
        } else if (std.mem.eql(u8, key, "url")) {
            url = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
                .string, .allocated_string => |v| v,
                else => null,
            };
        } else if (std.mem.eql(u8, key, "functions")) {
            try readFunctions(a, scanner, pending);
        } else {
            try scanner.skipValue();
        }
    }

    var path = url orelse return;
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path["file://".len..];
        // `file:///C:/x` decodes to `/C:/x`; the leading slash is not part of
        // the path on Windows.
        if (path.len > 2 and path[0] == '/' and path[2] == ':') path = path[1..];
    }
    path = percentDecode(a, path) catch path;
    path = normalizePath(a, path);
    if (!pathStartsWith(path, job.cfg.root)) return;

    // Anything under the root is either a file we report on or a bundle that
    // might map back to one; everything else is somebody else's code.
    const direct = job.cfg.reports(path);
    if (!direct and !looksBundled(path)) return;
    // A dependency's own bundle never maps back to a file we report on, and
    // reading them all is the difference between a fast run and a slow one.
    if (!direct and containsDir(path, "node_modules")) return;
    if (pending.items.len == 0) return;

    // Phase 1 only accumulates ranges, one set per appearance: a script that ran
    // in sixteen processes must stay sixteen sets or its branches read dead.
    const gop = w.scripts.getOrPut(path) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = job.gpa.dupe(u8, path) catch return;
        gop.value_ptr.* = .{ .direct = direct, .sets = .empty };
    }
    if (script_id) |id| {
        // The index belongs to the URL it was recorded under. A dump that
        // repeats an id across two URLs would otherwise index the other one's
        // sets, which is out of bounds as often as not.
        if (seen.get(id)) |prev| {
            if (std.mem.eql(u8, prev.url, path) and prev.index < gop.value_ptr.sets.items.len) {
                var existing = &gop.value_ptr.sets.items[prev.index];
                existing.appendSlice(job.gpa, pending.items) catch return;
                std.sort.pdq(scan.Range, existing.items, {}, scan.lessRange);
                return;
            }
        }
    }
    var set: std.ArrayList(scan.Range) = .empty;
    set.appendSlice(job.gpa, pending.items) catch return;
    std.sort.pdq(scan.Range, set.items, {}, scan.lessRange);
    if (script_id) |id| {
        seen.put(a.dupe(u8, id) catch id, .{
            .url = gop.key_ptr.*,
            .index = gop.value_ptr.sets.items.len,
        }) catch {};
    }
    gop.value_ptr.sets.append(job.gpa, set) catch return;
}

/// Where a script id's ranges were already put. The URL is part of it because
/// only that URL's set list is safe to index.
const SeenScript = struct { url: []const u8, index: usize };

fn readFunctions(
    a: std.mem.Allocator,
    scanner: *std.json.Scanner,
    out: *std.ArrayList(scan.Range),
) !void {
    if (try scanner.next() != .array_begin) return;
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .array_end => {
                _ = try scanner.next();
                return;
            },
            .object_begin => _ = try scanner.next(),
            else => return,
        }
        while (true) {
            const key = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
                .object_end => break,
                .string, .allocated_string => |k| k,
                else => return,
            };
            if (!std.mem.eql(u8, key, "ranges")) {
                try scanner.skipValue();
                continue;
            }
            if (try scanner.next() != .array_begin) return;
            // The first range of a function is its own body; the rest carve
            // blocks out of it. Only the first is a function root.
            var first = true;
            while (true) {
                switch (try scanner.peekNextTokenType()) {
                    .array_end => {
                        _ = try scanner.next();
                        break;
                    },
                    .object_begin => _ = try scanner.next(),
                    else => return,
                }
                var r: scan.Range = .{ .start = 0, .end = 0, .count = 0, .fn_root = first };
                // All three have to be present. A range missing `startOffset`
                // used to default to 0 and claim the top of the file ran.
                var seen_fields: u3 = 0;
                var usable = true;
                first = false;
                while (true) {
                    const f = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
                        .object_end => break,
                        .string, .allocated_string => |k| k,
                        else => return,
                    };
                    const num = switch (try scanner.nextAlloc(a, .alloc_if_needed)) {
                        .number, .allocated_number => |n| n,
                        else => continue,
                    };
                    const v = std.fmt.parseInt(i64, num, 10) catch continue;
                    // An offset no file could hold, or a negative count, means
                    // the whole range is nonsense: drop it rather than keep the
                    // fields around it and score against a fabricated zero.
                    if (std.mem.eql(u8, f, "startOffset")) {
                        seen_fields |= 1;
                        r.start = std.math.cast(u32, v) orelse {
                            usable = false;
                            continue;
                        };
                    } else if (std.mem.eql(u8, f, "endOffset")) {
                        seen_fields |= 2;
                        r.end = std.math.cast(u32, v) orelse {
                            usable = false;
                            continue;
                        };
                    } else if (std.mem.eql(u8, f, "count")) {
                        seen_fields |= 4;
                        if (v < 0) usable = false else r.count = std.math.lossyCast(i32, v);
                    }
                }
                if (usable and seen_fields == 7 and r.end >= r.start) try out.append(a, r);
            }
        }
    }
}

/// Matches a path component, so it cannot be fooled by `my_node_modules_thing`.
fn containsDir(path: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, path, i, name)) |at| {
        i = at + 1;
        const before_ok = at > 0 and isSep(path[at - 1]);
        const after = at + name.len;
        const after_ok = after < path.len and isSep(path[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn looksBundled(url: []const u8) bool {
    const ext = std.fs.path.extension(url);
    inline for (.{ ".js", ".mjs", ".cjs" }) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}

/// V8 reports script URLs percent-encoded, so paths containing characters like
/// `[` in `native-tag[html]/index.js` arrive as `%5B` and never match on disk.
fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out = try std.ArrayList(u8).initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            try out.append(a, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn langOf(p: []const u8) yuku.ast.Lang {
    const ext = std.fs.path.extension(p);
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".mts") or
        std.mem.eql(u8, ext, ".cts")) return .ts;
    if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
    if (std.mem.eql(u8, ext, ".jsx")) return .jsx;
    return .js;
}

/// Extensions yuku parses outright. The other entries in `source_exts` are
/// component formats; an `--extension` was asked for by name, so it counts.
fn parseableExt(cfg: Config, path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    inline for (.{ ".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx" }) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    for (cfg.extensions) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    return false;
}

/// Every statement in a source file, which is the denominator. Type stripping
/// preserves offsets, so parsing as TypeScript lines up with what V8 reported.
const LineSpan = struct { line: i32, end_line: i32, group: u32 = 0, order: u32 = 0, is_loop: bool = false };

/// Functions and branches read off the source itself. Only ever used for a file
/// with no coverage evidence at all, where nothing else can supply them.
const WalkItems = struct { fns: *std.ArrayList(FnEntry), brs: *std.ArrayList(BrEntry) };

/// What the walk made of a file: countable, unreadable, or somebody's build
/// output rather than a source at all.
const Walked = enum { ok, unparsed, generated };

fn sourceLines(
    gpa: std.mem.Allocator,
    keep: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayList(LineSpan),
    items: ?WalkItems,
) !Walked {
    const code = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 27));
    defer gpa.free(code);
    // A file carrying a source map is generated, and its coverage belongs to
    // the sources it maps to. One that ran was recognised as such when it was
    // scanned; this is the same test, for one that never ran.
    if (readSourceMap(io, gpa, path, code) != null) return .generated;
    var tree = yuku.parse(gpa, code, scan.parseOptions(code, langOf(path))) catch return .unparsed;
    defer tree.deinit();
    const ignore = try scan.ignoreRanges(gpa, &tree, code);
    var spans: std.ArrayList(scan.Span2) = .empty;
    defer spans.deinit(gpa);
    try scan.statementSpans(gpa, &tree, ignore, &spans);
    // yuku recovers rather than failing, so a file it could not really read
    // comes back with diagnostics and nothing to count. Say so, do not drop it.
    if (spans.items.len == 0 and tree.hasErrors()) return .unparsed;

    const off = try scan.Offsets.init(gpa, code);
    for (spans.items) |sp| {
        const end: u32 = @intCast(code.len);
        try out.append(gpa, .{
            .line = off.line(@min(sp.start, end)),
            .end_line = off.line(@min(sp.end, end)),
            .group = sp.group,
            .order = sp.order,
            .is_loop = sp.is_loop,
        });
    }
    if (items) |dst| try walkItems(keep, &tree, ignore, off, code, dst);
    return .ok;
}

/// Every function and branch in a never-loaded file, all at count zero, so its
/// uncovered ones reach the denominator instead of being absent from it.
fn walkItems(
    gpa: std.mem.Allocator,
    tree: *const yuku.ast.Tree,
    ignore: scan.Ignore,
    off: scan.Offsets,
    code: []const u8,
    dst: WalkItems,
) !void {
    var raw: std.ArrayList(scan.Item) = .empty;
    defer raw.deinit(gpa);
    try scan.collectItems(gpa, tree, ignore, &raw);
    for (raw.items) |it| {
        // A default parameter is dropped for want of evidence exactly as it is
        // on the scored path, so the two denominators stay the same shape.
        if (it.unevidenced) continue;
        const line = off.line(it.loc);
        const col: i32 = @intCast(off.columnU16(it.loc));
        if (it.is_branch) {
            try dst.brs.append(gpa, .{
                .line = line,
                .col = col,
                .btype = @intFromEnum(it.btype),
                .slot = it.slot,
                .count = 0,
                .span_end = it.span_end,
            });
            continue;
        }
        var name: []const u8 = "";
        if (it.name_len > 0 and it.name_start + it.name_len <= code.len) {
            name = try gpa.dupe(u8, code[it.name_start..][0..it.name_len]);
        }
        try dst.fns.append(gpa, .{ .line = line, .col = col, .count = 0, .name = name });
    }
}

// --- report ---------------------------------------------------------------

const FileReport = struct {
    file: []const u8,
    rows: std.ArrayList(Row),
    statements: usize = 0,
    statements_hit: usize = 0,
    fns: std.ArrayList(FnEntry) = .empty,
    brs: std.ArrayList(BrEntry) = .empty,
};
const FnEntry = struct { line: i32, col: i32, count: i32, name: []const u8 };
const BrEntry = struct { line: i32, col: i32, btype: u8, slot: u16, count: i32, span_end: u32 = 0, group: usize = 0 };

pub fn main(init: std.process.Init) void {
    std.process.exit(realMain(init) catch |err| fatal(err));
}

/// Exits with the wrapped command's own status -- `zcov npm
/// test` has to fail when the tests fail, and with their code, not a generic 1.
fn realMain(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);

    var given: Given = .{};
    var cfg = parseArgs(a, args, &given) catch |err| switch (err) {
        error.Help => {
            std.debug.print("{s}", .{usage});
            return 0;
        },
        error.Version => {
            std.debug.print("{s}\n", .{build_options.version});
            return 0;
        },
        error.UnknownOption,
        error.UnknownReporter,
        error.MissingValue,
        error.BadThreshold,
        error.BadThreads,
        => {
            std.debug.print("{s}", .{usage});
            return 2;
        },
        else => return err,
    };
    // The root has to be settled first, because that is where the config lives.
    cfg.root = normalizePath(a, try absolute(init.io, a, cfg.root));
    applyConfig(init.io, a, &cfg, given) catch |err| switch (err) {
        error.BadConfig => return 2,
        error.BadConfigValue, error.UnknownReporter => {
            std.debug.print("zcov: zcov.json has a value of the wrong shape\n", .{});
            return 2;
        },
        else => return err,
    };
    // `--check-coverage` on its own means c8's default of 90% lines; naming a
    // threshold anywhere means only the ones named are enforced.
    if (cfg.check and !given.thresholds and
        cfg.min_lines == 0 and cfg.min_functions == 0 and
        cfg.min_branches == 0 and cfg.min_statements == 0) cfg.min_lines = 90;
    if (!cfg.text and !cfg.text_summary and !cfg.lcov and !cfg.json and !cfg.html) cfg.text = true;
    // One thread per core, capped at 8: past that the parse is memory-bound, and
    // 16 threads measured slower in wall time than 8 for 37% more CPU.
    if (cfg.threads == 0) cfg.threads = @min(8, @max(1, std.Thread.getCpuCount() catch 8));
    if (!std.fs.path.isAbsolute(cfg.coverage_dir)) {
        cfg.coverage_dir = try std.fs.path.join(a, &.{ cfg.root, cfg.coverage_dir });
    }
    // Resolved, so `.` and `src/..` are recognised as the root they name.
    cfg.coverage_dir = normalizePath(a, try std.fs.path.resolve(a, &.{cfg.coverage_dir}));

    // Dumps land in their own directory. Pointing that at the project root is
    // always a mistake, and one that would have zcov writing into the source.
    if (std.mem.eql(u8, cfg.coverage_dir, cfg.root)) {
        std.debug.print("zcov: --coverage-dir cannot be the project root\n", .{});
        return 2;
    }

    var status: u8 = 0;
    if (cfg.command.len > 0) {
        if (cfg.clean) cleanDumps(init.io, cfg.coverage_dir);
        std.Io.Dir.cwd().createDirPath(init.io, cfg.coverage_dir) catch {};
        status = spawn(init, cfg) catch |err| {
            std.debug.print("zcov: could not run `{s}`: {s}\n", .{ cfg.command[0], @errorName(err) });
            // 127 is what a shell returns for a command it cannot execute.
            return 127;
        };
    } else if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }

    const met = report(init, gpa, a, cfg) catch |err| switch (err) {
        // A failed run with no dumps is the command's failure to report, not
        // zcov's; only complain when the run itself succeeded.
        error.NoCoverage => {
            if (status == 0) {
                std.debug.print("zcov: no coverage dumps in {s}\n", .{cfg.coverage_dir});
                return 1;
            }
            return status;
        },
        else => return err,
    };
    // A failing command still wins: its status is the more useful signal.
    if (status != 0) return status;
    return if (met) 0 else 1;
}

/// Removes last run's dumps, and only those: V8 names them
/// `coverage-<pid>-<ms>-<n>.json`. Deleting the directory, or every `.json` in
/// it, would follow a mistyped `--coverage-dir` into somebody's source tree.
fn cleanDumps(io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "coverage-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

fn fatal(err: anyerror) noreturn {
    std.debug.print("zcov: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}

/// Which options the command line supplied, so `zcov.json` can fill in the rest
/// without ever overriding something asked for explicitly.
const Given = struct {
    reporter: bool = false,
    report_dir: bool = false,
    coverage_dir: bool = false,
    include: bool = false,
    exclude: bool = false,
    threads: bool = false,
    all: bool = false,
    clean: bool = false,
    check: bool = false,
    thresholds: bool = false,
    extensions: bool = false,
};

fn parseArgs(a: std.mem.Allocator, args: []const []const u8, given: *Given) !Config {
    var cfg: Config = .{};
    var include: std.ArrayList([]const u8) = .empty;
    var exclude: std.ArrayList([]const u8) = .empty;
    var extensions: std.ArrayList([]const u8) = .empty;
    for (default_excludes) |p| try exclude.append(a, p);

    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "report")) i += 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "-")) break;
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const inline_val: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
        const next = struct {
            fn f(list: []const []const u8, idx: *usize, v: ?[]const u8) ![]const u8 {
                if (v) |x| return x;
                idx.* += 1;
                if (idx.* >= list.len) return error.MissingValue;
                return list[idx.*];
            }
        }.f;

        if (eqAny(name, &.{ "-r", "--reporter" })) {
            try setReporter(&cfg, try next(args, &i, inline_val));
            given.reporter = true;
        } else if (eqAny(name, &.{ "-o", "--report-dir" })) {
            cfg.report_dir = try next(args, &i, inline_val);
            given.report_dir = true;
        } else if (eqAny(name, &.{ "-d", "--coverage-dir" })) {
            cfg.coverage_dir = try next(args, &i, inline_val);
            given.coverage_dir = true;
        } else if (eqAny(name, &.{ "-n", "--include" })) {
            try include.append(a, try next(args, &i, inline_val));
            given.include = true;
        } else if (eqAny(name, &.{ "-x", "--exclude" })) {
            try exclude.append(a, try next(args, &i, inline_val));
            given.exclude = true;
        } else if (std.mem.eql(u8, name, "--cwd")) {
            cfg.root = try next(args, &i, inline_val);
        } else if (std.mem.eql(u8, name, "--threads")) {
            const n = std.fmt.parseInt(usize, try next(args, &i, inline_val), 10) catch
                return error.BadThreads;
            if (n == 0 or n > max_threads) return error.BadThreads;
            cfg.threads = n;
            given.threads = true;
        } else if (std.mem.eql(u8, name, "--no-all")) {
            cfg.all = false;
            given.all = true;
        } else if (std.mem.eql(u8, name, "--no-clean")) {
            cfg.clean = false;
            given.clean = true;
        } else if (std.mem.eql(u8, name, "--check-coverage")) {
            cfg.check = true;
            given.check = true;
        } else if (std.mem.eql(u8, name, "--extension")) {
            try extensions.append(a, try dottedExt(a, try next(args, &i, inline_val)));
            given.extensions = true;
        } else if (eqAny(name, &.{ "--lines", "--functions", "--branches", "--statements" })) {
            const v = std.fmt.parseFloat(f64, try next(args, &i, inline_val)) catch return error.BadThreshold;
            cfg.check = true;
            given.thresholds = true;
            setThreshold(&cfg, name["--".len..], v);
        } else if (eqAny(name, &.{ "-h", "--help" })) {
            return error.Help;
        } else if (eqAny(name, &.{ "-V", "--version" })) {
            return error.Version;
        } else return error.UnknownOption;
    }
    if (i < args.len) cfg.command = args[i..];
    cfg.include = try include.toOwnedSlice(a);
    cfg.exclude = try exclude.toOwnedSlice(a);
    cfg.extensions = try extensions.toOwnedSlice(a);
    return cfg;
}

fn setReporter(cfg: *Config, v: []const u8) !void {
    if (std.mem.eql(u8, v, "lcov")) cfg.lcov = true //
    else if (std.mem.eql(u8, v, "text")) cfg.text = true //
    else if (std.mem.eql(u8, v, "text-summary")) cfg.text_summary = true //
    else if (std.mem.eql(u8, v, "json")) cfg.json = true //
    else if (std.mem.eql(u8, v, "html")) cfg.html = true //
    else return error.UnknownReporter;
}

/// The canonical spelling of a threshold key, so a `"Lines"` in the config
/// reaches `setThreshold` under the name it actually compares against.
fn thresholdName(key: []const u8) ?[]const u8 {
    inline for (.{ "lines", "functions", "branches", "statements" }) |n| {
        if (keyIs(key, n)) return n;
    }
    return null;
}

fn setThreshold(cfg: *Config, name: []const u8, v: f64) void {
    if (std.mem.eql(u8, name, "lines")) cfg.min_lines = v;
    if (std.mem.eql(u8, name, "functions")) cfg.min_functions = v;
    if (std.mem.eql(u8, name, "branches")) cfg.min_branches = v;
    if (std.mem.eql(u8, name, "statements")) cfg.min_statements = v;
}

/// Accepts `vue` as well as `.vue`.
fn dottedExt(a: std.mem.Allocator, e: []const u8) ![]const u8 {
    if (e.len > 0 and e[0] != '.') return std.mem.concat(a, u8, &.{ ".", e });
    return e;
}

/// `report-dir`, `reportDir` and `report_dir` are one key. `want` is the flag's
/// own spelling, so the file and the command line never drift apart.
fn keyIs(key: []const u8, want: []const u8) bool {
    var k: usize = 0;
    var w: usize = 0;
    while (k < key.len and w < want.len) {
        if (key[k] == '-' or key[k] == '_') {
            k += 1;
            continue;
        }
        if (want[w] == '-') {
            w += 1;
            continue;
        }
        if (std.ascii.toLower(key[k]) != want[w]) return false;
        k += 1;
        w += 1;
    }
    while (k < key.len and (key[k] == '-' or key[k] == '_')) k += 1;
    while (w < want.len and want[w] == '-') w += 1;
    return k == key.len and w == want.len;
}

/// A string or an array of them, so `"reporter": "lcov"` and
/// `"reporter": ["lcov", "html"]` both read.
fn strList(a: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
    switch (v) {
        .string => |s| return a.dupe([]const u8, &.{s}),
        .array => |arr| {
            var out: std.ArrayList([]const u8) = .empty;
            for (arr.items) |e| {
                if (e != .string) return error.BadConfigValue;
                try out.append(a, e.string);
            }
            return out.toOwnedSlice(a);
        },
        else => return error.BadConfigValue,
    }
}

fn numOf(v: std.json.Value) !f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => error.BadConfigValue,
    };
}

/// `zcov.json` in the project root. Flags win over it, so the file carries what
/// a project always wants and the command line is still the last word.
fn applyConfig(io: std.Io, a: std.mem.Allocator, cfg: *Config, given: Given) !void {
    const path = try std.fs.path.join(a, &.{ cfg.root, "zcov.json" });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return;
    const doc = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch {
        std.debug.print("zcov: {s} is not valid JSON\n", .{path});
        return error.BadConfig;
    };
    if (doc.value != .object) {
        std.debug.print("zcov: {s} must hold a JSON object\n", .{path});
        return error.BadConfig;
    }

    var include: std.ArrayList([]const u8) = .empty;
    var exclude: std.ArrayList([]const u8) = .empty;
    var extensions: std.ArrayList([]const u8) = .empty;
    var thresholds = false;

    var it = doc.value.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (keyIs(key, "reporter")) {
            if (given.reporter) continue;
            for (try strList(a, v)) |r| try setReporter(cfg, r);
        } else if (keyIs(key, "report-dir")) {
            if (v != .string) return error.BadConfigValue;
            if (given.report_dir) continue;
            cfg.report_dir = v.string;
        } else if (keyIs(key, "coverage-dir")) {
            if (v != .string) return error.BadConfigValue;
            if (given.coverage_dir) continue;
            cfg.coverage_dir = v.string;
        } else if (keyIs(key, "include")) {
            if (given.include) continue;
            try include.appendSlice(a, try strList(a, v));
        } else if (keyIs(key, "exclude")) {
            try exclude.appendSlice(a, try strList(a, v));
        } else if (keyIs(key, "extension")) {
            for (try strList(a, v)) |x| try extensions.append(a, try dottedExt(a, x));
        } else if (keyIs(key, "threads")) {
            if (given.threads) continue;
            cfg.threads = @intFromFloat(std.math.clamp(try numOf(v), 1, max_threads));
        } else if (keyIs(key, "all")) {
            if (v != .bool) return error.BadConfigValue;
            if (given.all) continue;
            cfg.all = v.bool;
        } else if (keyIs(key, "clean")) {
            if (v != .bool) return error.BadConfigValue;
            if (given.clean) continue;
            cfg.clean = v.bool;
        } else if (keyIs(key, "check-coverage")) {
            if (v != .bool) return error.BadConfigValue;
            if (given.check) continue;
            cfg.check = v.bool;
        } else if (thresholdName(key)) |canon| {
            if (given.thresholds) continue;
            cfg.check = true;
            thresholds = true;
            setThreshold(cfg, canon, try numOf(v));
        } else {
            // A misspelled key that silently did nothing would be exactly the
            // quiet wrongness the rest of this tool refuses to produce.
            std.debug.print("zcov: unknown key \"{s}\" in {s}\n", .{ key, path });
            return error.BadConfig;
        }
    }

    // `exclude` and `extension` add to what is already there, matching the flags.
    if (exclude.items.len > 0) {
        try exclude.appendSlice(a, cfg.exclude);
        cfg.exclude = try exclude.toOwnedSlice(a);
    }
    if (extensions.items.len > 0) {
        try extensions.appendSlice(a, cfg.extensions);
        cfg.extensions = try extensions.toOwnedSlice(a);
    }
    if (include.items.len > 0) cfg.include = try include.toOwnedSlice(a);
    if (thresholds) cfg.check = true;
}

/// V8 reports absolute paths, so the root has to be one too. `path.resolve`
/// alone will not do it: it has no access to the working directory.
fn absolute(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const joined = if (std.fs.path.isAbsolute(path)) try std.fs.path.resolve(a, &.{path}) else blk: {
        var here = try std.Io.Dir.cwd().openDir(io, ".", .{});
        defer here.close(io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try here.realPath(io, &buf);
        break :blk try std.fs.path.resolve(a, &.{ buf[0..len], path });
    };
    // Through any symlink, because V8 reports where a script really is. macOS
    // puts temporary directories under `/var`, which is a link to `/private/var`,
    // so a root left unresolved matches nothing the run actually loaded.
    var dir = std.Io.Dir.cwd().openDir(io, joined, .{}) catch return joined;
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = dir.realPath(io, &buf) catch return joined;
    return a.dupe(u8, buf[0..len]);
}

fn eqAny(name: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, name, o)) return true;
    return false;
}

fn spawn(init: std.process.Init, cfg: Config) !u8 {
    try init.environ_map.put("NODE_V8_COVERAGE", cfg.coverage_dir);
    var child = try std.process.spawn(init.io, .{
        .argv = cfg.command,
        .environ_map = init.environ_map,
    });
    return switch (try child.wait(init.io)) {
        .exited => |c| c,
        else => 1,
    };
}

/// One reported file: its statement lines, the counts repaired onto them, and
/// the functions and branches a never-loaded file has to supply itself.
fn walkOne(job: *WalkJob, w: *WalkWorker, abs: []const u8) !void {
    // Everything the report keeps comes from `keep`; the source text and its
    // parse tree go in `a`, which is reset before the next file. Holding those
    // cost ~24x the size of the tree being walked.
    const keep = w.arena.allocator();
    _ = w.scratch.reset(.retain_capacity);
    const a = w.scratch.allocator();

    // A component format is parsed only where something already points into
    // it: recovering a `.vue` script on its own invents a denominator.
    const measured = job.evidenced.contains(abs);
    if (!measured and !parseableExt(job.cfg.*, abs)) {
        try w.unanalysed.append(keep, abs);
        return;
    }
    var spans_of: std.ArrayList(LineSpan) = .empty;
    var walk_fns: std.ArrayList(FnEntry) = .empty;
    var walk_brs: std.ArrayList(BrEntry) = .empty;
    const items: ?WalkItems = if (measured) null else .{ .fns = &walk_fns, .brs = &walk_brs };
    // A source V8 ran itself was already parsed for its probes, and its
    // statement lines came back with them.
    const walked = if (job.src_spans.get(abs)) |cached| blk: {
        spans_of = .fromOwnedSlice(cached);
        break :blk Walked.ok;
    } else sourceLines(a, keep, job.io, abs, &spans_of, items) catch {
        try w.unanalysed.append(keep, abs);
        return;
    };
    switch (walked) {
        // Silently, the way a generated file that ran is left out: it is not
        // missing from the report, its sources are standing in for it.
        .generated => return,
        // Listed rather than dropped: a file nothing could be read from is not
        // the same as a file with nothing in it, and only one is worth saying.
        .unparsed => {
            try w.unanalysed.append(keep, abs);
            return;
        },
        .ok => {},
    }

    // Raw count per line, then containment repair: a statement enclosing an
    // executed statement must itself have executed, whatever V8 mapped.
    var raw = std.AutoHashMap(i32, i32).init(a);
    for (spans_of.items) |sp| {
        var c = job.merged.get(.{ .file = abs, .line = sp.line }) orelse 0;
        // Unanchored lines lifted from segments. Only ever fills a gap: a
        // statement that mapped somewhere and scored zero is dead code.
        const mapped = job.merged.contains(.{ .file = abs, .line = sp.line });
        if (c == 0 and !mapped) c = job.resolved.get(.{ .file = abs, .line = sp.line }) orelse 0;
        const g = try raw.getOrPut(sp.line);
        if (!g.found_existing or g.value_ptr.* < c) g.value_ptr.* = c;
    }
    for (spans_of.items) |sp| {
        const g = raw.getPtr(sp.line).?;
        if (g.* > 0) continue;
        // Nothing can sit inside a statement that ends on the line it
        // starts on, and almost every statement does.
        if (sp.end_line <= sp.line) continue;
        var best: i32 = 0;
        for (spans_of.items) |inner| {
            if (inner.line <= sp.line or inner.line > sp.end_line) continue;
            const ic = raw.get(inner.line) orelse 0;
            if (ic > best) best = ic;
        }
        if (best > 0) g.* = best;
    }

    // Control flows top to bottom, so a statement before one that ran was
    // reached. Only zero lines are lifted, to the list's smallest positive.
    {
        var ordered: std.ArrayList(LineSpan) = .empty;
        try ordered.appendSlice(a, spans_of.items);
        std.mem.sort(LineSpan, ordered.items, {}, struct {
            fn lt(_: void, x: LineSpan, y: LineSpan) bool {
                if (x.group != y.group) return x.group < y.group;
                return x.order > y.order;
            }
        }.lt);
        // A line's count is the max over its statements, so a line carrying
        // two cannot say which ran. Only single-statement lines are usable.
        var per_line = std.AutoHashMap(i32, u32).init(a);
        for (spans_of.items) |sp| {
            const g = try per_line.getOrPut(sp.line);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        }
        var min_pos = std.AutoHashMap(u32, i32).init(a);
        for (ordered.items) |sp| {
            if (sp.group == 0) continue;
            const c = raw.get(sp.line) orelse 0;
            if (c <= 0) continue;
            if ((per_line.get(sp.line) orelse 2) != 1) continue;
            const g = try min_pos.getOrPut(sp.group);
            if (!g.found_existing or g.value_ptr.* > c) g.value_ptr.* = c;
        }
        // The same monotonicity forwards: once a statement is proven dead,
        // so is everything after it in the list.
        {
            var dead = false;
            var group_now: u32 = 0;
            var forward: std.ArrayList(LineSpan) = .empty;
            try forward.appendSlice(a, spans_of.items);
            std.mem.sort(LineSpan, forward.items, {}, struct {
                fn lt(_: void, x: LineSpan, y: LineSpan) bool {
                    if (x.group != y.group) return x.group < y.group;
                    return x.order < y.order;
                }
            }.lt);
            for (forward.items) |sp| {
                if (sp.group == 0) continue;
                if (sp.group != group_now) {
                    group_now = sp.group;
                    dead = false;
                }
                const g = raw.getPtr(sp.line) orelse continue;
                if (g.* == 0) {
                    // A zero proves death only where something mapped to the
                    // line; a loop header's zero just means it never looped.
                    if (!sp.is_loop and job.merged.contains(.{ .file = abs, .line = sp.line })) {
                        dead = true;
                    }
                    continue;
                }
                if (!dead) continue;
                var live = false;
                var ln2 = sp.line + 1;
                while (ln2 <= sp.end_line) : (ln2 += 1) {
                    if ((raw.get(ln2) orelse 0) > 0) live = true;
                }
                if (!live) g.* = 0;
            }
        }

        var seen_positive = false;
        var current: u32 = 0;
        for (ordered.items) |sp| {
            if (sp.group == 0) continue;
            if (sp.group != current) {
                current = sp.group;
                seen_positive = false;
            }
            const g = raw.getPtr(sp.line) orelse continue;
            if (g.* > 0) {
                // Only an unambiguous line proves a statement after this
                // one ran; a shared line might be reporting a nested body.
                if ((per_line.get(sp.line) orelse 2) == 1) seen_positive = true;
            } else if (seen_positive) {
                // Reaching a later statement means passing this one, so the
                // zero is V8's overshooting range rather than dead code.
                g.* = min_pos.get(sp.group) orelse 0;
            }
        }
    }

    var fr: FileReport = .{ .file = abs, .rows = .empty, .fns = walk_fns, .brs = walk_brs };
    var seen_lines = std.AutoHashMap(i32, void).init(a);
    for (spans_of.items) |sp| {
        const c = raw.get(sp.line) orelse 0;
        fr.statements += 1;
        if (c > 0) fr.statements_hit += 1;
        if ((try seen_lines.getOrPut(sp.line)).found_existing) continue;
        try fr.rows.append(keep, .{ .line = sp.line, .count = c });
    }
    // Kept even with no statement lines: a file holding nothing but an uncalled
    // function still owes that function to the denominator. Records that end up
    // with nothing at all are pruned once functions and branches are attached.
    try w.reports.append(keep, fr);
}

/// The `--all` denominator walk. Every file is independent, so it gets the same
/// work queue the dump and scan phases use rather than one serial pass.
const WalkJob = struct {
    files: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
    io: std.Io,
    cfg: *const Config,
    merged: *const LineMap,
    resolved: *const LineMap,
    src_spans: *const std.StringHashMap([]LineSpan),
    evidenced: *const std.StringHashMap(void),
};

const WalkWorker = struct {
    arena: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    reports: std.ArrayList(FileReport) = .empty,
    unanalysed: std.ArrayList([]const u8) = .empty,
};

fn runWalk(job: *WalkJob, w: *WalkWorker) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.files.len) return;
        walkOne(job, w, job.files[i]) catch continue;
    }
}

fn report(init: std.process.Init, gpa: std.mem.Allocator, a: std.mem.Allocator, cfg: Config) !bool {
    var dumps: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(init.io, cfg.coverage_dir, .{ .iterate = true }) catch
        return error.NoCoverage;
    defer dir.close(init.io);
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try dumps.append(a, try std.fs.path.join(a, &.{ cfg.coverage_dir, entry.name }));
    }

    var job: Job = .{
        .dumps = dumps.items,
        .cfg = &cfg,
        .io = init.io,
        .gpa = gpa,
        .scripts = .init(gpa),
    };
    const workers = try a.alloc(Worker, cfg.threads);
    const handles = try a.alloc(std.Thread, cfg.threads);
    for (workers) |*w| w.* = .{
        .gpa = gpa,
        .lines = .init(gpa),
        .fns = .init(gpa),
        .brs = .init(gpa),
        .scripts = .init(gpa),
        .resolved = .init(gpa),
        .remapped = .init(gpa),
        .src_spans = .init(gpa),
    };
    for (handles, 0..) |*h, i| h.* = try std.Thread.spawn(.{}, run, .{ &job, &workers[i] });
    for (handles) |h| h.join();

    // Fold the per-thread script tables together before scoring.
    for (workers) |*w| {
        var wi = w.scripts.iterator();
        while (wi.next()) |e| {
            const gop = try job.scripts.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .direct = e.value_ptr.direct, .sets = .empty };
            }
            try gop.value_ptr.sets.appendSlice(gpa, e.value_ptr.sets.items);
        }
    }

    var urls: std.ArrayList([]const u8) = .empty;
    var si = job.scripts.keyIterator();
    while (si.next()) |k| try urls.append(a, k.*);
    var scan_job: ScanJob = .{ .urls = urls.items, .scripts = &job.scripts, .io = init.io, .root = cfg.root };
    for (handles, 0..) |*h, i| h.* = try std.Thread.spawn(.{}, runScan, .{ &scan_job, &workers[i] });
    for (handles) |h| h.join();

    var merged: LineMap = .init(a);
    var resolved: LineMap = .init(a);
    var all_fns: FnMap = .init(a);
    var all_brs: BrMap = .init(a);
    var bundles: usize = 0;
    var bytes: usize = 0;
    var skipped: Skipped = .{};
    for (workers) |*w| {
        bundles += w.bundles;
        bytes += w.bytes;
        skipped.unreadable += w.unreadable;
        skipped.unparsed += w.unparsed;
        skipped.bad_dumps += w.bad_dumps;
        var mi = w.lines.iterator();
        while (mi.next()) |e| {
            const gop = try merged.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.* else gop.value_ptr.* +|= e.value_ptr.*;
        }
        var ri = w.resolved.iterator();
        while (ri.next()) |e| {
            const gop = try resolved.getOrPut(e.key_ptr.*);
            if (!gop.found_existing or gop.value_ptr.* < e.value_ptr.*) gop.value_ptr.* = e.value_ptr.*;
        }
        var fi2 = w.fns.iterator();
        while (fi2.next()) |e| {
            const gop = try all_fns.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = e.value_ptr.*;
            } else {
                gop.value_ptr.count +|= e.value_ptr.count;
                if (betterName(e.value_ptr.name, gop.value_ptr.name)) gop.value_ptr.name = e.value_ptr.name;
            }
        }
        var bi = w.brs.iterator();
        while (bi.next()) |e| {
            const gop = try all_brs.getOrPut(e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = e.value_ptr.*;
            } else {
                gop.value_ptr.count = mergeBranch(gop.value_ptr.count, e.value_ptr.count);
                if (e.value_ptr.span_end > gop.value_ptr.span_end) gop.value_ptr.span_end = e.value_ptr.span_end;
            }
        }
    }

    // Which files to report on: every source under the root, or only the ones
    // the run loaded when --no-all is passed. The walk is what surfaces a 0%.
    var remapped: std.StringHashMap(void) = .init(a);
    var src_spans: std.StringHashMap([]LineSpan) = .init(a);
    for (workers) |*w| {
        var it2 = w.remapped.keyIterator();
        while (it2.next()) |k| try remapped.put(k.*, {});
        var si2 = w.src_spans.iterator();
        while (si2.next()) |e| try src_spans.put(e.key_ptr.*, e.value_ptr.*);
    }

    var wanted: std.StringHashMap(void) = .init(a);
    if (cfg.all) {
        var root_dir = try std.Io.Dir.cwd().openDir(init.io, cfg.root, .{ .iterate = true });
        defer root_dir.close(init.io);
        var walker = try root_dir.walk(a);
        while (try walker.next(init.io)) |entry| {
            if (entry.kind != .file) continue;
            const abs = normalizePath(a, try std.fs.path.join(a, &.{ cfg.root, entry.path }));
            if (!cfg.reports(abs) or remapped.contains(abs)) continue;
            try wanted.put(abs, {});
        }
    }
    // Whatever the maps pointed at is reportable, extension or not.
    var mi = merged.keyIterator();
    while (mi.next()) |k| {
        if (cfg.included(k.file) and !remapped.contains(k.file)) try wanted.put(k.file, {});
    }
    var fi2 = all_fns.keyIterator();
    while (fi2.next()) |k| {
        if (cfg.included(k.file) and !remapped.contains(k.file)) try wanted.put(k.file, {});
    }

    // Which files anything at all was measured for. The rest reached the report
    // only through the --all walk, so nothing but their own source describes them.
    var evidenced: std.StringHashMap(void) = .init(a);
    var ei = merged.keyIterator();
    while (ei.next()) |k| try evidenced.put(k.file, {});
    var eri = resolved.keyIterator();
    while (eri.next()) |k| try evidenced.put(k.file, {});
    var efi = all_fns.keyIterator();
    while (efi.next()) |k| try evidenced.put(k.file, {});
    var ebi = all_brs.keyIterator();
    while (ebi.next()) |k| try evidenced.put(k.file, {});

    var reports: std.ArrayList(FileReport) = .empty;
    var unanalysed: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var wi2 = wanted.keyIterator();
    while (wi2.next()) |k| try files.append(a, k.*);
    var walk_job: WalkJob = .{
        .files = files.items,
        .io = init.io,
        .cfg = &cfg,
        .merged = &merged,
        .resolved = &resolved,
        .src_spans = &src_spans,
        .evidenced = &evidenced,
    };
    const walkers = try a.alloc(WalkWorker, cfg.threads);
    for (walkers) |*w| w.* = .{ .arena = .init(gpa), .scratch = .init(gpa) };
    for (handles, 0..) |*h, i| h.* = try std.Thread.spawn(.{}, runWalk, .{ &walk_job, &walkers[i] });
    for (handles) |h| h.join();
    for (walkers) |*w| {
        try reports.appendSlice(a, w.reports.items);
        try unanalysed.appendSlice(a, w.unanalysed.items);
    }

    std.mem.sort([]const u8, unanalysed.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    // Attach functions and branches, which come from the bundles rather than
    // from the source walk, so they exist only where a script mapped to them.
    var by_path: std.StringHashMap(usize) = .init(a);
    for (reports.items, 0..) |r, i| try by_path.put(r.file, i);
    var fi3 = all_fns.iterator();
    while (fi3.next()) |e| {
        const idx = by_path.get(e.key_ptr.file) orelse continue;
        try reports.items[idx].fns.append(a, .{
            .line = e.key_ptr.line,
            .col = e.key_ptr.col,
            .count = e.value_ptr.count,
            .name = e.value_ptr.name,
        });
    }
    var bi2 = all_brs.iterator();
    while (bi2.next()) |e| {
        // Nothing proved it either way, so it is omitted rather than guessed at.
        if (e.value_ptr.count == scan.unknown_branch) continue;
        const idx = by_path.get(e.key_ptr.file) orelse continue;
        try reports.items[idx].brs.append(a, .{
            .line = e.key_ptr.line,
            .col = e.key_ptr.col,
            .btype = e.key_ptr.btype,
            .slot = e.key_ptr.slot,
            .count = e.value_ptr.count,
            .span_end = e.value_ptr.span_end,
        });
    }

    // A coarse map places an item at column 0, so a source reached both ways has
    // it twice. Folded and summed, which is how the line counts already read.
    for (reports.items) |*r| {
        try foldCoarse(a, FnEntry, &r.fns, struct {
            fn same(x: FnEntry, y: FnEntry) bool {
                return x.line == y.line and std.mem.eql(u8, x.name, y.name);
            }
        }.same);
        try foldCoarse(a, BrEntry, &r.brs, struct {
            fn same(x: BrEntry, y: BrEntry) bool {
                return x.line == y.line and x.btype == y.btype and x.slot == y.slot;
            }
        }.same);
    }

    // `ignore file`, and an empty source, leave nothing coverable behind.
    {
        var kept: std.ArrayList(FileReport) = .empty;
        for (reports.items) |r| {
            if (r.rows.items.len == 0 and r.fns.items.len == 0 and r.brs.items.len == 0) continue;
            try kept.append(a, r);
        }
        reports = kept;
    }

    std.mem.sort(FileReport, reports.items, {}, struct {
        fn lt(_: void, x: FileReport, y: FileReport) bool {
            return std.mem.order(u8, x.file, y.file) == .lt;
        }
    }.lt);
    for (reports.items) |*r| {
        std.mem.sort(Row, r.rows.items, {}, struct {
            fn lt(_: void, x: Row, y: Row) bool {
                return x.line < y.line;
            }
        }.lt);
        std.mem.sort(FnEntry, r.fns.items, {}, struct {
            fn lt(_: void, x: FnEntry, y: FnEntry) bool {
                if (x.line != y.line) return x.line < y.line;
                return x.col < y.col;
            }
        }.lt);
        std.mem.sort(BrEntry, r.brs.items, {}, struct {
            fn lt(_: void, x: BrEntry, y: BrEntry) bool {
                if (x.line != y.line) return x.line < y.line;
                if (x.col != y.col) return x.col < y.col;
                // The conditional and the logical in `a && b ? 1 : 2` both start
                // at `a`; istanbul numbers them pre-order, so wider goes first.
                if (x.span_end != y.span_end) return x.span_end > y.span_end;
                if (x.btype != y.btype) return x.btype < y.btype;
                return x.slot < y.slot;
            }
        }.lt);
        // Branch group ids number the distinct (position, type) groups in the
        // order lcov will print them.
        var group: usize = 0;
        for (r.brs.items, 0..) |*b, i| {
            if (i > 0) {
                const p = r.brs.items[i - 1];
                if (p.line != b.line or p.col != b.col or p.btype != b.btype) group += 1;
            }
            b.group = group;
        }
    }

    if (cfg.lcov) try writeLcov(init.io, a, cfg, reports.items);
    if (cfg.json) try writeJson(init.io, a, cfg, reports.items);
    if (cfg.html) try writeHtml(init.io, a, cfg, reports.items, unanalysed.items);

    if (cfg.text) printTable(init.io, cfg, reports.items, unanalysed.items, false);
    if (cfg.text_summary) printTable(init.io, cfg, reports.items, unanalysed.items, true);
    skipped.warn();
    if (bundles == 0) {
        std.debug.print("zcov: no scripts under {s} were covered\n", .{cfg.root});
    } else if (cfg.text or cfg.text_summary) {
        std.debug.print("  {d} scripts, {d:.1}MB remapped on {d} threads\n\n", .{
            bundles, @as(f64, @floatFromInt(bytes)) / 1e6, cfg.threads,
        });
    }

    if (reports.items.len == 0) {
        std.debug.print("zcov: no files matched - check --include/--exclude and --cwd\n", .{});
        // Reporting nothing is not the same as covering everything: with zero
        // totals every percentage is vacuously 100 and a threshold would pass.
        return !cfg.check;
    }
    if (!cfg.check) return true;
    var total: Totals = .{};
    for (reports.items) |r| total.add(r);
    var ok = true;
    ok = checkOne("lines", total.lines_hit, total.lines, cfg.min_lines) and ok;
    ok = checkOne("statements", total.statements_hit, total.statements, cfg.min_statements) and ok;
    ok = checkOne("functions", total.fns_hit, total.fns, cfg.min_functions) and ok;
    ok = checkOne("branches", total.brs_hit, total.brs, cfg.min_branches) and ok;
    return ok;
}

fn checkOne(name: []const u8, hit: usize, total: usize, min: f64) bool {
    if (min <= 0) return true;
    const got = pct(hit, total);
    if (got + 1e-9 >= min) return true;
    std.debug.print("zcov: {s} coverage {d:.2}% is below the required {d:.2}%\n", .{ name, got, min });
    return false;
}

const Skipped = struct {
    unreadable: usize = 0,
    unparsed: usize = 0,
    bad_dumps: usize = 0,

    fn any(self: Skipped) bool {
        return self.unreadable + self.unparsed + self.bad_dumps > 0;
    }

    fn warn(self: Skipped) void {
        if (!self.any()) return;
        std.debug.print("zcov: skipped", .{});
        var first = true;
        if (self.bad_dumps > 0) {
            std.debug.print(" {d} unreadable dump(s)", .{self.bad_dumps});
            first = false;
        }
        if (self.unreadable > 0) {
            std.debug.print("{s} {d} missing script(s)", .{ if (first) "" else ",", self.unreadable });
            first = false;
        }
        if (self.unparsed > 0) {
            std.debug.print("{s} {d} script(s) that would not parse", .{ if (first) "" else ",", self.unparsed });
        }
        std.debug.print(" - coverage may read low\n", .{});
    }
};

const Totals = struct {
    statements: usize = 0,
    statements_hit: usize = 0,
    lines: usize = 0,
    lines_hit: usize = 0,
    fns: usize = 0,
    fns_hit: usize = 0,
    brs: usize = 0,
    brs_hit: usize = 0,

    fn add(self: *Totals, r: FileReport) void {
        self.statements += r.statements;
        self.statements_hit += r.statements_hit;
        for (r.rows.items) |row| {
            self.lines += 1;
            if (row.count > 0) self.lines_hit += 1;
        }
        for (r.fns.items) |f| {
            self.fns += 1;
            if (f.count > 0) self.fns_hit += 1;
        }
        for (r.brs.items) |b| {
            self.brs += 1;
            if (b.count > 0) self.brs_hit += 1;
        }
    }
};

fn pct(hit: usize, total: usize) f64 {
    if (total == 0) return 100;
    return 100 * @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(total));
}

/// Folds each column-0 entry into its unique precisely-placed twin, summing.
/// Left alone with no twin or with several: the column meant something then.
fn foldCoarse(
    a: std.mem.Allocator,
    comptime T: type,
    list: *std.ArrayList(T),
    comptime same: fn (T, T) bool,
) !void {
    var kept: std.ArrayList(T) = .empty;
    for (list.items) |item| {
        if (item.col != 0) continue;
        var found: ?usize = null;
        for (list.items, 0..) |other, j| {
            if (other.col == 0 or !same(item, other)) continue;
            if (found != null) {
                found = null;
                break;
            }
            found = j;
        }
        if (found) |j| list.items[j].count +|= item.count;
    }
    for (list.items) |item| {
        if (item.col != 0) {
            try kept.append(a, item);
            continue;
        }
        var matches: usize = 0;
        for (list.items) |other| {
            if (other.col != 0 and same(item, other)) matches += 1;
        }
        if (matches != 1) try kept.append(a, item);
    }
    list.* = kept;
}

/// The name each function is reported under, shared so lcov and JSON cannot
/// disagree: anonymous ones numbered, repeated ones suffixed.
fn fnLabels(a: std.mem.Allocator, fns: []const FnEntry) ![]const []const u8 {
    var names: std.StringHashMap(usize) = .init(a);
    const labels = try a.alloc([]const u8, fns.len);
    for (fns, 0..) |f, i| {
        if (f.name.len == 0) {
            labels[i] = try std.fmt.allocPrint(a, "(anonymous_{d})", .{i});
            continue;
        }
        const gop = try names.getOrPut(f.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
            labels[i] = f.name;
        } else {
            gop.value_ptr.* += 1;
            labels[i] = try std.fmt.allocPrint(a, "{s}_{d}", .{ f.name, gop.value_ptr.* });
        }
    }
    return labels;
}

fn writeLcov(io: std.Io, a: std.mem.Allocator, cfg: Config, reports: []const FileReport) !void {
    var out: std.ArrayList(u8) = .empty;
    var buf: [256]u8 = undefined;
    for (reports) |r| {
        try out.appendSlice(a, "TN:\nSF:");
        try out.appendSlice(a, relativeTo(cfg.root, r.file));
        try out.append(a, '\n');

        const labels = try fnLabels(a, r.fns.items);
        var fns_hit: usize = 0;
        for (r.fns.items, labels) |f, label| {
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "FN:{d},{s}\n", .{ f.line, label }));
            if (f.count > 0) fns_hit += 1;
        }
        try out.appendSlice(a, try std.fmt.bufPrint(&buf, "FNF:{d}\nFNH:{d}\n", .{ r.fns.items.len, fns_hit }));
        for (r.fns.items, labels) |f, label| {
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "FNDA:{d},{s}\n", .{ f.count, label }));
        }

        var lines_hit: usize = 0;
        for (r.rows.items) |row| {
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "DA:{d},{d}\n", .{ row.line, row.count }));
            if (row.count > 0) lines_hit += 1;
        }
        try out.appendSlice(a, try std.fmt.bufPrint(&buf, "LF:{d}\nLH:{d}\n", .{ r.rows.items.len, lines_hit }));

        var brs_hit: usize = 0;
        var slot_in_group: u16 = 0;
        for (r.brs.items, 0..) |b, i| {
            if (i > 0 and r.brs.items[i - 1].group != b.group) slot_in_group = 0;
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "BRDA:{d},{d},{d},{d}\n", .{
                b.line, b.group, slot_in_group, b.count,
            }));
            slot_in_group += 1;
            if (b.count > 0) brs_hit += 1;
        }
        try out.appendSlice(a, try std.fmt.bufPrint(&buf, "BRF:{d}\nBRH:{d}\nend_of_record\n", .{
            r.brs.items.len, brs_hit,
        }));
    }

    try writeReport(io, a, cfg, "lcov.info", out.items);
}

/// Writes one file under the report directory, creating it if need be.
fn writeReport(io: std.Io, a: std.mem.Allocator, cfg: Config, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ cfg.report_dir, name });
    const abs = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(a, &.{ cfg.root, path });
    if (std.fs.path.dirname(abs)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = data });
}

fn jsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31 => {
            var buf: [8]u8 = undefined;
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
        },
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

/// `coverage-final.json` in istanbul's coverage-map shape, so whatever already
/// reads one keeps working. Statements span a whole line; counts are exact.
fn writeJson(io: std.Io, a: std.mem.Allocator, cfg: Config, reports: []const FileReport) !void {
    var out: std.ArrayList(u8) = .empty;
    var buf: [256]u8 = undefined;
    try out.append(a, '{');
    for (reports, 0..) |r, ri| {
        if (ri > 0) try out.append(a, ',');
        try jsonString(a, &out, relativeTo(cfg.root, r.file));
        try out.appendSlice(a, ":{\"path\":");
        try jsonString(a, &out, relativeTo(cfg.root, r.file));

        try out.appendSlice(a, ",\"statementMap\":{");
        for (r.rows.items, 0..) |row, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, try std.fmt.bufPrint(
                &buf,
                "\"{d}\":{{\"start\":{{\"line\":{d},\"column\":0}},\"end\":{{\"line\":{d},\"column\":null}}}}",
                .{ i, row.line, row.line },
            ));
        }
        try out.appendSlice(a, "},\"fnMap\":{");
        const labels = try fnLabels(a, r.fns.items);
        for (r.fns.items, labels, 0..) |f, label, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\"{d}\":{{\"name\":", .{i}));
            try jsonString(a, &out, label);
            try out.appendSlice(a, try std.fmt.bufPrint(
                &buf,
                ",\"decl\":{{\"start\":{{\"line\":{d},\"column\":{d}}},\"end\":{{\"line\":{d},\"column\":{d}}}}}" ++
                    ",\"loc\":{{\"start\":{{\"line\":{d},\"column\":{d}}},\"end\":{{\"line\":{d},\"column\":null}}}}" ++
                    ",\"line\":{d}}}",
                .{ f.line, f.col, f.line, f.col, f.line, f.col, f.line, f.line },
            ));
        }
        try out.appendSlice(a, "},\"branchMap\":{");
        {
            // One entry per group, with a location per slot, which is the shape
            // istanbul's `b` array indexes into.
            var i: usize = 0;
            var written: usize = 0;
            while (i < r.brs.items.len) {
                const start = i;
                while (i < r.brs.items.len and r.brs.items[i].group == r.brs.items[start].group) i += 1;
                const b = r.brs.items[start];
                if (written > 0) try out.append(a, ',');
                try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\"{d}\":{{\"loc\":{{\"start\":{{\"line\":{d},\"column\":{d}}},\"end\":{{\"line\":{d},\"column\":null}}}},\"type\":", .{
                    written, b.line, b.col, b.line,
                }));
                try jsonString(a, &out, @as(scan.BranchType, @enumFromInt(b.btype)).label());
                try out.appendSlice(a, ",\"locations\":[");
                for (r.brs.items[start..i], 0..) |slot, k| {
                    if (k > 0) try out.append(a, ',');
                    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "{{\"start\":{{\"line\":{d},\"column\":{d}}},\"end\":{{\"line\":{d},\"column\":null}}}}", .{
                        slot.line, slot.col, slot.line,
                    }));
                }
                try out.appendSlice(a, try std.fmt.bufPrint(&buf, "],\"line\":{d}}}", .{b.line}));
                written += 1;
            }
        }

        try out.appendSlice(a, "},\"s\":{");
        for (r.rows.items, 0..) |row, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\"{d}\":{d}", .{ i, row.count }));
        }
        try out.appendSlice(a, "},\"f\":{");
        for (r.fns.items, 0..) |f, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\"{d}\":{d}", .{ i, f.count }));
        }
        try out.appendSlice(a, "},\"b\":{");
        {
            var i: usize = 0;
            var written: usize = 0;
            while (i < r.brs.items.len) {
                const start = i;
                while (i < r.brs.items.len and r.brs.items[i].group == r.brs.items[start].group) i += 1;
                if (written > 0) try out.append(a, ',');
                try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\"{d}\":[", .{written}));
                for (r.brs.items[start..i], 0..) |slot, k| {
                    if (k > 0) try out.append(a, ',');
                    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d}", .{slot.count}));
                }
                try out.append(a, ']');
                written += 1;
            }
        }
        try out.appendSlice(a, "}}");
    }
    try out.append(a, '}');
    try writeReport(io, a, cfg, "coverage-final.json", out.items);
}

fn htmlEscape(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

const html_style =
    \\<style>
    \\body{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;color:#24292f;background:#fff}
    \\header{padding:16px 24px;border-bottom:1px solid #d0d7de}
    \\h1{font-size:16px;margin:0 0 4px}
    \\.sub{color:#57606a;font-size:12px}
    \\main{padding:16px 24px}
    \\table{border-collapse:collapse;width:100%;font-size:12px}
    \\th,td{text-align:right;padding:4px 10px;border-bottom:1px solid #eaeef2;white-space:nowrap}
    \\th:first-child,td:first-child{text-align:left;width:100%}
    \\th{color:#57606a;font-weight:600;border-bottom:1px solid #d0d7de}
    \\a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}
    \\.hi{color:#1a7f37}.mid{color:#9a6700}.lo{color:#cf222e}
    \\pre{margin:0;overflow-x:auto}
    \\.src{border:1px solid #d0d7de;border-radius:6px;overflow:hidden}
    \\.ln{display:flex;align-items:baseline}
    \\.ln>.n{flex:0 0 56px;text-align:right;padding-right:10px;color:#8c959f;user-select:none}
    \\.ln>.c{flex:0 0 64px;text-align:right;padding-right:14px;color:#57606a;user-select:none}
    \\.ln>.t{white-space:pre;flex:1}
    \\.na{color:#8c959f;font-style:italic;text-align:center}
    \\.miss{background:#ffebe9}.miss>.c{color:#cf222e;font-weight:600}
    \\.hit{background:#f6fefa}
    \\</style>
;

fn pctClass(p: f64) []const u8 {
    if (p >= 90) return "hi";
    if (p >= 70) return "mid";
    return "lo";
}

fn htmlCell(a: std.mem.Allocator, out: *std.ArrayList(u8), hit: usize, total: usize) !void {
    var buf: [128]u8 = undefined;
    const p = pct(hit, total);
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "<td class=\"{s}\">{d:.2}%</td><td>{d}/{d}</td>", .{
        pctClass(p), p, hit, total,
    }));
}

/// A self-contained HTML report: an index plus a page per file with per-line
/// counts. No assets and no JavaScript, so it opens straight from disk.
fn writeHtml(
    io: std.Io,
    a: std.mem.Allocator,
    cfg: Config,
    reports: []const FileReport,
    unanalysed: []const []const u8,
) !void {
    var index: std.ArrayList(u8) = .empty;
    var buf: [512]u8 = undefined;
    var total: Totals = .{};
    for (reports) |r| total.add(r);

    try index.appendSlice(a, "<!doctype html><html><head><meta charset=\"utf-8\"><title>coverage</title>");
    try index.appendSlice(a, html_style);
    try index.appendSlice(a, "</head><body><header><h1>Coverage</h1><div class=\"sub\">");
    try index.appendSlice(a, try std.fmt.bufPrint(&buf, "{d} files &middot; {d:.2}% of lines", .{
        reports.len, pct(total.lines_hit, total.lines),
    }));
    try index.appendSlice(a, "</div></header><main><table><thead><tr><th>File</th>" ++
        "<th colspan=2>Statements</th><th colspan=2>Branches</th><th colspan=2>Functions</th><th colspan=2>Lines</th>" ++
        "</tr></thead><tbody>");
    try index.appendSlice(a, "<tr><td><strong>All files</strong></td>");
    try htmlCell(a, &index, total.statements_hit, total.statements);
    try htmlCell(a, &index, total.brs_hit, total.brs);
    try htmlCell(a, &index, total.fns_hit, total.fns);
    try htmlCell(a, &index, total.lines_hit, total.lines);
    try index.appendSlice(a, "</tr>");

    for (reports) |r| {
        const rel = relativeTo(cfg.root, r.file);
        var t: Totals = .{};
        t.add(r);
        const page = try std.mem.concat(a, u8, &.{ rel, ".html" });
        try index.appendSlice(a, "<tr><td><a href=\"");
        try htmlEscape(a, &index, page);
        try index.appendSlice(a, "\">");
        try htmlEscape(a, &index, rel);
        try index.appendSlice(a, "</a></td>");
        try htmlCell(a, &index, t.statements_hit, t.statements);
        try htmlCell(a, &index, t.brs_hit, t.brs);
        try htmlCell(a, &index, t.fns_hit, t.fns);
        try htmlCell(a, &index, t.lines_hit, t.lines);
        try index.appendSlice(a, "</tr>");

        // A file that cannot be read still gets its row above; only its page is
        // skipped, so a missing source never loses a number.
        const src = std.Io.Dir.cwd().readFileAlloc(io, r.file, a, .limited(1 << 26)) catch continue;
        var counts = std.AutoHashMap(i32, i32).init(a);
        for (r.rows.items) |row| try counts.put(row.line, row.count);

        var page_out: std.ArrayList(u8) = .empty;
        try page_out.appendSlice(a, "<!doctype html><html><head><meta charset=\"utf-8\"><title>");
        try htmlEscape(a, &page_out, rel);
        try page_out.appendSlice(a, "</title>");
        try page_out.appendSlice(a, html_style);
        try page_out.appendSlice(a, "</head><body><header><h1>");
        try htmlEscape(a, &page_out, rel);
        try page_out.appendSlice(a, "</h1><div class=\"sub\">");
        try page_out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d:.2}% lines &middot; {d:.2}% branches &middot; {d:.2}% functions &middot; ", .{
            pct(t.lines_hit, t.lines), pct(t.brs_hit, t.brs), pct(t.fns_hit, t.fns),
        }));
        // Relative link back, one `..` per directory the file sits under.
        var up: std.ArrayList(u8) = .empty;
        for (rel) |c| {
            if (c == '/') try up.appendSlice(a, "../");
        }
        try page_out.appendSlice(a, "<a href=\"");
        try page_out.appendSlice(a, up.items);
        try page_out.appendSlice(a, "index.html\">all files</a></div></header><main><div class=\"src\"><pre>");

        var line: i32 = 1;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |text| : (line += 1) {
            const clean = std.mem.trimEnd(u8, text, "\r");
            const c = counts.get(line);
            const class = if (c) |n| (if (n > 0) "ln hit" else "ln miss") else "ln";
            try page_out.appendSlice(a, "<div class=\"");
            try page_out.appendSlice(a, class);
            try page_out.appendSlice(a, "\"><span class=\"n\">");
            try page_out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d}", .{line}));
            try page_out.appendSlice(a, "</span><span class=\"c\">");
            if (c) |n| {
                try page_out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d}&times;", .{n}));
            }
            try page_out.appendSlice(a, "</span><span class=\"t\">");
            try htmlEscape(a, &page_out, clean);
            try page_out.appendSlice(a, "</span></div>");
        }
        try page_out.appendSlice(a, "</pre></div></main></body></html>\n");
        try writeReport(io, a, cfg, page, page_out.items);
    }

    for (unanalysed) |p| {
        try index.appendSlice(a, "<tr><td>");
        try htmlEscape(a, &index, relativeTo(cfg.root, p));
        try index.appendSlice(a, "</td><td class=\"na\" colspan=8>not analysed</td></tr>");
    }
    try index.appendSlice(a, "</tbody></table></main></body></html>\n");
    try writeReport(io, a, cfg, "index.html", index.items);
}

/// The report goes to stdout, the way c8 and nyc write theirs, so piping or
/// redirecting it captures something. Warnings and errors stay on stderr.
fn report_print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

fn printTable(io: std.Io, cfg: Config, reports: []const FileReport, unanalysed: []const []const u8, summary_only: bool) void {
    // Every percentage over an empty set is vacuously 100, which reads as
    // success. Say there was nothing instead.
    if (reports.len == 0) {
        report_print(io, "\n  no files to report\n\n", .{});
        printUnanalysed(io, cfg, unanalysed);
        return;
    }
    var total: Totals = .{};
    for (reports) |r| total.add(r);

    if (summary_only) {
        report_print(io, "\n  statements : {d:.2}% ({d}/{d})\n", .{ pct(total.statements_hit, total.statements), total.statements_hit, total.statements });
        report_print(io, "  branches   : {d:.2}% ({d}/{d})\n", .{ pct(total.brs_hit, total.brs), total.brs_hit, total.brs });
        report_print(io, "  functions  : {d:.2}% ({d}/{d})\n", .{ pct(total.fns_hit, total.fns), total.fns_hit, total.fns });
        report_print(io, "  lines      : {d:.2}% ({d}/{d})\n\n", .{ pct(total.lines_hit, total.lines), total.lines_hit, total.lines });
        printUnanalysed(io, cfg, unanalysed);
        return;
    }

    var width: usize = "All files".len;
    for (reports) |r| width = @max(width, relativeTo(cfg.root, r.file).len);
    width = @min(width, 60);

    printRule(io, width);
    printPadded(io, "File", width);
    report_print(io, " | % Stmts | % Branch | % Funcs | % Lines\n", .{});
    printRule(io, width);
    printRow(io, cfg, "All files", width, total);
    for (reports) |r| {
        var t: Totals = .{};
        t.add(r);
        printRow(io, cfg, relativeTo(cfg.root, r.file), width, t);
    }
    printRule(io, width);
    printUnanalysed(io, cfg, unanalysed);
}

/// Named rather than counted. No parse means no denominator, and a made-up one
/// would move every percentage above without measuring anything.
fn printUnanalysed(io: std.Io, cfg: Config, unanalysed: []const []const u8) void {
    if (unanalysed.len == 0) return;
    report_print(io, "not analysed ({d}): ", .{unanalysed.len});
    for (unanalysed, 0..) |p, i| {
        if (i == 6) {
            report_print(io, ", and {d} more", .{unanalysed.len - i});
            break;
        }
        report_print(io, "{s}{s}", .{ if (i > 0) ", " else "", relativeTo(cfg.root, p) });
    }
    report_print(io, "\n", .{});
}

fn printRule(io: std.Io, width: usize) void {
    var i: usize = 0;
    while (i < width) : (i += 1) report_print(io, "-", .{});
    report_print(io, "-|---------|----------|---------|--------\n", .{});
}

fn printRow(io: std.Io, cfg: Config, name: []const u8, width: usize, t: Totals) void {
    _ = cfg;
    printPadded(io, if (name.len > width) name[name.len - width ..] else name, width);
    report_print(io, " | {d: >6.2}  | {d: >7.2}  | {d: >6.2}  | {d: >6.2}\n", .{
        pct(t.statements_hit, t.statements),
        pct(t.brs_hit, t.brs),
        pct(t.fns_hit, t.fns),
        pct(t.lines_hit, t.lines),
    });
}

fn printPadded(io: std.Io, text: []const u8, width: usize) void {
    report_print(io, "{s}", .{text});
    var i = text.len;
    while (i < width) : (i += 1) report_print(io, " ", .{});
}
