import fs from "node:fs";
import path from "node:path";
import { WebSocket } from "ws";
import { config } from "../src/config.js";
import { buildLegs } from "../src/plan.js";
import type { Mission, MissionSpec, Progress, StoreData } from "../shared/api.js";
import { DEMO_UNITS } from "./demo-data.js";

const targetDir = process.env.DATA_DIR
  ? config.dataDir
  : path.join(config.root, "data", "demo");
const file = path.join(targetDir, "state.json");

if (!fs.existsSync(file)) {
  console.error(`[demo] no state at ${file}. Run npm run seed:demo first.`);
  process.exit(1);
}

type Sim = {
  id: string;
  legs: ReturnType<typeof buildLegs>;
  total: number;
  progress: Progress;
  stats: { blocks: number; ores: number; trips: number };
  running: boolean;
};

function makeSim(
  id: string,
  spec: MissionSpec,
  progress?: Progress,
  stats?: { blocks: number; ores: number; trips: number },
): Sim {
  const legs = buildLegs(spec);
  const first = legs[0];
  return {
    id,
    legs,
    total: legs.reduce((sum, leg) => sum + leg.length, 0),
    progress: progress ?? {
      leg: 1,
      offset: 0,
      layer: first?.layer ?? 0,
      strip: first?.strip ?? 0,
    },
    stats: stats ? { ...stats } : { blocks: 0, ores: 0, trips: 0 },
    running: true,
  };
}

function advance(sim: Sim, amount: number): boolean {
  let leg = Math.max(1, Math.min(sim.progress.leg, sim.legs.length));
  let offset = Math.max(0, sim.progress.offset);
  let remaining = amount;
  let moved = 0;

  while (remaining > 0) {
    const row = sim.legs[leg - 1];
    const space = Math.max(0, row.length - offset);
    if (space === 0) {
      if (leg >= sim.legs.length) break;
      leg += 1;
      offset = 0;
      continue;
    }
    const take = Math.min(space, remaining);
    offset += take;
    remaining -= take;
    moved += take;
    if (offset >= row.length) {
      if (leg >= sim.legs.length) break;
      leg += 1;
      offset = 0;
    }
  }

  const row = sim.legs[Math.max(0, Math.min(leg, sim.legs.length) - 1)];
  sim.progress = { leg, offset, layer: row.layer, strip: row.strip };
  sim.stats.blocks = Math.min(sim.total, sim.stats.blocks + moved);
  if (moved > 0) sim.stats.ores += Math.max(1, Math.round(moved / 48));
  return leg >= sim.legs.length && offset >= row.length;
}

const state = JSON.parse(fs.readFileSync(file, "utf8")) as StoreData;
const port = process.env.PORT ?? "3000";
const endpoint =
  process.env.DEMO_SERVER ?? `ws://127.0.0.1:${port}/ws`;
const clients: WebSocket[] = [];

for (const unit of DEMO_UNITS) {
  if (!unit.connect) continue;
  const turtle = state.turtles[unit.id];
  if (!turtle) {
    console.warn(`[demo] missing ${unit.label} in state`);
    continue;
  }

  const ws = new WebSocket(endpoint);
  clients.push(ws);
  let heartbeat: NodeJS.Timeout | null = null;
  let ticker: NodeJS.Timeout | null = null;
  const pose = unit.pose;
  const fuel = unit.fuel;
  const inventory = unit.inventory;
  let turtleState = unit.state;
  const seeded = turtle.missionId ? state.missions[turtle.missionId] : undefined;
  let sim: Sim | null =
    seeded?.state === "active" && turtle.missionId
      ? makeSim(seeded.id, seeded.spec, seeded.progress, seeded.stats)
      : null;

  const send = (message: unknown) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
  };

  const beat = () => {
    send({
      v: 1,
      type: "heartbeat",
      pose,
      fuel,
      inventory,
      state: turtleState,
      missionId: turtle.missionId ?? null,
    });
  };

  const step = () => {
    if (!sim?.running) return;
    const done = advance(sim, 48);
    send({
      v: 1,
      type: "progress",
      missionId: sim.id,
      progress: sim.progress,
      pose,
      fuel,
      inventory,
      state: "mining",
      stats: sim.stats,
    });
    if (done) {
      send({ v: 1, type: "result", missionId: sim.id, status: "done", progress: sim.progress, stats: sim.stats });
      sim = null;
      turtle.missionId = null;
      turtleState = "idle";
    }
  };

  ws.on("open", () => {
    send({
      v: 1,
      type: "hello",
      id: turtle.id,
      secret: unit.secret,
      fw: "CC:T 1.20.1",
      pose,
      fuel,
      inventory,
      state: turtleState,
      missionId: turtle.missionId ?? null,
    });
    heartbeat = setInterval(beat, 4_000);
    ticker = setInterval(step, 8_000);
    console.log(`[demo] ${unit.label.padEnd(8)} ${unit.role.padEnd(11)} ${turtleState}`);
  });

  ws.on("message", (raw) => {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw.toString()) as Record<string, unknown>;
    } catch {
      return;
    }
    if (message.type === "command") {
      if (typeof message.id === "string") {
        send({ v: 1, type: "ack", id: message.id });
      }
      if (message.op === "ping") beat();
      if (message.op === "abort" && sim) {
        sim.running = false;
        send({
          v: 1,
          type: "result",
          missionId: sim.id,
          status: "failed",
          error: "aborted by demo operator",
          progress: sim.progress,
          stats: sim.stats,
        });
        sim = null;
        turtle.missionId = null;
        turtleState = "idle";
      }
      if (message.op === "returnHome" && sim) {
        sim.running = false;
        send({
          v: 1,
          type: "result",
          missionId: sim.id,
          status: "paused",
          progress: sim.progress,
          stats: sim.stats,
        });
        turtleState = "paused";
      }
      if (message.op === "startMission") {
        const mission = message.mission as { id?: string; spec?: MissionSpec } | undefined;
        const id = typeof mission?.id === "string" ? mission.id : turtle.missionId;
        if (id && sim?.id !== id) {
          const stored: Mission | undefined = state.missions[id];
          if (mission?.spec) {
            sim = makeSim(id, mission.spec, stored?.progress, stored?.stats);
            turtle.missionId = id;
            turtleState = "mining";
          }
        } else if (sim) {
          sim.running = true;
          turtleState = "mining";
        }
      }
    }
    if (message.type === "error") {
      console.error(`[demo] ${unit.label}: ${String(message.error ?? "server error")}`);
    }
  });

  ws.on("close", (code) => {
    if (heartbeat) clearInterval(heartbeat);
    if (ticker) clearInterval(ticker);
    console.log(`[demo] ${unit.label.padEnd(8)} disconnected (${code})`);
  });

  ws.on("error", (error) => {
    console.error(`[demo] ${unit.label}: ${error.message}`);
  });
}

console.log(`[demo] connected ${clients.length} simulated turtles to ${endpoint}`);

const shutdown = () => {
  for (const ws of clients) {
    try {
      ws.close();
    } catch {
      /* ignore */
    }
  }
  process.exit(0);
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
