// Runs istanbul's own reference corpus against zcov, asserting exact per-line
// counts rather than a covered/uncovered verdict.
//
//   node test/run.mjs            # summary
//   node test/run.mjs --verbose  # every failing case
//   node test/run.mjs if.yaml    # one file
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ZCOV = path.join(HERE, "..", "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");

// Report an existing dump directory, single-threaded so output is comparable.
const zcovArgs = (covDir, dir) => [
  "report", "-d", covDir, "--cwd", dir, "--threads", "1", "-r", "lcov", "-o", "report",
];
const CORPUS = path.join(HERE, "corpus");
const verbose = process.argv.includes("--verbose");
const only = process.argv.slice(2).filter((a) => a.endsWith(".yaml"));

if (!fs.existsSync(ZCOV)) {
  console.error("zcov not built - run: zig build -Doptimize=ReleaseFast");
  process.exit(1);
}

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zcov-corpus-")));
process.on("exit", () => fs.rmSync(root, { recursive: true, force: true }));

// `args` and `output` are globals the corpus expects. Setting them in a
// preload keeps the case's own line numbers starting at 1.
const preload = path.join(root, "preload.cjs");
fs.writeFileSync(
  preload,
  `globalThis.args = JSON.parse(process.env.CASE_ARGS || "null");
globalThis.output = undefined;
process.on("exit", () => {
  try {
    require("fs").writeFileSync(process.env.CASE_OUT, JSON.stringify(globalThis.output ?? null));
  } catch {}
});
`,
);

function runCase(code, testCase, id) {
  const dir = path.join(root, "case" + id);
  const covDir = path.join(dir, "cov");
  fs.mkdirSync(covDir, { recursive: true });
  const file = path.join(dir, "case.js");
  fs.writeFileSync(file, code);
  const outFile = path.join(dir, "out.json");

  try {
    execFileSync(process.execPath, ["--require", preload, file], {
      env: {
        ...process.env,
        NODE_V8_COVERAGE: covDir,
        CASE_ARGS: JSON.stringify(testCase.args ?? null),
        CASE_OUT: outFile,
      },
      stdio: "ignore",
      timeout: 20000,
    });
  } catch (e) {
    return { error: "run failed: " + (e.message || "").slice(0, 60) };
  }

  const lcov = path.join(dir, "report", "lcov.info");
  try {
    execFileSync(ZCOV, zcovArgs(covDir, dir), { stdio: "ignore", timeout: 20000 });
  } catch (e) {
    return { error: "zcov failed: " + (e.message || "").slice(0, 60) };
  }

  if (!fs.existsSync(lcov)) return { error: "no lcov produced" };
  const lines = new Map();
  let cur = null;
  for (const l of fs.readFileSync(lcov, "utf8").split("\n")) {
    if (l.startsWith("SF:")) cur = l.slice(3);
    else if (cur && cur.endsWith("case.js") && l.startsWith("DA:")) {
      const [a, b] = l.slice(3).split(",");
      lines.set(+a, +b);
    }
  }
  return { lines };
}

let total = 0;
let exact = 0;
let verdictOk = 0;
const failures = [];
const extra = [];

for (const fileName of fs.readdirSync(CORPUS).filter((f) => f.endsWith(".yaml"))) {
  if (only.length && !only.includes(fileName)) continue;
  const docs = YAML.parseAllDocuments(fs.readFileSync(path.join(CORPUS, fileName), "utf8"));
  for (const doc of docs) {
    const c = doc.toJS();
    if (!c || !c.code || !c.tests) continue;
    for (const t of c.tests) {
      const expected = t.lines;
      if (!expected) continue;
      total++;
      const got = runCase(c.code, t, total);
      if (got.error) {
        failures.push({ fileName, name: c.name, test: t.name, why: got.error });
        continue;
      }
      const keys = Object.keys(expected).map(Number);
      let allExact = true;
      let allVerdict = true;
      const diffs = [];
      // Lines zcov calls coverable that istanbul does not: invisible to a
      // check of istanbul's lines alone, and they move the denominator.
      for (const ln of got.lines.keys()) {
        if (!(String(ln) in expected)) extra.push({ fileName, name: c.name, line: ln });
      }
      for (const ln of keys) {
        const want = expected[String(ln)];
        const have = got.lines.get(ln);
        if (have === undefined) {
          allExact = allVerdict = false;
          diffs.push(`${ln}: want ${want}, missing`);
          continue;
        }
        if (have !== want) {
          allExact = false;
          diffs.push(`${ln}: want ${want}, got ${have}`);
        }
        if (want > 0 !== have > 0) allVerdict = false;
      }
      if (allExact) exact++;
      if (allVerdict) verdictOk++;
      if (!allExact) failures.push({ fileName, name: c.name, test: t.name, diffs, verdictOk: allVerdict });
    }
  }
}

console.log(`\n  istanbul reference corpus: ${total} cases`);
console.log(`    exact line counts match : ${exact}  (${((100 * exact) / total).toFixed(1)}%)`);
console.log(`    covered/uncovered match : ${verdictOk}  (${((100 * verdictOk) / total).toFixed(1)}%)`);
console.log(`    lines istanbul does not count : ${extra.length}`);
if (verbose) for (const e of extra) console.log(`      ${e.fileName} ${e.name}: line ${e.line}`);

const byFile = new Map();
for (const f of failures) byFile.set(f.fileName, (byFile.get(f.fileName) ?? 0) + 1);
if (byFile.size) {
  console.log("\n  failures by construct:");
  for (const [f, n] of [...byFile].sort((a, b) => b[1] - a[1])) {
    console.log(`    ${String(n).padStart(3)}  ${f}`);
  }
}
if (verbose) {
  console.log("\n  detail:");
  for (const f of failures) {
    console.log(`    [${f.fileName}] ${f.name} / ${f.test}${f.verdictOk ? "  (verdict ok, counts differ)" : ""}`);
    for (const d of f.diffs ?? [f.why]) console.log(`        ${d}`);
  }
}
process.exitCode = failures.length ? 1 : 0;
