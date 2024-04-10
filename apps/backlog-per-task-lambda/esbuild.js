const { build } = require("esbuild");

build({
  entryPoints: ["./src/handler.ts"],
  bundle: true,
  platform: "node",
  target: "node20",
  outfile: "dist/index.js",
  external: ["sharp"],
});
