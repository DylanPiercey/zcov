# zcov

[![CI](https://github.com/DylanPiercey/zcov/actions/workflows/ci.yml/badge.svg)](https://github.com/DylanPiercey/zcov/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/%40zcov%2Fcli.svg)](https://www.npmjs.com/package/@zcov/cli)

A drop-in replacement for `c8` and `nyc`. Runs a command with `NODE_V8_COVERAGE`
set, remaps every script it loaded through its source map, and writes lcov and a
text table.

The whole pipeline is one native binary, so no AST and no coverage JSON ever
crosses into JavaScript.

## Install

```sh
pnpm add -D @zcov/cli      # or npm install --save-dev @zcov/cli
```

The right prebuilt binary arrives as an optional dependency, so there is no
build step and no runtime dependency on Node beyond the launcher. Nine platforms
are published; `zcov --version` confirms the install.

```sh
zcov -- node --test
zcov -r lcov -n 'src/**' -- npm test
zcov report -d coverage-v8            # report a directory of dumps already on disk
```

## Why

V8 reports byte ranges over generated code. Turning that into "which source
lines ran, and how often" means parsing every script, decoding its source map,
and scoring those ranges against the AST, for every bundle on every run. In
JavaScript that is the bulk of the time, and most of it goes on syntax trees
that are discarded immediately.

zcov does that work natively and keeps nothing it does not need.

## Benchmarks

Reproduce with `node tools/bench.mjs`. The workload is 400 generated CommonJS
modules, ~92,000 lines, half executed. Median of five runs.

End to end, spawning the process, collecting coverage and writing lcov:

| tool | wall | CPU | peak RSS | overhead vs bare node |
|---|---|---|---|---|
| (bare `node`) | 0.10s | 0.10s | 61MB | baseline |
| **zcov** | **0.30s** | **0.37s** | **79MB** | **3.0x** |
| c8 | 0.61s | 0.84s | 148MB | 6.1x |
| nyc | 4.55s | 6.37s | 487MB | 45.1x |

Report only, the same dumps in and lcov out, so the test run is factored out and
only the coverage engine is measured:

| engine | wall | CPU | peak RSS |
|---|---|---|---|
| **zcov** | **0.12s** | **0.19s** | **53MB** |
| c8 | 0.48s | 0.61s | 153MB |
| ast-v8-to-istanbul (Vitest's V8 provider) | 0.83s | 1.31s | 192MB |

### Accuracy

Speed is worth nothing if the numbers are wrong, so the benchmark checks those
too. `nyc` instruments the source and counts executions directly, which makes it
an independent answer to check the V8-based engines against.

The same workload bundled by esbuild into a single script with a source map,
which is the case where an engine has to get remapping right:

| tool | lines judged | agree with instrumentation | called covered but never ran |
|---|---|---|---|
| **zcov** | 31,405 | **31,405** | **0** |
| ast-v8-to-istanbul | 31,405 | 31,405 | 0 |
| c8 | 31,405 | 25,261 | 6,144 |

Unbundled, the same: 31,405 of 31,405. On randomly generated programs, where the
three engines do separate, zcov disagrees with instrumented execution 13 times
in 23,657 lines against the reference engine's 83.

zcov and Vitest's engine agree with instrumented execution exactly on this
workload. c8 reports 6,144 lines as covered that never ran: it treats closing
braces and blank lines as coverable, and marks `switch` cases as covered inside a
`switch` that never executed.

Branches, on the same dumps and the same comparison, counted per branch and
compared slot against slot so that which `BRDA` block a count lands in has to
match too, and skipped where an engine disagrees on how many branches a line has:

| engine | agree | claims a branch was taken that was not | omitted |
|---|---|---|---|
| **zcov** | 33,600 | **0** | 2,400 |
| ast-v8-to-istanbul | 33,600 | 2,400 | 0 |
| c8 | 1,248 | 2,400 | 32,352 |

Theirs is one construct. V8 emits no range for a default parameter that was
_used_, since it only records code that did not run, and both engines read that
absence as taken. zcov reports not-taken where a zero range proves the default
was skipped and omits the branch otherwise (the 2,400 above) rather than claiming
either way.

On lines zcov ties with Vitest's engine here and is ahead on random programs,
13 against 83; on branches it is ahead on both, at about an eighth of the cost.

### Scaling

Measured on a larger workload: 346MB of dumps over 196MB of generated code,
4,800 bundles, 36 worker processes.

| threads | wall | speedup | efficiency | CPU | peak RSS |
|---|---|---|---|---|---|
| 1 | 12.89s | 1.00x | 100% | 12.8s | 109MB |
| 2 | 6.81s | 1.89x | 95% | 13.2s | 123MB |
| 4 | 3.55s | 3.63x | 91% | 13.1s | 135MB |
| 8 | 2.15s | 6.00x | 75% | 14.5s | 199MB |
| 16 | 2.36s | 5.46x | 34% | 19.8s | 355MB |

Near-linear to four threads. Past eight the work is memory-bound rather than
CPU-bound, and sixteen threads is _slower_ in wall time while burning 37% more
CPU, so the default caps at eight.

Dumps are streamed rather than parsed into a tree. A dump averages 10MB and
reaches 22MB, a tree of one costs roughly ten times that, and every thread holds
one. Only the script URL and three numbers per range are ever needed, so the
scanner skips the rest of the document.

Output is deterministic: byte-identical lcov at 1, 2, 4, 8 and 16 threads.

## Options

```
zcov [options] [--] <command> [args...]   run a command and report
zcov report [options]                     report an existing dump directory

-r, --reporter <name>   text, text-summary, lcov, json or html (repeatable, default: text)
-o, --report-dir <dir>  where to write lcov (default: coverage)
-d, --coverage-dir <d>  V8 dump directory (default: coverage-v8)
-n, --include <glob>    files to report on (repeatable, default: everything)
-x, --exclude <glob>    files to leave out (repeatable, adds to the defaults)
    --cwd <dir>         project root (default: the working directory)
    --threads <n>       default: one per core, capped at 8
    --no-all            only report files the run actually loaded
    --no-clean          keep any dumps already in the coverage directory
    --extension <.ext>  treat another extension as source (repeatable)

Thresholds (naming any of these implies --check-coverage):
    --check-coverage    enforce thresholds; alone it means --lines 90
    --lines <n>         minimum line coverage
    --functions <n>     minimum function coverage
    --branches <n>      minimum branch coverage
    --statements <n>    minimum statement coverage
```

Opinionated defaults, so most projects need no flags. Everything under the root
is reported except `node_modules`, `test`/`tests`/`__tests__`, `*.test.*`,
`*.spec.*`, `dist`, `build`, `coverage` and `*.d.ts`. Any script carrying a
source map, sibling `.map` or inline base64, is remapped to its sources and does
not appear in the report itself, so compiler output sitting beside its sources
does the right thing with no configuration.

### Configuration

A `zcov.json` in the project root sets the defaults, and any flag overrides it,
so the file holds what a project always wants and the command line stays the
last word. Keys are the long flag names, in whichever case reads better:
`reportDir` and `report-dir` are the same key.

```json
{
  "reporter": ["text-summary", "lcov"],
  "exclude": ["**/generated/**"],
  "checkCoverage": true,
  "lines": 90
}
```

`exclude` and `extension` add to what is already there, matching the flags that
carry them. A key zcov does not recognise is an error rather than a silent
no-op, because a misspelled `exclude` that quietly does nothing is the kind of
wrongness the rest of this tool exists to avoid.

### Reporters

`lcov` writes `lcov.info`. `json` writes `coverage-final.json` in the istanbul
coverage-map shape, so anything that reads `nyc`'s output keeps working: feeding
it back through istanbul's own lcov reporter reproduces zcov's lcov exactly,
which the suite checks. One caveat is structural. zcov's statements are per
_line_, because a line's count is the maximum over the statements on it and that
is what makes a remapped bundle tractable, so a `statementMap` entry spans a
whole line. Functions and branches carry their real columns, and every count is
exact.

`html` writes a self-contained `index.html` plus a page per file showing the
source with a count against every line. No assets and no JavaScript, so it opens
straight from disk. On a 400-file project all three reporters together cost the
same as lcov alone.

### Exit codes

zcov exits with the wrapped command's own status, so `zcov -- npm test`
fails with the test runner's code. A threshold failure exits 1, a usage error 2,
and a command that could not be run 127. A failing command always wins, since its
status is the more useful signal.

Anything skipped, such as an unreadable dump or a script that will not parse, is
reported rather than silently dropped, so a quietly-low number is visible instead
of plausible.

The `text` and `text-summary` tables go to stdout, so `zcov -- npm test > cov.txt`
captures one. Warnings and errors go to stderr, which leaves them visible when the
table is redirected.

### Ignore hints

Recognised in comments, with `v8` as the prefix worth writing because it names
the mechanism rather than a tool:

```js
/* v8 ignore next */      // skip the next statement and everything inside it
/* v8 ignore if */        // skip the consequent of the next if
/* v8 ignore else */      // skip its alternate
/* v8 ignore file */      // skip the file entirely
/* v8 ignore start */     // skip everything until...
/* v8 ignore stop */      // ...here
```

All four spellings in circulation work and are interchangeable: `v8`, `c8`,
`node:coverage` and `istanbul`. Only zcov and Vitest's engine accept every one.
c8 matches `[cv]8|node:coverage`, so it never sees an `istanbul` hint, and `nyc`
matches only `istanbul`, so it never sees the other three.

`start`/`stop` is a plain text search over source lines rather than a comment
parse, so it also works where the marker is not in a JavaScript comment.

### Costs

Memory grows slowly with `--threads`: 109MB at 1, 199MB at 8, 355MB at 16. The
default caps at 8 because sixteen threads is slower in wall time as well as
hungrier. Lowering it on a constrained runner costs close to linear wall time
down to 2 threads.

`--all`, on by default, parses every JavaScript or TypeScript source matching the
include patterns whether it loaded or not, so files a test run never touched
still appear at 0%, functions included. The cost scales with the number of
unloaded sources, so a large tree with a narrow test run will notice.

A component format (`.vue`, `.svelte`, `.astro`, `.marko`) is only parsed when
something already points into it, which is to say when a source map anchors to
it or V8 loaded it directly. One found by the walk alone is named under the table
as "not analysed" rather than parsed, because no JavaScript parser reads those
files whole and a partial read invents a denominator out of whatever it happened
to recognise. The same goes for any file that fails to parse. They are listed and
left out of the totals, so an unmeasured file is visible without moving a
percentage.

Everything else is free: ignore hints are one pass over the comments the parser
already collected, and glob matching happens once per script URL.

## Platform support

Nine targets are cross-compiled from one machine. Each is checked by running its
own binary against a fixture and requiring byte-identical lcov to the host build,
including a Windows-shaped dump (`file:///Z:/...` URLs, backslash arguments) to
exercise drive letters and separator normalisation.

| target | verified | how |
|---|---|---|
| linux-x64-gnu | yes | native, and in a Debian container |
| linux-x64-musl | yes | Alpine container |
| linux-arm64-gnu | yes | Debian container, qemu |
| linux-arm64-musl | yes | Alpine container, qemu |
| win32-x64 | yes | CI runs the suite natively; also a Wine container, Windows-shaped paths |
| darwin-arm64 | yes | CI runs the suite natively |
| win32-arm64 | builds only | no emulator for it here |
| darwin-x64 | builds only | not containerisable, and CI's macOS runners are arm64 |
| freebsd-x64 | builds only | no image tried |

```sh
zig build release && tools/test-platforms.sh
```

CI runs the full suite natively on Linux, macOS and Windows, which is the only
real check for darwin. `tools/test-platforms.sh` covers the rest locally.

## Tests

```sh
pnpm test                 # everything
pnpm run test:corpus      # exact per-line counts over a reference corpus
pnpm run test:regressions # every defect found so far, with fixed expectations
pnpm run test:cli         # exit codes and messages
pnpm run test:model       # every construct, against instrumented execution
pnpm run test:scenarios   # differential, against an independent implementation
```

### Corpus

A reference corpus of coverage cases, each run as a real file under
`NODE_V8_COVERAGE` and compared against published exact per-line counts, a far
sharper assertion than covered/uncovered. 191 cases.

### Regressions

One case per defect found while building zcov: shebangs, CRLF, mixed newlines,
astral-plane offsets, percent-encoded URLs, every ignore-hint form, inline base64
source maps, `--all`, multi-process merging, branches of every type, functions of
every shape, thread-count determinism. These assert fixed expectations rather
than diffing against anything, so they fail on their own terms. 45 cases, every
one of which was broken at some point.

### CLI

Exit codes and messages, and the reporters' contract: that the json is what the
istanbul tooling reads, and that feeding it back through istanbul's own lcov
reporter reproduces zcov's lcov exactly. 20 cases.

### Model

One construct at a time against `nyc`, which instruments and so observes rather
than infers, comparing the whole key set: every reported line, every function
line and count, `FNF`, `FNH`, and every branch slot. Where zcov answers
differently from istanbul on purpose, the deviation is declared in
`test/model.mjs` with the reason and the reference source that justifies it. The
suite fails both on an undeclared difference and on a declared one that stops
happening, so the list cannot drift from the code. 38 constructs.

This is the suite the others could not be. `test/scenarios.mjs` diffs against
another V8 engine, so a defect zcov shared with it was invisible, and
`test/run.mjs` only checked the lines istanbul expects, never the ones zcov
adds. Between them they hid an uncalled `static` method reported as called, two
branch groups on one line numbered in the wrong order, and a declarator statement
attributed to the wrong line.

### Differential

17 scenarios run through zcov and an independent implementation, diffing
per-line, per-function and per-branch results. Two differences are expected and
both are zcov being right: it omits a default parameter's branch where that
engine fabricates it, and it reports an uncalled method as uncalled.

### Fuzz

Random programs from a grammar (nested conditionals, loops, switch, try/finally,
early returns, default parameters, concise arrows), executed and checked line by
line against instrumented counts. Some disagreements belong to V8 rather than to
any engine, so the bar is that zcov is no worse than the reference V8 engine on
identical input, compared in aggregate: a single seed's count is noisy, and a
rule that helps broadly can cost a line on one input. Run twice, plain and
`--bundled`, which puts the same random programs through esbuild into one script
with a source map so the remapping path gets random input rather than only the
fixed corpora. Across eight seeds and 23,657 lines, both modes give 13
disagreements against the reference engine's 83, or 99.95% agreement with
instrumented execution.

The suite enforces something stronger than that comparison: **zero false
positives, absolutely**. Reporting untested code as covered hides risk;
reporting covered code as untested only wastes a reader's time. Every one of the
13 is the second kind, for lines, functions and branches alike. Widening the
grammar is how the last ones were found. Labelled `break`/`continue`, `for-of`,
destructuring and nested functions all went in after the narrower grammar ran
clean, and all three counts went non-zero the day they did. Seeds are
deterministic, so a failure reproduces with
`node test/fuzz.mjs <seed> --keep --bundled`.

## Build

Zig 0.16 via mise:

```sh
mise use -g zig@latest            # 0.16.0
zig build -Doptimize=ReleaseFast  # -> zig-out/bin/zcov
```

One static binary, no native addon, no runtime dependency on Node.

## Release

`zig build release` cross-compiles all nine published platforms into
`npm/zcov-<platform>/` (~49s for the set), and `tools/gen-npm.mjs` writes each
platform's `package.json` plus the main package's `optionalDependencies`, so the
version is edited in exactly one place:

```sh
pnpm run build:npm   # zig build release && node tools/gen-npm.mjs
```

`@zcov/cli` ships only a `bin/zcov.js` shim that resolves
`@zcov/<platform>-<arch>[-libc]` and execs the binary. Linux musl is detected at
runtime rather than assumed.

Versions come from changesets. Describe a change as you make it, and cut the
release when you want one:

```sh
pnpm run change            # write a changeset alongside the change
pnpm run release:version   # apply them: package.json, CHANGELOG.md, zon, manifests
```

`release:version` is the only thing that edits a version. It runs `changeset
version`, then propagates to `build.zig.zon` and regenerates the npm manifests,
because the publish workflow checks the tag against `package.json` alone — a zon
left behind would ship a binary whose `--version` lies. CI runs the same check
(`pnpm run release:check`) on every push.

Commit that, then tag `v<version>` and push it. Pushing a `v*` tag rebuilds, runs
the full suite, verifies the tag matches `package.json`, then publishes the
platform packages **before** the main package, so a partial publish can never
leave `zcov` installable without its binaries. The GitHub release is cut last,
from that version's `CHANGELOG.md` section, so it only ever describes packages
that actually went out.
CI builds and tests on Linux, macOS and Windows, checks formatting, and
cross-compiles every target on each run.

## How it works

`src/scan.zig` is the core; `src/cli.zig` drives it across dumps in parallel,
each thread accumulating its own tables and merging at the end.

A mapped script is parsed to collect statement, function and branch positions;
V8's truncated continuation counters have their extent restored from that parse;
the source map's VLQ segments are decoded; the V8 ranges are swept with a stack
to find each position's innermost count; and the result is mapped back to a
source line. A script V8 ran directly takes the same path minus the source map,
since type stripping preserves offsets and parsing the `.ts` lines up with V8's
ranges.

Then every reported source is parsed once more to enumerate its statement lines,
which is the line denominator; anything not hit is emitted as `DA:n,0`. Functions
and branches take their denominator from the generated code instead, because a
function's name maps back to an exact source position only 72% of the time while
a branch does 98%, not good enough to match against a separately parsed source.

The details that took measurement to get right:

1. Statement selection: 16 statement types, plus a variable declarator anchored
   on its initializer, a class property on its value, and a concise arrow body as
   an implicit return. Not block statements, not declarations, not imports or
   exports.
2. Source-map lines are 0-based and coverage lines are 1-based. That single
   off-by-one was worth ~45 points of agreement on its own.
3. V8 offsets are UTF-16 code units while AST spans are bytes. Any source with
   non-ASCII drifts apart: one file with 139 box-drawing characters had 278 bytes
   of drift, and every line in it was mis-attributed.
4. A statement that is a function expression sits exactly on that function's own
   V8 range, and its count is the enclosing block's, so range 0 of a function is
   skipped when it starts exactly at the statement, unless nothing encloses it. A
   function entry is the opposite: its count is its own range. Applying the
   statement rule to functions reports every uncalled function as called.
5. V8 percent-encodes script URLs, so a path containing `[` arrives as `%5B` and
   silently matches nothing.
6. Range sets from different worker processes do not nest with one another, so
   they are scored separately, taking the max within a process and the sum across
   them. Concatenating them lets a zero range from an idle process win the
   innermost-wins sweep.
7. A block branch is read one character in, and that bias belongs in UTF-16
   space, not byte space.
8. Inference must fill gaps, never argue with evidence. A statement that mapped
   somewhere and scored zero is dead code; a statement that mapped nowhere has no
   answer yet. Keeping zero-count hits is what makes the two distinguishable.
   Discarding them and inferring over both produced 12,960 lines reported as
   covered that never ran.
9. Loop and switch headers are the exception to that. V8 starts their range at
   the body brace, so the count sitting on the header is inherited from whatever
   encloses it and is not evidence at all. They are resolved by control flow
   instead: statements in a list run top to bottom, so if anything after the
   header ran it was reached, and if something before it is proven dead it was
   not. Applying that to every statement is unsafe, because a statement a bundler
   eliminated also reads as zero and propagating that forwards kills the live
   code after it.
10. V8 truncates its continuation counters, and the AST is what restores them.
    How often control passed a point is recorded as a bare position, then ended
    at the start of whatever range V8 emits next, so a `continue` taken on every
    iteration ends its dead range at the first sub-expression inside the next
    statement and everything past that reads the loop's count. The count holds to
    the end of the enclosing statement list, which the parse already knows.
    Widening the range there rather than overriding counts directly leaves
    anything nested inside it, such as a hoisted function callable from before
    the jump, winning on its own count; and a continuation can never exceed the
    block it sits in, so it only lowers. This was the last source of false
    positives in all three of lines, functions and branches.

Known inaccuracies are enumerated in [ACCURACY.md](ACCURACY.md), all 13 of them,
with the mechanism for each.

## Licence

MIT. See [NOTICE](NOTICE) for the third-party components zcov builds on.
