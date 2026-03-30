import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = resolve(__dirname, "..");
const entryFile = resolve(projectRoot, "app/static/js/src/charts-bundle-entry.mjs");
const outFile = resolve(projectRoot, "app/static/js/charts.bundle.js");

await mkdir(dirname(outFile), { recursive: true });

await build({
  entryPoints: [entryFile],
  outfile: outFile,
  bundle: true,
  format: "iife",
  target: ["es2019"],
  sourcemap: false,
  minify: true,
  legalComments: "none",
});

console.log(`Built ${outFile}`);
