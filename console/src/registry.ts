import { createHash } from "node:crypto";
import { config } from "./config.js";
import { store } from "./store.js";
import type { Station, Turtle } from "./types.js";

export function hashSecret(secret: string): string {
  return createHash("sha256").update(secret).digest("hex");
}

function nextStationIndex(): number {
  const used = new Set(Object.values(store.data.stations).map((s) => s.index));
  for (let i = 0; ; i++) if (!used.has(i)) return i;
}

export function register(body: unknown):
  | { ok: true; turtle: Turtle; station: Station }
  | { ok: false; error: string } {
  const input = (body ?? {}) as Record<string, unknown>;
  const id = String(input.id ?? "");
  const secret = String(input.secret ?? "");

  if (!/^[a-f0-9]{16,64}$/.test(id)) return { ok: false, error: "invalid id" };
  if (!/^[a-f0-9]{32,128}$/.test(secret)) return { ok: false, error: "invalid secret" };

  const existing = store.data.turtles[id];
  if (existing) {
    if (existing.secretHash !== hashSecret(secret)) return { ok: false, error: "secret mismatch" };
    existing.lastSeen = Date.now();
    if (typeof input.label === "string") existing.label = input.label;
    if (typeof input.computerId === "number") existing.computerId = input.computerId;
    store.save();
    return { ok: true, turtle: existing, station: store.data.stations[existing.stationId] };
  }

  const index = nextStationIndex();
  const station: Station = {
    id: `s${index}`,
    index,
    anchor: {
      x: config.baseX + index * config.stationSpacing,
      y: config.baseY,
      z: config.baseZ,
    },
    name: `Station ${index + 1}`,
    shaftPose: null,
    roomPose: null,
    dockPose: null,
    minerLanes: {},
    built: false,
    storageChestCount: 32,
    storageChestsFilled: 0,
    depotNotifiedAt: null,
    haulerEvacuatingAt: null,
    createdAt: Date.now(),
  };
  const turtle: Turtle = {
    id,
    secretHash: hashSecret(secret),
    stationId: station.id,
    role: "unassigned",
    computerId: typeof input.computerId === "number" ? input.computerId : undefined,
    label: typeof input.label === "string" ? input.label : undefined,
    createdAt: Date.now(),
    lastSeen: Date.now(),
    state: "idle",
    missionId: null,
  };

  store.data.stations[station.id] = station;
  store.data.turtles[id] = turtle;
  store.event(id, "registered", { station: station.id, index });
  store.save();
  return { ok: true, turtle, station };
}

export function authenticate(id: string, secret: string): Turtle | null {
  const turtle = store.data.turtles[id];
  if (!turtle) return null;
  if (turtle.secretHash !== hashSecret(secret)) return null;
  turtle.lastSeen = Date.now();
  return turtle;
}

export function publicTurtle(turtle: Turtle) {
  return {
    id: turtle.id,
    stationId: turtle.stationId,
    role: turtle.role ?? "miner",
    computerId: turtle.computerId,
    label: turtle.label,
    createdAt: turtle.createdAt,
    lastSeen: turtle.lastSeen,
    state: turtle.state,
    pose: turtle.pose,
    fuel: turtle.fuel,
    inventory: turtle.inventory,
    missionId: turtle.missionId,
  };
}
