// package.json is the one place a version is edited, and changesets owns it.
// The Zig build carries its own copy, and the publish workflow only checks the
// tag against package.json, so a zon left behind ships a binary whose
// `--version` lies about what it is.
//
//   node tools/sync-version.mjs [--check]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;
const zonPath = path.join(ROOT, "build.zig.zon");
const zon = fs.readFileSync(zonPath, "utf8");

const VERSION_FIELD = /\.version\s*=\s*"([^"]*)"/;
const found = VERSION_FIELD.exec(zon);
if (!found) {
  console.error("build.zig.zon: no .version field to read");
  process.exit(1);
}

if (process.argv.includes("--check")) {
  if (found[1] !== version) {
    console.error(`  version drift: package.json is ${version}, build.zig.zon is ${found[1]}`);
    process.exit(1);
  }
  console.log(`  package.json and build.zig.zon agree at ${version}`);
} else if (found[1] === version) {
  console.log(`  build.zig.zon already at ${version}`);
} else {
  fs.writeFileSync(zonPath, zon.replace(VERSION_FIELD, `.version = "${version}"`));
  console.log(`  build.zig.zon ${found[1]} -> ${version}`);
}
