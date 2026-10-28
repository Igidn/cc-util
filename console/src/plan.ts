import { config } from "./config.js";
import type { MissionSpec, Progress } from "./types.js";
import { isBranchMineSpec, isMiningProgress } from "../shared/api.js";

export type Leg = {
  kind: "down" | "line";
  dir: 0 | 1 | 2 | 3;
  length: number;
  layer: number;
  strip: number;
};

/**
 * Deterministic 3D serpentine. The base is the centre of a square sector.
 * Layer 0 walks -Z to +Z, layer 1 walks back, and so on. Every layer drops
 * LAYER_STEP at the end, so the path is continuous and the trip tape is a
 * simple reverse of the route taken.
 */
export function buildLegs(spec: MissionSpec): Leg[] {
  if (!isBranchMineSpec(spec)) {
    throw new Error("buildLegs only supports branchMine missions");
  }
  const half = spec.maxRadius;
  const staging = spec.staging;
  // Lanes split the sector along X: each miner walks its own X slice while
  // both share the same Z range.
  const x0 = spec.sector?.x0 ?? -half;
  const x1 = spec.sector?.x1 ?? half;
  const z0 = spec.sector?.z0 ?? -half - staging;
  const z1 = spec.sector?.z1 ?? half - staging;
  const legs: Leg[] = [];

  const line = (dir: 0 | 1 | 2 | 3, length: number, layer: number, strip: number) => {
    if (length > 0) legs.push({ kind: "line", dir, length, layer, strip });
  };

  // The dock is one block south of the shaft top; step into the shaft first.
  line(0, staging, 0, 0);

  if (spec.startY < 0) {
    legs.push({ kind: "down", dir: 0, length: -spec.startY, layer: 0, strip: 0 });
  }

  // Get from the shaft centre to the west edge of the lane, then north to its
  // first row, and serpentine from there.
  line(x0 < 0 ? 3 : 1, Math.abs(x0), 0, 0);
  line(0, -staging - z0, 0, 0); // north

  const width = x1 - x0;
  const strips = Math.floor((z1 - z0) / spec.spacing) + 1;
  let y = spec.startY;
  let layer = 0;
  let zDir: 1 | -1 = 1;
  let xDir: 1 | 3 = 1; // east, then flip

  while (y >= spec.endY) {
    for (let strip = 0; strip < strips; strip++) {
      line(xDir, width, layer, strip);
      xDir = xDir === 1 ? 3 : 1;
      if (strip < strips - 1) {
        line(zDir === 1 ? 2 : 0, spec.spacing, layer, strip);
      }
    }

    if (y - spec.layerStep < spec.endY) break;
    legs.push({ kind: "down", dir: 0, length: spec.layerStep, layer, strip: strips - 1 });
    y -= spec.layerStep;
    zDir = zDir === 1 ? -1 : 1;
    layer += 1;
  }

  return legs;
}

export function totalBlocks(legs: Leg[]): number {
  return legs.reduce((sum, leg) => sum + leg.length, 0);
}

/** Plan geometry is immutable per spec. Cache it for snapshots and maps. */
const legCache = new Map<string, Leg[]>();

function specKey(spec: MissionSpec): string {
  if (!isBranchMineSpec(spec)) throw new Error("specKey only supports branchMine");
  return [
    spec.maxRadius,
    spec.staging,
    spec.startY,
    spec.endY,
    spec.layerStep,
    spec.spacing,
    spec.sector?.x0 ?? "",
    spec.sector?.x1 ?? "",
    spec.sector?.z0 ?? "",
    spec.sector?.z1 ?? "",
  ].join(":");
}

export function cachedLegs(spec: MissionSpec): Leg[] {
  if (!isBranchMineSpec(spec)) throw new Error("cachedLegs only supports branchMine");
  const key = specKey(spec);
  const hit = legCache.get(key);
  if (hit) return hit;
  const legs = buildLegs(spec);
  if (legCache.size > 64) legCache.clear();
  legCache.set(key, legs);
  return legs;
}

export function planSummary(spec: MissionSpec): {
  totalBlocks: number;
  layers: number;
  strips: number;
} {
  if (!isBranchMineSpec(spec)) throw new Error("planSummary only supports branchMine");
  const legs = cachedLegs(spec);
  let layers = 0;
  let strips = 0;
  for (const leg of legs) {
    if (leg.kind === "line") {
      layers = Math.max(layers, leg.layer + 1);
      strips = Math.max(strips, leg.strip + 1);
    }
  }
  return { totalBlocks: totalBlocks(legs), layers, strips };
}


export function blocksBefore(legs: Leg[], legIndex: number): number {
  let sum = 0;
  for (let i = 0; i < Math.min(legIndex - 1, legs.length); i++) sum += legs[i].length;
  return sum;
}

export function progressPercent(legs: Leg[], progress: Progress): number {
  const total = totalBlocks(legs);
  if (total === 0) return 100;
  if (!isMiningProgress(progress)) return 0;
  const done = blocksBefore(legs, progress.leg) + Math.max(0, progress.offset);
  return Math.min(100, Math.round((done / total) * 1000) / 10);
}

export function validateSpec(spec: MissionSpec): { ok: true } | { ok: false; error: string } {
  if (!isBranchMineSpec(spec)) return { ok: false, error: "unknown mission kind" };
  if (!Number.isFinite(spec.maxRadius) || spec.maxRadius < 4) return { ok: false, error: "maxRadius too small" };
  if (spec.maxRadius > config.maxRadius) return { ok: false, error: `maxRadius exceeds local cap ${config.maxRadius}` };
  if (!Number.isFinite(spec.staging) || spec.staging < 0 || spec.staging > 4) {
    return { ok: false, error: "staging must be 0..4" };
  }
  if (spec.startY > 0) return { ok: false, error: "startY must be <= 0 (base is y=0)" };
  if (spec.endY > spec.startY) return { ok: false, error: "endY must be at or below startY" };
  if (-spec.endY > config.maxDepth) return { ok: false, error: `depth exceeds local cap ${config.maxDepth}` };
  if (spec.layerStep < 1) return { ok: false, error: "layerStep must be >= 1" };
  if (spec.spacing < 2) return { ok: false, error: "spacing must be >= 2" };
  if (spec.maxTripBlocks < 1) return { ok: false, error: "maxTripBlocks must be >= 1" };
  if (spec.maxVeinBlocks < 0) return { ok: false, error: "maxVeinBlocks must be >= 0" };
  if (spec.reserve < 0) return { ok: false, error: "reserve must be >= 0" };
  return { ok: true };
}
