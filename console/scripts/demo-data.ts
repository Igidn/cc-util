import { createHash, randomUUID } from "node:crypto";
import type {
  EventRecord,
  InventoryItem,
  Mission,
  MissionSpec,
  MissionState,
  OreCell,
  Pose,
  Station,
  StoreData,
  Turtle,
  TurtleRole,
} from "../shared/api.js";
import { config } from "../src/config.js";
import { buildLegs, totalBlocks } from "../src/plan.js";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export type DemoUnit = {
  id: string;
  secret: string;
  label: string;
  computerId: number;
  role: TurtleRole;
  stationIndex: number;
  connect: boolean;
  state: string;
  fuel: number | "unlimited";
  pose?: Pose;
  lastSeenAgo: number;
  inventory: InventoryItem[];
  mission?: {
    state: MissionState;
    fraction: number;
    createdAgo: number;
    updatedAgo: number;
  };
};

const ore = (slot: number, name: string, count: number): InventoryItem => ({ slot, name, count });

export const DEMO_UNITS: DemoUnit[] = [
  {
    id: "a7f3c2d91b4e6a80",
    secret: "a7f3c2d91b4e6a80f1c5e9b3d7a2048c6e1f9b5d3a7c2e8046b8d1f5a3c9e7b2",
    label: "Ward",
    computerId: 12,
    role: "miner",
    stationIndex: 0,
    connect: true,
    state: "mining",
    fuel: 512,
    pose: { x: 18, y: -54, z: 26, f: 1 },
    lastSeenAgo: 2_000,
    inventory: [
      ore(1, "minecraft:cobbled_deepslate", 64),
      ore(2, "minecraft:coal", 64),
      ore(3, "minecraft:raw_iron", 58),
      ore(4, "minecraft:raw_copper", 48),
      ore(5, "minecraft:redstone", 39),
      ore(6, "minecraft:lapis_lazuli", 18),
      ore(7, "minecraft:raw_gold", 9),
      ore(8, "minecraft:diamond", 3),
    ],
    mission: { state: "active", fraction: 0.46, createdAgo: 5 * HOUR, updatedAgo: 40_000 },
  },
  {
    id: "b2e8d4c17a9f3065",
    secret: "b2e8d4c17a9f3065a4d9e7c1b5f3086a2c8e4d7b1f9a5036c2e8d4b7a1f5c9e3",
    label: "Tallow",
    computerId: 14,
    role: "miner",
    stationIndex: 1,
    connect: true,
    state: "mining",
    fuel: 28,
    pose: { x: -22, y: -64, z: -30, f: 3 },
    lastSeenAgo: 5_000,
    inventory: [
      ore(1, "minecraft:cobbled_deepslate", 64),
      ore(2, "minecraft:coal", 64),
      ore(3, "minecraft:raw_iron", 64),
      ore(4, "minecraft:raw_copper", 64),
      ore(5, "minecraft:redstone", 48),
      ore(6, "minecraft:lapis_lazuli", 32),
      ore(7, "minecraft:raw_gold", 16),
      ore(8, "minecraft:diamond", 8),
      ore(9, "minecraft:emerald", 2),
      ore(10, "gtceu:tin_dust", 24),
      ore(11, "gtceu:nickel_dust", 16),
      ore(12, "minecraft:coal", 64),
      ore(13, "minecraft:raw_iron", 64),
      ore(14, "minecraft:raw_copper", 64),
      ore(15, "minecraft:redstone", 17),
    ],
    mission: { state: "active", fraction: 0.79, createdAgo: 3.4 * HOUR, updatedAgo: 5_000 },
  },
  {
    id: "c4a1f7e28d3b5096",
    secret: "c4a1f7e28d3b5096b8e2d5c1a7f4093b6d2e8c4a1f7b5039d5c8e2a4b6f1d7c3",
    label: "Mica",
    computerId: 18,
    role: "miner",
    stationIndex: 2,
    connect: true,
    state: "paused",
    fuel: 310,
    pose: { x: 24, y: -34, z: -8, f: 0 },
    lastSeenAgo: 95_000,
    inventory: [
      ore(1, "minecraft:cobbled_deepslate", 48),
      ore(2, "minecraft:coal", 64),
      ore(3, "minecraft:raw_iron", 37),
      ore(4, "minecraft:raw_copper", 28),
      ore(5, "minecraft:lapis_lazuli", 12),
    ],
    mission: { state: "paused", fraction: 0.34, createdAgo: 8 * HOUR, updatedAgo: 70 * MINUTE },
  },
  {
    id: "d9c5b3a17e2f4860",
    secret: "d9c5b3a17e2f4860c2f6e1a9d3b7058e4a1c7f2d9b5e3068a4c1f7d2b8e5a9c3",
    label: "Bramble",
    computerId: 22,
    role: "lumberjack",
    stationIndex: 3,
    connect: true,
    state: "idle",
    fuel: 744,
    pose: { x: 0, y: 0, z: 0, f: 2 },
    lastSeenAgo: 8_000,
    inventory: [
      ore(1, "minecraft:oak_sapling", 64),
      ore(2, "minecraft:birch_sapling", 64),
      ore(3, "minecraft:oak_log", 48),
      ore(4, "minecraft:spruce_log", 32),
      ore(5, "minecraft:charcoal", 24),
    ],
  },
  {
    id: "e1b7a9c34d6f8205",
    secret: "e1b7a9c34d6f8205d3a8f2c6e9b1047a5d1c8e3f6b2a9057c3e9d4b1f7a2c6e8",
    label: "Sable",
    computerId: 27,
    role: "hauler",
    stationIndex: 4,
    connect: true,
    state: "unloading",
    fuel: "unlimited",
    pose: { x: 0, y: 0, z: 0, f: 0 },
    lastSeenAgo: 3_000,
    inventory: [
      ore(1, "minecraft:raw_iron", 64),
      ore(2, "minecraft:raw_copper", 64),
      ore(3, "minecraft:coal", 64),
      ore(4, "minecraft:redstone", 48),
      ore(5, "minecraft:lapis_lazuli", 32),
      ore(6, "minecraft:oak_log", 64),
      ore(7, "minecraft:spruce_log", 48),
      ore(8, "minecraft:raw_gold", 12),
      ore(9, "gtceu:tin_dust", 16),
      ore(10, "minecraft:cobbled_deepslate", 64),
      ore(11, "minecraft:diamond", 4),
      ore(12, "minecraft:emerald", 2),
    ],
  },
  {
    id: "f3d9e5b71c4a2860",
    secret: "f3d9e5b71c4a2860e5b1d7c3a9f2046b8e2a5d1c7f3b9058a6d4e2b8c1f5a7d3",
    label: "Rook",
    computerId: 31,
    role: "miner",
    stationIndex: 5,
    connect: false,
    state: "stale",
    fuel: 440,
    pose: { x: -40, y: -18, z: 12, f: 2 },
    lastSeenAgo: 11 * MINUTE,
    inventory: [
      ore(1, "minecraft:cobbled_deepslate", 32),
      ore(2, "minecraft:coal", 41),
      ore(3, "minecraft:raw_iron", 19),
      ore(4, "minecraft:raw_copper", 12),
    ],
    mission: { state: "active", fraction: 0.18, createdAgo: 2.2 * HOUR, updatedAgo: 12 * MINUTE },
  },
  {
    id: "0a6c8e2d4f7b91c3",
    secret: "0a6c8e2d4f7b91c3a1e5c9b7d3f2068a4c8e1b5d9f3a7c2046e8b2d6f1a9c5e3",
    label: "Flint",
    computerId: 35,
    role: "unassigned",
    stationIndex: 6,
    connect: false,
    state: "stale",
    fuel: 12,
    lastSeenAgo: 2.5 * DAY,
    inventory: [],
  },
];

function specFor(station: Station): MissionSpec {
  const half = Math.min(config.sectorHalf, config.maxRadius);
  return {
    kind: "branchMine",
    base: { x: 0, y: 0, z: 0, f: 0 },
    staging: 1,
    sector: {
      x0: -half,
      z0: -half - 1,
      x1: half,
      z1: half - 1,
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

function progressAt(spec: MissionSpec, fraction: number) {
  const legs = buildLegs(spec);
  const total = totalBlocks(legs);
  let target = Math.round(total * Math.max(0, Math.min(1, fraction)));
  for (let index = 0; index < legs.length; index++) {
    const leg = legs[index];
    if (target <= leg.length) {
      return {
        progress: { leg: index + 1, offset: target, layer: leg.layer, strip: leg.strip },
        blocks: Math.round(total * fraction),
        total,
      };
    }
    target -= leg.length;
  }
  const last = legs[legs.length - 1];
  return {
    progress: { leg: legs.length, offset: last.length, layer: last.layer, strip: last.strip },
    blocks: total,
    total,
  };
}

function missionFor(
  unit: DemoUnit,
  turtle: Turtle,
  station: Station,
  now: number,
  index: number,
): Mission {
  if (!unit.mission) throw new Error(`${unit.label} has no demo mission`);
  const spec = specFor(station);
  const { progress, blocks } = progressAt(spec, unit.mission.fraction);
  const createdAt = now - unit.mission.createdAgo;
  return {
    id: `demo-${unit.id.slice(0, 6)}-${index}`,
    turtleId: turtle.id,
    spec,
    state: unit.mission.state,
    progress,
    stats: {
      blocks,
      ores: Math.max(1, Math.round(blocks / 340)),
      trips: Math.max(1, Math.floor(blocks / config.maxTripBlocks)),
    },
    createdAt,
    updatedAt: now - unit.mission.updatedAgo,
  };
}

function rng(seed: number): () => number {
  let state = seed;
  return () => {
    state += 0x6d2b79f5;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(text: string): number {
  let value = 2166136261;
  for (let index = 0; index < text.length; index++) {
    value ^= text.charCodeAt(index);
    value = Math.imul(value, 16777619);
  }
  return value >>> 0;
}

const ORE_TABLE = [
  ["minecraft:coal_ore", 24],
  ["minecraft:iron_ore", 18],
  ["minecraft:copper_ore", 15],
  ["minecraft:redstone_ore", 12],
  ["minecraft:lapis_ore", 8],
  ["minecraft:gold_ore", 6],
  ["minecraft:diamond_ore", 3],
  ["minecraft:emerald_ore", 1],
  ["gtceu:tin_ore", 7],
  ["gtceu:nickel_ore", 5],
] as const;

function oreName(random: () => number): string {
  const total = ORE_TABLE.reduce((sum, [, weight]) => sum + weight, 0);
  let roll = random() * total;
  for (const [name, weight] of ORE_TABLE) {
    roll -= weight;
    if (roll <= 0) return name;
  }
  return ORE_TABLE[0][0];
}

function makeOres(unit: DemoUnit, station: Station, count: number): OreCell[] {
  const spec = specFor(station);
  const random = rng(hash(`${unit.id}:${unit.label}:ores`));
  const half = spec.maxRadius;
  const cells: OreCell[] = [];
  for (let index = 0; index < count; index++) {
    const x = Math.round((random() * 2 - 1) * (half - 4));
    const z = Math.round((random() * 2 - 1) * (half - 4));
    const y = Math.round(spec.endY + 2 + random() * (spec.startY - spec.endY - 4));
    cells.push({ x, y, z, name: oreName(random) });
  }
  return cells;
}

export function buildDemoState(now = Date.now()): StoreData {
  const missions: Record<string, Mission> = {};
  const turtles: Record<string, Turtle> = {};
  const stations: Record<string, Station> = {};
  const events: EventRecord[] = [];
  const maps: StoreData["maps"] = {};

  const event = (turtleId: string, kind: string, at: number, data: unknown) => {
    events.push({ id: randomUUID(), at, turtleId, kind, data });
  };

  const hashes = new Map(
    DEMO_UNITS.map((unit) => [unit.id, createHash("sha256").update(unit.secret).digest("hex")]),
  );

  for (const unit of DEMO_UNITS) {
    const station: Station = {
      id: `s${unit.stationIndex}`,
      index: unit.stationIndex,
      anchor: {
        x: config.baseX + unit.stationIndex * config.stationSpacing,
        y: config.baseY,
        z: config.baseZ,
      },
      createdAt: now - (18 - unit.stationIndex) * DAY,
    };
    stations[station.id] = station;

    const turtle: Turtle = {
      id: unit.id,
      secretHash: hashes.get(unit.id)!,
      stationId: station.id,
      role: unit.role,
      computerId: unit.computerId,
      label: unit.label,
      createdAt: now - (18 - unit.stationIndex) * DAY,
      lastSeen: now - unit.lastSeenAgo,
      state: unit.state,
      pose: unit.pose,
      fuel: unit.fuel,
      inventory: unit.inventory,
      missionId: null,
    };

    if (unit.mission) {
      const mission = missionFor(unit, turtle, station, now, 1);
      missions[mission.id] = mission;
      turtle.missionId = mission.id;
    }
    turtles[unit.id] = turtle;

    if (unit.mission) {
      const current = Object.values(missions).find((row) => row.turtleId === unit.id);
      if (current) {
        event(unit.id, "mission_created", current.createdAt, { missionId: current.id });
      }
    }
  }

  const ward = DEMO_UNITS[0];
  const tallow = DEMO_UNITS[1];
  const mica = DEMO_UNITS[2];
  const bramble = DEMO_UNITS[3];
  const sable = DEMO_UNITS[4];
  const rook = DEMO_UNITS[5];
  const flint = DEMO_UNITS[6];

  for (const unit of DEMO_UNITS) {
    const at = now - (12 - unit.stationIndex) * DAY;
    event(unit.id, "registered", at, { station: `s${unit.stationIndex}`, index: unit.stationIndex });
    event(unit.id, "connected", at + 30_000, { fw: "CC:T 1.20.1" });
  }

  event(ward.id, "renamed", now - 6 * DAY, { label: "Ward" });
  event(tallow.id, "renamed", now - 5 * DAY, { label: "Tallow" });
  event(bramble.id, "role_changed", now - 5 * DAY, { role: "lumberjack" });
  event(sable.id, "role_changed", now - 4 * DAY, { role: "hauler" });
  event(flint.id, "role_changed", now - 3 * DAY, { role: "unassigned" });

  const wardHistory = missionFor(
    { ...ward, mission: { state: "done", fraction: 1, createdAgo: 2.5 * DAY, updatedAgo: 1.4 * DAY } },
    turtles[ward.id],
    stations[`s${ward.stationIndex}`],
    now,
    2,
  );
  missions[wardHistory.id] = wardHistory;
  event(ward.id, "mission_created", wardHistory.createdAt, { missionId: wardHistory.id });
  event(ward.id, "mission_result", wardHistory.updatedAt, {
    status: "done",
    missionId: wardHistory.id,
    blocks: wardHistory.stats.blocks,
    trips: wardHistory.stats.trips,
  });

  const tallowFailure = missionFor(
    {
      ...tallow,
      mission: { state: "failed", fraction: 0.07, createdAgo: 7 * HOUR, updatedAgo: 6.1 * HOUR },
    },
    turtles[tallow.id],
    stations[`s${tallow.stationIndex}`],
    now,
    2,
  );
  missions[tallowFailure.id] = tallowFailure;
  event(tallow.id, "mission_created", tallowFailure.createdAt, { missionId: tallowFailure.id });
  event(tallow.id, "fault", now - 6.2 * HOUR, {
    code: "MOVE_BLOCKED",
    error: "Movement blocked at Y -48 while cutting a branch",
    pose: { x: -12, y: -58, z: -18, f: 2 },
  });
  event(tallow.id, "recovery_failed", now - 6.16 * HOUR, {
    error: "Tape replay diverged at leg 41",
  });
  event(tallow.id, "disconnected", now - 6.14 * HOUR, { code: 4004 });
  event(tallow.id, "mission_result", tallowFailure.updatedAt, {
    status: "failed",
    missionId: tallowFailure.id,
    error: "MOVE_BLOCKED",
  });
  event(tallow.id, "connected", now - 3.5 * HOUR, { fw: "CC:T 1.20.1" });

  const micaHistory = missionFor(
    { ...mica, mission: { state: "done", fraction: 1, createdAgo: 4 * DAY, updatedAgo: 3 * DAY } },
    turtles[mica.id],
    stations[`s${mica.stationIndex}`],
    now,
    2,
  );
  missions[micaHistory.id] = micaHistory;
  event(mica.id, "mission_created", micaHistory.createdAt, { missionId: micaHistory.id });
  event(mica.id, "mission_result", micaHistory.updatedAt, {
    status: "done",
    missionId: micaHistory.id,
    blocks: micaHistory.stats.blocks,
    trips: micaHistory.stats.trips,
  });

  const micaCurrent = Object.values(missions).find(
    (row) => row.turtleId === mica.id && row.state === "paused",
  );
  if (micaCurrent) {
    event(mica.id, "mission_result", micaCurrent.updatedAt, {
      status: "paused",
      missionId: micaCurrent.id,
      blocks: micaCurrent.stats.blocks,
      trips: micaCurrent.stats.trips,
    });
  }

  event(rook.id, "connected", now - 2.2 * HOUR, { fw: "CC:T 1.20.1" });
  event(rook.id, "disconnected", now - 11 * MINUTE, { code: 4004 });
  event(flint.id, "disconnected", now - 2.5 * DAY, { code: 4001 });

  event(bramble.id, "connected", now - 18 * MINUTE, { fw: "CC:T 1.20.1" });
  event(sable.id, "connected", now - 34 * MINUTE, { fw: "CC:T 1.20.1" });
  event(ward.id, "connected", now - 5 * HOUR, { fw: "CC:T 1.20.1" });
  event(mica.id, "connected", now - 4 * HOUR, { fw: "CC:T 1.20.1" });

  const mappedUnits = [ward, tallow, mica, rook];
  const counts: Record<string, number> = {
    [ward.id]: 38,
    [tallow.id]: 27,
    [mica.id]: 15,
    [rook.id]: 9,
  };
  const oreCells: { unit: DemoUnit; station: Station; cell: OreCell }[] = [];

  for (const unit of mappedUnits) {
    const station = stations[`s${unit.stationIndex}`];
    const cells = makeOres(unit, station, counts[unit.id]);
    maps[station.id] = {
      ores: Object.fromEntries(cells.map((cell) => [`${cell.x},${cell.y},${cell.z}`, cell])),
    };
    for (const cell of cells) oreCells.push({ unit, station, cell });
  }

  const random = rng(20_261_026);
  const reportCells = oreCells
    .map((entry) => ({ entry, key: random() }))
    .sort((a, b) => a.key - b.key)
    .slice(0, 42)
    .map((item) => item.entry);
  for (const entry of reportCells) {
    event(entry.unit.id, "ore", now - 40 * MINUTE - random() * 21 * HOUR, {
      ...entry.cell,
      stationId: `s${entry.unit.stationIndex}`,
    });
  }

  events.sort((a, b) => a.at - b.at);

  return {
    version: 1,
    turtles,
    stations,
    missions,
    events,
    maps,
  };
}
