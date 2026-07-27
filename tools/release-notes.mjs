// The GitHub release body is the section changesets already wrote for this
// version, so the changelog has one source instead of a second, commit-derived
// one drifting against it. `getChangelogEntry` is the parser the official
// changesets action uses, but it returns the *whole* file for a version it
// cannot find, so the heading is checked before trusting it.
//
//   node tools/release-notes.mjs 0.2.0
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getChangelogEntry } from "@changesets/release-utils";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = process.argv[2];
if (!version) {
  console.error("usage: release-notes.mjs <version>");
  process.exit(1);
}

const changelog = path.join(ROOT, "CHANGELOG.md");
if (!fs.existsSync(changelog)) {
  console.error("CHANGELOG.md does not exist; nothing to release from");
  process.exit(1);
}

const md = fs.readFileSync(changelog, "utf8");
if (!md.split("\n").some((line) => line.trim() === `## ${version}`)) {
  console.error(`CHANGELOG.md has no section for ${version} - was \`pnpm run release:version\` run?`);
  process.exit(1);
}

const body = (await getChangelogEntry(md, version)).content.trim();
if (!body) {
  console.error(`CHANGELOG.md section for ${version} is empty`);
  process.exit(1);
}
process.stdout.write(`${body}\n`);
