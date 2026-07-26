// Scenarios the istanbul corpus does not cover: shebangs, CRLF, minified maps,
// merged processes. No published expectation, so diffed against the reference.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ZCOV = path.join(HERE, "..", "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");

// Report an existing dump directory, single-threaded so output is comparable.
const zcovArgs = (covDir, dir) => [
  "report", "-d", covDir, "--cwd", dir, "--threads", "1", "-r", "lcov", "-o", "report",
];
const { parseSync } = await import("oxc-parser");
const { mergeProcessCovs } = await import("@bcoe/v8-coverage");
const { default: convert } = await import("ast-v8-to-istanbul");

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zcov-scen-")));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));

/** @type {{name:string, files:Record<string,string>, entry:string, runs?:number}[]} */
const SCENARIOS = [
  {
    name: "shebang",
    entry: "main.js",
    files: {
      "main.js": `#!/usr/bin/env node\nfunction used() {\n  return 1;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`,
    },
  },
  {
    name: "CRLF line endings",
    entry: "main.js",
    files: {
      "main.js": "function used() {\r\n  return 1;\r\n}\r\nfunction unused() {\r\n  return 2;\r\n}\r\nused();\r\n",
    },
  },
  {
    name: "mixed newlines",
    entry: "main.js",
    files: {
      "main.js": "function used() {\r\n  return 1;\n}\r\nfunction unused() {\n  return 2;\r\n}\nused();\n",
    },
  },
  {
    name: "non-ascii before code",
    entry: "main.js",
    files: {
      "main.js": `const banner = "┏━━━━━━━━━━┓";\nfunction used() {\n  return banner;\n}\nfunction unused() {\n  return 2;\n}\nused();\n`,
    },
  },
  {
    name: "async await",
    entry: "main.js",
    files: {
      "main.js": `async function run(n) {\n  if (n > 0) {\n    return await Promise.resolve(n);\n  }\n  return 0;\n}\nrun(1);\n`,
    },
  },
  {
    name: "generator",
    entry: "main.js",
    files: {
      "main.js": `function* gen() {\n  yield 1;\n  yield 2;\n}\nfor (const v of gen()) {\n  void v;\n}\n`,
    },
  },
  {
    name: "class private + accessors",
    entry: "main.js",
    files: {
      "main.js": `class A {\n  #x = 1;\n  get x() {\n    return this.#x;\n  }\n  set x(v) {\n    this.#x = v;\n  }\n  #hidden() {\n    return 2;\n  }\n}\nconst a = new A();\nvoid a.x;\n`,
    },
  },
  {
    name: "optional chaining and nullish",
    entry: "main.js",
    files: {
      "main.js": `const o = { a: { b: 1 } };\nconst v = o?.a?.b ?? 5;\nconst w = o?.z?.b ?? 6;\nvoid v;\nvoid w;\n`,
    },
  },
  {
    name: "logical chains",
    entry: "main.js",
    files: {
      "main.js": `const a = 1, b = 0, c = 3;\nconst x = a || b || c;\nconst y = b && a && c;\nconst z = null ?? b ?? a;\nvoid [x, y, z];\n`,
    },
  },
  {
    name: "ternary, incl. nested and parenthesised",
    entry: "main.js",
    files: {
      "main.js": `const n = 2;\nconst a = n > 1 ? "big" : "small";\nconst b = n > 5 ? "x" : n > 1 ? "mid" : "y";\nconst c = n ? (1) : (2);\nvoid [a, b, c];\n`,
    },
  },
  {
    name: "switch with default",
    entry: "main.js",
    files: {
      "main.js": `function pick(n) {\n  switch (n) {\n    case 1:\n      return "one";\n    case 2:\n      return "two";\n    default:\n      return "other";\n  }\n}\npick(1);\npick(9);\n`,
    },
  },
  {
    name: "default parameters",
    entry: "main.js",
    files: {
      "main.js": `function f(a = 1, b = 2) {\n  return a + b;\n}\nf(5);\nconst g = (x = 3) => x;\ng();\n`,
    },
  },
  {
    name: "class and object methods",
    entry: "main.js",
    files: {
      "main.js": `class A {\n  constructor() {\n    this.v = 1;\n  }\n  method() {\n    return this.v;\n  }\n  get prop() {\n    return 2;\n  }\n  static stat() {\n    return 3;\n  }\n}\nconst o = {\n  shorthand() {\n    return 1;\n  },\n  value: function named() {\n    return 2;\n  },\n  arrow: () => 3,\n};\nconst a = new A();\na.method();\nvoid a.prop;\no.shorthand();\n`,
    },
  },
  {
    name: "try catch finally",
    entry: "main.js",
    files: {
      "main.js": `function run(fail) {\n  try {\n    if (fail) {\n      throw new Error("x");\n    }\n    return "ok";\n  } catch {\n    return "caught";\n  } finally {\n    void 0;\n  }\n}\nrun(false);\n`,
    },
  },
  {
    name: "ignore hints: next, if, else",
    entry: "main.js",
    files: {
      "main.js": `function used(n) {\n  /* c8 ignore next */\n  if (n < 0) return "neg";\n  /* c8 ignore if */\n  if (n === 99) {\n    return "ninety-nine";\n  }\n  /* c8 ignore else */\n  if (n > 0) {\n    return "pos";\n  } else {\n    return "zero";\n  }\n}\nused(1);\n`,
    },
  },
  {
    name: "ignore hints: whole file",
    entry: "main.js",
    files: {
      "main.js": `/* c8 ignore file */\nfunction unused() {\n  return 1;\n}\nvoid unused;\n`,
    },
  },
  {
    name: "coverage merged across two processes",
    entry: "main.js",
    runs: 2,
    files: {
      "main.js": `function pick(n) {\n  if (n > 0) {\n    return "pos";\n  }\n  return "other";\n}\npick(Number(process.env.N || "0"));\n`,
    },
    env: [{ N: "1" }, { N: "-1" }],
  },
];

function collect(dir, entry, envs) {
  const covDir = path.join(dir, "cov");
  fs.mkdirSync(covDir, { recursive: true });
  for (const env of envs) {
    execFileSync(process.execPath, [path.join(dir, entry)], {
      env: { ...process.env, ...env, NODE_V8_COVERAGE: covDir },
      stdio: "ignore",
      timeout: 20000,
    });
  }
  return covDir;
}

function zcovReport(covDir, dir, entry) {
  const lcov = path.join(dir, "report", "lcov.info");
  execFileSync(ZCOV, zcovArgs(covDir, dir), { stdio: "ignore" });
  const lines = new Map();
  const fns = [];
  const brs = [];
  let cur = null;
  let pendingFns = [];
  for (const l of fs.readFileSync(lcov, "utf8").split("\n")) {
    if (l.startsWith("SF:")) {
      cur = l.slice(3);
      pendingFns = [];
      continue;
    }
    if (!cur || !cur.endsWith(entry)) continue;
    if (l.startsWith("DA:")) {
      const [a, b] = l.slice(3).split(",");
      lines.set(+a, +b);
    } else if (l.startsWith("FN:")) {
      pendingFns.push(+l.slice(3).split(",")[0]);
    } else if (l.startsWith("FNDA:")) {
      // FN and FNDA are emitted in the same order.
      fns.push([pendingFns[fns.length], +l.slice(5).split(",")[0]]);
    } else if (l.startsWith("BRDA:")) {
      const [line, , , count] = l.slice(5).split(",");
      brs.push([+line, +count]);
    }
  }
  return { lines, fns, brs };
}

async function referenceReport(covDir, dir, entry) {
  const file = path.join(dir, entry);
  const entries = [];
  for (const f of fs.readdirSync(covDir)) {
    const j = JSON.parse(fs.readFileSync(path.join(covDir, f), "utf8"));
    for (const e of j.result || []) {
      if (!e.url) continue;
      let p;
      try {
        p = e.url.startsWith("file:") ? fileURLToPath(e.url) : e.url;
      } catch {
        continue;
      }
      if (p === file) entries.push(e);
    }
  }
  if (!entries.length) return { lines: new Map(), fns: [], brs: [] };
  const merged = mergeProcessCovs(entries.map((e) => ({ result: [{ ...e, url: "file:///x" }] }))).result[0];
  const code = fs.readFileSync(file, "utf8");
  const { program } = parseSync(file, code, { experimentalRawTransfer: true });
  const out = await convert({
    ast: program,
    code,
    wrapperLength: 0,
    coverage: { url: pathToFileURL(file).href, functions: merged.functions },
  });
  // `ignore file` makes the reference return no entry for the file at all.
  const cov = out[file];
  if (!cov) return { lines: new Map(), fns: [], brs: [] };
  const lines = new Map();
  for (const [k, st] of Object.entries(cov.statementMap)) {
    const l = st.start.line;
    lines.set(l, Math.max(lines.get(l) ?? 0, cov.s[k]));
  }
  const fns = Object.entries(cov.fnMap).map(([k, m]) => [(m.decl || m.loc).start.line, cov.f[k]]);
  const brs = [];
  for (const [k, m] of Object.entries(cov.branchMap)) {
    cov.b[k].forEach((count) => brs.push([m.loc.start.line, count]));
  }
  return { lines, fns, brs };
}

// The two number functions and branches differently, so (line, count) pairs are
// compared as multisets rather than pretending the ids line up.
function diffPairs(label, mine, theirs) {
  const key = (p) => `${p[0]}:${p[1]}`;
  const tally = (list) => {
    const m = new Map();
    for (const p of list) m.set(key(p), (m.get(key(p)) ?? 0) + 1);
    return m;
  };
  const a = tally(mine);
  const b = tally(theirs);
  const out = [];
  for (const k of new Set([...a.keys(), ...b.keys()])) {
    const x = a.get(k) ?? 0;
    const y = b.get(k) ?? 0;
    if (x === y) continue;
    const [line, count] = k.split(":");
    out.push(`${label} line ${line} count ${count}: zcov x${x} reference x${y}`);
  }
  return out;
}

let differing = 0;
for (const [i, s] of SCENARIOS.entries()) {
  const dir = path.join(root, "s" + i);
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, content] of Object.entries(s.files)) {
    fs.writeFileSync(path.join(dir, name), content);
  }
  const envs = s.env ?? [{}];
  let covDir;
  try {
    covDir = collect(dir, s.entry, envs);
  } catch (e) {
    console.log(`  ${s.name.padEnd(38)} RUN FAILED: ${(e.message || "").slice(0, 50)}`);
    continue;
  }
  const zig = zcovReport(covDir, dir, s.entry);
  const ref = await referenceReport(covDir, dir, s.entry);
  const all = [...new Set([...zig.lines.keys(), ...ref.lines.keys()])].sort((a, b) => a - b);
  const diffs = [];
  for (const ln of all) {
    const z = zig.lines.get(ln);
    const r = ref.lines.get(ln);
    if (z === r) continue;
    const zv = z === undefined ? "-" : z;
    const rv = r === undefined ? "-" : r;
    const verdict = (z > 0) === (r > 0) && z !== undefined && r !== undefined;
    diffs.push(`line ${ln}: zcov=${zv} reference=${rv}${verdict ? " (same verdict)" : ""}`);
  }
  diffs.push(...diffPairs("fn", zig.fns, ref.fns));
  diffs.push(...diffPairs("branch", zig.brs, ref.brs));
  if (diffs.length) differing++;
  console.log(`  ${s.name.padEnd(38)} ${diffs.length ? diffs.length + " difference(s)" : "match"}`);
  for (const d of diffs) console.log(`      ${d}`);
}
console.log(`\n  ${SCENARIOS.length} scenarios, ${differing} with differences`);
