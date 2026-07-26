// Builds a self-contained fixture: sources, a source map, and a real V8 dump.
// Every platform binary must turn it into byte-identical lcov.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2];
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(path.join(dir, "src"), { recursive: true });

fs.writeFileSync(
  path.join(dir, "src", "lib.js"),
  `export function used(n) {\n  if (n > 0) {\n    return "pos";\n  }\n  return "other";\n}\nexport function unused() {\n  return 2;\n}\nexport const double = (x) =>\n  x * 2;\n`,
);
// Non-ascii, so the UTF-16 vs byte offset handling is exercised too.
fs.writeFileSync(
  path.join(dir, "src", "banner.js"),
  `export const banner = "┏━━━━━━┓";\nexport function show() {\n  return banner;\n}\n`,
);
fs.writeFileSync(
  path.join(dir, "main.js"),
  `import { used, double } from "./src/lib.js";\nimport { show } from "./src/banner.js";\nused(1);\ndouble(2);\nshow();\n`,
);

const cov = path.join(dir, "cov");
fs.mkdirSync(cov);
execFileSync(process.execPath, [path.join(dir, "main.js")], {
  env: { ...process.env, NODE_V8_COVERAGE: cov },
  stdio: "ignore",
});
console.log("fixture ready");
