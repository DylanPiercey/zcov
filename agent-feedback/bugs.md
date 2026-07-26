# Suspected Bugs

Out-of-scope defects noticed while working on something else. Format and rules: [README.md](README.md).

## Deeply nested expressions overflow the stack and kill the whole run

`src/scan.zig` › `flattenLogical` | 2026-07-26 | impact:med | effort:med

Two unbounded recursions crash the published binary with SIGSEGV rather than costing one script.
zcov's own is `flattenLogical`, which recurses once per operand: `var x = 1` followed by 150,000
`||1` segfaults (Debug shows the recursive frames at `scan.zig:972`), while 120,000 is fine. The
other is inside yuku's parser and fires much earlier — `(((...1...)))` nested 8,000 deep, 20,000
nested arrays, objects, `if`s or arrows all segfault, with the Debug trace in
`parser/syntax/expressions.zig`. Both matter because a stack overflow is not catchable: `scanOne`'s
`catch` around `scan.prepare` handles a parse *error* gracefully, but this takes the process down and
loses every other script's coverage. Suggested direction: make `flattenLogical` iterative with an
explicit stack, and either raise the worker stack via `std.Thread.SpawnConfig.stack_size` or ask yuku
for a depth limit that returns an error. Re-check by scoring a dump over a file generated with
`"var x = 1" + "||1".repeat(150000)`.

## The `--all` walk never sees symlinked sources

`src/cli.zig` › `report` | 2026-07-26 | impact:low | effort:low

The denominator walk keeps only `entry.kind == .file`, so a symlinked source file is skipped and a
symlinked directory is never descended into — silently, with no "not analysed" entry. Monorepo
setups that link packages into a tree lose those files from the denominator while the README
promises `--all` "parses every JavaScript or TypeScript source matching the include patterns".
Loaded symlinked files still report (V8 names the real path), which makes the gap inconsistent as
well as silent. Suggested direction: stat symlink entries and treat file targets as files, or at
minimum list them as not analysed. Re-check with `ln -s <file>.js src/linked.js` under the root:
it appears nowhere in the table.

## An external source map resolves its sources against the script, not the map

`src/cli.zig` › `readSourceMap` | 2026-07-26 | impact:med | effort:med

Source-map semantics put `sources` and `sourceRoot` relative to the map's own
URL, but `scanOne` resolves them against the directory of the generated script.
Those agree for a sibling `.map`, which is why nothing has caught it, and differ
whenever a build writes maps into a subdirectory (`//# sourceMappingURL=maps/app.js.map`
with `sourceRoot: "../src"`). The resolved path then misses the real file and the
evidence is discarded silently: an executed line reports `DA:2,0`. Suggested
direction: have `readSourceMap` return the directory it read the map from and
resolve against that, falling back to the script's directory for inline maps.
Re-check by moving a fixture's `.map` into a subdirectory and confirming its
sources still report.

## A source map's `sourcesContent` is never used

`src/scan.zig` › `prepare` | 2026-07-26 | impact:med | effort:high

A map may carry its originals inline in `sourcesContent`, and for a generated-only
artifact that is the only copy there is. zcov always looks for the file on disk,
so such a source is listed as "not analysed" and contributes nothing. This is a
gap rather than a wrong number, and closing it means threading the embedded text
through the denominator walk, which currently reads from disk by path. Decide
precedence against an on-disk copy before starting. Re-check with a bundle whose
map has `sourcesContent` and whose sources do not exist.

## Segment-derived counts take a maximum across processes where the rest sum

`src/cli.zig` › `scanOne` | 2026-07-26 | impact:low | effort:low

A line recovered only from mapping-segment evidence keeps the largest count any
one process saw, while lines, functions and branches saturating-add across
processes. Duplicating a dump therefore leaves such a line at `DA:1,1` where a
directly-hit line would read 2. Only the magnitude is affected, never the
covered/uncovered verdict, which is why no suite caught it. Suggested direction:
keep the per-set maximum, then add across sets and workers the way `record` does.
Re-check by reporting one dump, then the same dump twice.
