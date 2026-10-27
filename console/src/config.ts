import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

/**
 * Load the local .env before reading configuration. Real environment variables
 * win, so `DATA_DIR=data/demo npm start` still overrides the file.
 */
function loadEnvFile(file: string): void {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return;
  }

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const split = line.indexOf("=");
    if (split < 1) continue;
    const key = line.slice(0, split).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    if (process.env[key] !== undefined) continue;

    let value = line.slice(split + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote = value[0];
      const end = value.indexOf(quote, 1);
      if (end !== -1) value = value.slice(1, end);
    } else {
      value = value.replace(/\s+#.*$/, "").trim();
    }
    process.env[key] = value.replace(/\\n/g, "\n");
  }
}

loadEnvFile(path.join(root, ".env"));

function num(key: string, fallback: number): number {
  const value = Number(process.env[key]);
  return Number.isFinite(value) ? value : fallback;
}

function bool(key: string, fallback: boolean): boolean {
  const value = process.env[key];
  if (value === undefined) return fallback;
  return value !== "0" && value.toLowerCase() !== "false";
}

export const config = {
  root,
  dataDir: path.resolve(root, process.env.DATA_DIR ?? "data"),
  runtimeDir: path.resolve(root, process.env.RUNTIME_DIR ?? ".runtime"),

  port: num("PORT", 3000),
  host: process.env.HOST ?? "127.0.0.1",
  adminToken: process.env.ADMIN_TOKEN ?? "",
  heartbeatMs: num("HEARTBEAT_MS", 5000),
  staleMs: num("STALE_MS", 20000),

  // Tunnel + publishing
  publicUrl: (process.env.PUBLIC_URL ?? "").replace(/\/+$/, ""),
  publish: bool("PUBLISH", true),
  githubRepo: process.env.GITHUB_REPO ?? "Igidn/cc-util",
  releaseTag: process.env.RELEASE_TAG ?? "tunnel-latest",

  // Mine geometry, in world coordinates.
  // SECTOR_HALF is a Chebyshev radius. Keep it <= floor(viewDistance*16/sqrt(2))
  // if you want the whole square inside the loaded circle.
  sectorHalf: num("SECTOR_HALF", 48),
  topWorldY: num("TOP_WORLD_Y", 0),
  bottomWorldY: num("BOTTOM_WORLD_Y", -58),
  layerStep: num("LAYER_STEP", 2),
  branchSpacing: num("BRANCH_SPACING", 3),

  // Safety defaults, copied into each mission.
  reserve: num("RESERVE", 64),
  maxTripBlocks: num("MAX_TRIP_BLOCKS", 240),
  maxVeinBlocks: num("MAX_VEIN_BLOCKS", 24),
  maxRadius: num("MAX_RADIUS", 128),
  maxDepth: num("MAX_DEPTH", 200),

  // Stations are laid out along X. The operator sets the world anchor.
  baseX: num("BASE_X", 0),
  baseY: num("BASE_Y", 10),
  baseZ: num("BASE_Z", 0),
  stationSpacing: num("STATION_SPACING", 256),
};
