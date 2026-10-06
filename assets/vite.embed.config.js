import path from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  publicDir: false,
  build: {
    target: "es2020",
    outDir: "../priv/static/assets",
    emptyOutDir: false,
    lib: {
      entry: path.resolve(import.meta.dirname, "js/embed.ts"),
      name: "ZaqEmbed",
      formats: ["iife"],
      fileName: () => "embed.js",
    },
  },
});
