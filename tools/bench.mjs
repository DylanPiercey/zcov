// Generates a workload and times zcov against the alternatives on it. The
// fixture is CommonJS: the one format all three handle without extra flags.
//
//   node tools/bench.mjs [moduleCount]
import { execFileSync, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const ZCOV = path.join(ROOT, "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");
const N = Number(process.argv[2] || 400);
const dir = path.join(os.tmpdir(), "zcov-bench");

function generate() {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  for (let i = 0; i < N; i++) {
    const fns = [];
    for (let f = 0; f < 12; f++) {
      fns.push(`
function fn${f}(a, b) {
  const scale = a || b || 1;
  if (a > b) {
    return a * scale;
  } else if (a === b) {
    return ${f} + scale;
  }
  let total = 0;
  for (let i = 0; i < b; i++) {
    total += i % ${f + 2} ? i : -i;
  }
  switch (total % 3) {
    case 0: return total;
    case 1: return total + 1;
    default: return a ? total - 1 : scale;
  }
}
const arrow${f} = (x = ${f}) => x * 2;
`);
    }
    fs.writeFileSync(
      path.join(dir, "src", `mod${i}.js`),
      `${fns.join("")}\nmodule.exports = { ${Array.from({ length: 12 }, (_, f) => `fn${f}, arrow${f}`).join(", ")} };\n`,
    );
  }
  // Half the modules run, so there is real uncovered code to account for.
  fs.writeFileSync(
    path.join(dir, "entry.js"),
    `for (let i = 0; i < ${Math.floor(N / 2)}; i++) {\n` +
      `  const m = require("./src/mod" + i + ".js");\n` +
      `  for (let f = 0; f < 12; f++) {\n` +
      `    m["fn" + f](i % 7, i % 5);\n    m["arrow" + f](i);\n  }\n}\n`,
  );
  const lines = fs
    .readdirSync(path.join(dir, "src"))
    .reduce((n, f) => n + fs.readFileSync(path.join(dir, "src", f), "utf8").split("\n").length, 0);
  return lines;
}

function measure(label, argv, env = {}) {
  const runs = [];
  for (let i = 0; i < 5; i++) {
    const t = process.hrtime.bigint();
    const r = spawnSync("/usr/bin/time", ["-f", "%e %U %S %M", ...argv], {
      cwd: dir,
      env: { ...process.env, ...env },
      encoding: "utf8",
    });
    const wall = Number(process.hrtime.bigint() - t) / 1e9;
    const last = (r.stderr || "").trim().split("\n").pop().trim().split(/\s+/);
    runs.push({ wall, cpu: Number(last[1]) + Number(last[2]), rss: Number(last[3]) / 1024 });
  }
  runs.sort((a, b) => a.wall - b.wall);
  const m = runs[Math.floor(runs.length / 2)];
  return { label, wall: m.wall, cpu: m.cpu, rss: Math.max(...runs.map((r) => r.rss)) };
}

function lcovTotals(file) {
  if (!fs.existsSync(file)) return null;
  let lf = 0, lh = 0;
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    if (l.startsWith("LF:")) lf += +l.slice(3);
    else if (l.startsWith("LH:")) lh += +l.slice(3);
  }
  return { lf, lh, pct: ((100 * lh) / lf).toFixed(2) };
}

const lines = generate();
console.log(`  workload: ${N} modules, ~${lines.toLocaleString()} lines, half executed\n`);

// The `.bin` shims are `.cmd` files on Windows, which Node will not spawn
// without a shell. Resolving each package's own JS entry and running it with
// node sidesteps both, and needs no shell anywhere.
const req = createRequire(import.meta.url);
const binJs = (name) => {
  const pkg = req(`${name}/package.json`);
  const rel = typeof pkg.bin === "string" ? pkg.bin : pkg.bin[name];
  return path.join(path.dirname(req.resolve(`${name}/package.json`)), rel);
};

// One shared set of dumps, so the engines can be compared on identical input
// with the test run itself factored out.
const shared = path.join(dir, "cov-v8");
fs.rmSync(shared, { recursive: true, force: true });
fs.mkdirSync(shared, { recursive: true });
execFileSync(process.execPath, ["entry.js"], {
  cwd: dir,
  env: { ...process.env, NODE_V8_COVERAGE: shared },
  stdio: "ignore",
});

const engines = [
  measure("zcov", [ZCOV, "report", "-d", shared, "--cwd", dir, "--no-all", "-r", "lcov", "-o", "r-zcov"]),
  measure("c8", [process.execPath, binJs("c8"), "report", "--temp-directory", shared, "-r", "lcovonly", "--report-dir", "r-c8"]),
  measure("ast-v8-to-istanbul", [
    process.execPath, path.join(ROOT, "tools", "vitest-engine.mjs"), shared, dir, path.join(dir, "r-vitest"),
  ]),
];
console.log("  report only, over identical V8 dumps (median of 5):\n");
console.log("  | engine | wall | CPU | peak RSS |");
console.log("  |---|---|---|---|");
for (const r of engines) {
  console.log(`  | ${r.label} | ${r.wall.toFixed(2)}s | ${r.cpu.toFixed(2)}s | ${r.rss.toFixed(0)}MB |`);
}
console.log("");
const results = [
  measure("zcov", [ZCOV, "-r", "lcov", "-o", "cov-zcov", "--", process.execPath, "entry.js"]),
  measure("c8", [process.execPath, binJs("c8"), "-r", "lcovonly", "--report-dir", "cov-c8", process.execPath, "entry.js"]),
  measure("nyc", [process.execPath, binJs("nyc"), "-r", "lcovonly", "--report-dir", "cov-nyc", process.execPath, "entry.js"]),
];

const baseline = measure("node alone", [process.execPath, "entry.js"]);
console.log("  end to end (spawn + report), median of 5:\n");
console.log("  | tool | wall | CPU | peak RSS | overhead vs bare node |");
console.log("  |---|---|---|---|---|");
console.log(`  | (bare node) | ${baseline.wall.toFixed(2)}s | ${baseline.cpu.toFixed(2)}s | ${baseline.rss.toFixed(0)}MB | - |`);
for (const r of results) {
  console.log(
    `  | ${r.label} | ${r.wall.toFixed(2)}s | ${r.cpu.toFixed(2)}s | ${r.rss.toFixed(0)}MB | ${(r.wall / baseline.wall).toFixed(1)}x |`,
  );
}

// Accuracy against nyc, which instruments and so measures rather than infers.
// zcov runs --no-all here because the others only report files that loaded.
const readDA = (file) => {
  const out = new Map();
  let cur = null;
  for (const l of fs.readFileSync(path.join(dir, file), "utf8").split("\n")) {
    if (l.startsWith("SF:")) cur = l.slice(3).replace(/^\.\//, "");
    else if (cur && l.startsWith("DA:")) {
      const [a, b] = l.slice(3).split(",");
      out.set(cur + ":" + a, +b);
    }
  }
  return out;
};

const truth = readDA("cov-nyc/lcov.info");
console.log("\n  agreement with instrumented execution counts (nyc):\n");
console.log("  | tool | lines judged | agree | called covered but never ran | omitted |");
console.log("  |---|---|---|---|---|");
for (const [label, file] of [
  ["zcov", "r-zcov/lcov.info"],
  ["c8", "r-c8/lcov.info"],
  ["ast-v8-to-istanbul", "r-vitest/lcov.info"],
]) {
  const got = readDA(file);
  let judged = 0, agree = 0, falsePos = 0, missing = 0;
  for (const [k, v] of got) {
    if (!truth.has(k)) continue;
    judged++;
    if (v > 0 === truth.get(k) > 0) agree++;
    else if (v > 0) falsePos++;
  }
  for (const k of truth.keys()) if (!got.has(k)) missing++;
  console.log(`  | ${label} | ${judged} | ${agree} | ${falsePos} | ${missing} |`);
}

// The unbundled case is the easy one. Bundling is where these engines have to
// agree on a source map, and where they stop agreeing.
console.log("\n  same workload, bundled with esbuild (source map, one script):\n");
const bundleDir = path.join(dir, "bundled");
fs.rmSync(bundleDir, { recursive: true, force: true });
fs.mkdirSync(bundleDir, { recursive: true });
req("esbuild").buildSync({
  entryPoints: [path.join(dir, "entry.js")],
  bundle: true,
  platform: "node",
  sourcemap: true,
  outfile: path.join(bundleDir, "bundle.js"),
});

const bcov = path.join(dir, "cov-bundled");
fs.rmSync(bcov, { recursive: true, force: true });
fs.mkdirSync(bcov, { recursive: true });
execFileSync(process.execPath, [path.join(bundleDir, "bundle.js")], {
  cwd: dir,
  env: { ...process.env, NODE_V8_COVERAGE: bcov },
  stdio: "ignore",
});

execFileSync(ZCOV, ["report", "-d", bcov, "--cwd", dir, "--no-all", "-r", "lcov", "-o", "b-zcov"], {
  cwd: dir, stdio: "ignore",
});
spawnSync(process.execPath, [binJs("c8"),"report", "--temp-directory", bcov, "-r", "lcovonly", "--report-dir", "b-c8"], {
  cwd: dir, stdio: "ignore",
});
spawnSync(process.execPath, [path.join(ROOT, "tools", "vitest-engine.mjs"), bcov, dir, path.join(dir, "b-vitest")], {
  cwd: dir, stdio: "ignore",
});

console.log("  | tool | lines judged | agree | called covered but never ran | omitted |");
console.log("  |---|---|---|---|---|");
for (const [label, file] of [
  ["zcov", "b-zcov/lcov.info"],
  ["c8", "b-c8/lcov.info"],
  ["ast-v8-to-istanbul", "b-vitest/lcov.info"],
]) {
  let got;
  try {
    got = readDA(file);
  } catch {
    console.log(`  | ${label} | - | - | - | produced no lcov |`);
    continue;
  }
  let judged = 0, agree = 0, falsePos = 0, missing = 0;
  for (const [k, v] of got) {
    if (!truth.has(k)) continue;
    judged++;
    if (v > 0 === truth.get(k) > 0) agree++;
    else if (v > 0) falsePos++;
  }
  for (const k of truth.keys()) if (!got.has(k)) missing++;
  console.log(`  | ${label} | ${judged} | ${agree} | ${falsePos} | ${missing} |`);
}

// Branches, slot against slot rather than as a set: which BRDA block a count
// lands in is part of being compatible. A line that disagrees at all is skipped.
const readBR = (file) => {
  const out = new Map();
  let cur = null;
  for (const l of fs.readFileSync(path.join(dir, file), "utf8").split("\n")) {
    if (l.startsWith("SF:")) cur = l.slice(3).replace(/^\.\//, "");
    else if (cur && l.startsWith("BRDA:")) {
      const [line, , , count] = l.slice(5).split(",");
      const k = cur + ":" + line;
      if (!out.has(k)) out.set(k, []);
      out.get(k).push(count === "-" ? 0 : +count);
    }
  }
  return out;
};

const brTruth = readBR("cov-nyc/lcov.info");
console.log("\n  branches, same dumps, same instrumented truth:\n");
console.log("  | engine | agree | claims a branch was taken that was not | says not taken when it was | omitted |");
console.log("  |---|---|---|---|---|");
for (const [label, file] of [
  ["zcov", "r-zcov/lcov.info"],
  ["c8", "r-c8/lcov.info"],
  ["ast-v8-to-istanbul", "r-vitest/lcov.info"],
]) {
  let got;
  try {
    got = readBR(file);
  } catch {
    console.log(`  | ${label} | - | - | - | produced no lcov |`);
    continue;
  }
  let agree = 0, falsePos = 0, falseNeg = 0, omitted = 0;
  for (const [k, want] of brTruth) {
    const have = got.get(k);
    if (!have || have.length !== want.length) {
      omitted += want.length;
      continue;
    }
    for (let i = 0; i < want.length; i++) {
      if (want[i] > 0 === have[i] > 0) agree++;
      else if (have[i] > 0) falsePos++;
      else falseNeg++;
    }
  }
  console.log(`  | ${label} | ${agree} | ${falsePos} | ${falseNeg} | ${omitted} |`);
}

console.log("\n  totals each one reported:\n");
for (const [label, f] of [
  ["zcov", "r-zcov/lcov.info"],
  ["c8", "r-c8/lcov.info"],
  ["ast-v8-to-istanbul", "r-vitest/lcov.info"],
  ["nyc", "cov-nyc/lcov.info"],
]) {
  const t = lcovTotals(path.join(dir, f));
  console.log(`  ${label.padEnd(8)} ${t ? `${t.pct}%  (${t.lh}/${t.lf} lines)` : "no lcov produced"}`);
}
