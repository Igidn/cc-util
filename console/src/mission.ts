import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import { store } from "./store.js";
import { cachedLegs, planSummary, progressPercent, totalBlocks } from "./plan.js";
import type { Mission, MissionSpec, Station, Turtle } from "./types.js";
import { isTimberSpec, isTimberProgress, isBranchMineSpec, isMiningProgress } from "../shared/api.js";

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
    spec = {
      kind: "branchMine",
      base: { x: 0, y: 0, z: 0, f: 0 },
      staging,
      sector: {
        x0: -half,
        z0: -half - staging,
        x1: half,
        z1: half - staging,
      },
      startY: config.topWorldY - station.anchor.y,
      endY: config.bottomWorldY - station.anchor.y,
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
  if (existing) return existing;
  const mission = makeMission(turtle, station);
  turtle.missionId = mission.id;
  store.save();
  return mission;
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
