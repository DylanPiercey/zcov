// Writes the per-platform npm packages and wires them into the main package's
// optionalDependencies, so the version is only ever edited in one place.
//
//   zig build release && node tools/gen-npm.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;

const PLATFORMS = [
  { suffix: "linux-x64-gnu", os: "linux", cpu: "x64", libc: "glibc" },
  { suffix: "linux-x64-musl", os: "linux", cpu: "x64", libc: "musl" },
  { suffix: "linux-arm64-gnu", os: "linux", cpu: "arm64", libc: "glibc" },
  { suffix: "linux-arm64-musl", os: "linux", cpu: "arm64", libc: "musl" },
  { suffix: "darwin-x64", os: "darwin", cpu: "x64" },
  { suffix: "darwin-arm64", os: "darwin", cpu: "arm64" },
  { suffix: "win32-x64", os: "win32", cpu: "x64" },
  { suffix: "win32-arm64", os: "win32", cpu: "arm64" },
  { suffix: "freebsd-x64", os: "freebsd", cpu: "x64" },
];

const shared = {
  version,
  license: "MIT",
  repository: { type: "git", url: "git+https://github.com/DylanPiercey/zcov.git" },
  homepage: "https://github.com/DylanPiercey/zcov",
  bugs: { url: "https://github.com/DylanPiercey/zcov/issues" },
};

const optional = {};
let missing = 0;
for (const p of PLATFORMS) {
  const name = `@zcov/${p.suffix}`;
  const dir = path.join(ROOT, "npm", `zcov-${p.suffix}`);
  const exe = p.os === "win32" ? "zcov.exe" : "zcov";
  fs.mkdirSync(dir, { recursive: true });

  if (!fs.existsSync(path.join(dir, exe))) {
    console.warn(`  missing binary: ${dir}/${exe} - run \`zig build release\``);
    missing++;
  } else if (p.os !== "win32") {
    fs.chmodSync(path.join(dir, exe), 0o755);
  }

  fs.writeFileSync(
    path.join(dir, "package.json"),
    JSON.stringify(
      {
        name,
        description: `zcov binary for ${p.os} ${p.cpu}${p.libc ? ` (${p.libc})` : ""}`,
        ...shared,
        os: [p.os],
        cpu: [p.cpu],
        ...(p.libc ? { libc: [p.libc] } : {}),
        files: [exe, "LICENSE", "NOTICE"],
      },
      null,
      2,
    ) + "\n",
  );
  for (const f of ["LICENSE", "NOTICE"]) {
    fs.copyFileSync(path.join(ROOT, f), path.join(dir, f));
  }
  optional[name] = version;
}

const mainDir = path.join(ROOT, "npm", "zcov");
fs.writeFileSync(
  path.join(mainDir, "package.json"),
  JSON.stringify(
    {
      name: "@zcov/cli",
      description: "V8 coverage to lcov, natively - a c8 replacement built on yuku",
      ...shared,
      bin: { zcov: "bin/zcov.js" },
      files: ["bin/zcov.js", "LICENSE", "NOTICE"],
      engines: { node: ">=18" },
      optionalDependencies: optional,
      keywords: ["coverage", "c8", "istanbul", "lcov", "v8", "nyc", "zig", "yuku"],
    },
    null,
    2,
  ) + "\n",
);
fs.copyFileSync(path.join(ROOT, "README.md"), path.join(mainDir, "README.md"));
fs.copyFileSync(path.join(ROOT, "LICENSE"), path.join(mainDir, "LICENSE"));
fs.copyFileSync(path.join(ROOT, "NOTICE"), path.join(mainDir, "NOTICE"));

console.log(`  wrote ${PLATFORMS.length} platform packages + @zcov/cli@${version}`);
if (missing) {
  console.error(`  ${missing} binaries missing; not publishable`);
  process.exitCode = 1;
}
