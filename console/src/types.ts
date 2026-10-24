export type Vec3 = { x: number; y: number; z: number };
export type Facing = 0 | 1 | 2 | 3;
export type Pose = Vec3 & { f: Facing };

export type Sector = { x0: number; z0: number; x1: number; z1: number };

export type MissionSpec = {
  kind: "branchMine";
  base: Pose;
  staging: number;
  sector: Sector;
  startY: number;
  endY: number;
  layerStep: number;
  spacing: number;
  maxRadius: number;
  maxTripBlocks: number;
  maxVeinBlocks: number;
  reserve: number;
};

export type Progress = {
  leg: number;
  offset: number;
  layer: number;
  strip: number;
};

export type InventoryItem = { slot: number; name: string; count: number };

export type Station = {
  id: string;
  index: number;
  anchor: Vec3;
  createdAt: number;
};

export type Turtle = {
  id: string;
  secretHash: string;
  stationId: string;
  computerId?: number;
  label?: string;
  createdAt: number;
  lastSeen: number;
  state: string;
  pose?: Pose;
  fuel?: number | "unlimited";
  inventory?: InventoryItem[];
  missionId?: string | null;
};

export type Mission = {
  id: string;
  turtleId: string;
  spec: MissionSpec;
  state: "offered" | "active" | "paused" | "done" | "failed";
  progress: Progress;
  stats: { blocks: number; ores: number; trips: number };
  createdAt: number;
  updatedAt: number;
};

export type EventRecord = {
  id: string;
  at: number;
  turtleId: string;
  kind: string;
  data: unknown;
};

export type OreCell = { x: number; y: number; z: number; name: string };

/** Sparse per-station ore map. Tunnels are derived from the deterministic plan. */
export type StationMap = { ores: Record<string, OreCell> };

export type StoreData = {
  version: 1;
  turtles: Record<string, Turtle>;
  stations: Record<string, Station>;
  missions: Record<string, Mission>;
  events: EventRecord[];
  maps: Record<string, StationMap>;
};
