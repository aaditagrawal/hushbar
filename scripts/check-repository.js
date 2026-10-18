// Portable repository hygiene checks. This is a guardrail, not a privacy audit.
import { readdir, readFile, stat } from "node:fs/promises";
import { resolve, dirname, relative, extname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const allowMissingScreenshots = process.argv.slice(2).includes("--allow-missing-screenshots");
if (process.argv.slice(2).some((arg) => arg !== "--allow-missing-screenshots")) {
  throw new Error("Usage: bun scripts/check-repository.js [--allow-missing-screenshots]");
}
const skipped = new Set([".git", ".build", ".swiftpm", "dist", "DerivedData", "node_modules"]);
async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (skipped.has(entry.name) || entry.isSymbolicLink()) continue;
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}
const files = await walk(root);
const failures = [];
for (const required of ["README.md", "AGENTS.md", "LICENSE", "VERSION", "Support/PrivacyInfo.xcprivacy",
  "Package.swift", "Packages/DeviceProtocol/Package.swift", "Packages/DeviceRuntime/Package.swift",
  "Packages/SupportDiagnostics/Package.swift", "docs/PROTOCOL.md"]) {
  if (!files.includes(resolve(root, required))) failures.push(`Missing required file: ${required}`);
}
const privatePatterns = [
  [/\/(?:Users|home)\/[^\s/`]+\//, "absolute personal home path"],
  [/\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b/i, "Bluetooth or network address"],
  [/\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2})\b/, "private network address"],
];
for (const file of files.filter((path) => extname(path) === ".md")) {
  const contents = await readFile(file, "utf8");
  const name = relative(root, file);
  for (const [pattern, description] of privatePatterns) {
    if (pattern.test(contents)) failures.push(`${name}: contains a possible ${description}. Review before publication.`);
  }
  // Check ordinary local Markdown links, including image links. Remote URLs and anchors are excluded.
  for (const match of contents.matchAll(/!?\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)) {
    const target = match[1];
    if (/^(?:https?:|mailto:|#)/.test(target)) continue;
    const decoded = decodeURIComponent(target.split("#")[0]);
    if (!decoded) continue;
    const destination = resolve(dirname(file), decoded);
    if (destination !== root && !destination.startsWith(`${root}/`)) {
      failures.push(`${name}: local link escapes the repository.`);
      continue;
    }
    try {
      await stat(destination);
    } catch {
      if (allowMissingScreenshots && destination.startsWith(`${root}/docs/screenshots/`) && destination.endsWith(".png")) {
        console.log(`Awaiting real-view screenshot: ${relative(root, destination)}`);
      } else failures.push(`${name}: missing local link target ${target}`);
    }
  }
}
const forbiddenExtensions = new Set([".ttf", ".otf", ".woff", ".woff2", ".log", ".jsonl", ".p12", ".p8"]);
for (const file of files) {
  if (forbiddenExtensions.has(extname(file).toLowerCase())) failures.push(`Unexpected font, capture, log, or signing credential: ${relative(root, file)}`);
}
if (failures.length) {
  failures.forEach((failure) => console.error(failure));
  process.exit(1);
}
console.log("Repository links, public documentation privacy patterns, and packaging inputs checked.");
