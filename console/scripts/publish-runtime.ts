import fs from "node:fs";
import { config } from "../src/config.js";
import { publishRelease, releaseBase, writeRuntime } from "../src/publish.js";

/**
 * Rebuilds console/.runtime from mine/ and optionally uploads it to the fixed
 * release tag the installer resolves. Lets Lua changes ship without restarting
 * the console (which would also move the tunnel).
 */
const tunnelFile = `${config.runtimeDir}/tunnel.json`;
if (!fs.existsSync(tunnelFile)) {
  console.error(`[publish] no ${tunnelFile}; start the console once to create it.`);
  process.exit(1);
}

const { url } = JSON.parse(fs.readFileSync(tunnelFile, "utf8")) as { url?: string };
if (!url) {
  console.error(`[publish] ${tunnelFile} has no tunnel URL.`);
  process.exit(1);
}

const runtime = writeRuntime(url);
console.log(`[publish] wrote ${runtime.manifest.files.length} Lua assets to ${config.runtimeDir}`);

if (!process.argv.includes("--publish")) {
  console.log("[publish] local only (pass --publish to upload the release)");
  process.exit(0);
}

const ok = await publishRelease(runtime);
console.log(`[publish] ${ok ? "published" : "FAILED"} ${releaseBase()}`);
process.exit(ok ? 0 : 1);
