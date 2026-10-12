import { defineConfig } from "@playwright/test";
import path from "node:path";
import defaults from "./playwright.config";

export default defineConfig({
  ...defaults,
  testMatch: "**/scope.spec.ts",
  testIgnore: [],
  use: { ...defaults.use, baseURL: "https://localhost:4023", ignoreHTTPSErrors: true },
  webServer: {
    command: "MIX_ENV=dev mix run --no-start --no-halt assets/tests/scoped_server.exs",
    cwd: path.resolve(import.meta.dirname, ".."),
    url: "http://127.0.0.1:4021/ready",
    reuseExistingServer: false,
    timeout: 60000,
  },
});
