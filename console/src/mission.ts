import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import { store } from "./store.js";
import { buildLegs, progressPercent, totalBlocks } from "./plan.js";
import type { Mission, MissionSpec, Station, Turtle } from "./types.js";

export function makeMission(turtle: Turtle, station: Station): Mission {
  const staging = 1;
  // The turtle enforces its own hard cap; never hand it a wider sector.
  const half = Math.min(config.sectorHalf, config.maxRadius);
  const spec: MissionSpec = {
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

  const now = Date.now();
  const mission: Mission = {
    id: randomUUID(),
    turtleId: turtle.id,
    spec,
    state: "offered",
    progress: { leg: 1, offset: 0, layer: 0, strip: 0 },
    stats: { blocks: 0, ores: 0, trips: 0 },
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
  const legs = buildLegs(mission.spec);
  return {
    id: mission.id,
    turtleId: mission.turtleId,
    state: mission.state,
    progress: mission.progress,
    stats: mission.stats,
    percent: progressPercent(legs, mission.progress),
    blocksTotal: totalBlocks(legs),
    createdAt: mission.createdAt,
    updatedAt: mission.updatedAt,
  };
}
