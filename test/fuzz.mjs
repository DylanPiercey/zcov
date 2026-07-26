// Differential fuzzing: random programs run under nyc, which instruments, and
// under zcov, which infers, with every line required to agree.
//
//   node test/fuzz.mjs              # default seeds
//   node test/fuzz.mjs 7            # one seed, for reproducing a failure
//   node test/fuzz.mjs 1 --keep     # leave the generated program on disk
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

const args = process.argv.slice(2);
const keep = args.includes("--keep");
// The same random programs bundled through esbuild, so the remapping path gets
// fuzzed too rather than only the fixed corpora.
const bundled = args.includes("--bundled");
const explicit = args.filter((a) => /^\d+$/.test(a)).map(Number);
const SEEDS = explicit.length ? explicit : [1, 2, 3, 4, 5, 6, 7, 8];
const MODULES = 25;

if (!fs.existsSync(NYC)) {
  console.log("  skipped: nyc is not installed");
  process.exit(0);
}

// Deterministic PRNG so a failing seed reproduces exactly.
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5;
    s >>>= 0;
    return s / 0x100000000;
  };
}

let uid = 0;
function generate(rand, depth = 0) {
  const pick = (...xs) => xs[Math.floor(rand() * xs.length)];
  const num = () => Math.floor(rand() * 5);
  const cond = () => pick("a > b", "a === b", "a < b", "!a", "a && b", "a || b", "a > 2 && b < 3");
  const ind = "  ".repeat(depth + 1);

  const stmt = () => {
    if (depth > 2) return `${ind}total += ${num()};`;
    switch (
      pick("if", "ifelse", "for", "while", "switch", "try", "ret", "expr", "decl", "ternary",
           "arrow", "dowhile", "forof", "labeled", "logical", "optional", "destructure",
           "nested", "throwcatch")
    ) {
      case "if":
        return `${ind}if (${cond()}) {\n${generate(rand, depth + 1)}\n${ind}}`;
      case "ifelse":
        return `${ind}if (${cond()}) {\n${generate(rand, depth + 1)}\n${ind}} else {\n${generate(rand, depth + 1)}\n${ind}}`;
      case "for":
        const iv = `i${uid++}`;
        return `${ind}for (let ${iv} = 0; ${iv} < ${num()}; ${iv}++) {\n${generate(rand, depth + 1)}\n${ind}}`;
      case "while":
        const w = `w${uid++}`;
        return `${ind}let ${w} = ${num()};\n${ind}while (${w} > 0) {\n${ind}  ${w}--;\n${generate(rand, depth + 1)}\n${ind}}`;
      case "dowhile":
        const d = `d${uid++}`;
        return `${ind}let ${d} = ${num()};\n${ind}do {\n${ind}  ${d}--;\n${ind}} while (${d} > 0);`;
      case "switch":
        return (
          `${ind}switch (a % 3) {\n` +
          `${ind}  case 0:\n${generate(rand, depth + 2)}\n${ind}    break;\n` +
          `${ind}  case 1:\n${generate(rand, depth + 2)}\n${ind}    break;\n` +
          `${ind}  default:\n${generate(rand, depth + 2)}\n${ind}}`
        );
      case "try":
        return (
          `${ind}try {\n${generate(rand, depth + 1)}\n` +
          `${ind}} catch (e) {\n${ind}  total -= 1;\n${ind}} finally {\n${ind}  total += 0;\n${ind}}`
        );
      case "ret":
        return `${ind}if (${cond()}) {\n${ind}  return total;\n${ind}}`;
      case "ternary":
        return `${ind}total += ${cond()} ? ${num()} : ${num()};`;
      case "arrow":
        const fv = `f${uid++}`;
        return `${ind}const ${fv} = (x = ${num()}) =>\n${ind}  x + ${num()};\n${ind}total += ${fv}(${num()});`;
      case "decl":
        const vv = `v${uid++}`;
        return `${ind}const ${vv} =\n${ind}  ${cond()} ? ${num()} : ${num()};\n${ind}total += ${vv};`;
      case "forof":
        return `${ind}for (const el${uid++} of [${num()}, ${num()}]) {\n${generate(rand, depth + 1)}\n${ind}}`;
      case "labeled": {
        const lb = `L${uid++}`;
        return (
          `${ind}${lb}: for (let k = 0; k < 2; k++) {\n` +
          `${ind}  if (${cond()}) { ${pick("break", "continue")} ${lb}; }\n` +
          `${generate(rand, depth + 1)}\n${ind}}`
        );
      }
      case "logical": {
        const v = `g${uid++}`;
        return `${ind}const ${v} = ${cond()} && (a ?? b) || ${num()};\n${ind}total += ${v} ? 1 : 0;`;
      }
      case "optional": {
        const v = `o${uid++}`;
        return `${ind}const ${v} = { p: { q: ${num()} } };\n${ind}total += ${v}?.p?.q ?? ${num()};`;
      }
      case "destructure": {
        const v = `d${uid++}`;
        return `${ind}const { x: ${v} = ${num()} } = ${cond()} ? {} : { x: ${num()} };\n${ind}total += ${v};`;
      }
      case "nested": {
        const f = `n${uid++}`;
        return (
          `${ind}function ${f}(p) {\n${ind}  if (p) {\n${ind}    return p * 2;\n${ind}  }\n${ind}  return 0;\n${ind}}\n` +
          `${ind}total += ${f}(${num()});`
        );
      }
      case "throwcatch":
        return (
          `${ind}try {\n${ind}  if (${cond()}) { throw new Error("e"); }\n${generate(rand, depth + 1)}\n` +
          `${ind}} catch (e) {\n${ind}  total += 1;\n${ind}}`
        );
      default:
        return `${ind}total += ${num()};`;
    }
  };
  return Array.from({ length: 2 + Math.floor(rand() * 3) }, stmt).join("\n");
}

function build(dir, seed) {
  const rand = rng(seed);
  uid = 0;
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  for (let i = 0; i < MODULES; i++) {
    const body = Array.from(
      { length: 3 },
      (_, f) => `function fn${f}(a, b) {\n  let total = 0;\n${generate(rand)}\n  return total;\n}\n`,
    ).join("\n");
    fs.writeFileSync(
      path.join(dir, "src", `m${i}.js`),
      `${body}\nmodule.exports = { fn0, fn1, fn2 };\n`,
    );
  }
  // Only some modules load, and each is called with a few argument shapes, so
  // there is a mix of covered, partly covered and untouched code.
  fs.writeFileSync(
    path.join(dir, "entry.js"),
    `const pairs = [[0,0],[1,0],[3,2],[2,2]];\n` +
      `for (let i = 0; i < ${MODULES - 5}; i++) {\n` +
      `  const m = require("./src/m" + i + ".js");\n` +
      `  for (const [a, b] of pairs) {\n` +
      `    for (const k of ["fn0", "fn1", "fn2"]) { try { m[k](a, b); } catch {} }\n` +
      `  }\n}\n`,
  );
}

// Each tool writes SF: differently, so keys are normalised to the path from the
// fixture root. Otherwise a comparison matches nothing and reports agreement.
const normalize = (raw) => {
  const p = raw.split("\\").join("/");
  const at = p.lastIndexOf("src/");
  if (at >= 0) return p.slice(at);
  return path.basename(p);
};

// Functions and branches, per line. Comparing counts per line rather than by id
// sidesteps the two tools numbering them differently.
const readFnBr = (file) => {
  const fns = new Map(), brs = new Map();
  let cur = null, pend = [], seen = 0;
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    if (l.startsWith("SF:")) { cur = normalize(l.slice(3)); pend = []; seen = 0; }
    else if (!cur) continue;
    else if (l.startsWith("FN:")) pend.push(+l.slice(3).split(",")[0]);
    else if (l.startsWith("FNDA:")) {
      const k = cur + ":" + pend[seen++];
      fns.set(k, (fns.get(k) ?? 0) + +l.slice(5).split(",")[0]);
    } else if (l.startsWith("BRDA:")) {
      const [line, , , count] = l.slice(5).split(",");
      const k = cur + ":" + line;
      if (!brs.has(k)) brs.set(k, []);
      brs.get(k).push(count === "-" ? 0 : +count);
    }
  }
  return { fns, brs };
};

const readDA = (file) => {
  const out = new Map();
  let cur = null;
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    if (l.startsWith("SF:")) cur = normalize(l.slice(3));
    else if (cur && l.startsWith("DA:")) {
      const [a, b] = l.slice(3).split(",");
      out.set(cur + ":" + a, +b);
    }
  }
  return out;
};

// Compared in aggregate rather than per seed: a rule that helps on most inputs
// can cost a line on one, and what matters is the overall standing.
let failures = 0;
// Reporting untested code as covered hides risk; the opposite error only wastes
// a reader's time. So this one is checked absolutely, not against another tool.
let phantoms = 0;
let brPhantoms = 0;
let mine = 0;
let theirs = 0;
let judged = 0;
for (const seed of SEEDS) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `zcov-fuzz-${seed}-`)));
  try {
    build(dir, seed);
    execFileSync(process.execPath, [NYC, "-r", "lcovonly", "--report-dir", "n", process.execPath, "entry.js"], {
      cwd: dir,
      stdio: "ignore",
      timeout: 120000,
    });
    let target = "entry.js";
    if (bundled) {
      req("esbuild").buildSync({
        entryPoints: [path.join(dir, "entry.js")],
        bundle: true,
        platform: "node",
        sourcemap: true,
        outfile: path.join(dir, "bundle.js"),
      });
      target = "bundle.js";
    }
    execFileSync(ZCOV, ["--no-all", "-r", "lcov", "-o", "z", "--", process.execPath, target], {
      cwd: dir,
      stdio: "ignore",
      timeout: 120000,
    });
    // The same dumps through the reference V8 engine, as a yardstick: some
    // disagreements are V8's own, so the bar is being no worse than it.
    fs.mkdirSync(path.join(dir, "v8dump"), { recursive: true });
    execFileSync(process.execPath, [target], {
      cwd: dir,
      env: { ...process.env, NODE_V8_COVERAGE: path.join(dir, "v8dump") },
      stdio: "ignore",
    });
    let refDiffs = null;
    try {
      execFileSync(process.execPath, [path.join(ROOT, "tools", "vitest-engine.mjs"), path.join(dir, "v8dump"), dir, path.join(dir, "ve")], {
        stdio: "ignore",
        timeout: 120000,
      });
      refDiffs = 0;
      const ref = readDA(path.join(dir, "ve", "lcov.info"));
      for (const [k, want] of readDA(path.join(dir, "n", "lcov.info"))) {
        if (ref.has(k) && want > 0 !== ref.get(k) > 0) refDiffs++;
      }
    } catch {}

    const truth = readDA(path.join(dir, "n", "lcov.info"));
    const got = readDA(path.join(dir, "z", "lcov.info"));

    const diffs = [];
    for (const [k, want] of truth) {
      if (!got.has(k)) continue; // a line zcov does not model is a separate concern
      const have = got.get(k);
      if (want > 0 !== have > 0) {
        const [file, line] = k.split(":");
        const src = (fs.readFileSync(path.join(dir, file), "utf8").split("\n")[+line - 1] || "").trim();
        diffs.push(
          `${k}: instrumented=${want} zcov=${have}  ${want > 0 ? "MISSED" : "PHANTOM"}  ${src.slice(0, 44)}`,
        );
      }
    }
    // Functions and branches held to the same standard as lines.
    const ty = readFnBr(path.join(dir, "n", "lcov.info"));
    const tz = readFnBr(path.join(dir, "z", "lcov.info"));
    for (const [k, v] of ty.fns) {
      if (!tz.fns.has(k)) continue;
      const h = tz.fns.get(k);
      if (v > 0 === h > 0) continue;
      if (h > 0) { phantoms++; diffs.push(`${k}: function PHANTOM instrumented=${v} zcov=${h}`); }
      else diffs.push(`${k}: function MISSED instrumented=${v} zcov=${h}`);
    }
    for (const [k, v] of ty.brs) {
      if (!tz.brs.has(k)) continue;
      const h = tz.brs.get(k);
      if (v.length !== h.length) continue;
      const vt = v.filter((x) => x > 0).length, ht = h.filter((x) => x > 0).length;
      if (vt === ht) continue;
      // Counted apart from lines only so a failure says which it was; both are
      // held at zero.
      if (ht > vt) { brPhantoms++; diffs.push(`${k}: branch PHANTOM instrumented ${vt} taken, zcov ${ht}`); }
      else diffs.push(`${k}: branch MISSED instrumented ${vt} taken, zcov ${ht}`);
    }

    const bar = refDiffs ?? 0;
    phantoms += diffs.filter((d) => d.includes("PHANTOM") && !d.includes("function PHANTOM") && !d.includes("branch PHANTOM")).length;
    mine += diffs.length;
    theirs += bar;
    judged += truth.size;
    const flag = diffs.length > bar ? "  (above the reference on this seed)" : "";
    console.log(`  seed ${seed}: ${truth.size} lines, zcov ${diffs.length}, reference ${bar}${flag}`);
    if (diffs.length > bar) for (const d of diffs.slice(0, 4)) console.log(`          ${d}`);
  } catch (e) {
    failures++;
    console.log(`  ERROR seed ${seed}: ${(e.message || "").split("\n")[0].slice(0, 70)}`);
  } finally {
    if (!keep) fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Not a tolerance: lines, functions and branches must all be zero. Widening the
// grammar is how the remaining ones get found, so keep adding shapes.
if (mine > theirs) failures++;
if (phantoms > 0) failures++;
if (brPhantoms > 0) failures++;
console.log(
  `\n  ${SEEDS.length} seeds${bundled ? " (bundled)" : ""}, ${judged} lines judged:` +
    ` zcov ${mine} disagreements, reference engine ${theirs}` +
    `\n  lines and functions reported as covered that never ran: ${phantoms}` +
    `\n  branches reported as taken that were not: ${brPhantoms}`,
);
if (phantoms > 0) console.log("  FAIL - lines or functions reported as covered that never ran");
else if (brPhantoms > 0) console.log("  FAIL - branches reported as taken that were not");
else if (mine > theirs) console.log("  FAIL - zcov is behind the reference");
else console.log("  ok - no false positives, and not behind the reference");
process.exitCode = failures ? 1 : 0;
