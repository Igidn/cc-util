import type { Server } from "node:http";
import { Server as SocketServer } from "socket.io";
import { config } from "./config.js";
import { hub } from "./hub.js";
import { store } from "./store.js";

let io: SocketServer | null = null;
let timer: NodeJS.Timeout | null = null;

function broadcast(): void {
  io?.emit("state", hub.snapshot());
}

function schedule(): void {
  if (timer) return;
  timer = setTimeout(() => {
    timer = null;
    broadcast();
  }, 250);
}

function tokenFrom(handshake: {
  auth?: Record<string, unknown>;
  query?: Record<string, unknown>;
}): string {
  const auth = handshake.auth?.token;
  if (typeof auth === "string" && auth) return auth;
  const query = handshake.query?.token;
  if (typeof query === "string") return query;
  return "";
}

export function attachRealtime(server: Server): void {
  io = new SocketServer(server, {
    path: "/socket.io",
    serveClient: false,
    maxHttpBufferSize: 200_000,
  });

  io.use((socket, next) => {
    if (!config.adminToken) {
      next();
      return;
    }
    if (tokenFrom(socket.handshake) === config.adminToken) {
      next();
      return;
    }
    next(new Error("unauthorized"));
  });

  io.on("connection", (socket) => {
    socket.emit("state", hub.snapshot());
    socket.on("request", () => {
      socket.emit("state", hub.snapshot());
    });
  });

  store.subscribe(schedule);

  // Heartbeats write the store, but a quiet console still deserves a fresh
  // server clock and relative-time baseline.
  setInterval(broadcast, 30_000).unref();
}

export function broadcastState(): void {
  broadcast();
}

export function closeRealtime(): Promise<void> {
  return new Promise((resolve) => {
    if (!io) {
      resolve();
      return;
    }
    io.close(() => resolve());
    io = null;
  });
}
