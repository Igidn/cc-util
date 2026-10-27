import http, { type IncomingMessage, type Server, type ServerResponse } from "node:http";
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";
import { hub } from "./hub.js";
import { mapForMission } from "./map.js";
import { register } from "./registry.js";
import { store } from "./store.js";

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
        const ok =
          op === "start"
            ? hub.start(id)
            : op === "abort"
              ? hub.abort(id)
              : op === "return"
                ? hub.returnHome(id)
                : hub.ping(id);
        json(res, ok ? 200 : 409, { ok });
        return;
      }

      const edit = url.pathname.match(/^\/api\/turtles\/([^/]+)\/(label|role)$/);
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
            : hub.setRole(id, String(body.role ?? ""));
        json(res, ok ? 200 : 400, { ok });
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

  return server;
}
