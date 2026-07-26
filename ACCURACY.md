# Known inaccuracies

Every known case, measured against instrumented execution counts (`nyc`), which
observes rather than infers. Reproduce with `pnpm run test:model`,
`pnpm run test:fuzz` and `node tools/bench.mjs`.

Anything below that is a _deviation_ rather than an inaccuracy, meaning a place
zcov deliberately answers differently from istanbul, is declared in
`test/model.mjs` with the reason and the reference source that justifies it. The
suite fails on an undeclared difference, and also on a declared one that stops
happening, so this list cannot drift from what the code does.

zcov never reports a line, function or branch as covered that did not run.
That is checked absolutely rather than against another tool: the fuzzer fails if
it happens once, on any of the shapes its grammar can build, including labelled
`break`/`continue`, `for-of`, optional chaining, destructuring, nested functions
and `throw`/`catch`. Every inaccuracy below is the opposite error, a line that
ran reported as uncovered, which wastes a reader's time rather than hiding risk.

Rate, bundled or not: 9 of 23,289 lines (0.04%), 6 of 11,359 branches, 0 of 1,224
functions. The suite reports 13, which is the same thing counting a branch
disagreement once per line rather than once per branch. Two fixed corpora are
exact.

## Dead loop bodies

Every one of the nine is a statement after a loop whose body never ran.

```js
for (let i = 0; i < 0; i++) {  //  body never executes
  ...
}
return total;                  //  runs, reported as uncovered
```

The counter for a loop body is a bare position, so when the body never ran V8
has no end to give its zero range and invents one: the start of the next range it
emits, or failing that the end of the _enclosing_ range. Either overshoots the
body's closing brace and swallows what follows. When something later also ran,
control flow recovers it; when the swallowed statement is last in its block, the
`return` a function ends with, 7 times in 9, nothing is left to prove it ran.

Clipping the range back to the body has now been tried four times and is wrong
every time. The reason is that V8 omits a nested counter whose count matches its
parent's, so where a dead loop sits inside an already-dead region the body gets
no range of its own, and the outer range's invented end is the only record that
the body is dead. Clipping deletes that record: the last attempt guarded on the
loop's header having been reached, which is sound in itself, and still traded
these 9 for 47 lines and 7 branches reported as covered that never ran.

Not to be confused with the opposite move, which is right. Where the range is a
_continuation_ counter, one recorded at a statement boundary rather than for a
block, its invented end can only be too short, and widening it to the end of the
enclosing statement list only lowers counts, so it cannot cause this.

## Runtime-only dead code

```js
if (!a) { return total; }   //  taken on every call, but only conditionally
somethingAfter();           //  never runs; may be reported either way
```

Statically control falls through, so no analysis can prove this dead. A
control-flow graph would conclude it is reachable and change nothing, and V8
draws no boundary. `nyc` gets it right by observing, which is why matching
instrumentation exactly is not reachable by inference, and why static exit
accounting was not worth building.

## Bundler-deleted code

A source may contain code the bundler removes, such as a deliberate
temporal-dead-zone probe or a debug-only branch. zcov reports what actually
ran; an instrumented oracle over the _source_ reports what the source says. Two
disagreements on one real workload are this, and zcov is arguably right.

## Not line coverage

Default parameters are left out of the report unless V8 proves they were
skipped. V8 emits ranges only for code that did not run, so a default being used
is undetectable; a zero range covering the expression does prove it was skipped,
and that case is reported as not-taken. Where there is no such range the branch
is omitted rather than guessed at in either direction, so it neither helps nor
hurts the percentage. c8 and Vitest's engine report taken, which is a fabrication
and their single largest source of branch false positives: 2,400 on one corpus
where zcov has 0. The cost is a smaller branch denominator than theirs.

Functions are exact. 1,224 of 1,224 agree with instrumentation across the fuzz
corpus, in both directions, and 38 hand-written constructs, which is every method
shape there is, agree on line, count, `FNF` and `FNH`.

Private methods are counted, and istanbul does not count them. Its visitor
registers `ClassMethod` and `ObjectMethod`
(`istanbul-lib-instrument/src/visitor.js:638,642`) and babel parses `#m() {}` as
`ClassPrivateMethod`, which is not in the list. On
`class A { pub() {} #priv() {} usePriv() {} }`: zcov `FNF:3`, c8 `FNF:3`,
ast-v8-to-istanbul `FNF:3`, nyc `FNF:2`. zcov follows the majority, so its
function total is higher than nyc's for a class with private methods.

Methods are named rather than `(anonymous_N)`. istanbul reads
`node.id?.name ?? node.name` (`visitor.js:380`), and a babel method node has
neither, because the name is in `.key`. zcov emits the name, byte-identical to
what c8 emits for the same input. No count changes.

Files no JavaScript parser can read, such as `.vue` and `.svelte`, take their
line denominator from what the source map anchors rather than from a parse, so
they report fewer lines than c8 does for the same input. zcov reports the lines
that are code; c8 also counts template lines. One that never loaded has no
anchors either, so there is nothing to take a denominator from: it is named under
the table as "not analysed" and left out of the totals rather than given a
made-up one.

`nyc`'s `ignoreClassMethods` has no equivalent, so a method that config would
drop is reported. It is the only thing in istanbul's own corpus zcov still
counts lines for that istanbul does not, two lines across 191 cases, and
`pnpm run test:corpus` prints the count.
