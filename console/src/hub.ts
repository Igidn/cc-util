import { randomUUID } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { config } from "./config.js";
import { authenticate, publicTurtle } from "./registry.js";
import { ensureMission, missionSummary } from "./mission.js";
import { store } from "./store.js";
import type {
  InventoryItem,
  Mission,
  OreTally,
  Pose,
  Progress,
  PublicConfig,
  Snapshot,
  Turtle,
  TurtleRole,
} from "./types.js";

type Conn = { ws: WebSocket; turtle: Turtle; alive: boolean };

type Pending = {
  turtleId: string;
  message: string;
  timer: NodeJS.Timeout;
  retried: boolean;
};

class Hub {
  private wss: WebSocketServer | null = null;
  private connections = new Map<string, Conn>();
  private pending = new Map<string, Pending>();
  private seq = 0;
  tunnelUrl = "";

  attach(server: Server): void {
    this.wss = new WebSocketServer({ noServer: true });
    this.wss.on("connection", (ws) => this.onConnection(ws));

    // Route turtle upgrades ourselves. Attaching two WebSocketServer
    // instances with `path` to the same HTTP server makes one of them answer
    // 400 for the other's path (Socket.IO in particular).
    server.on("upgrade", (req: IncomingMessage, socket, head) => {
      const url = new URL(req.url ?? "/", "http://localhost");
      if (url.pathname !== "/ws" || !this.wss) return;
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.wss?.emit("connection", ws, req);
      });
    });

    setInterval(() => this.checkStale(), Math.max(5000, Math.floor(config.staleMs / 2))).unref();
  }

  private onConnection(ws: WebSocket): void {
    let turtle: Turtle | null = null;
    const authTimer = setTimeout(() => {
      if (!turtle) ws.close(4001, "hello timeout");
    }, 10000);

    ws.on("message", (raw) => {
      let msg: any;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }

      if (msg.type === "hello") {
        const found = authenticate(String(msg.id ?? ""), String(msg.secret ?? ""));
        if (!found) {
          ws.send(JSON.stringify({ v: 1, type: "error", error: "authentication failed" }));
          ws.close(4003, "authentication failed");
          return;
        }
        turtle = found;
        clearTimeout(authTimer);
        const previous = this.connections.get(turtle.id);
        if (previous && previous.ws !== ws) previous.ws.close(4002, "replaced");
        this.connections.set(turtle.id, { ws, turtle, alive: true });
        turtle.lastSeen = Date.now();
        turtle.state = "connected";
        turtle.pose = msg.pose ?? turtle.pose;
        turtle.fuel = msg.fuel ?? turtle.fuel;
        turtle.inventory = msg.inventory ?? turtle.inventory;
        if (typeof msg.missionId === "string") turtle.missionId = msg.missionId;
        if (typeof msg.state === "string") turtle.state = msg.state;
        this.sendRaw(ws, JSON.stringify({
          v: 1,
          type: "welcome",
          turtleId: turtle.id,
          station: store.data.stations[turtle.stationId],
          config: {
            reserve: config.reserve,
            maxTripBlocks: config.maxTripBlocks,
            maxVeinBlocks: config.maxVeinBlocks,
            maxRadius: config.maxRadius,
            maxDepth: config.maxDepth,
            heartbeatMs: config.heartbeatMs,
          },
          serverTime: Date.now(),
          mission: this.missionFor(turtle),
        }));
        store.event(turtle.id, "connected", { fw: msg.fw, missionId: msg.missionId });
        store.save();
        // The turtle may be mid-mission after a reboot; re-offer it. The
        // command is idempotent, so a duplicate does not restart work.
        setTimeout(() => this.reoffer(turtle!), 250);
        return;
      }

      if (!turtle) return;

      switch (msg.type) {
        case "heartbeat":
          this.touch(turtle, msg);
          break;
        case "progress":
          this.onProgress(turtle, msg);
          break;
        case "ack":
          this.onAck(turtle, msg);
          break;
        case "result":
          this.onResult(turtle, msg);
          break;
        case "event": {
          const kind = String(msg.kind ?? "event");
          if (kind === "ore" && msg.data && typeof msg.data === "object") {
            const d = msg.data as Record<string, unknown>;
            const x = Number(d.x);
            const y = Number(d.y);
            const z = Number(d.z);
            const name = String(d.name ?? "");
            if (Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z) && name) {
              store.markOre(turtle.stationId, { x, y, z, name });
            }
          }
          store.event(turtle.id, kind, msg.data ?? msg);
          break;
        }
        case "pong":
          break;
        default:
          break;
      }
    });

    ws.on("close", () => {
      clearTimeout(authTimer);
      if (turtle) {
        const conn = this.connections.get(turtle.id);
        if (conn?.ws === ws) {
          this.connections.delete(turtle.id);
          turtle.state = "stale";
          store.event(turtle.id, "disconnected", {});
          store.save();
        }
      }
    });

    ws.on("error", () => {
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    });
  }

  private touch(turtle: Turtle, msg: any): void {
    turtle.lastSeen = Date.now();
    if (msg.pose) turtle.pose = msg.pose as Pose;
    if (typeof msg.fuel === "number" || msg.fuel === "unlimited") turtle.fuel = msg.fuel;
    if (Array.isArray(msg.inventory)) turtle.inventory = msg.inventory as InventoryItem[];
    if (typeof msg.state === "string") turtle.state = msg.state;
    if (typeof msg.missionId === "string" || msg.missionId === null) turtle.missionId = msg.missionId;
    store.save();
  }

  private onProgress(turtle: Turtle, msg: any): void {
    const currentId = turtle.missionId;
    this.touch(turtle, msg);
    if (typeof msg.missionId !== "string") {
      turtle.missionId = currentId;
      store.save();
      return;
    }
    const mission = store.data.missions[msg.missionId];
    if (
      !mission ||
      mission.turtleId !== turtle.id ||
      mission.state === "done" ||
      mission.state === "failed" ||
      mission.state === "paused"
    ) {
      // A late queued message must not resurrect an old or paused mission.
      turtle.missionId = currentId;
      store.save();
      return;
    }
    mission.state = "active";
    mission.progress = (msg.progress as Progress) ?? mission.progress;
    if (msg.stats) mission.stats = { ...mission.stats, ...msg.stats };
    mission.updatedAt = Date.now();
    store.save();
  }

  private onAck(turtle: Turtle, msg: any): void {
    const id = String(msg.id ?? "");
    const pending = this.pending.get(id);
    if (pending && pending.turtleId === turtle.id) {
      clearTimeout(pending.timer);
      this.pending.delete(id);
    }
  }

  private onResult(turtle: Turtle, msg: any): void {
    const currentId = turtle.missionId;
    const id = String(msg.id ?? "");
    const pending = this.pending.get(id);
    if (pending) {
      clearTimeout(pending.timer);
      this.pending.delete(id);
    }
    this.touch(turtle, msg);
    const missionId = typeof msg.missionId === "string" ? msg.missionId : currentId;
    const mission = missionId ? store.data.missions[missionId] : undefined;
    if (!mission || mission.turtleId !== turtle.id) {
      turtle.missionId = currentId;
      store.save();
      return;
    }
    if (mission.state === "done" || mission.state === "failed") {
      // Duplicate or late result; do not touch the mission or the current id.
      turtle.missionId = currentId;
      store.save();
      return;
    }

    const isCurrent = currentId === mission.id;
    const status = msg.status === "done" ? "done" : msg.status === "paused" ? "paused" : "failed";
    mission.state = status;
    mission.updatedAt = Date.now();
    if (msg.stats) mission.stats = { ...mission.stats, ...msg.stats };
    if (msg.progress) mission.progress = msg.progress;
    if (status === "paused") {
      if (isCurrent) {
        turtle.missionId = mission.id;
        turtle.state = "paused";
      }
    } else if (isCurrent) {
      turtle.missionId = null;
      turtle.state = "idle";
    }
    if (!isCurrent) turtle.missionId = currentId;
    store.event(turtle.id, "mission_result", { status, error: msg.error ?? null, missionId: mission.id });
    store.save();
  }

  private missionFor(turtle: Turtle): Mission | null {
    if (turtle.missionId) {
      const mission = store.data.missions[turtle.missionId];
      if (mission && (mission.state === "active" || mission.state === "offered")) return mission;
    }
    return null;
  }

  private reoffer(turtle: Turtle): void {
    const conn = this.connections.get(turtle.id);
    if (!conn) return;
    if (turtle.role !== "miner" && turtle.role !== "lumberjack") return;
    const station = store.data.stations[turtle.stationId];
    if (!station) return;
    if (turtle.state === "paused" || turtle.state === "halted") return;

    const current = turtle.missionId ? store.data.missions[turtle.missionId] : undefined;
    if (current && (current.state === "paused" || current.state === "done" || current.state === "failed")) {
      return;
    }
    if (!current) {
      // Only auto-start the first mission. After a done/failed mission the
      // operator starts the next one from the dashboard.
      const hasHistory = Object.values(store.data.missions).some((m) => m.turtleId === turtle.id);
      if (hasHistory) return;
    }

    const mission = ensureMission(turtle, station);
    if (mission.state === "paused") return;
    mission.state = "active";
    turtle.missionId = mission.id;
    store.save();
    this.sendCommand(turtle.id, "startMission", { mission: { id: mission.id, spec: mission.spec } });
  }

  sendCommand(turtleId: string, op: string, extra: Record<string, unknown> = {}): boolean {
    const conn = this.connections.get(turtleId);
    if (!conn) return false;
    const id = randomUUID();
    const message = JSON.stringify({ v: 1, type: "command", id, seq: ++this.seq, op, ...extra });
    this.sendRaw(conn.ws, message);
    const timer = setTimeout(() => this.retry(id), 8000);
    this.pending.set(id, { turtleId, message, timer, retried: false });
    return true;
  }

  private retry(id: string): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    if (pending.retried) {
      this.pending.delete(id);
      return;
    }
    pending.retried = true;
    const conn = this.connections.get(pending.turtleId);
    if (conn) this.sendRaw(conn.ws, pending.message);
    pending.timer = setTimeout(() => this.retry(id), 12000);
  }

  abort(turtleId: string): boolean {
    const turtle = store.data.turtles[turtleId];
    if (!turtle) return false;
    const mission = turtle.missionId ? store.data.missions[turtle.missionId] : undefined;
    if (mission && (mission.state === "paused" || mission.state === "offered")) {
      // There is no running trip to recall, so fail it on the server now.
      mission.state = "failed";
      mission.updatedAt = Date.now();
      turtle.missionId = null;
      turtle.state = "idle";
      store.event(turtle.id, "mission_result", { status: "failed", error: "aborted", missionId: mission.id });
      store.save();
      return true;
    }
    return this.sendCommand(turtleId, "abort");
  }

  returnHome(turtleId: string): boolean {
    const turtle = store.data.turtles[turtleId];
    const mission = turtle?.missionId ? store.data.missions[turtle.missionId] : undefined;
    if (mission && (mission.state === "paused" || mission.state === "offered")) return true;
    return this.sendCommand(turtleId, "returnHome");
  }

  start(turtleId: string): boolean {
    const turtle = store.data.turtles[turtleId];
    const station = turtle ? store.data.stations[turtle.stationId] : undefined;
    if (!turtle || !station || (turtle.role !== "miner" && turtle.role !== "lumberjack")) return false;
    const mission = ensureMission(turtle, station);
    mission.state = "active";
    turtle.missionId = mission.id;
    store.save();
    return this.sendCommand(turtleId, "startMission", { mission: { id: mission.id, spec: mission.spec } });
  }

  ping(turtleId: string): boolean {
    if (!store.data.turtles[turtleId]) return false;
    return this.sendCommand(turtleId, "ping");
  }

  setLabel(turtleId: string, label: string): boolean {
    const turtle = store.data.turtles[turtleId];
    if (!turtle) return false;
    const clean = label.trim().slice(0, 40);
    turtle.label = clean || undefined;
    store.event(turtle.id, "renamed", { label: turtle.label ?? null });
    store.save();
    return true;
  }

  setRole(turtleId: string, role: string): boolean {
    const turtle = store.data.turtles[turtleId];
    if (!turtle) return false;
    if (!["miner", "lumberjack", "hauler", "unassigned"].includes(role)) return false;
    turtle.role = role as TurtleRole;
    store.event(turtle.id, "role_changed", { role });
    store.save();
    return true;
  }

  private sendRaw(ws: WebSocket, message: string): void {
    try {
      if (ws.readyState === WebSocket.OPEN) ws.send(message);
    } catch {
      /* the close handler will mark it stale */
    }
  }

  private checkStale(): void {
    const now = Date.now();
    for (const [id, conn] of this.connections) {
      if (now - conn.turtle.lastSeen > config.staleMs) {
        conn.ws.close(4004, "heartbeat timeout");
        this.connections.delete(id);
        conn.turtle.state = "stale";
        store.save();
      }
    }
    for (const turtle of Object.values(store.data.turtles)) {
      if (this.connections.has(turtle.id)) continue;
      if (turtle.state !== "stale" && now - turtle.lastSeen > config.staleMs) {
        turtle.state = "stale";
        store.save();
      }
    }
  }

  snapshot(): Snapshot {
    const now = Date.now();
    const turtles = Object.values(store.data.turtles).map(publicTurtle);
    const online = [...this.connections.keys()];
    const allMissions = Object.values(store.data.missions);
    const missions = allMissions
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, 200)
      .map(missionSummary);

    const oreTotals = new Map<string, number>();
    const oreCounts: Record<string, number> = {};
    const oreRecent: { x: number; y: number; z: number; name: string; stationId: string }[] = [];
    let ores = 0;
    for (const [stationId, map] of Object.entries(store.data.maps)) {
      const cells = Object.values(map.ores ?? {});
      oreCounts[stationId] = cells.length;
      ores += cells.length;
      for (const cell of cells) {
        oreTotals.set(cell.name, (oreTotals.get(cell.name) ?? 0) + 1);
        oreRecent.push({ ...cell, stationId });
      }
    }

    const tallies: OreTally[] = [...oreTotals.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count);

    const publicConfig: PublicConfig = {
      port: config.port,
      sectorHalf: config.sectorHalf,
      topWorldY: config.topWorldY,
      bottomWorldY: config.bottomWorldY,
      layerStep: config.layerStep,
      branchSpacing: config.branchSpacing,
      reserve: config.reserve,
      maxTripBlocks: config.maxTripBlocks,
      maxVeinBlocks: config.maxVeinBlocks,
      maxRadius: config.maxRadius,
      maxDepth: config.maxDepth,
      baseX: config.baseX,
      baseY: config.baseY,
      baseZ: config.baseZ,
      stationSpacing: config.stationSpacing,
      heartbeatMs: config.heartbeatMs,
      staleMs: config.staleMs,
      adminRequired: Boolean(config.adminToken),
      publish: config.publish,
      githubRepo: config.githubRepo,
      releaseTag: config.releaseTag,
    };

    return {
      serverTime: now,
      tunnelUrl: this.tunnelUrl,
      online,
      config: publicConfig,
      counts: {
        turtles: turtles.length,
        online: online.length,
        miners: turtles.filter((turtle) => turtle.role === "miner").length,
        lumberjacks: turtles.filter((turtle) => turtle.role === "lumberjack").length,
        activeMissions: missions.filter((mission) => mission.state === "active" || mission.state === "offered").length,
        pausedMissions: missions.filter((mission) => mission.state === "paused").length,
        failedMissions: missions.filter(
          (mission) => mission.state === "failed" && now - mission.updatedAt < 86_400_000,
        ).length,
        ores,
        blocks: missions.reduce((sum, mission) => sum + mission.stats.blocks, 0),
        trips: missions.reduce((sum, mission) => sum + mission.stats.trips, 0),
      },
      turtles,
      stations: Object.values(store.data.stations),
      missions,
      events: store.data.events.slice(-200).reverse(),
      ores: tallies,
      oreRecent: oreRecent.slice(-80),
      oreCounts,
    };
  }
}

export const hub = new Hub();
