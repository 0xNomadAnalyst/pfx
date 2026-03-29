import { build } from "esbuild";

await build({
  entryPoints: ["app/static/js/src/charts-entry.js"],
  outfile: "app/static/js/charts.bundle.js",
  bundle: true,
  format: "iife",
  target: ["es2020"],
  platform: "browser",
  minify: false,
  sourcemap: false,
  logLevel: "info",
});
