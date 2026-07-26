# Cleanup

Duplication, dead code, inconsistencies, refactor opportunities. Format and rules: [README.md](README.md).

## Do not set yuku's `preserve_parens = false` to retire the paren-unwrapping helpers

`src/scan.zig` › `unwrapParens` | 2026-07-26 | impact:low | effort:low

`unwrapParens` and `unwrapParensIdx` exist only to look through `parenthesized_expression` nodes, and
yuku's `preserve_parens: false` would stop the parser emitting those at all, making both helpers dead
and shrinking the node array. It is not safe. zcov positions probes and branch groups by node span,
and stripping the parens moves those spans: measured with the option flipped, two constructs in
`test/model.mjs` break. `(function () { return 1; })()` double-counts its `FNDA`, 1 becoming 2, because
the function node then starts where the statement does, and `(a > 0 ? 1 : 0) && b` reports branch slot
`1:2` where instrumentation says `1:1`. Re-check by setting the option in `parseOptions` and running
`npm run test:model`.

## `report` grows walker-owned lists with a different allocator than allocated them

`src/cli.zig` › `report` | 2026-07-26 | impact:low | effort:low

The attach-functions/branches loops call `reports.items[idx].fns.append(a, ...)` on `ArrayList`s
whose buffers were allocated from a `WalkWorker`'s arena inside `walkOne`, passing the main arena
`a` instead. This only works because both allocators are arenas, whose `resize`/`free` on a foreign
pointer are no-ops that fall back to alloc-and-copy; swap either for a real allocator and the first
growth is a cross-heap free — silent corruption, not a compile error. Suggested direction: have the
walk phase return plain slices and build the final lists with one allocator, or record which
allocator owns each list. Re-check by confirming `walkOne` fills `fr.fns`/`fr.brs` from
`w.arena` while `report` later appends to the same lists with `a`.
