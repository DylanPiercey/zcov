// Vitest's V8 coverage pipeline standalone, so it can be timed over the same
// dumps as the other tools.
//
//   node tools/vitest-engine.mjs <coverage-dir> <root> <out-dir>
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseSync } from "oxc-parser";
import { mergeProcessCovs } from "@bcoe/v8-coverage";
import convert from "ast-v8-to-istanbul";
import libCoverage from "istanbul-lib-coverage";
import libReport from "istanbul-lib-report";
import reports from "istanbul-reports";

const [covDir, root, outDir] = process.argv.slice(2);

const byUrl = new Map();
for (const f of fs.readdirSync(covDir)) {
  if (!f.endsWith(".json")) continue;
  const j = JSON.parse(fs.readFileSync(path.join(covDir, f), "utf8"));
  for (const e of j.result || []) {
    if (!e.url?.startsWith("file://")) continue;
    let p;
    try {
      p = fileURLToPath(e.url);
    } catch {
      continue;
    }
    if (!p.startsWith(root) || p.includes("node_modules")) continue;
    (byUrl.get(p) ?? byUrl.set(p, []).get(p)).push(e);
  }
}

const map = libCoverage.createCoverageMap({});
for (const [file, entries] of byUrl) {
  let code;
  try {
    code = fs.readFileSync(file, "utf8");
  } catch {
    continue;
  }
  const merged = mergeProcessCovs(entries.map((e) => ({ result: [{ ...e, url: "file:///x" }] }))).result[0];
  try {
    const { program } = parseSync(file, code, { experimentalRawTransfer: true });
    const data = await convert({
      ast: program,
      code,
      wrapperLength: 0,
      coverage: { url: pathToFileURL(file).href, functions: merged.functions },
    });
    map.merge(data);
  } catch {}
}

fs.mkdirSync(outDir, { recursive: true });
const context = libReport.createContext({ dir: outDir, coverageMap: map, defaultSummarizer: "nested" });
reports.create("lcovonly", { file: "lcov.info" }).execute(context);
