// One case per defect found so far, asserting fixed expectations rather than
// diffing, so they still fail when a reference is absent or itself wrong.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ZCOV = path.join(HERE, "..", "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zcov-reg-")));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));

if (!fs.existsSync(ZCOV)) {
  console.error("zcov not built - run: zig build -Doptimize=ReleaseFast");
  process.exit(1);
}

// Each case writes `files`, runs `entry` once per `env`, and checks `expect`
// against the lcov record for `assert`. See any case below for the shape.
const CASES = [
  // ---- defects found in zcov itself ---------------------------------
  {
    name: "stale range does not leak from a finished sibling function",
    why: "a function that already ended stayed on the sweep stack and lent its 0",
    files: {
      "main.js": `function dead() {\n  return 1;\n}\nfunction live() {\n  return 2;\n}\nlive();\n`,
    },
    expect: { lines: { 2: 0, 5: 1, 7: 1 } },
  },
  {
    name: "concise arrow body is a statement",
    why: "istanbul treats `x => x + 1` as an implicit return; it was missing entirely",
    files: {
      // The arrow body sits on its own line, so its count is not masked by the
      // declarator's -- both are statements and a line takes the larger.
      "main.js": `const double = (x) =>\n  x * 2;\nconst never = (x) =>\n  x * 3;\ndouble(2);\n`,
    },
    expect: { lines: { 1: 1, 2: 1, 3: 1, 4: 0, 5: 1 } },
  },
  {
    name: "counts sum across processes, max within one",
    why: "taking the max everywhere halved counts for anything run in two processes",
    files: { "main.js": `function hit() {\n  return 1;\n}\nhit();\n` },
    env: [{}, {}, {}],
    expect: { lines: { 2: 3, 4: 3 } },
  },
  {
    name: "non-ascii before code does not shift attribution",
    why: "V8 offsets are UTF-16 code units, AST spans are bytes; they drift apart",
    files: {
      "main.js": `const banner = "┏━━━━━━━━━━┓┏━━━━━━━━━━┓";\nfunction used() {\n  return banner;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`,
    },
    expect: { lines: { 1: 1, 3: 1, 6: 0, 8: 1 } },
  },
  {
    name: "astral plane characters count as two UTF-16 units",
    why: "a 4-byte character is one byte-span but two V8 offsets",
    files: {
      "main.js": `const emoji = "😀😀😀😀😀";\nfunction used() {\n  return emoji;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`,
    },
    expect: { lines: { 1: 1, 3: 1, 6: 0, 8: 1 } },
  },
  {
    name: "percent-encoded script url still matches on disk",
    why: "V8 reports `native-tag[html]` as `%5B`, which silently matched nothing",
    files: { "weird[name].js": `function used() {\n  return 1;\n}\nused();\n` },
    entry: "weird[name].js",
    expect: { lines: { 2: 1, 4: 1 } },
  },
  {
    name: "an uncalled function reports zero calls",
    why: "the statement fn-root rule was applied to functions, so every one read as called",
    files: {
      "main.js": `function called() {\n  return 1;\n}\nfunction uncalled() {\n  return 2;\n}\ncalled();\ncalled();\n`,
    },
    expect: { fns: { 1: 2, 4: 0 } },
  },
  {
    name: "a hit inside a multi-line statement credits the statement",
    why: "bundlers anchor `const x =\\n <expr>` at the expression, and the hit was dropped",
    files: {
      "main.js": `function f(v) {\n  const isThing =\n    typeof v === "object" &&\n    v !== null;\n  return isThing;\n}\nf({});\n`,
    },
    // istanbul locates a declarator statement at its *initializer*, so the
    // multi-line one reports on line 3, not on the `const`.
    expect: { lines: { 3: 1, 5: 1, 7: 1 } },
  },
  {
    name: "loop header reached but iterating zero times is covered",
    why: "V8 folds a zero-iteration loop into the preceding dead range",
    files: {
      "main.js": `function scan(obj) {\n  for (const k in obj) {\n    void k;\n  }\n  for (const k in { a: 1 }) {\n    void k;\n  }\n}\nscan({});\n`,
    },
    expect: { lines: { 2: 1, 5: 1 } },
  },
  {
    name: "loop header after proven-dead code stays uncovered",
    why: "the opposite error: V8 starts a loop range at the body brace, so the header inherited a live count",
    files: {
      "main.js": `function early(n) {\n  if (n === 0) {\n    return "none";\n  }\n  var acc = [];\n  for (var i = n; i--;) {\n    acc.push(i);\n  }\n  return acc;\n}\nearly(0);\nearly(0);\n`,
    },
    expect: { lines: { 3: 2, 5: 0, 6: 0, 7: 0 } },
  },
  {
    name: "function names are stable, not whichever bundle won the race",
    why: "output differed between thread counts when a bundler renamed a function",
    files: { "main.js": `function stable() {\n  return 1;\n}\nstable();\n` },
    threads: [1, 4, 8],
    expect: { fns: { 1: 1 } },
  },

  {
    name: "switch header after proven-dead code stays uncovered",
    why: "V8 starts a switch range at the body, so the header inherited a live count",
    files: {
      "main.js": `function pick(n) {\n  if (n === 0) {\n    return "none";\n  }\n  switch (n % 2) {\n    case 0:\n      return "even";\n    default:\n      return "odd";\n  }\n}\npick(0);\npick(0);\n`,
    },
    expect: { lines: { 3: 2, 5: 0, 7: 0, 9: 0 } },
  },
  {
    name: "dead code is not inferred over when it mapped and scored zero",
    why: "inference must fill gaps, never argue with evidence -- this cost 12,960 false positives",
    files: {
      "main.js": `function f(a, b) {\n  if (a > b) {\n    return a;\n  }\n  let total = 0;\n  for (let i = 0; i < b; i++) {\n    total += i;\n  }\n  switch (total % 2) {\n    case 0:\n      return total;\n    default:\n      return -total;\n  }\n}\nf(5, 1);\n`,
    },
    // Only the early-return path runs; everything after it must stay at zero.
    expect: { lines: { 3: 1, 5: 0, 6: 0, 7: 0, 9: 0, 11: 0, 13: 0 } },
  },
  {
    name: "a taken continue leaves the rest of the loop body dead",
    why: "V8 truncates the dead range at the first sub-expression it instrumented, and everything past it read the loop's count",
    files: {
      // The ternary does the damage: V8 gives its alternate a range of its own,
      // cutting the zero range short two lines into a body dead for six.
      "main.js": `function f(a, b) {\n  let total = 0;\n  L: for (let k = 0; k < 2; k++) {\n    if (a === b) { continue L; }\n    const v =\n      a === b ? 2 : 3;\n    total += v;\n    try {\n      total += 1;\n    } catch (e) {\n      total -= 1;\n    }\n  }\n  return total;\n}\nf(2, 2);\n`,
    },
    expect: { lines: { 2: 1, 3: 1, 4: 2, 6: 0, 7: 0, 8: 0, 9: 0, 11: 0, 14: 1, 16: 1 } },
  },
  {
    name: "a taken break leaves the rest of the loop body dead",
    why: "same truncation, reached by the other labelled jump",
    files: {
      "main.js": `function f(a, b) {\n  let total = 0;\n  L: for (let k = 0; k < 2; k++) {\n    if (a === b) { break L; }\n    const v =\n      a === b ? 2 : 3;\n    total += v;\n    try {\n      total += 1;\n    } catch (e) {\n      total -= 1;\n    }\n  }\n  return total;\n}\nf(2, 2);\n`,
    },
    expect: { lines: { 2: 1, 3: 1, 4: 1, 6: 0, 7: 0, 8: 0, 9: 0, 11: 0, 14: 1, 16: 1 } },
  },
  {
    name: "a catch that returns lowers the count of the code after the try",
    why: "the counter for that sits at the end of the catch, so the code after it read the whole function's count and an implicit else looked taken",
    files: {
      // The `finally` is the trap: it runs on the call that returns from the
      // catch too, so the counter must not be stretched over it.
      "main.js": `function f(a, b) {\n  let total = 0;\n  try {\n    if (a > 0) { throw new Error("x"); }\n    total += 1;\n  } catch (e) {\n    return -1;\n  } finally {\n    total += 4;\n  }\n  const v = b > 0 && b < 9 ? 1 : 2;\n  if (b > 0) {\n    total += v;\n  }\n  return total;\n}\nf(1, 1);\nf(-1, 1);\nf(-1, 1);\n`,
    },
    expect: {
      lines: { 5: 2, 7: 1, 9: 3, 11: 2, 12: 2, 13: 2, 15: 2 },
      brs: { 12: [2, 0] },
    },
  },

  {
    name: "a coarse source map does not duplicate a function or a branch",
    why: "the same source reached directly and through a line-granular map produced two entries -- `getRootNode` at 0 calls beside `getRootNode_2` at 1132",
    files: {
      // `bundle.js` has a line-granular map, so its items land at column 0 while
      // the direct run places them precisely. Same items, and the counts add.
      "src.js": `function hit(a) {\n  if (a) {\n    return 1;\n  }\n  return 0;\n}\nmodule.exports = hit;\n`,
      "bundle.js": `function hit(a) {\n  if (a) {\n    return 1;\n  }\n  return 0;\n}\nhit(1);\n//# sourceMappingURL=bundle.js.map\n`,
      "bundle.js.map": JSON.stringify({
        version: 3,
        file: "bundle.js",
        sources: ["src.js"],
        // One segment per line, at column 0 -- AAAA, then AACA to step the
        // source line on each following line.
        mappings: "AAAA;AACA;AACA;AACA;AACA;AACA;AACA",
      }),
      "main.js": `require("./bundle.js");\nconst hit = require("./src.js");\nhit(1);\nhit(1);\n`,
    },
    entry: "main.js",
    assert: "src.js",
    // Three calls in all: one through the bundle, two directly.
    expect: { lines: { 2: 3, 3: 3 }, fns: { 1: 3 }, assert: "src.js" },
  },
  {
    name: "the same script id twice in one dump is not double counted",
    why: "a repeated entry is one script; a repeated URL with a different id is not",
    files: { "main.js": `function hit() {\n  return 1;\n}\nhit();\n` },
    // A wholesale duplicate carries the same scriptId, so it is the same
    // script listed twice and its ranges must merge rather than sum.
    mutateDump: (j) => {
      const e = j.result.find((x) => x.url && x.url.endsWith("main.js"));
      if (e) j.result.push(JSON.parse(JSON.stringify(e)));
      return j;
    },
    expect: { lines: { 2: 1, 4: 1 } },
  },
  {
    name: "the same file under two script ids stays two instances",
    why: "V8 compiles a module once per context; those ranges do not nest and must not merge",
    files: { "main.js": `function hit() {\n  return 1;\n}\nhit();\n` },
    mutateDump: (j) => {
      const e = j.result.find((x) => x.url && x.url.endsWith("main.js"));
      if (e) {
        const copy = JSON.parse(JSON.stringify(e));
        copy.scriptId = String(Number(e.scriptId || 1) + 1000);
        j.result.push(copy);
      }
      return j;
    },
    // Two instances each ran it once, so the counts add.
    expect: { lines: { 2: 2, 4: 2 } },
  },
  {
    name: "sourceRoot and a subdirectory sourceMappingURL are both followed",
    why: "only sibling .map and inline base64 were handled; bundlers use neither",
    externalMap: true,
    // The point is path resolution: before the fix the map was never found, so
    // the generated file was reported instead of the source it maps to.
    expect: { reported: "src/lib.js", notReported: "app.js" },
  },
  {
    name: "a malformed source map is skipped, not fatal",
    why: "a negative or out-of-range source index used to be an illegal cast",
    brokenMap: true,
    // Reaching the assertion at all means zcov exited cleanly.
    expect: { survives: true },
  },

  {
    name: "a component file a JS parser cannot read is still reported",
    why: "a .vue or .svelte source needed --extension before its coverage counted",
    componentMap: true,
    expect: { reported: "src/App.vue" },
  },

  {
    name: "a statement after a zero-iteration loop still counts",
    why: "V8's zero range covers the loop body AND the statements after it",
    files: {
      "main.js": `function f(n) {\n  let total = 0;\n  for (let i = 0; i < n; i++) {\n    total += 1;\n  }\n  total += 2;\n  switch (total % 2) {\n    case 0:\n      return "even";\n    default:\n      return "odd";\n  }\n}\nf(0);\nf(0);\n`,
    },
    // The loop body never runs, but everything after it does.
    expect: { lines: { 4: 0, 6: 2, 7: 2 } },
  },

  {
    name: "a finally runs even though the try returned",
    why: "the dead-after-return rule must stop at the statement list boundary",
    files: {
      "main.js": `function f() {\n  try {\n    return "a";\n    unreachable();\n  } finally {\n    cleanup();\n  }\n}\nfunction unreachable() { return 1; }\nfunction cleanup() { return 1; }\nf();\n`,
    },
    expect: { lines: { 3: 1, 4: 0, 6: 1 } },
  },
  {
    name: "a finally can override the try's return",
    files: {
      "main.js": `function f() {\n  try {\n    return "try";\n  } finally {\n    return "finally";\n  }\n}\nf();\n`,
    },
    expect: { lines: { 3: 1, 5: 1 } },
  },
  {
    name: "code after a try that always returns is dead",
    files: {
      "main.js": `function f() {\n  try {\n    return "always";\n  } finally {\n    cleanup();\n  }\n  afterwards();\n  return "never";\n}\nfunction cleanup() { return 1; }\nfunction afterwards() { return 1; }\nf();\n`,
    },
    expect: { lines: { 3: 1, 5: 1, 7: 0, 8: 0 } },
  },
  {
    name: "continue inside try still runs the finally each iteration",
    why: "a jump out of the try body is not a jump out of the finally",
    files: {
      "main.js": `function f() {\n  let n = 0;\n  for (let i = 0; i < 3; i++) {\n    try {\n      if (i === 0) { continue; }\n      n += 1;\n    } finally {\n      each();\n    }\n  }\n  return n;\n}\nfunction each() { return 1; }\nf();\n`,
    },
    expect: { lines: { 5: 3, 6: 2, 8: 3, 11: 1 } },
  },
  {
    name: "a throw past a nested finally is caught outside it",
    files: {
      "main.js": `function f() {\n  try {\n    try {\n      throw new Error("x");\n      never();\n    } finally {\n      inner();\n    }\n  } catch {\n    caught();\n  }\n  return "done";\n}\nfunction never() { return 1; }\nfunction inner() { return 1; }\nfunction caught() { return 1; }\nf();\n`,
    },
    expect: { lines: { 4: 1, 5: 0, 7: 1, 10: 1, 12: 1 } },
  },

  // ---- c8's own test surface ------------------------------------------
  {
    name: "c8: shebang does not shift offsets",
    files: {
      "main.js": `#!/usr/bin/env node\nfunction used() {\n  return 1;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`,
    },
    expect: { lines: { 3: 1, 6: 0, 8: 1 } },
  },
  {
    name: "c8: ignore next",
    files: {
      "main.js": `function f(n) {\n  /* c8 ignore next */\n  if (n < 0) return "neg";\n  return "ok";\n}\nf(1);\n`,
    },
    expect: { lines: { 4: 1 }, absent: [3] },
  },
  {
    name: "c8: ignore start / stop",
    files: {
      "main.js": `const a = 1;\n/* c8 ignore start */\nfunction never() {\n  return 2;\n}\n/* c8 ignore stop */\nconst b = 2;\nvoid [a, b];\n`,
    },
    expect: { lines: { 1: 1, 7: 1 }, absent: [4] },
  },
  {
    name: "c8: unterminated ignore start runs to end of file",
    files: {
      "main.js": `const a = 1;\n/* c8 ignore start */\nfunction never() {\n  return 2;\n}\nconst b = 2;\nvoid [a, b];\n`,
    },
    expect: { lines: { 1: 1 }, absent: [4, 6, 7] },
  },
  {
    name: "c8: ignore file drops the record entirely",
    files: { "main.js": `/* c8 ignore file */\nfunction f() {\n  return 1;\n}\nf();\n` },
    expect: { noFile: true },
  },
  {
    name: "c8: v8 and node:coverage spellings are honoured too",
    files: {
      "main.js": `function f(n) {\n  /* v8 ignore next */\n  if (n < 0) return "neg";\n  /* node:coverage ignore next */\n  if (n > 99) return "big";\n  return "ok";\n}\nf(1);\n`,
    },
    expect: { lines: { 6: 1 }, absent: [3, 5] },
  },
  {
    name: "c8: inline base64 source map is followed",
    inlineMap: true,
    expect: { lines: { 2: 1, 5: 0 }, assert: "src.js" },
  },
  {
    name: "c8: CRLF line endings",
    files: {
      "main.js": "function used() {\r\n  return 1;\r\n}\r\nfunction unused() {\r\n  return 2;\r\n}\r\nused();\r\n",
    },
    expect: { lines: { 2: 1, 5: 0, 7: 1 } },
  },
  {
    name: "c8: a file that never loads still reports at zero",
    why: "this is what --all buys, and it is on by default",
    files: {
      "main.js": `console.log("ran");\n`,
      "untouched.js": `function never() {\n  return 1;\n}\nnever();\n`,
    },
    expect: { lines: { 2: 0, 4: 0 }, assert: "untouched.js" },
  },
  {
    name: "a file that never loads reports its functions as uncovered",
    why: "functions came only from scripts that ran, so an unloaded file had FNF:0",
    files: {
      "main.js": `console.log("ran");\n`,
      "untouched.js": `export function a() {\n  return 1;\n}\nexport function b() {\n  return 2;\n}\n`,
    },
    expect: { fns: { 1: 0, 4: 0 }, assert: "untouched.js" },
  },
  {
    name: "an unloaded component file is left out rather than half-parsed",
    why: "recovering a .vue <script> without its enclosing markup invented a denominator: 2 lines, no functions, none of it trustworthy",
    files: {
      "main.js": `console.log("ran");\n`,
      "Widget.vue": `<template>\n  <div>{{ label }}</div>\n</template>\n<script setup>\nconst label = "hi";\nfunction onClick() {\n  console.log(label);\n}\n</script>\n`,
    },
    expect: { noFile: true, assert: "Widget.vue" },
  },
  {
    name: "generated output that never ran is not reported beside its source",
    why: "`remapped` is only filled for scripts that ran, so the --all walk counted the compiler's output as a second source and doubled it",
    files: {
      "main.js": `console.log("ran");\n`,
      "src.js": `export function idle() {\n  return 1;\n}\n`,
      "out.js": `export function idle() {\n  return 1;\n}\n//# sourceMappingURL=out.js.map\n`,
      "out.js.map": JSON.stringify({
        version: 3,
        sources: ["src.js"],
        names: [],
        mappings: "AAAA;AACA;AACA",
      }),
    },
    expect: { reported: "src.js", notReported: "out.js" },
  },
  {
    name: "a component file a source map points into is still reported",
    why: "skipping component formats outright would drop the mapped ones with them",
    files: {
      "bundle.js": `function greet() {\n  return "hi";\n}\nfunction unused() {\n  return "bye";\n}\ngreet();\n//# sourceMappingURL=bundle.js.map\n`,
      "bundle.js.map": JSON.stringify({
        version: 3,
        sources: ["Comp.vue"],
        names: [],
        // Generated line N maps to Comp.vue line N+4, where its <script> starts.
        mappings: "AAIA;AACA;AACA;AACA;AACA;AACA;AACA",
      }),
      "Comp.vue": `<template>\n  <div>{{ msg }}</div>\n</template>\n<script>\nexport function greet() {\n  return "hi";\n}\nexport function unused() {\n  return "bye";\n}\n</script>\n`,
    },
    entry: "bundle.js",
    expect: { lines: { 6: 1, 9: 0 }, fns: { 5: 1, 8: 0 }, assert: "Comp.vue" },
  },

  // ---- v8-to-istanbul's own test surface ------------------------------
  {
    name: "v8-to-istanbul: mixed newlines",
    files: {
      "main.js": "function used() {\r\n  return 1;\n}\r\nfunction unused() {\n  return 2;\r\n}\nused();\n",
    },
    expect: { lines: { 2: 1, 5: 0, 7: 1 } },
  },
  {
    name: "v8-to-istanbul: branches",
    files: {
      "main.js": `function f(a, b) {\n  const x = a || b;\n  const y = a ? 1 : 2;\n  if (a) {\n    return x;\n  } else {\n    return y;\n  }\n}\nf(1, 0);\n`,
    },
    // `a || b`: left taken, right never. ternary: consequent only. if: no else.
    expect: { brs: { 2: [1, 0], 3: [1, 0], 4: [1, 0] } },
  },
  {
    name: "v8-to-istanbul: functions of every shape",
    files: {
      "main.js": `function decl() {\n  return 1;\n}\nconst expr = function named() {\n  return 2;\n};\nconst arrow = () => 3;\nclass K {\n  method() {\n    return 4;\n  }\n  get prop() {\n    return 5;\n  }\n}\nconst obj = {\n  shorthand() {\n    return 6;\n  },\n};\ndecl();\nexpr();\narrow();\nnew K().method();\nobj.shorthand();\n`,
    },
    expect: { fns: { 1: 1, 4: 1, 7: 1, 9: 1, 12: 0, 17: 1 } },
  },
  {
    name: "v8-to-istanbul: default parameters are branches",
    // V8 emits ranges only for code that did not run, so a default being used is
    // undetectable; claiming it either way is a guess, so it is left out.
    files: {
      "main.js": `function f(a = 1, b = 2) {\n  return a + b;\n}\nf(5);\n`,
    },
    expect: { brs: {}, noBranchesOn: [1] },
  },
  {
    name: "v8-to-istanbul: switch cases are branches",
    files: {
      "main.js": `function pick(n) {\n  switch (n) {\n    case 1:\n      return "one";\n    case 2:\n      return "two";\n    default:\n      return "other";\n  }\n}\npick(1);\n`,
    },
    expect: { brs: { 2: [1, 0, 0] } },
  },
];

// A generated file whose map lives in a subdirectory and uses sourceRoot.
function writeExternalMapCase(dir) {
  fs.mkdirSync(path.join(dir, "maps"), { recursive: true });
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  fs.writeFileSync(path.join(dir, "src", "lib.js"), `export function used() {\n  return 1;\n}\n`);
  fs.writeFileSync(
    path.join(dir, "app.js"),
    `function used() {\n  return 1;\n}\nused();\n//# sourceMappingURL=maps/app.js.map\n`,
  );
  fs.writeFileSync(
    path.join(dir, "maps", "app.js.map"),
    JSON.stringify({
      version: 3,
      file: "app.js",
      sourceRoot: "../src",
      sources: ["lib.js"],
      names: [],
      mappings: "AAAA;AACA;AACA",
    }),
  );
  return "app.js";
}

// Source indices and line deltas that decode out of range, plus an over-long
// VLQ. Nothing here should be fatal.
function writeBrokenMapCase(dir) {
  fs.writeFileSync(path.join(dir, "app.js"), `function f() {\n  return 1;\n}\nf();\n`);
  fs.writeFileSync(
    path.join(dir, "app.js.map"),
    JSON.stringify({
      version: 3,
      file: "app.js",
      sources: ["nope.js"],
      names: [],
      mappings: "AAAA;AADA;AAggggggggggggA;ADDA",
    }),
  );
  return "app.js";
}

// Compiled component output mapping back to a file no JavaScript parser reads.
function writeComponentCase(dir) {
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  fs.writeFileSync(
    path.join(dir, "src", "App.vue"),
    `<template>\n  <p>{{ msg }}</p>\n</template>\n<script>\nexport default {\n  computed: {\n    msg() { return "hi"; },\n  },\n};\n</script>\n`,
  );
  fs.writeFileSync(
    path.join(dir, "app.js"),
    `function msg() {\n  return "hi";\n}\nmsg();\n//# sourceMappingURL=app.js.map\n`,
  );
  fs.writeFileSync(
    path.join(dir, "app.js.map"),
    JSON.stringify({ version: 3, file: "app.js", sources: ["src/App.vue"], names: [], mappings: "AAMA;AACA;AACA;AACA" }),
  );
  return "app.js";
}

function write(dir, files) {
  for (const [name, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
    fs.writeFileSync(path.join(dir, name), content);
  }
}

// A generated file plus an inline base64 map back to a source that never runs
// as its own script -- the shape tsc and esbuild emit by default.
function writeInlineMapCase(dir) {
  const src = `export function used() {\n  return 1;\n}\nexport function unused() {\n  return 2;\n}\n`;
  fs.writeFileSync(path.join(dir, "src.js"), src);
  const gen = `function used() {\n  return 1;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`;
  // Identity mapping, line for line, column 0.
  const vlq = "AAAA";
  const mappings = gen
    .split("\n")
    .map((_, i) => (i === 0 ? vlq : "AACA"))
    .join(";");
  const map = {
    version: 3,
    file: "out.js",
    sources: ["src.js"],
    sourcesContent: [src],
    names: [],
    mappings,
  };
  const b64 = Buffer.from(JSON.stringify(map)).toString("base64");
  fs.writeFileSync(
    path.join(dir, "out.js"),
    gen + `//# sourceMappingURL=data:application/json;base64,${b64}\n`,
  );
  return "out.js";
}

function report(dir, covDir, threads) {
  execFileSync(
    ZCOV,
    ["report", "-d", covDir, "--cwd", dir, "--threads", String(threads), "-r", "lcov", "-o", "rep"],
    { stdio: "ignore", timeout: 30000 },
  );
  const text = fs.readFileSync(path.join(dir, "rep", "lcov.info"), "utf8");
  // Holds for every case: nothing runs a negative number of times, and lcov
  // cannot express it. An implicit `else` is a subtraction, so it can go under.
  const negative = text.split("\n").filter((l) => /^(DA|FNDA|BRDA):.*,-\d/.test(l));
  const files = new Map();
  let cur = null;
  for (const l of text.split("\n")) {
    if (l.startsWith("SF:")) {
      cur = { lines: new Map(), fns: new Map(), brs: new Map(), fnLines: [] };
      files.set(l.slice(3), cur);
    } else if (!cur) continue;
    else if (l.startsWith("DA:")) {
      const [a, b] = l.slice(3).split(",");
      cur.lines.set(+a, +b);
    } else if (l.startsWith("FN:")) {
      cur.fnLines.push(+l.slice(3).split(",")[0]);
    } else if (l.startsWith("FNDA:")) {
      cur.fns.set(cur.fnLines[cur.fns.size], +l.slice(5).split(",")[0]);
    } else if (l.startsWith("BRDA:")) {
      const [line, , , count] = l.slice(5).split(",");
      if (!cur.brs.has(+line)) cur.brs.set(+line, []);
      cur.brs.get(+line).push(+count);
    }
  }
  files.negative = negative;
  return files;
}

let failed = 0;
let passed = 0;
for (const [i, c] of CASES.entries()) {
  const dir = path.join(root, "c" + i);
  fs.mkdirSync(dir, { recursive: true });
  let entry = c.entry ?? "main.js";
  if (c.inlineMap) entry = writeInlineMapCase(dir);
  else if (c.externalMap) entry = writeExternalMapCase(dir);
  else if (c.brokenMap) entry = writeBrokenMapCase(dir);
  else if (c.componentMap) entry = writeComponentCase(dir);
  else write(dir, c.files);

  const covDir = path.join(dir, "cov");
  fs.mkdirSync(covDir, { recursive: true });
  const errs = [];
  try {
    for (const env of c.env ?? [{}]) {
      execFileSync(process.execPath, [path.join(dir, entry)], {
        env: { ...process.env, ...env, NODE_V8_COVERAGE: covDir },
        stdio: "ignore",
        timeout: 20000,
      });
    }
  } catch (e) {
    errs.push("run failed: " + (e.message || "").split("\n")[0].slice(0, 60));
  }

  if (c.mutateDump) {
    for (const f of fs.readdirSync(covDir)) {
      const p = path.join(covDir, f);
      fs.writeFileSync(p, JSON.stringify(c.mutateDump(JSON.parse(fs.readFileSync(p, "utf8")))));
    }
  }

  const target = c.expect.assert ?? entry;
  const threadList = c.threads ?? [1];
  const seen = [];
  for (const t of threadList) {
    let files;
    try {
      files = report(dir, covDir, t);
    } catch (e) {
      errs.push("zcov failed: " + (e.message || "").split("\n")[0].slice(0, 60));
      break;
    }
    for (const l of files.negative) errs.push(`negative count in lcov: ${l}`);
    const rec = [...files.entries()].find(([f]) => f.endsWith(target))?.[1];
    seen.push(JSON.stringify(rec && [...rec.lines], null, 0));

    // Some cases only assert that zcov came back at all; report() throws on a
    // non-zero exit, so reaching here is the assertion.
    if (c.expect.survives) continue;
    if (c.expect.reported) {
      if (![...files.keys()].some((f) => f.endsWith(c.expect.reported))) {
        errs.push(`expected a record for ${c.expect.reported}, got ${[...files.keys()].join(", ") || "none"}`);
      }
      if (c.expect.notReported && [...files.keys()].some((f) => f.endsWith(c.expect.notReported))) {
        errs.push(`${c.expect.notReported} should have been remapped away, not reported`);
      }
      continue;
    }
    if (c.expect.noFile) {
      if (rec) errs.push(`expected no record for ${target}, got one`);
      continue;
    }
    if (!rec) {
      errs.push(`no lcov record for ${target}`);
      continue;
    }
    for (const [line, want] of Object.entries(c.expect.lines ?? {})) {
      const got = rec.lines.get(+line);
      if (got !== want) errs.push(`line ${line}: want ${want}, got ${got ?? "missing"}`);
    }
    for (const [line, want] of Object.entries(c.expect.fns ?? {})) {
      const got = rec.fns.get(+line);
      if (got !== want) errs.push(`fn on line ${line}: want ${want}, got ${got ?? "missing"}`);
    }
    for (const line of c.expect.noBranchesOn ?? []) {
      if (rec.brs.has(line)) errs.push(`line ${line} should have no branches, got ${JSON.stringify(rec.brs.get(line))}`);
    }
    for (const [line, want] of Object.entries(c.expect.brs ?? {})) {
      const got = rec.brs.get(+line);
      if (JSON.stringify(got) !== JSON.stringify(want)) {
        errs.push(`branches on line ${line}: want ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
      }
    }
    for (const line of c.expect.absent ?? []) {
      if (rec.lines.has(line)) errs.push(`line ${line} should be ignored, got ${rec.lines.get(line)}`);
    }
  }
  if (threadList.length > 1 && new Set(seen).size > 1) {
    errs.push(`output differs across thread counts ${threadList.join("/")}`);
  }

  if (errs.length) {
    failed++;
    console.log(`  FAIL  ${c.name}`);
    if (c.why) console.log(`          (${c.why})`);
    for (const e of errs) console.log(`          ${e}`);
  } else {
    passed++;
    console.log(`  ok    ${c.name}`);
  }
}

console.log(`\n  ${CASES.length} regression cases: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
