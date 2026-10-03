import { defineConfig } from "@playwright/test";
import path from "node:path";

export default defineConfig({
  testDir: "./tests",
  testMatch: "**/*.spec.ts",
  workers: 1,
  use: {
    baseURL: "http://127.0.0.1:4019",
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_BIN
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_BIN }
      : {},
  },
  webServer: {
    command: "MIX_ENV=dev mix run --no-start --no-halt assets/tests/server.exs",
    cwd: path.resolve(import.meta.dirname, ".."),
    url: "http://127.0.0.1:4019/widget-demo",
    reuseExistingServer: false,
    timeout: 60000,
  },
});
