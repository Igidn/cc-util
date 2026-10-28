export type Vec3 = { x: number; y: number; z: number };
export type Facing = 0 | 1 | 2 | 3;
export type Pose = Vec3 & { f: Facing };

export type Sector = { x0: number; z0: number; x1: number; z1: number };

export type MissionSpec =
  | {
      kind: "branchMine";
      base: Pose;
      /** 2 = base is the station room dock, not the surface. */
      baseVersion?: number;
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
    }
  | {
      kind: "timber";
      base: Pose;
      treePos: Pose;
      chestPos: Pose;
      saplingChestPos: Pose;
      maxCycles: number;
      reserve: number;
      // UI fields
      radius: number;
      species: string[];
      replant: boolean;
      deposit: string;
      grid: string;
      zone: string;
    };

export function isBranchMineSpec(spec: MissionSpec): spec is MissionSpec & { kind: "branchMine" } {
  return spec.kind === "branchMine";
}

export function isTimberSpec(spec: MissionSpec): spec is MissionSpec & { kind: "timber" } {
  return spec.kind === "timber";
}

export type Progress =
  | { leg: number; offset: number; layer: number; strip: number }
  | { cycles: number };

export function isMiningProgress(p: Progress): p is { leg: number; offset: number; layer: number; strip: number } {
  return "leg" in p;
}

export function isTimberProgress(p: Progress): p is { cycles: number } {
  return "cycles" in p;
}

export type InventoryItem = { slot: number; name: string; count: number };

export type Station = {
  id: string;
  index: number;
  anchor: Vec3;
  createdAt: number;
  name: string;
  /** Surface entry of the shaft, reported by the station builder. */
  shaftPose: Pose | null;
  /** Shaft column at the room's walking level (top of the room). */
  roomPose: Pose | null;
  /** Miner dock inside the room: one block south of the shaft column. */
  dockPose: Pose | null;
  built: boolean;
  storageChestCount: number;
  storageChestsFilled: number;
  depotNotifiedAt: number | null;
  haulerEvacuatingAt: number | null;
};

export type TurtleRole = "miner" | "lumberjack" | "hauler" | "unassigned" | "station_builder";

export type Turtle = {
  id: string;
  secretHash: string;
  stationId: string;
  role: TurtleRole;
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

export type MissionState = "offered" | "active" | "paused" | "done" | "failed";

export type Mission = {
  id: string;
  turtleId: string;
  spec: MissionSpec;
  state: MissionState;
  progress: Progress;
  stats: MissionStats;
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

export type Chest = {
  id: string;
  stationId: string;
  kind: "storage" | "refuel" | "depot" | "fuel";
  pose: Pose;
  label?: string;
  filledAt?: number;
  requestedBy?: string;
  fillPercent?: number;
};

export type ItemRequest = {
  id: string;
  stationId: string;
  requestedBy: string;
  itemName: string;
  count: number;
  status: "pending" | "assigned" | "delivered" | "cancelled";
  haulerId?: string;
  createdAt: number;
  updatedAt: number;
};

export type ShaftLock = {
  stationId: string;
  holderTurtleId: string | null;
  queue: string[];
  acquiredAt: number | null;
  expiresAt: number | null;
};

/** Sparse per-station ore map. Tunnels are derived from the deterministic plan. */
export type StationMap = { ores: Record<string, OreCell> };

export type StoreData = {
  version: 1;
  turtles: Record<string, Turtle>;
  stations: Record<string, Station>;
  missions: Record<string, Mission>;
  events: EventRecord[];
  maps: Record<string, StationMap>;
  chests: Record<string, Chest>;
  requests: Record<string, ItemRequest>;
  shaftLocks: Record<string, ShaftLock>;
};

export type PublicTurtle = Omit<Turtle, "secretHash">;

export type PlanSummary = {
  totalBlocks: number;
  layers: number;
  strips: number;
};

export type MissionStats = 
  | { blocks: number; ores: number; trips: number }
  | { blocks: number; ores: number; trips: number; logs: number; planted: number; collected: number; deposited: number };

export type MissionSummary = {
  id: string;
  turtleId: string;
  state: MissionState;
  progress: Progress;
  stats: MissionStats;
  percent: number;
  blocksTotal: number;
  plan: PlanSummary;
  spec: MissionSpec;
  // Timber-specific fields
  grid?: string;
  zone?: string;
  createdAt: number;
  updatedAt: number;
};

export type PublicConfig = {
  port: number;
  sectorHalf: number;
  topWorldY: number;
  bottomWorldY: number;
  layerStep: number;
  branchSpacing: number;
  reserve: number;
  maxTripBlocks: number;
  maxVeinBlocks: number;
  maxRadius: number;
  maxDepth: number;
  baseX: number;
  baseY: number;
  baseZ: number;
  stationSpacing: number;
  heartbeatMs: number;
  staleMs: number;
  adminRequired: boolean;
  publish: boolean;
  githubRepo: string;
  releaseTag: string;
};

export type OreTally = { name: string; count: number };

export type SnapshotCounts = {
  turtles: number;
  online: number;
  miners: number;
  lumberjacks: number;
  activeMissions: number;
  pausedMissions: number;
  failedMissions: number;
  ores: number;
  blocks: number;
  trips: number;
};

export type Snapshot = {
  serverTime: number;
  tunnelUrl: string;
  online: string[];
  config: PublicConfig;
  counts: SnapshotCounts;
  turtles: PublicTurtle[];
  stations: Station[];
  missions: MissionSummary[];
  events: EventRecord[];
  ores: OreTally[];
  oreRecent: (OreCell & { stationId: string })[];
  oreCounts: Record<string, number>;
  chests: Chest[];
  requests: ItemRequest[];
  shaftLocks: ShaftLock[];
};
