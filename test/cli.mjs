// Exit codes and messages, which are contract rather than implementation:
// `zcov npm test` must fail with the runner's own status, or CI goes green.
import { execFileSync, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ZCOV = path.join(HERE, "..", "zig-out", "bin", process.platform === "win32" ? "zcov.exe" : "zcov");
const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "zcov-cli-")));
const pkgVersion = JSON.parse(fs.readFileSync(path.join(HERE, "..", "package.json"), "utf8")).version;
process.on("exit", () => fs.rmSync(dir, { recursive: true, force: true }));

fs.writeFileSync(path.join(dir, "ok.js"), 'console.log("ok");\n');
fs.writeFileSync(path.join(dir, "fail3.js"), "process.exit(3);\n");
fs.writeFileSync(path.join(dir, "fail7.js"), "process.exit(7);\n");
fs.mkdirSync(path.join(dir, "empty"));

const run = (...args) => {
  const r = spawnSync(ZCOV, args, { cwd: dir, encoding: "utf8" });
  return { code: r.status, out: (r.stdout || "") + (r.stderr || "") };
};

const CASES = [
  { name: "propagates a child exit code of 3", args: ["-r", "text-summary", "--", process.execPath, "fail3.js"], code: 3 },
  { name: "propagates a child exit code of 7", args: ["-r", "text-summary", "--", process.execPath, "fail7.js"], code: 7 },
  { name: "succeeds when the child succeeds", args: ["-r", "text-summary", "--", process.execPath, "ok.js"], code: 0 },
  { name: "--help exits 0 and prints usage", args: ["--help"], code: 0, match: /zcov \[options\]/ },
  // Read from build.zig.zon at build time, so a release cannot ship a binary
  // that disagrees with the tag the publish workflow checked.
  { name: "--version prints package.json's version", args: ["--version"], code: 0, match: new RegExp(`^${pkgVersion}$`, "m") },
  { name: "-V is accepted too", args: ["-V"], code: 0, match: new RegExp(`^${pkgVersion}$`, "m") },
  { name: "unknown option exits 2", args: ["--nonsense"], code: 2, match: /zcov \[options\]/ },
  { name: "unknown reporter exits 2", args: ["-r", "bogus", "--", process.execPath, "ok.js"], code: 2 },
  { name: "option with no value exits 2", args: ["--reporter"], code: 2 },
  { name: "no args exits 2 with usage", args: [], code: 2, match: /zcov \[options\]/ },
  { name: "missing dump directory exits 1", args: ["report", "-d", "nope"], code: 1, match: /no coverage dumps/ },
  { name: "unrunnable command exits 127", args: ["--", "no-such-binary-xyz"], code: 127, match: /could not run/ },
  // A failing command with no dumps must report the command's status, not
  // complain about missing coverage it was never going to produce.
  { name: "no raw zig error names leak", args: ["--nonsense"], code: 2, notMatch: /^error: [A-Z]/m },
];

let failed = 0;
let extra = 0;
for (const c of CASES) {
  const { code, out } = run(...c.args);
  const errs = [];
  if (code !== c.code) errs.push(`want exit ${c.code}, got ${code}`);
  if (c.match && !c.match.test(out)) errs.push(`output did not match ${c.match}`);
  if (c.notMatch && c.notMatch.test(out)) errs.push(`output matched ${c.notMatch}: ${out.split("\n").find((l) => c.notMatch.test(l))}`);
  if (errs.length) {
    failed++;
    console.log(`  FAIL  ${c.name}`);
    for (const e of errs) console.log(`          ${e}`);
  } else {
    console.log(`  ok    ${c.name}`);
  }
}

// The reporters, on contract rather than contents: istanbul's own lcov reporter
// fed zcov's json must reproduce zcov's lcov exactly.
{
  const proj = path.join(dir, "reporters");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(
    path.join(proj, "main.js"),
    "function f(a) {\n  if (a > 0) {\n    return 1;\n  }\n  const g = (x = 2) => x * 2;\n  return g(a);\n}\n" +
      "function never() {\n  return 0;\n}\nf(1);\nf(-1);\n",
  );
  execFileSync(process.execPath, ["main.js"], {
    cwd: proj,
    env: { ...process.env, NODE_V8_COVERAGE: path.join(proj, "cov") },
    stdio: "ignore",
  });
  const r = spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", ".", "-r", "json", "-r", "html", "-r", "lcov", "-o", "out"], {
    cwd: proj,
    encoding: "utf8",
  });
  const check = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  check("json and html reporters exit 0", r.status === 0, `exit ${r.status}: ${(r.stderr || "").slice(0, 80)}`);
  const has = (f) => fs.existsSync(path.join(proj, "out", f));
  check("json writes coverage-final.json", has("coverage-final.json"));
  check("html writes an index and a page per file", has("index.html") && has("main.js.html"));

  let roundTrip = null;
  try {
    const req = createRequire(path.join(HERE, "..", "package.json"));
    const libCoverage = req("istanbul-lib-coverage");
    const libReport = req("istanbul-lib-report");
    const reports = req("istanbul-reports");
    const data = JSON.parse(fs.readFileSync(path.join(proj, "out", "coverage-final.json"), "utf8"));
    const map = libCoverage.createCoverageMap(data);
    reports
      .create("lcovonly")
      .execute(libReport.createContext({ dir: path.join(proj, "from-json"), coverageMap: map }));
    const keep = (f) =>
      fs
        .readFileSync(f, "utf8")
        .split("\n")
        .filter((l) => /^(DA|FN|FNDA|BRDA|LF|LH|FNF|FNH|BRF|BRH):/.test(l))
        .join("\n");
    const mine = keep(path.join(proj, "out", "lcov.info"));
    const theirs = keep(path.join(proj, "from-json", "lcov.info"));
    roundTrip = mine === theirs ? null : `zcov lcov and istanbul-from-json differ`;
  } catch (e) {
    roundTrip = `istanbul could not read it: ${(e.message || "").split("\n")[0].slice(0, 70)}`;
  }
  check("istanbul reads the json back to the same lcov", roundTrip === null, roundTrip);
  // The html has to stand on its own -- no asset directory to lose, and the
  // counts visible without running anything.
  const page = fs.readFileSync(path.join(proj, "out", "main.js.html"), "utf8");
  check("html page is self-contained", page.includes("<style>") && !/<script|src=/.test(page));
  check("html page marks an uncovered line", /class="ln miss"/.test(page));
}

// A file --all found but zcov cannot measure is named rather than dropped:
// no denominator to invent, but silence would read as nothing being there.
{
  const proj = path.join(dir, "unanalysed");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), 'console.log("ran");\n');
  fs.writeFileSync(path.join(proj, "Widget.vue"), "<template>\n  <div>{{ x }}</div>\n</template>\n");
  execFileSync(process.execPath, ["main.js"], {
    cwd: proj,
    env: { ...process.env, NODE_V8_COVERAGE: path.join(proj, "cov") },
    stdio: "ignore",
  });
  const r = spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", ".", "-r", "text", "-r", "html", "-o", "out"], {
    cwd: proj,
    encoding: "utf8",
  });
  const out = (r.stdout || "") + (r.stderr || "");
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  one("text names what it could not analyse", /not analysed \(1\): Widget\.vue/.test(out), out.slice(-200));
  one("an unmeasurable file stays out of the table", !/Widget\.vue\s+\|/.test(out));
  const index = fs.readFileSync(path.join(proj, "out", "index.html"), "utf8");
  one("html index lists it too", /Widget\.vue<\/td><td class="na"/.test(index));
}

// zcov.json, whose whole contract is that flags still win and that a key it
// does not understand is refused rather than quietly ignored.
{
  const proj = path.join(dir, "config");
  fs.mkdirSync(path.join(proj, "src"), { recursive: true });
  fs.writeFileSync(path.join(proj, "src", "app.mjs"), "export function used() {\n  return 1;\n}\n");
  fs.writeFileSync(path.join(proj, "src", "skipme.mjs"), "export function never() {\n  return 3;\n}\n");
  fs.writeFileSync(path.join(proj, "main.mjs"), 'import { used } from "./src/app.mjs";\nused();\n');
  const cfg = (o) => fs.writeFileSync(path.join(proj, "zcov.json"), JSON.stringify(o));
  const go = (...args) => {
    const r = spawnSync(ZCOV, [...args, "--", process.execPath, "main.mjs"], { cwd: proj, encoding: "utf8" });
    return { code: r.status, out: (r.stdout || "") + (r.stderr || "") };
  };
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };

  cfg({ reporter: ["lcov"], reportDir: "from-config", exclude: ["**/skipme.mjs"] });
  let r = go();
  one("zcov.json selects the reporter and its directory", r.code === 0 && fs.existsSync(path.join(proj, "from-config", "lcov.info")), r.out.slice(-160));
  const lcov = fs.readFileSync(path.join(proj, "from-config", "lcov.info"), "utf8");
  one("zcov.json exclude is honoured", !lcov.includes("skipme.mjs"));

  // camelCase and kebab-case name the same key, and a flag beats the file.
  cfg({ "report-dir": "from-config", reporter: "lcov" });
  r = go("-o", "from-flag");
  one("a flag overrides zcov.json", fs.existsSync(path.join(proj, "from-flag", "lcov.info")));

  cfg({ reporter: "text-summary", "check-coverage": true, lines: 99 });
  one("a threshold in zcov.json is enforced", go().code === 1);

  cfg({ reporters: ["lcov"] });
  r = go();
  one("an unknown key is refused, not ignored", r.code === 2 && /unknown key "reporters"/.test(r.out), r.out.slice(-160));

  fs.writeFileSync(path.join(proj, "zcov.json"), '{ "reporter": ');
  r = go();
  one("malformed zcov.json exits 2 and says so", r.code === 2 && /not valid JSON/.test(r.out), r.out.slice(-160));

  // The key is matched loosely but has to be applied under its own name, or the
  // threshold silently vanishes and `check` falls back to the 90% default.
  cfg({ reporter: "text-summary", checkCoverage: true, Lines: 50 });
  one("a differently-cased threshold key still applies", go().code === 0);
}

// `--clean` must never reach outside the dumps it wrote. A mistyped
// --coverage-dir pointed at source used to delete it, unrecoverably.
{
  const proj = path.join(dir, "clean-safety");
  fs.mkdirSync(path.join(proj, "src"), { recursive: true });
  fs.writeFileSync(path.join(proj, "src", "lib.js"), "export function a() {\n  return 1;\n}\n");
  fs.writeFileSync(path.join(proj, "src", "notes.json"), "{}\n");
  fs.writeFileSync(path.join(proj, "main.js"), 'console.log("hi");\n');
  fs.writeFileSync(path.join(proj, "package.json"), '{ "name": "demo" }\n');
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  spawnSync(ZCOV, ["-d", "src", "-r", "text-summary", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
  one("--coverage-dir at a source tree leaves its files alone", fs.existsSync(path.join(proj, "src", "lib.js")) && fs.existsSync(path.join(proj, "src", "notes.json")));

  fs.writeFileSync(path.join(proj, "zcov.json"), JSON.stringify({ coverageDir: "." }));
  const r = spawnSync(ZCOV, ["-r", "text-summary", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
  one("--coverage-dir at the project root is refused", r.status === 2 && /cannot be the project root/.test((r.stdout || "") + (r.stderr || "")));
  one("nothing in the root was deleted", fs.existsSync(path.join(proj, "package.json")) && fs.existsSync(path.join(proj, "main.js")));
  fs.rmSync(path.join(proj, "zcov.json"), { force: true });
}

// A map that decodes to nothing, or that is not shaped like a map at all, is
// one script's problem. It used to take the whole run down with a segfault.
{
  const proj = path.join(dir, "bad-maps");
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), 'console.log("x");\n//# sourceMappingURL=main.js.map\n');
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  for (const [label, map] of [
    ["empty mappings", '{"version":3,"sources":["a.js"],"names":[],"mappings":""}'],
    ["mappings of the wrong type", '{"version":3,"sources":["a.js"],"names":[],"mappings":123}'],
    ["sources of the wrong type", '{"version":3,"sources":"a.js","names":[],"mappings":"AAAA"}'],
    ["a top-level array", "[]"],
    ["truncated json", '{"version":3,"sources":'],
  ]) {
    fs.writeFileSync(path.join(proj, "main.js.map"), map);
    const r = spawnSync(ZCOV, ["-r", "text-summary", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
    one(`a source map with ${label} does not crash`, r.status === 0, `exit ${r.status}`);
  }
}

// A file with nothing but an uncalled function still owes that function to the
// denominator; it used to be dropped for having no statement lines.
{
  const proj = path.join(dir, "fn-only");
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "empty.js"), "function neverCalled() {}\n");
  fs.writeFileSync(path.join(proj, "main.js"), 'require("./empty.js");\nfunction used() {\n  return 1;\n}\nused();\n');
  const r = spawnSync(ZCOV, ["--cwd", ".", "-r", "lcov", "--functions", "90", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
  const lcov = fs.readFileSync(path.join(proj, "coverage", "lcov.info"), "utf8");
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  one("a function-only file reaches the report", /SF:empty\.js/.test(lcov), lcov.slice(0, 160));
  one("its uncalled function fails the threshold", r.status === 1, `exit ${r.status}`);
}

// A stale map can name a generated line the file does not have. That must not
// score against whatever happens to be live at offset zero.
{
  const proj = path.join(dir, "stale-map");
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "bundle.js"), 'console.log("ran");\n//# sourceMappingURL=bundle.js.map\n');
  fs.writeFileSync(path.join(proj, "src.js"), "neverCalled();\n");
  const enc = (n) => {
    let v = n < 0 ? (-n << 1) | 1 : n << 1, r = "";
    const C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    do { let d = v & 31; v >>>= 5; if (v > 0) d |= 32; r += C[d]; } while (v > 0);
    return r;
  };
  const rows = [];
  for (let g = 0; g < 11; g++) rows.push(g === 10 ? enc(0) + enc(0) + enc(0) + enc(0) : "");
  fs.writeFileSync(path.join(proj, "bundle.js.map"), JSON.stringify({ version: 3, sources: ["src.js"], names: [], mappings: rows.join(";") }));
  spawnSync(ZCOV, ["--cwd", ".", "-r", "lcov", "--", process.execPath, "bundle.js"], { cwd: proj, encoding: "utf8" });
  const lcov = fs.readFileSync(path.join(proj, "coverage", "lcov.info"), "utf8");
  extra++;
  if (/^DA:1,0$/m.test(lcov) && !/^DA:1,[1-9]/m.test(lcov)) console.log("  ok    a segment past the generated file invents no coverage");
  else {
    failed++;
    console.log(`  FAIL  a segment past the generated file invents no coverage\n          ${lcov.slice(0, 200)}`);
  }
}

// `**/test/**` must not match `contest/`: a `**` may only resume where a path
// component starts, or default excludes silently drop production code.
{
  const proj = path.join(dir, "glob-boundary");
  for (const d of ["contest", "latest", "test", "src"]) fs.mkdirSync(path.join(proj, d), { recursive: true });
  for (const d of ["contest", "latest", "test"]) fs.writeFileSync(path.join(proj, d, "a.js"), "exports.f = function () {\n  return 1;\n};\n");
  fs.writeFileSync(path.join(proj, "src", "real.js"), "exports.g = function () {\n  return 2;\n};\n");
  fs.writeFileSync(path.join(proj, "main.js"), ["contest", "latest", "test"].map((d) => `require("./${d}/a.js");`).join("") + 'require("./src/real.js");\n');
  spawnSync(ZCOV, ["--cwd", ".", "-r", "lcov", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
  const lcov = fs.readFileSync(path.join(proj, "coverage", "lcov.info"), "utf8");
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  one("a directory merely containing 'test' is still reported", /SF:contest\/a\.js/.test(lcov) && /SF:latest\/a\.js/.test(lcov), lcov.match(/^SF:.*$/gm)?.join(" "));
  one("a real test directory is still excluded", !/SF:test\/a\.js/.test(lcov));
}

// A source map names its own sources, so it can point anywhere. Anything
// outside the project is not ours to report, and emphatically not ours to read.
{
  const proj = path.join(dir, "escape");
  fs.mkdirSync(path.join(proj, "app"), { recursive: true });
  fs.writeFileSync(path.join(proj, "outside.js"), 'const KEY = "zcov-secret-marker";\nexport function leak() {\n  return KEY;\n}\n');
  const app = path.join(proj, "app");
  fs.writeFileSync(path.join(app, "bundle.js"), 'function leak() {\n  return "x";\n}\nleak();\n//# sourceMappingURL=bundle.js.map\n');
  fs.writeFileSync(path.join(app, "bundle.js.map"), JSON.stringify({
    version: 3, sources: ["../outside.js"], names: [], mappings: "AAAA;AACA;AACA;AACA",
  }));
  const r = spawnSync(ZCOV, ["--cwd", ".", "-r", "lcov", "-r", "html", "-o", "out", "--", process.execPath, "bundle.js"], { cwd: app, encoding: "utf8" });
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  const lcov = fs.existsSync(path.join(app, "out", "lcov.info")) ? fs.readFileSync(path.join(app, "out", "lcov.info"), "utf8") : "";
  one("a source outside the root is not reported", r.status === 0 && !/outside\.js/.test(lcov), lcov.slice(0, 160));
  const hunt = spawnSync("grep", ["-rl", "zcov-secret-marker", path.join(app, "out")], { encoding: "utf8" });
  const leaked = (hunt.stdout || "").trim();
  one("its contents are never copied into the html report", leaked === "", leaked);
}

// Reporting nothing is not the same as covering everything.
{
  const proj = path.join(dir, "empty-report");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(path.join(proj, "cov", "coverage-1-1-0.json"), '{"result":[]}');
  const r = spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", ".", "--no-all", "-r", "text"], { cwd: proj, encoding: "utf8" });
  extra++;
  if (!/100\.00/.test(r.stdout || "")) console.log("  ok    an empty report does not print 100%");
  else {
    failed++;
    console.log(`  FAIL  an empty report does not print 100%\n          ${(r.stdout || "").slice(0, 160)}`);
  }
}

// Wrong-typed config values are refused for every key, not just some.
{
  const proj = path.join(dir, "config-types");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), 'console.log("x");\n');
  for (const bad of [{ reportDir: 123 }, { all: "false" }, { clean: 1 }, { checkCoverage: "yes" }, { coverageDir: [] }]) {
    fs.writeFileSync(path.join(proj, "zcov.json"), JSON.stringify(bad));
    const r = spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", "."], { cwd: proj, encoding: "utf8" });
    extra++;
    if (r.status === 2) console.log(`  ok    zcov.json refuses ${JSON.stringify(bad)}`);
    else {
      failed++;
      console.log(`  FAIL  zcov.json refuses ${JSON.stringify(bad)}\n          exit ${r.status}`);
    }
  }
}

// c8 and nyc put their tables on stdout, so a drop-in `zcov ... > cov.txt`
// has to capture one. Diagnostics stay on stderr.
{
  const proj = path.join(dir, "streams");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), "function a() {\n  return 1;\n}\na();\n");
  execFileSync(process.execPath, ["main.js"], {
    cwd: proj,
    env: { ...process.env, NODE_V8_COVERAGE: path.join(proj, "cov") },
    stdio: "ignore",
  });
  const r = spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", ".", "-r", "text"], { cwd: proj, encoding: "utf8" });
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  one("the coverage table goes to stdout", /% Stmts/.test(r.stdout || ""), JSON.stringify((r.stdout || "").slice(0, 80)));
  const bad = spawnSync(ZCOV, ["report", "-d", "nope"], { cwd: proj, encoding: "utf8" });
  one("errors stay on stderr", /no coverage dumps/.test(bad.stderr || "") && !/no coverage dumps/.test(bad.stdout || ""));
}

// A dump is untrusted input. None of these shapes may crash the run, and none
// may put a count on a line the ranges do not actually cover.
{
  const proj = path.join(dir, "bad-dumps");
  fs.mkdirSync(path.join(proj, "cov"), { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), "function a() {\n  return 1;\n}\na();\n");
  const url = `file://${path.join(proj, "main.js")}`;
  const dump = (fns) => fs.writeFileSync(path.join(proj, "cov", "coverage-1-1-0.json"), JSON.stringify({ result: fns }));
  const one = (name, ok, detail) => {
    extra++;
    if (ok) return console.log(`  ok    ${name}`);
    failed++;
    console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ""}`);
  };
  const go = () => spawnSync(ZCOV, ["report", "-d", "cov", "--cwd", ".", "-r", "lcov", "-o", "out"], { cwd: proj, encoding: "utf8" });

  // One id under two URLs indexed the other URL's range list, out of bounds.
  dump([
    { scriptId: "7", url, functions: [{ functionName: "", ranges: [{ startOffset: 0, endOffset: 30, count: 1 }], isBlockCoverage: true }] },
    { scriptId: "7", url: `${url}x`, functions: [{ functionName: "", ranges: [{ startOffset: 0, endOffset: 30, count: 1 }], isBlockCoverage: true }] },
  ]);
  one("a scriptId reused across two urls does not crash", go().status === 0);

  // A range whose offsets or count are nonsense has to be dropped whole: it
  // used to keep the fields around it and score against a fabricated zero.
  dump([{ scriptId: "1", url, functions: [{ functionName: "", ranges: [
    { startOffset: 5000000000, endOffset: 5000000010, count: 7 },
    { startOffset: 0, endOffset: 30, count: -9 },
  ], isBlockCoverage: true }] }]);
  const r = go();
  const lcov = fs.existsSync(path.join(proj, "out", "lcov.info")) ? fs.readFileSync(path.join(proj, "out", "lcov.info"), "utf8") : "";
  one("an out-of-range offset does not fabricate a count", r.status === 0 && !/^DA:\d+,7$/m.test(lcov), lcov.slice(0, 120));
  one("a negative count never reaches the report", !/^DA:\d+,-/m.test(lcov));
}

// A source the walk cannot read is named, the same as one it cannot parse.
{
  const proj = path.join(dir, "unreadable");
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "main.js"), 'console.log("ran");\n');
  const locked = path.join(proj, "locked.js");
  fs.writeFileSync(locked, "export function x() {\n  return 1;\n}\n");
  extra++;
  try {
    fs.chmodSync(locked, 0o000);
    const r = spawnSync(ZCOV, ["--cwd", ".", "-r", "text-summary", "--", process.execPath, "main.js"], { cwd: proj, encoding: "utf8" });
    const out = (r.stdout || "") + (r.stderr || "");
    // Running as root defeats the permission bit, so only assert when it took.
    const readable = (() => { try { fs.readFileSync(locked); return true; } catch { return false; } })();
    if (!readable && !/not analysed \(1\): locked\.js/.test(out)) {
      failed++;
      console.log(`  FAIL  an unreadable source is named, not dropped\n          ${out.slice(-160)}`);
    } else console.log("  ok    an unreadable source is named, not dropped");
  } finally {
    fs.chmodSync(locked, 0o644);
  }
}

// A root of `/x/proj` must not swallow `/x/proj-tools`; a neighbouring
// project's files moved the percentages.
{
  const proj = path.join(dir, "boundary", "proj");
  const sibling = path.join(dir, "boundary", "proj-tools");
  fs.mkdirSync(proj, { recursive: true });
  fs.mkdirSync(sibling, { recursive: true });
  fs.writeFileSync(path.join(sibling, "other.mjs"), "export function t() {\n  return 1;\n}\n");
  fs.writeFileSync(path.join(proj, "main.mjs"), 'import { t } from "../proj-tools/other.mjs";\nt();\n');
  spawnSync(ZCOV, ["--cwd", ".", "-r", "lcov", "--", process.execPath, "main.mjs"], { cwd: proj, encoding: "utf8" });
  const lcov = fs.readFileSync(path.join(proj, "coverage", "lcov.info"), "utf8");
  extra++;
  if (!/other\.mjs/.test(lcov)) console.log("  ok    a sibling directory sharing a name prefix stays out");
  else {
    failed++;
    console.log("  FAIL  a sibling directory sharing a name prefix stays out");
  }
}

// yuku recovers instead of failing, so an unreadable file came back with no
// statements and was dropped, leaving the totals reading 100%.
{
  const proj = path.join(dir, "garbage");
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "good.js"), "function ok() {\n  return 1;\n}\nok();\n");
  fs.writeFileSync(path.join(proj, "bad1.js"), "this is (((not javascript at all $$$\n");
  fs.writeFileSync(path.join(proj, "bad2.js"), "const = = = ;;;\n");
  const r = spawnSync(ZCOV, ["--cwd", ".", "-r", "text-summary", "--", process.execPath, "good.js"], { cwd: proj, encoding: "utf8" });
  const out = (r.stdout || "") + (r.stderr || "");
  extra++;
  if (/not analysed \(2\):/.test(out) && /bad1\.js/.test(out) && /bad2\.js/.test(out)) {
    console.log("  ok    files no parser could read are named, not dropped");
  } else {
    failed++;
    console.log(`  FAIL  files no parser could read are named, not dropped\n          ${out.slice(-200)}`);
  }
}

console.log(`\n  ${CASES.length + extra} cli cases: ${CASES.length + extra - failed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
