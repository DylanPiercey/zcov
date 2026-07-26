# Performance

Runtime speed and memory opportunities. Format and rules: [README.md](README.md).

## Ask yuku for a separate node-tag array so consumers can filter without loading 44 bytes

`src/scan.zig` › `statementOffsets` | 2026-07-26 | impact:med | effort:med

yuku stores nodes as `MultiArrayList(Node)` where `Node = {data: NodeData, span: Span}`, and a
`comptime` assert in its `ast.zig` pins `@sizeOf(NodeData) == 44`. The tag lives inside that union,
so every one of zcov's whole-array walks (`statementOffsets`, `collectItems`, `continuationReach`)
touches 44 bytes per node to read what is really a one-byte discriminant. Splitting the tag into its
own `MultiArrayList` field would let a filtering pass stream ~1 byte per node instead, which is the
difference between roughly 5MB and 220MB of memory traffic per pass on a multi-million-node bundle.
This is a change in the yuku package rather than here, which is why it is recorded and not done.
Re-check by confirming `tree.nodes.items(.data)` is still the only way to reach a node's kind.

## Fusing the remaining per-script node walks did not pay off at current scale

`src/scan.zig` › `prepare` | 2026-07-26 | impact:low | effort:med

Two walks were already fused into their neighbours (the bodyless-arrow pass in `statementOffsets` and
the one in `statementSpans`), and the result was inside measurement noise on a 601-module workload.
Three full walks remain per script (`statementOffsets`, `collectItems`, `continuationReach`). Fusing
them is still directionally right but should not be attempted for speed without first showing the
walks matter: on every fixture tried, parsing dominated them by a wide margin. Re-check by timing
`zcov report` on a generated tree before and after; anything under about 2% is noise on this
hardware.
