// Audits the istanbul model construct by construct against `nyc`, which
// observes rather than infers, comparing the whole key set both ways.
//
//   node test/model.mjs                # all constructs
//   node test/model.mjs --verbose      # including the declared deviations
//   node test/model.mjs ternary        # one construct
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const ZCOV = path.join(ROOT, "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");
// The `.bin` shims are `.cmd` files on Windows, which Node will not spawn
// without a shell. Resolving each package's own JS entry and running it with
// node sidesteps both, and needs no shell anywhere.
const req = createRequire(import.meta.url);
const binJs = (name) => {
  const pkg = req(`${name}/package.json`);
  const rel = typeof pkg.bin === "string" ? pkg.bin : pkg.bin[name];
  return path.join(path.dirname(req.resolve(`${name}/package.json`)), rel);
};
const NYC = binJs("nyc");
const ENGINE = path.join(ROOT, "tools", "vitest-engine.mjs");

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const only = args.filter((a) => !a.startsWith("--"))[0];

if (!fs.existsSync(ZCOV)) {
  console.error("zcov not built - run: zig build -Doptimize=ReleaseFast");
  process.exit(1);
}
if (!fs.existsSync(NYC)) {
  console.log("  skipped: nyc is not installed");
  process.exit(0);
}

// One construct per entry. Kept narrow on purpose: when one fails, the failure
// names the construct rather than a line number in a generated program.
const CASES = {
  // istanbul locates a declarator at its *initializer* (visitor.js,
  // coverVariableDeclarator); a multi-line one is the only way to see that.
  "declarator multi-line": `function f(v) {\n  const isThing =\n    typeof v === "object";\n  return isThing;\n}\nf({});\n`,
  "declarator single line": `function f() {\n  const a = 1;\n  return a;\n}\nf();\n`,
  "declarator no init": `function f() {\n  let a;\n  a = 1;\n  return a;\n}\nf();\n`,
  "class property multi-line": `class A {\n  x =\n    1 + 1;\n}\nnew A();\n`,
  "class private property": `class A {\n  #x =\n    2;\n  get v() { return this.#x; }\n}\nnew A().v;\n`,
  // A concise arrow body is an implicit return, located at the body.
  "concise arrow multi-line": `const d = (x) =>\n  x * 2;\nconst n = (x) =>\n  x * 3;\nd(2);\n`,
  "concise arrow uncalled": `const n = (x) =>\n  x * 3;\nvoid n;\n`,
  "arrow returning object": `const f = () => ({\n  a: 1,\n});\nf();\n`,
  // A string literal in statement position is a directive, not a statement.
  "use strict directive": `"use strict";\nfunction f() {\n  return 1;\n}\nf();\n`,
  "string expression not a directive": `function f() {\n  "not a directive";\n  return 1;\n}\nf();\n`,
  "empty statement": `function f() {\n  ;\n  return 1;\n}\nf();\n`,
  "labeled block": `function f() {\n  L: {\n    break L;\n  }\n  return 1;\n}\nf();\n`,
  "do while": `function f() {\n  let i = 2;\n  do {\n    i--;\n  } while (i > 0);\n  return i;\n}\nf();\n`,
  "switch fallthrough": `function f(n) {\n  switch (n) {\n    case 0:\n    case 1:\n      return "low";\n    default:\n      return "high";\n  }\n}\nf(0);\nf(5);\n`,
  // Two branch groups starting in the same place. istanbul's walk is pre-order,
  // so the conditional is numbered before the logical in its own test.
  "logical inside ternary": `function f(a, b) {\n  return a > 0 && b < 9 ? 1 : 2;\n}\nf(1, 1);\nf(1, 1);\n`,
  "ternary inside logical": `function f(a, b) {\n  return (a > 0 ? 1 : 0) && b;\n}\nf(1, 1);\n`,
  "nested ternary": `function f(a) {\n  return a > 2 ? "big" : a > 0 ? "small" : "neg";\n}\nf(1);\n`,
  "logical chain mixed": `function f(a, b, c) {\n  return a && b || c;\n}\nf(1, 1, 1);\n`,
  "nullish and optional": `function f(o) {\n  return o?.a?.b ?? 5;\n}\nf({ a: { b: 1 } });\nf(null);\n`,
  "default arg used and skipped": `function f(x = 1) {\n  return x;\n}\nf();\nf(2);\n`,
  "default arg destructured": `function f({ x = 1 } = {}) {\n  return x;\n}\nf();\nf({ x: 2 });\n`,
  "default arg arrow": `const g = (x = 3) =>\n  x + 1;\ng();\n`,
  "implicit else": `function f(a) {\n  if (a > 0) {\n    return 1;\n  }\n  return 2;\n}\nf(1);\nf(-1);\n`,
  // The implicit else is a subtraction, so a disagreement between the two probes
  // used to come out negative.
  "implicit else body always throws": `function f(a) {\n  try {\n    if (a > 0) { throw new Error("x"); }\n    return 1;\n  } catch (e) {\n    return 2;\n  }\n}\nf(1);\nf(-1);\n`,
  "if without braces": `function f(a) {\n  if (a) return 1;\n  else return 2;\n}\nf(1);\n`,
  // A class declaration is not a statement.
  "class declaration": `class A {\n  constructor() {\n    this.v = 1;\n  }\n  method() {\n    return this.v;\n  }\n}\nnew A().method();\n`,
  // V8 starts a method's range at the value, which for `static m()` is after
  // the modifier; reading at the member reports an uncalled one as called.
  "uncalled methods": `class A {\n  called() {\n    return 1;\n  }\n  static neverCalled() {\n    return 2;\n  }\n  notCalled() {\n    return 3;\n  }\n}\nnew A().called();\n`,
  "every method shape": `const k = "computed";\nclass A {\n  plain() { return 1; }\n  static stat() { return 2; }\n  get getter() { return 3; }\n  set setter(v) { void v; }\n  static get sgetter() { return 4; }\n  async asyncM() { return 5; }\n  *gen() { yield 6; }\n  #priv() { return 8; }\n  static async sasync() { return 9; }\n  [k]() { return 10; }\n}\nnew A().plain();\n`,
  "class accessors and static": `class A {\n  get p() {\n    return 1;\n  }\n  set p(v) {\n    void v;\n  }\n  static s() {\n    return 2;\n  }\n}\nvoid new A().p;\n`,
  "object methods": `const o = {\n  shorthand() {\n    return 1;\n  },\n  named: function named() {\n    return 2;\n  },\n  arrow: () => 3,\n};\no.shorthand();\n`,
  "getter in object literal": `const o = {\n  get p() {\n    return 1;\n  },\n};\nvoid o.p;\n`,
  "anonymous functions": `const a = function () {\n  return 1;\n};\nconst b = () => 2;\nsetTimeout(function () {\n  return 3;\n}, 0);\na();\nb();\n`,
  "generator and async": `async function a() {\n  return 1;\n}\nfunction* g() {\n  yield 1;\n}\na();\n[...g()];\n`,
  "try catch finally": `function f(fail) {\n  try {\n    if (fail) {\n      throw new Error("x");\n    }\n    return "ok";\n  } catch {\n    return "caught";\n  } finally {\n    void 0;\n  }\n}\nf(false);\n`,
  "for in and of": `function f(o) {\n  for (const k in o) {\n    void k;\n  }\n  for (const v of [1]) {\n    void v;\n  }\n}\nf({ a: 1 });\n`,
  "sequence expression": `function f() {\n  let a = (1, 2);\n  return a;\n}\nf();\n`,
  "iife": `(function () {\n  return 1;\n})();\n`,
  // istanbul misses this one entirely -- see the FNF deviation below.
  "private method": `class A {\n  pub() { return 1; }\n  #priv() { return 2; }\n  usePriv() { return this.#priv(); }\n}\nnew A().pub();\n`,
};

// Every accepted difference from instrumented execution, with its reason. One
// outside this list fails; one that stops happening is reported for deletion.
const DEVIATIONS = [
  {
    kind: "FN-name",
    cases: "*",
    why:
      "istanbul names a method `(anonymous_N)`: its visitor reads `node.id?.name ?? node.name` " +
      "(istanbul-lib-instrument/src/visitor.js:380) and a babel method node carries neither -- " +
      "the name is in `.key`. That is a consequence of the node shape, not a decision, and it " +
      "changes no count: FNF, FNH and every FNDA are compared strictly above and must still " +
      "agree. zcov uses the name, which is what V8 puts in `functionName` and what **c8** " +
      "emits -- `FN:2,pub FN:3,#priv FN:4,usePriv`, byte for byte what zcov emits for the " +
      "same input. So this follows the tool zcov replaces and differs only from istanbul.",
  },
  {
    kind: "FNF",
    cases: ["every method shape", "private method"],
    why:
      "istanbul does not count a **private** method as a function at all: its visitor registers " +
      "`ClassMethod` and `ObjectMethod` (visitor.js:638,642) and babel parses `#m() {}` as " +
      "`ClassPrivateMethod`, which is not in the list. Measured on `class A { pub() {} #priv() " +
      "{} usePriv() {} }`: zcov FNF 3, c8 FNF 3, ast-v8-to-istanbul FNF 3, nyc FNF **2**. " +
      "Three of the four count it and istanbul is alone, so this is a gap in istanbul rather " +
      "than a deviation worth copying -- and a private method that is never called is exactly " +
      "the kind of dead code a coverage report exists to show. The cost is that FNF and the " +
      "function percentage are higher than nyc's for a class with private methods.",
  },
  {
    kind: "FNDA",
    cases: ["every method shape", "private method"],
    why: "Same private-method gap as the FNF entry above: the extra function shifts the list.",
  },
  {
    kind: "BRDA",
    cases: ["default arg used and skipped", "default arg destructured", "default arg arrow"],
    why:
      "V8 emits ranges only for code that did *not* run, so a default parameter that was used " +
      "leaves no trace at all. zcov reports not-taken where a zero range proves it was " +
      "skipped and omits the branch otherwise, rather than claiming either way. c8 and " +
      "ast-v8-to-istanbul report taken, which is a fabrication -- checked below, and it is " +
      "their single largest source of branch false positives.",
  },
];

const parse = (file, want) => {
  const out = { lines: new Map(), fns: [], fnNames: [], brs: new Map(), fnf: null, fnh: null };
  let on = false, pending = [], seen = 0;
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    if (l.startsWith("SF:")) { on = l.slice(3).endsWith(want); pending = []; seen = 0; }
    else if (!on) continue;
    else if (l.startsWith("DA:")) { const [a, b] = l.slice(3).split(","); out.lines.set(+a, +b); }
    else if (l.startsWith("FN:")) pending.push(+l.slice(3).split(",")[0]);
    else if (l.startsWith("FNDA:")) {
      const [c, name] = l.slice(5).split(",");
      out.fns.push(`${pending[seen]}=${c}`);
      out.fnNames.push(`${pending[seen]},${name}`);
      seen++;
    } else if (l.startsWith("FNF:")) out.fnf = +l.slice(4);
    else if (l.startsWith("FNH:")) out.fnh = +l.slice(4);
    else if (l.startsWith("BRDA:")) {
      const [line, blk, , c] = l.slice(5).split(",");
      if (!out.brs.has(+line)) out.brs.set(+line, []);
      out.brs.get(+line).push(`${blk}:${c}`);
    }
  }
  return out;
};

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zcov-model-")));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));

const declared = (kind, name) =>
  DEVIATIONS.find((d) => d.kind === kind && (d.cases === "*" || d.cases.includes(name)));

let failures = 0, checked = 0, skipped = 0;
const used = new Set();
const refWrong = [];

for (const [name, code] of Object.entries(CASES)) {
  if (only && !name.includes(only)) continue;
  const dir = path.join(root, name.replace(/\W+/g, "_"));
  const cov = path.join(dir, "cov");
  fs.mkdirSync(cov, { recursive: true });
  const file = "case.js";
  fs.writeFileSync(path.join(dir, file), code);

  const run = (fn, label) => {
    try { fn(); return true; } catch (e) {
      console.log(`  FAIL  ${name}\n          ${label}: ${(e.message || "").split("\n")[0].slice(0, 70)}`);
      failures++;
      return false;
    }
  };
  if (!run(() => execFileSync(process.execPath, [file], {
    cwd: dir, env: { ...process.env, NODE_V8_COVERAGE: cov }, stdio: "ignore", timeout: 20000,
  }), "running the case")) continue;
  if (!run(() => execFileSync(ZCOV, [
    "report", "-d", cov, "--cwd", dir, "--threads", "1", "-r", "lcov", "-o", "z",
  ], { cwd: dir, stdio: "ignore", timeout: 20000 }), "zcov")) continue;
  if (!run(() => execFileSync(process.execPath, [NYC,
    "-r", "lcovonly", "--report-dir", "n", process.execPath, file,
  ], { cwd: dir, stdio: "ignore", timeout: 60000 }), "nyc")) continue;

  const zig = parse(path.join(dir, "z", "lcov.info"), file);
  const truth = parse(path.join(dir, "n", "lcov.info"), file);
  if (truth.lines.size === 0) {
    console.log(`  skip  ${name}  (nyc produced no record for it)`);
    skipped++;
    continue;
  }
  // The other V8 engine, for information only: where it disagrees with
  // instrumentation and zcov does not, zcov is ahead and it is worth saying.
  let ref = null;
  try {
    execFileSync(process.execPath, [ENGINE, cov, dir, path.join(dir, "ve")], { stdio: "ignore", timeout: 20000 });
    ref = parse(path.join(dir, "ve", "lcov.info"), file);
  } catch {}

  const problems = [];
  const note = (kind, detail) => {
    const d = declared(kind, name);
    if (d) { used.add(d); if (verbose) console.log(`  ok    ${name}\n          declared ${kind}: ${detail}`); return; }
    problems.push(`${kind}: ${detail}`);
  };

  // Lines: the full key set, so a statement on the wrong line shows up as both
  // an extra and a missing one rather than being skipped.
  for (const ln of [...new Set([...zig.lines.keys(), ...truth.lines.keys()])].sort((a, b) => a - b)) {
    const z = zig.lines.get(ln), t = truth.lines.get(ln);
    if (z === t) continue;
    if (z === undefined) note("DA", `line ${ln} not reported, instrumented says ${t}`);
    else if (t === undefined) note("DA", `line ${ln} reported as ${z}, istanbul does not count it`);
    else note("DA", `line ${ln}: zcov ${z}, instrumented ${t}`);
  }
  // Functions by position: line and count, which is everything but the name.
  if (zig.fns.join("|") !== truth.fns.join("|")) {
    note("FNDA", `zcov [${zig.fns.join(" ")}] instrumented [${truth.fns.join(" ")}]`);
  }
  if (zig.fnf !== truth.fnf || zig.fnh !== truth.fnh) {
    note("FNF", `zcov ${zig.fnf}/${zig.fnh}, instrumented ${truth.fnf}/${truth.fnh}`);
  }
  if (zig.fnNames.join("|") !== truth.fnNames.join("|")) {
    note("FN-name", `zcov [${zig.fnNames.join(" ")}] instrumented [${truth.fnNames.join(" ")}]`);
  }
  for (const ln of [...new Set([...zig.brs.keys(), ...truth.brs.keys()])].sort((a, b) => a - b)) {
    const z = JSON.stringify(zig.brs.get(ln) ?? null), t = JSON.stringify(truth.brs.get(ln) ?? null);
    if (z === t) continue;
    note("BRDA", `line ${ln}: zcov ${z}, instrumented ${t}`);
  }

  if (ref) {
    const bad = [];
    for (const ln of truth.lines.keys()) {
      const r = ref.lines.get(ln), t = truth.lines.get(ln);
      if (r !== undefined && r > 0 !== t > 0) bad.push(`line ${ln}`);
    }
    if (ref.fns.join("|") !== truth.fns.join("|")) bad.push("function counts");
    if (bad.length) refWrong.push(`${name}: ${bad.join(", ")}`);
  }

  checked++;
  if (problems.length) {
    failures++;
    console.log(`  FAIL  ${name}`);
    code.split("\n").forEach((l, i) => console.log(`          ${String(i + 1).padStart(3)}| ${l}`));
    problems.forEach((p) => console.log(`          ${p}`));
  } else if (!verbose) {
    console.log(`  ok    ${name}`);
  }
}

console.log(`\n  ${checked} constructs checked against instrumented execution, ${failures} failing${skipped ? `, ${skipped} skipped` : ""}`);
for (const d of DEVIATIONS) {
  if (used.has(d)) continue;
  console.log(`\n  STALE deviation (${d.kind}) no longer happens - delete it:\n    ${d.why.slice(0, 100)}...`);
  failures++;
}
if (refWrong.length) {
  console.log(`\n  where ast-v8-to-istanbul disagrees with instrumentation and zcov does not:`);
  for (const r of refWrong) console.log(`    ${r}`);
}
process.exitCode = failures ? 1 : 0;
