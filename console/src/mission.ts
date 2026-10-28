import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import { store } from "./store.js";
import { cachedLegs, planSummary, progressPercent, totalBlocks } from "./plan.js";
import type { Mission, MissionSpec, Pose, Station, Turtle } from "./types.js";
import { isTimberSpec, isTimberProgress, isBranchMineSpec, isMiningProgress } from "../shared/api.js";

/**
 * Where the miner docks in the station room. New stations report this directly;
 * older ones fall back to the room pose or, failing that, the turtle's last
 * known column and the anchor's Y.
 */
function branchMineDock(station: Station, turtle: Turtle): Pose {
  if (station.dockPose) return station.dockPose;
  if (station.roomPose) {
    return { x: station.roomPose.x, y: station.roomPose.y, z: station.roomPose.z + 1, f: 0 };
  }
  return {
    x: turtle.pose?.x ?? 0,
    y: station.anchor.y + 1,
    z: (turtle.pose?.z ?? 0) + 1,
    f: 0,
  };
}

export function makeMission(turtle: Turtle, station: Station): Mission {
  const now = Date.now();
  let spec: MissionSpec;
  
  if (turtle.role === "lumberjack") {
    const stationIndex = station.index || 0;
    const grid = `S${String(stationIndex).padStart(2, "0")} · ${station.anchor.x}, ${station.anchor.z}`;
    const zone = turtle.label?.trim() || `Grove ${stationIndex + 1}`;
    
    spec = {
      kind: "timber",
      base: { x: 0, y: 0, z: 0, f: 0 },
      treePos: { x: 1, y: 0, z: 0, f: 0 }, // Tree is 1 block forward from base
      chestPos: { x: 0, y: 0, z: 0, f: 1 }, // Chest is to the right (east) of base
      saplingChestPos: { x: 0, y: 1, z: 0, f: 0 }, // Sapling chest is above base
      maxCycles: 0, // Infinite
      reserve: config.reserve,
      // UI fields
      radius: 32,
      species: ["dark_oak"],
      replant: true,
      deposit: grid,
      grid,
      zone,
    };
  } else {
    const staging = 1;
    const half = Math.min(config.sectorHalf, config.maxRadius);
    // The miner works from the station room, not the surface. The dock is one
    // block south of the shaft column at the room's walking level; the plan's
    // staging leg (north 1) steps into the shaft column, then descends to the
    // first mining layer. Stations built before geometry reporting fall back to
    // the turtle's last known column and the anchor's Y.
    const dock = branchMineDock(station, turtle);
    spec = {
      kind: "branchMine",
      base: { x: dock.x, y: dock.y, z: dock.z, f: dock.f ?? 0 },
      baseVersion: 2,
      staging,
      sector: {
        x0: -half,
        z0: -half - staging,
        x1: half,
        z1: half - staging,
      },
      startY: config.topWorldY - dock.y,
      endY: config.bottomWorldY - dock.y,
      layerStep: config.layerStep,
      spacing: config.branchSpacing,
      maxRadius: config.sectorHalf,
      maxTripBlocks: config.maxTripBlocks,
      maxVeinBlocks: config.maxVeinBlocks,
      reserve: config.reserve,
    };
  }

  const mission: Mission = {
    id: randomUUID(),
    turtleId: turtle.id,
    spec,
    state: "offered",
    progress: spec.kind === "timber" ? { cycles: 0 } : { leg: 1, offset: 0, layer: 0, strip: 0 },
    stats: spec.kind === "timber" ? { blocks: 0, ores: 0, trips: 0, collected: 0, deposited: 0, planted: 0 } : { blocks: 0, ores: 0, trips: 0 },
    createdAt: now,
    updatedAt: now,
  };

  store.data.missions[mission.id] = mission;
  store.event(turtle.id, "mission_created", { missionId: mission.id });
  store.save();
  return mission;
}

export function currentMission(turtleId: string): Mission | undefined {
  return Object.values(store.data.missions).find(
    (m) => m.turtleId === turtleId && (m.state === "offered" || m.state === "active" || m.state === "paused"),
  );
}

export function ensureMission(turtle: Turtle, station: Station): Mission {
  const existing = currentMission(turtle.id);
  if (existing) {
    rebaseLegacyBranchMine(existing, turtle, station);
    return existing;
  }
  const mission = makeMission(turtle, station);
  turtle.missionId = mission.id;
  store.save();
  return mission;
}

/**
 * Missions created before the room-as-base change carry `base {0,0,0}` and a
 * startY measured from the synthetic station anchor. Rewrite them onto the
 * real dock before they are re-offered. Safe because the placeholder base was
 * never a valid world position, and the rewrite skips any mission that already
 * mined something.
 */
function rebaseLegacyBranchMine(mission: Mission, turtle: Turtle, station: Station): void {
  const spec = mission.spec;
  if (!isBranchMineSpec(spec)) return;
  if (spec.baseVersion === 2) return;
  if ((mission.stats?.blocks ?? 0) > 0 || (mission.stats?.trips ?? 0) > 0) return;

  const dock = branchMineDock(station, turtle);
  const placeholder = spec.base.x === 0 && spec.base.y === 0 && spec.base.z === 0;
  const sameDock = spec.base.x === dock.x && spec.base.y === dock.y && spec.base.z === dock.z;
  if (!placeholder && !sameDock) return;

  spec.base = { x: dock.x, y: dock.y, z: dock.z, f: dock.f ?? 0 };
  spec.baseVersion = 2;
  spec.startY = config.topWorldY - dock.y;
  spec.endY = config.bottomWorldY - dock.y;
  mission.updatedAt = Date.now();
  store.event(turtle.id, "mission_rebased", { missionId: mission.id, base: spec.base });
  store.save();
}

export function missionSummary(mission: Mission) {
  const spec = mission.spec;
  if (isTimberSpec(spec)) {
    const progress = isTimberProgress(mission.progress) ? mission.progress : { cycles: 0 };
    return {
      id: mission.id,
      turtleId: mission.turtleId,
      state: mission.state,
      progress: mission.progress,
      stats: mission.stats,
      percent: progress.cycles > 0 ? Math.min(100, progress.cycles * 10) : 0, // placeholder
      blocksTotal: spec.maxCycles > 0 ? spec.maxCycles : 0,
      plan: { totalBlocks: 0, layers: 0, strips: 0 },
      spec: mission.spec,
      grid: spec.grid,
      zone: spec.zone ?? "Unnamed Grove",
      createdAt: mission.createdAt,
      updatedAt: mission.updatedAt,
    };
  }
  
  if (!isBranchMineSpec(spec) || !isMiningProgress(mission.progress)) {
    throw new Error("Invalid mission spec or progress for branch mine");
  }
  const legs = cachedLegs(spec);
  return {
    id: mission.id,
    turtleId: mission.turtleId,
    state: mission.state,
    progress: mission.progress,
    stats: mission.stats,
    percent: progressPercent(legs, mission.progress),
    blocksTotal: totalBlocks(legs),
    plan: planSummary(spec),
    spec: mission.spec,
    createdAt: mission.createdAt,
    updatedAt: mission.updatedAt,
  };
}
