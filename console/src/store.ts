import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import type { EventRecord, OreCell, StoreData, TurtleRole } from "./types.js";

const ROLES: TurtleRole[] = ["miner", "lumberjack", "hauler", "unassigned"];

function empty(): StoreData {
  return { version: 1, turtles: {}, stations: {}, missions: {}, events: [], maps: {} };
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
      if (!raw.maps) raw.maps = {};
      for (const turtle of Object.values(raw.turtles ?? {})) {
        if (!ROLES.includes(turtle.role)) turtle.role = "miner";
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
