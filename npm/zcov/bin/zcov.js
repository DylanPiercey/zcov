#!/usr/bin/env node
// Locates the prebuilt binary for this platform and hands off to it. The
// binaries ship as optionalDependencies, so npm installs only the matching one.
"use strict";
const { spawnSync } = require("node:child_process");
const { createRequire } = require("node:module");
const { readFileSync } = require("node:fs");
const { execSync } = require("node:child_process");

const require_ = createRequire(__filename);
const { platform, arch } = process;

const isFileMusl = (f) => f.includes("libc.musl-") || f.includes("ld-musl-");

function isMusl() {
  if (platform !== "linux") return false;
  try {
    if (readFileSync("/usr/bin/ldd", "utf8").includes("musl")) return true;
  } catch {}
  try {
    const report = typeof process.report?.getReport === "function" ? process.report.getReport() : null;
    if (report) {
      const header = typeof report === "string" ? JSON.parse(report).header : report.header;
      if (header?.glibcVersionRuntime) return false;
      if (Array.isArray(report.sharedObjects) && report.sharedObjects.some(isFileMusl)) return true;
    }
  } catch {}
  try {
    return execSync("ldd --version", { encoding: "utf8" }).includes("musl");
  } catch {}
  return false;
}

function binaryPath() {
  const libc = platform === "linux" ? (isMusl() ? "-musl" : "-gnu") : "";
  const pkg = `@zcov/${platform}-${arch}${libc}`;
  const exe = platform === "win32" ? "zcov.exe" : "zcov";
  try {
    return require_.resolve(`${pkg}/${exe}`);
  } catch (cause) {
    throw new Error(
      `zcov has no prebuilt binary for ${platform}-${arch}.\n` +
        `Expected the optional dependency "${pkg}" to be installed.\n` +
        `If you are on a supported platform, try removing node_modules and reinstalling.`,
      { cause },
    );
  }
}

const result = spawnSync(binaryPath(), process.argv.slice(2), { stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status === null ? 1 : result.status);
