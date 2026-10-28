import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import type { EventRecord, OreCell, StoreData, TurtleRole } from "./types.js";

const ROLES: TurtleRole[] = ["miner", "lumberjack", "hauler", "unassigned", "station_builder"];

function empty(): StoreData {
  return { version: 1, turtles: {}, stations: {}, missions: {}, events: [], maps: {}, chests: {}, requests: {}, shaftLocks: {} };
}

class Store {
  data: StoreData;
  private file: string;
  private timer: NodeJS.Timeout | null = null;
  private listeners = new Set<() => void>();

  constructor() {
    fs.mkdirSync(config.dataDir, { recursive: true });
    this.file = path.join(config.dataDir, "state.json");
    this.data = this.read();
  }

  private read(): StoreData {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, "utf8")) as StoreData;
      if (raw.version !== 1) return empty();
      if (!raw.turtles) raw.turtles = {};
      if (!raw.stations) raw.stations = {};
      if (!raw.missions) raw.missions = {};
      if (!raw.events) raw.events = [];
      if (!raw.maps) raw.maps = {};
      if (!raw.chests) raw.chests = {};
      if (!raw.requests) raw.requests = {};
      if (!raw.shaftLocks) raw.shaftLocks = {};
      for (const turtle of Object.values(raw.turtles ?? {})) {
        if (!ROLES.includes(turtle.role)) turtle.role = "miner";
      }
      for (const station of Object.values(raw.stations ?? {})) {
        if (typeof station.name !== "string") station.name = `Station ${station.index}`;
        if (station.shaftPose === undefined) station.shaftPose = null;
        if (station.roomPose === undefined) station.roomPose = null;
        if (station.dockPose === undefined) station.dockPose = null;
        if (station.built === undefined) station.built = false;
        if (typeof station.storageChestCount !== "number") station.storageChestCount = 32;
        if (typeof station.storageChestsFilled !== "number") station.storageChestsFilled = 0;
        if (station.depotNotifiedAt === undefined) station.depotNotifiedAt = null;
        if (station.haulerEvacuatingAt === undefined) station.haulerEvacuatingAt = null;
      }
      return raw;
    } catch {
      return empty();
    }
  }

  /** Notify the realtime layer. The store stays debounced on disk writes. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private notify(): void {
    for (const listener of this.listeners) {
      try {
        listener();
      } catch {
        /* a dead subscriber must not break persistence */
      }
    }
  }

  save(): void {
    this.notify();
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.write();
    }, 100);
  }

  flush(): void {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.write();
  }

  private write(): void {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmp, this.file);
  }

  event(turtleId: string, kind: string, data: unknown): EventRecord {
    const event: EventRecord = { id: randomUUID(), at: Date.now(), turtleId, kind, data };
    this.data.events.push(event);
    if (this.data.events.length > 5000) {
      this.data.events.splice(0, this.data.events.length - 5000);
    }
    this.save();
    return event;
  }

  markOre(stationId: string, cell: OreCell): void {
    const map = (this.data.maps[stationId] ??= { ores: {} });
    map.ores[`${cell.x},${cell.y},${cell.z}`] = cell;
    this.save();
  }
}

export const store = new Store();
