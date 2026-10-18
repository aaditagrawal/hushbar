// Validate bundled data and derive the public catalogue. No upstream checkout needed.
import { fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const mode = process.argv[2] ?? "--check";
if (!["--check", "--write"].includes(mode) || process.argv.length > 3) {
  throw new Error("Usage: bun scripts/export-catalog.js [--check|--write]");
}
const resources = `${root}/Packages/DeviceProtocol/Sources/DeviceProtocol/Resources`;
const models = await Bun.file(`${resources}/models.json`).json();
const configs = await Bun.file(`${resources}/ear_config_file.json`).json();
const rules = await Bun.file(`${resources}/model_rules.json`).json();
const bases = new Set();
for (const config of configs) {
  if (!/^B\d{3}$/.test(config.id) || bases.has(config.id) || !Array.isArray(config.configs) || !config.configs.length) {
    throw new Error(`Invalid or duplicate configuration: ${config.id}`);
  }
  bases.add(config.id);
}
const names = new Map();
for (const [id, model] of Object.entries(models)) {
  if (!/^[0-9A-F]{6}$/.test(id) || typeof model.name !== "string" || !model.name.trim() || /[|\r\n]/.test(model.name)) {
    throw new Error(`Invalid model entry: ${id}`);
  }
  const modelBases = [model.base, model.altBase].filter(Boolean);
  if (modelBases.some((base) => !bases.has(base))) throw new Error(`Missing configuration for ${model.name}`);
  const row = names.get(model.name) ?? new Set();
  modelBases.forEach((base) => row.add(base));
  names.set(model.name, row);
}
for (const [rule, values] of Object.entries(rules)) {
  if (!Array.isArray(values) || values.some((base) => !bases.has(base))) throw new Error(`Invalid routing rule: ${rule}`);
}
const rows = [...names.entries()].sort(([a], [b]) => a.localeCompare(b, "en"));
const markdown = [
  "| Device | Model codes |",
  "| --- | --- |",
  ...rows.map(([name, codes]) => `| ${name} | ${[...codes].sort().map((code) => `\`${code}\``).join(", ")} |`),
  "",
].join("\n");
const destination = `${root}/README.md`;
const readme = await Bun.file(destination).text();
const startMarker = "<!-- catalogue:start -->";
const endMarker = "<!-- catalogue:end -->";
const start = readme.indexOf(startMarker);
const end = readme.indexOf(endMarker);
if (start === -1 || end <= start ||
    readme.indexOf(startMarker, start + startMarker.length) !== -1 ||
    readme.indexOf(endMarker, end + endMarker.length) !== -1) {
  throw new Error("README.md must contain one ordered pair of catalogue:start and catalogue:end markers.");
}
const updated = `${readme.slice(0, start + startMarker.length)}\n\n${markdown}\n${readme.slice(end)}`;
if (mode === "--write") {
  await Bun.write(destination, updated);
  console.log("Updated README.md catalogue section");
} else {
  if (readme !== updated) {
    throw new Error("README.md catalogue is stale. Run bun scripts/export-catalog.js --write and review the diff.");
  }
  console.log(`Catalogue checked: ${names.size} names, ${Object.keys(models).length} identifiers, ${bases.size} configurations.`);
}
