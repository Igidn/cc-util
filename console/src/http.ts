import http, { type IncomingMessage, type Server, type ServerResponse } from "node:http";
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";
import { hub } from "./hub.js";
import { mapForMission } from "./map.js";
import { register } from "./registry.js";
import { store } from "./store.js";
import { Chest } from "./types.js";
import { acquireShaft, releaseShaft, getShaftStatus, expireStaleLocks } from "./shaft.js";
import { placeChest, listChests, updateChestFill, getStorageChests, getRefuelChest } from "./chests.js";
import { createRequest, listRequests, cancelRequest, assignRequest, deliverRequest } from "./requests.js";

const webDist = path.resolve(config.root, "web", "dist");

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
};

function json(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(data),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(data);
}

function html(res: ServerResponse, status: number, body: string): void {
  res.writeHead(status, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-cache",
    "x-content-type-options": "nosniff",
    "referrer-policy": "same-origin",
    "x-frame-options": "DENY",
  });
  res.end(body);
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {});
      } catch {
        reject(new Error("invalid json"));
      }
    });
    req.on("error", reject);
  });
}

function authorized(req: IncomingMessage, url: URL): boolean {
  if (!config.adminToken) return true;
  const header = req.headers.authorization ?? "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : "";
  return bearer === config.adminToken || url.searchParams.get("token") === config.adminToken;
}

/** Parse a reported world pose, rejecting missing or non-finite coordinates. */
function parsePose(value: unknown): { x: number; y: number; z: number; f: 0 | 1 | 2 | 3 } | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const x = Number(raw.x);
  const y = Number(raw.y);
  const z = Number(raw.z);
  const f = Number(raw.f ?? 0);
  if (![x, y, z, f].every(Number.isFinite)) return null;
  if (![0, 1, 2, 3].includes(f)) return null;
  return { x, y, z, f: f as 0 | 1 | 2 | 3 };
}

function serveFile(res: ServerResponse, file: string, immutable = false): boolean {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile()) return false;
    const ext = path.extname(file).toLowerCase();
    res.writeHead(200, {
      "content-type": MIME[ext] ?? "application/octet-stream",
      "content-length": stat.size,
      "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
      "x-content-type-options": "nosniff",
    });
    fs.createReadStream(file).pipe(res);
    return true;
  } catch {
    return false;
  }
}

function notBuiltPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cc-util console</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100svh; display:grid; place-items:center;
    background:oklch(0.145 0.012 105); color:oklch(0.92 0.012 95);
    font:15px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
  main { max-width:560px; padding:40px; }
  h1 { font-size:22px; letter-spacing:-0.02em; margin:0 0 8px; }
  p { color:oklch(0.66 0.015 100); }
  code { color:oklch(0.79 0.145 78); background:oklch(0.22 0.014 105);
    padding:3px 6px; border-radius:4px; }
  pre { background:oklch(0.19 0.014 105); border:1px solid oklch(0.305 0.018 105);
    padding:16px; border-radius:8px; overflow:auto; }
  a { color:oklch(0.79 0.145 78); }
</style>
</head>
<body>
<main>
  <h1>Console frontend is not built</h1>
  <p>The Node API is running, but <code>console/web/dist</code> does not exist yet.</p>
  <p>For development, run the API and Vite together:</p>
  <pre>cd console
npm run dev</pre>
  <p>Then open <a href="http://127.0.0.1:5173">http://127.0.0.1:5173</a>.</p>
  <p>For a single production server:</p>
  <pre>cd console
npm run build
npm start</pre>
</main>
</body>
</html>`;
}

function serveApp(req: IncomingMessage, res: ServerResponse, url: URL): boolean {
  if (req.method !== "GET" && req.method !== "HEAD") return false;

  if (fs.existsSync(webDist)) {
    const pathname = decodeURIComponent(url.pathname);
    const target = path.resolve(webDist, `.${pathname}`);
    if (target.startsWith(webDist) && fs.existsSync(target) && fs.statSync(target).isFile()) {
      return serveFile(res, target, pathname.startsWith("/assets/"));
    }
    const index = path.join(webDist, "index.html");
    if (fs.existsSync(index)) {
      return serveFile(res, index);
    }
  }

  if (url.pathname === "/") {
    html(res, 200, notBuiltPage());
    return true;
  }
  return false;
}

export function createServer(): Server {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    try {
      if (req.method === "GET" && url.pathname === "/api/health") {
        json(res, 200, {
          ok: true,
          uptime: process.uptime(),
          tunnelUrl: hub.tunnelUrl,
          turtles: Object.keys(store.data.turtles).length,
        });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/tunnel") {
        json(res, 200, { url: hub.tunnelUrl });
        return;
      }

      if (req.method === "POST" && url.pathname === "/api/register") {
        const body = await readBody(req);
        const result = register(body);
        if (!result.ok) {
          json(res, 400, { ok: false, error: result.error });
          return;
        }
        json(res, 200, {
          ok: true,
          id: result.turtle.id,
          station: result.station,
          server: hub.tunnelUrl,
          protocol: 1,
        });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/state") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        json(res, 200, hub.snapshot());
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/export") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const data = JSON.stringify(store.data, null, 2);
        res.writeHead(200, {
          "content-type": "application/json; charset=utf-8",
          "content-length": Buffer.byteLength(data),
          "content-disposition": `attachment; filename="cc-util-state-${new Date()
            .toISOString()
            .slice(0, 10)}.json"`,
          "cache-control": "no-store",
        });
        res.end(data);
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/map") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const missionId = url.searchParams.get("missionId") ?? "";
        const mission = missionId ? store.data.missions[missionId] : undefined;
        if (!mission) {
          json(res, 404, { ok: false, error: "unknown mission" });
          return;
        }
        json(res, 200, mapForMission(mission));
        return;
      }

      const control = url.pathname.match(
        /^\/api\/turtles\/([^/]+)\/(start|abort|return|ping)$/,
      );
      if (req.method === "POST" && control) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(control[1]);
        const op = control[2];
        if (op === "start") {
          const result = hub.start(id);
          json(res, result.ok ? 200 : 409, result);
          return;
        }
        const ok =
          op === "abort"
            ? hub.abort(id)
            : op === "return"
              ? hub.returnHome(id)
              : hub.ping(id);
        json(res, ok ? 200 : 409, { ok });
        return;
      }

      const edit = url.pathname.match(/^\/api\/turtles\/([^/]+)\/(label|role|station)$/);
      if (req.method === "POST" && edit) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(edit[1]);
        const body = (await readBody(req)) as Record<string, unknown>;
        const ok =
          edit[2] === "label"
            ? hub.setLabel(id, String(body.label ?? ""))
            : edit[2] === "role"
              ? hub.setRole(id, String(body.role ?? ""))
              : hub.setStation(id, String(body.stationId ?? ""));
        json(res, ok ? 200 : 400, {
          ok,
          ...(ok
            ? {}
            : {
                error:
                  edit[2] === "station"
                    ? "station change rejected: unknown station or an active mission"
                    : "update rejected",
              }),
        });
        return;
      }

      // ---- Role assignment (turtle blocks on this during install) ----
      const roleReq = url.pathname.match(/^\/api\/turtles\/([^/]+)\/role-request$/);
      if (req.method === "POST" && roleReq) {
        const body = (await readBody(req)) as Record<string, unknown>;
        const turtleId = decodeURIComponent(roleReq[1]);
        const turtle = store.data.turtles[turtleId];
        if (!turtle) {
          json(res, 404, { ok: false, error: "unknown turtle" });
          return;
        }
        // Mark as pending role assignment; installer polls until role is set.
        store.event(turtleId, "role_requested", { computerId: body.computerId, label: body.label });
        store.save();
        json(res, 200, { ok: true, pending: true });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/turtles/pending") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const pending = Object.values(store.data.turtles).filter(
          (t) => t.role === "unassigned",
        );
        json(res, 200, { ok: true, turtles: pending });
        return;
      }

      const assignRole = url.pathname.match(/^\/api\/turtles\/([^/]+)\/assign-role$/);
      if (req.method === "POST" && assignRole) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(assignRole[1]);
        const body = (await readBody(req)) as Record<string, unknown>;
        const stationId =
          typeof body.stationId === "string" && body.stationId ? body.stationId : undefined;
        if (stationId && !store.data.stations[stationId]) {
          json(res, 400, { ok: false, error: "unknown station" });
          return;
        }
        const ok = hub.assignRole(id, String(body.role ?? ""), stationId);
        json(res, ok ? 200 : 409, {
          ok,
          ...(ok ? {} : { error: "role or station change rejected" }),
        });
        return;
      }

      const roleStatus = url.pathname.match(/^\/api\/turtles\/([^/]+)\/role-status$/);
      if (req.method === "GET" && roleStatus) {
        const id = decodeURIComponent(roleStatus[1]);
        const turtle = store.data.turtles[id];
        if (!turtle) {
          json(res, 404, { ok: false, error: "unknown turtle" });
          return;
        }
        json(res, 200, {
          ok: true,
          role: turtle.role,
          station: store.data.stations[turtle.stationId] ?? null,
        });
        return;
      }

      // ---- Chests ----
      // Turtles read chest positions over HTTP (they have no admin token), so
      // these GETs stay open like the shaft status and station geometry routes.
      if (req.method === "GET" && url.pathname === "/api/chests") {
        const stationId = url.searchParams.get("stationId") ?? undefined;
        json(res, 200, { ok: true, chests: listChests(stationId) });
        return;
      }

      const chestStation = url.pathname.match(/^\/api\/chests\/([^/]+)$/);
      if (req.method === "GET" && chestStation) {
        const stationId = decodeURIComponent(chestStation[1]);
        json(res, 200, { ok: true, chests: listChests(stationId) });
        return;
      }

      if (req.method === "POST" && url.pathname === "/api/chests") {
        const body = (await readBody(req)) as Record<string, unknown>;
        const chest = body as Chest;
        if (!chest || typeof chest.id !== "string" || !chest.stationId || !chest.kind || !chest.pose) {
          json(res, 400, { ok: false, error: "invalid chest" });
          return;
        }
        placeChest(chest);
        json(res, 200, { ok: true, chestId: chest.id });
        return;
      }

      if (req.method === "POST" && url.pathname === "/api/chests/fill") {
        const body = (await readBody(req)) as Record<string, unknown>;
        const chestId = String(body.chestId ?? "");
        const fillPercent = Number(body.fillPercent);
        if (!chestId || !Number.isFinite(fillPercent)) {
          json(res, 400, { ok: false, error: "invalid fill update" });
          return;
        }
        const updated = updateChestFill(chestId, fillPercent);
        if (!updated) {
          json(res, 404, { ok: false, error: "chest not found" });
          return;
        }
        json(res, 200, { ok: true, chest: updated });
        return;
      }

      // ---- Item requests ----
      if (req.method === "POST" && url.pathname === "/api/requests") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const body = (await readBody(req)) as Record<string, unknown>;
        const stationId = String(body.stationId ?? "");
        const requestedBy = String(body.requestedBy ?? "");
        const itemName = String(body.itemName ?? "");
        const count = Number(body.count);
        if (!stationId || !requestedBy || !itemName || !Number.isFinite(count) || count <= 0) {
          json(res, 400, { ok: false, error: "invalid request" });
          return;
        }
        const request = createRequest(stationId, requestedBy, itemName, count);
        json(res, 200, { ok: true, request });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/requests") {
        // Turtles poll for work over HTTP without an admin token.
        const stationId = url.searchParams.get("stationId") ?? undefined;
        const status = url.searchParams.get("status") as ("pending" | "assigned" | "delivered" | "cancelled") | undefined;
        json(res, 200, { ok: true, requests: listRequests(stationId, status) });
        return;
      }

      const cancelReq = url.pathname.match(/^\/api\/requests\/([^/]+)\/cancel$/);
      if (req.method === "POST" && cancelReq) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(cancelReq[1]);
        const request = cancelRequest(id);
        if (!request) {
          json(res, 404, { ok: false, error: "request not found or not cancellable" });
          return;
        }
        json(res, 200, { ok: true, request });
        return;
      }

      const assignReq = url.pathname.match(/^\/api\/requests\/([^/]+)\/assign$/);
      if (req.method === "POST" && assignReq) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(assignReq[1]);
        const body = (await readBody(req)) as Record<string, unknown>;
        const haulerId = String(body.haulerId ?? "");
        if (!haulerId) {
          json(res, 400, { ok: false, error: "haulerId required" });
          return;
        }
        const request = assignRequest(id, haulerId);
        if (!request) {
          json(res, 409, { ok: false, error: "request not found or not pending" });
          return;
        }
        json(res, 200, { ok: true, request });
        return;
      }

      const deliverReq = url.pathname.match(/^\/api\/requests\/([^/]+)\/deliver$/);
      if (req.method === "POST" && deliverReq) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(deliverReq[1]);
        const request = deliverRequest(id);
        if (!request) {
          json(res, 404, { ok: false, error: "request not found" });
          return;
        }
        json(res, 200, { ok: true, request });
        return;
      }

      // ---- Shaft queuing ----
      const shaftAcquire = url.pathname.match(/^\/api\/shaft\/([^/]+)\/acquire$/);
      if (req.method === "POST" && shaftAcquire) {
        const body = (await readBody(req)) as Record<string, unknown>;
        const stationId = decodeURIComponent(shaftAcquire[1]);
        const turtleId = String(body.turtleId ?? "");
        if (!turtleId) {
          json(res, 400, { ok: false, error: "turtleId required" });
          return;
        }
        const result = acquireShaft(stationId, turtleId);
        if ("rejected" in result) {
          json(res, 429, { ok: false, reason: result.reason });
          return;
        }
        json(res, 200, { ok: true, ...result });
        return;
      }

      const shaftRelease = url.pathname.match(/^\/api\/shaft\/([^/]+)\/release$/);
      if (req.method === "POST" && shaftRelease) {
        const body = (await readBody(req)) as Record<string, unknown>;
        const stationId = decodeURIComponent(shaftRelease[1]);
        const turtleId = String(body.turtleId ?? "");
        if (!turtleId) {
          json(res, 400, { ok: false, error: "turtleId required" });
          return;
        }
        const result = releaseShaft(stationId, turtleId);
        if (!("ok" in result) || !result.ok) {
          json(res, 409, { ok: false, reason: (result as { reason?: string }).reason });
          return;
        }
        json(res, 200, { ok: true, next: result.next });
        return;
      }

      const shaftStatus = url.pathname.match(/^\/api\/shaft\/([^/]+)\/status$/);
      if (req.method === "GET" && shaftStatus) {
        const stationId = decodeURIComponent(shaftStatus[1]);
        const lock = getShaftStatus(stationId);
        json(res, 200, { ok: true, lock: lock ?? { stationId, holderTurtleId: null, queue: [], acquiredAt: null, expiresAt: null } });
        return;
      }

      // ---- GPS alert / reload ----
      const gpsAlert = url.pathname.match(/^\/api\/stations\/([^/]+)\/gps-alert$/);
      if (req.method === "POST" && gpsAlert) {
        const body = (await readBody(req)) as Record<string, unknown>;
        const stationId = decodeURIComponent(gpsAlert[1]);
        const turtleId = String(body.turtleId ?? "");
        store.event(turtleId || "system", "gps_alert", { stationId });
        store.save();
        json(res, 200, { ok: true, alerted: true });
        return;
      }

      const stationGeometry = url.pathname.match(/^\/api\/stations\/([^/]+)\/geometry$/);
      if (req.method === "POST" && stationGeometry) {
        const stationId = decodeURIComponent(stationGeometry[1]);
        const station = store.data.stations[stationId];
        if (!station) {
          json(res, 404, { ok: false, error: "unknown station" });
          return;
        }
        const body = (await readBody(req)) as Record<string, unknown>;
        const shaftPose = parsePose(body.shaftPose);
        const roomPose = parsePose(body.roomPose);
        const dockPose = parsePose(body.dockPose);
        if (!shaftPose || !roomPose || !dockPose) {
          json(res, 400, { ok: false, error: "invalid station geometry" });
          return;
        }
        // A station built from inside an existing room reports its own level as
        // the "surface": the shaft is then 0-1 blocks tall and miners cannot
        // reserve fuel for the real climb. Reject that instead of saving it.
        if (shaftPose.y <= roomPose.y + 1) {
          json(res, 400, {
            ok: false,
            error: `shaft top Y${shaftPose.y} is not above the room Y${roomPose.y}; start the station builder on the surface`,
          });
          return;
        }
        if (dockPose.y !== roomPose.y) {
          json(res, 400, {
            ok: false,
            error: `dock Y${dockPose.y} must match the room walking level Y${roomPose.y}`,
          });
          return;
        }
        const dockStep = Math.abs(dockPose.x - roomPose.x) + Math.abs(dockPose.z - roomPose.z);
        if (dockStep !== 1) {
          json(res, 400, {
            ok: false,
            error: "dock must be one block from the shaft column",
          });
          return;
        }
        station.shaftPose = shaftPose;
        station.roomPose = roomPose;
        station.dockPose = dockPose;
        station.built = true;
        // The anchor is the room floor; roomPose is the walking level above it.
        station.anchor = { x: roomPose.x, y: roomPose.y - 1, z: roomPose.z };
        store.event("system", "station_geometry", { stationId, shaftPose, roomPose, dockPose });
        store.save();
        json(res, 200, { ok: true, stationId, built: true });
        return;
      }

      const stationReload = url.pathname.match(/^\/api\/stations\/([^/]+)\/reload$/);
      if (req.method === "POST" && stationReload) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const stationId = decodeURIComponent(stationReload[1]);
        const station = store.data.stations[stationId];
        if (!station) {
          json(res, 404, { ok: false, error: "unknown station" });
          return;
        }
        store.event("system", "station_reload", { stationId });
        store.save();
        json(res, 200, { ok: true, stationId });
        return;
      }

      if (url.pathname.startsWith("/api/")) {
        json(res, 404, { ok: false, error: "not found" });
        return;
      }

      if (serveApp(req, res, url)) return;

      json(res, 404, { ok: false, error: "not found" });
    } catch (error) {
      console.error("[http]", error);
      json(res, 500, { ok: false, error: (error as Error).message });
    }
  });

  // Periodically expire shaft locks whose TTL has passed.
  setInterval(() => {
    expireStaleLocks();
  }, 30_000).unref();

  return server;
}
